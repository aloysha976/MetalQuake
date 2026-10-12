/*
 * snd_avcore.m -- MetalQuake
 *
 * CoreAudio / AVAudioEngine backend for QuakeSpasm-style DMA ring.
 * Replaces the SDL audio device while keeping the exact same contract:
 *   - snd_mix.c paints signed 16-bit stereo into shm->buffer ring,
 *   - this backend drains the ring and feeds AVAudioEngine.
 *
 * Chain: AVAudioPlayerNode -> AVAudioEnvironmentNode -> mainMixerNode.
 * AVAudioEnvironmentNode enables AirPods head tracking (macOS 14+).
 * Quake's own panning mix is preserved unchanged (per-source spatialization
 * is a future stage).
 *
 * Feeding model ([D3] rewrite): self-paced chained scheduling.
 * Each buffer's completionHandler schedules the next exactly when the
 * previous is consumed -> queue depth stays at PREROLL, pacing matches
 * real-time consumption by construction (the old wall-clock budget could
 * underfeed -> silent gaps). A 250ms watchdog revives the chain after
 * stalls/route changes and prints [PERF·A] telemetry every 5 seconds.
 *
 * Thread safety of AVAudioConverter: at most one conversion runs at any
 * moment -- either from a completion handler (previous buffer consumed)
 * or from the watchdog when s_inFlight == 0 (nothing else can be running).
 *
 * Backend switch: cvar s_backend ("av" default, falls back to SDL),
 * dispatched from the SNDDMA_* entry points below.
 */

#include "quakedef.h"

#include "../MetalEngine/mq_log.h" /* [PERF·A] MLog diagnostics */

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <pthread.h>

/* SDL backend (renamed implementations in snd_sdl.c) */
#ifndef MQ_NO_SDL /* [MQ-NATIVE] snd_sdl.c исключён из таргета */
qboolean SNDDMA_SDL_Init (dma_t *dma);
int SNDDMA_SDL_GetDMAPos (void);
void SNDDMA_SDL_Shutdown (void);
void SNDDMA_SDL_LockBuffer (void);
void SNDDMA_SDL_Submit (void);
void SNDDMA_SDL_BlockSound (void);
void SNDDMA_SDL_UnblockSound (void);
#endif

extern cvar_t	s_backend;

/* ======================================================================= */
/* AV backend internals                                                    */
/* ======================================================================= */

static qboolean	av_active = false;
static volatile bool s_avTeardown = false; /* [FIX Q3] handlers stop rescheduling */

static AVAudioEngine		*s_engine = nil;
static AVAudioPlayerNode	*s_player = nil;
static AVAudioEnvironmentNode	*s_env = nil;
static AVAudioFormat		*s_srcFmt = nil;	/* int16 interleaved, snd_mixspeed */
static AVAudioFormat		*s_dstFmt = nil;	/* engine float32 deinterleaved */

static id				 s_routeObserver = nil;
static dispatch_queue_t		 s_watchQueue = nil;
static dispatch_source_t		 s_watchTimer = nil;

#define AV_SRC_FRAMES		512	/* src frames per buffer (~12ms @44.1k) */
#define AV_PREROLL_BUFFERS	3	/* queue depth ~35ms: well below the mixer's
_snd_mixahead (100ms) so the reader never
collides with the writer ([D3c] crackle fix) */

/* [D3c] Ring consistency lock. The classic DMA contract protects the shared
 * ring with SNDDMA_LockBuffer/Submit around snd_mix painting; SDL used
 * SDL_LockAudio for that. Our reader runs on an audio thread, so painting
 * and copying must be mutually exclusive or the copy tears mid-write
 * (heard as crackle/smeared echo). */
static pthread_mutex_t		s_ringMutex;
static pthread_mutex_t		s_convMutex;	/* serializes conversions */

/* pipeline counters ([PERF·A] telemetry) */
static volatile int64_t	 s_schedFrames    = 0;	/* frames handed to the player node */
static volatile int64_t	 s_consumedFrames = 0;	/* frames reported consumed */
static volatile int32_t	 s_inFlight       = 0;	/* scheduled-but-unconsumed buffers */
static volatile int32_t	 s_starved        = 0;	/* conversions that produced nothing */
static volatile int32_t	 s_rebuilds       = 0;
static volatile int	 s_routeRestart = 0;

/* ======================================================================
 * [FIX Q1] Асинхронный лог для аудио-потоков.
 * Watchdog/фидер живут на своих очередях; прямой Con_Printf/MLog оттуда
 * при шатдауне давал дедлок: main держит dispatch_sync(watchQueue)
 * (AV_StopWatchdog), а handler блокирован на доставке лога в главный
 * поток (sink лаунчера -> AppKit). Теперь аудио-потоки только кладут
 * строки в кольцо; дрейн делает главный поток раз в кадр.
 * ====================================================================== */
#define AVLOG_SLOTS 32
#define AVLOG_LEN   256
static char			 s_avlogBuf[AVLOG_SLOTS][AVLOG_LEN];
static volatile int	 s_avlogHead = 0;	/* пишется продюсерами */
static volatile int	 s_avlogTail = 0;	/* читается main */

static void AV_LogAsync (const char *fmt, ...)
{
    int head = s_avlogHead;
    int next = (head + 1) % AVLOG_SLOTS;
    if (next == s_avlogTail)
        return; /* кольцо полно: молча роняем (лучше дедлока) */
    
    va_list ap;
    va_start(ap, fmt);
    q_vsnprintf(s_avlogBuf[head], AVLOG_LEN, fmt, ap);
    va_end(ap);
    
    s_avlogHead = next;
}

/* Вызывается ТОЛЬКО из главного потока (R_Metal_BeginFrame). */
void AV_DrainLogs (void)
{
    while (s_avlogTail != s_avlogHead)
    {
        MLog(MQ_LVL_DEV, "AV·SYNC", "%s", s_avlogBuf[s_avlogTail]);
        s_avlogTail = (s_avlogTail + 1) % AVLOG_SLOTS;
    }
}

static void AV_ConvertAndSchedule (void);
static qboolean AV_BuildAndStartGraph (void);
static void AV_ResetResampler (void);

/* ------------------------------------------------------------------ */
/* Diagnostics                                                         */
/* ------------------------------------------------------------------ */

static void AV_LogWireFormats (const char *when)
{
    if (!s_engine || !s_player || !s_env)
        return;
    
    AVAudioFormat *pf = [s_player outputFormatForBus:0];
    AVAudioFormat *ei = [s_env inputFormatForBus:0];
    AVAudioFormat *mi = [s_engine.mainMixerNode inputFormatForBus:0];
    
    AV_LogAsync("[PERF·A] %s wire: playerOut %.0fHz/%uch/%s | envIn %.0fHz/%uch | mixerIn %.0fHz/%uch",
                when,
                pf ? pf.sampleRate : -1, pf ? (long)pf.channelCount : -1,
                (pf && pf.isInterleaved) ? "ilv" : "ch",
                ei ? ei.sampleRate : -1, ei ? (long)ei.channelCount : -1,
                mi ? mi.sampleRate : -1, mi ? (long)mi.channelCount : -1);
}

static void AV_TelemetryTick (void)
{
    static double t0 = 0;
    static int64_t lastSched = 0, lastCons = 0;
    double now = [NSDate timeIntervalSinceReferenceDate];
    if (t0 <= 0) { t0 = now; return; }
    double dt = now - t0;
    if (dt < 5.0 || !s_dstFmt)
        return;
    
    int64_t queued = s_schedFrames - s_consumedFrames;
    AV_LogAsync("[PERF·A] sched %.0f f/s | consumed %.0f f/s | queued %lld (%.0f ms) | "
                "starved %d | rebuilds %d | inFlight %d",
                (double)(s_schedFrames - lastSched) / dt,
                (double)(s_consumedFrames - lastCons) / dt,
                (long long)queued,
                s_dstFmt.sampleRate > 0 ? (double)queued / s_dstFmt.sampleRate * 1000.0 : 0.0,
                s_starved, s_rebuilds, s_inFlight);
    
    /* [D3d] DMA-loop health: paintedtime must trail ~mixahead ahead of
     * soundtime and BOTH must advance at the same rate; a shrinking gap or
     * frozen soundtime means the painter/reader loop is broken. */
    if (shm)
    {
        static int st_prev = 0;
        static int have_prev = 0;
        int gap = paintedtime - soundtime;
        int st_rate = have_prev ? (int)((soundtime - st_prev) / dt) : 0;
        AV_LogAsync("[PERF·A] dma: soundtime=%d (+%d/s) paintedtime=%d gap=%d (~%d ms)",
                    soundtime, st_rate, paintedtime, gap,
                    shm->speed > 0 ? gap * 1000 / shm->speed : 0);
        st_prev = soundtime;
        have_prev = 1;
    }
    
    lastSched = s_schedFrames;
    lastCons  = s_consumedFrames;
    t0 = now;
}

/* ------------------------------------------------------------------ */
/* Graph lifecycle                                                     */
/* ------------------------------------------------------------------ */

static void AV_TearDownGraph (void)
{
    if (s_player)
        [s_player stop];
    if (s_engine && s_engine.running)
        [s_engine stop];
    s_schedFrames = s_consumedFrames = 0;
    s_inFlight = 0;
    AV_ResetResampler();
}

static qboolean AV_BuildAndStartGraph (void)
{
    NSError *err = nil;
    
    s_dstFmt = [s_engine.mainMixerNode outputFormatForBus:0];
    s_env = [[AVAudioEnvironmentNode alloc] init];
    s_player = [[AVAudioPlayerNode alloc] init];
    
    [s_engine attachNode:s_env];
    [s_engine attachNode:s_player];
    
    /* Keep one uniform wire format through the whole chain. */
    [s_engine connect:s_player to:s_env format:s_dstFmt];
    [s_engine connect:s_env to:s_engine.mainMixerNode format:s_dstFmt];
    
    s_srcFmt = [[AVAudioFormat alloc]
                initWithCommonFormat:AVAudioPCMFormatInt16
                sampleRate:(double)shm->speed
                channels:(AVAudioChannelCount)shm->channels
                interleaved:YES];
    if (!s_srcFmt)
    {
        Con_Printf("[AVCORE] failed to create int16 source format\n");
        return false;
    }
    
    [s_engine prepare];
    if (![s_engine startAndReturnError:&err])
    {
        Con_Printf("AVAudioEngine start failed: %s\n",
                   err.localizedDescription.UTF8String ?
                   err.localizedDescription.UTF8String : "(nil)");
        return false;
    }
    
    AV_LogWireFormats("start");
    
    [s_player play];
    for (int i = 0; i < AV_PREROLL_BUFFERS; i++)
        AV_ConvertAndSchedule(); /* prime-up */
    
    AV_LogAsync("[PERF·A] graph up: src %d Hz int16ilv -> dst %.0f Hz float32, preroll %d x %d frames",
                shm->speed, s_dstFmt.sampleRate, AV_PREROLL_BUFFERS, AV_SRC_FRAMES);
    return true;
}

/* ------------------------------------------------------------------ */
/* Ring drain                                                          */
/* ------------------------------------------------------------------ */

/* Copy the next chunk out of the Quake DMA ring, advancing shm->samplepos.
 *
 * [D3d] UNIT CONTRACT (this was THE reverb/crackle bug): shm->samplepos
 * counts INTERLEAVED SAMPLES (frames * channels), exactly like the SDL
 * driver's paint_audio (snd_sdl.c: "samplepos += len1/(samplebits/8)")
 * and like GetSoundtime() expects (it divides by channels again).
 * Advancing by frames alone made soundtime crawl at half speed, the mixer
 * painted half the needed audio per second, and the reader kept replaying
 * stale ring content -- heard as constant reverb + crackle.
 */
static void AV_TakeSrcChunkRaw (int16_t *dst, int wantFrames)
{
    pthread_mutex_lock(&s_ringMutex);
    
    int	bytesPerSample = shm->samplebits / 8;
    int	bufBytes = shm->samples * bytesPerSample;
    int	wantBytes = wantFrames * shm->channels * bytesPerSample;
    int	pos, toEnd, len1, len2;
    
    pos = shm->samplepos * bytesPerSample;
    if (pos >= bufBytes)
        shm->samplepos = pos = 0;
    
    toEnd = bufBytes - pos;
    len1 = wantBytes;
    len2 = 0;
    if (len1 > toEnd)
    {
        len1 = toEnd;
        len2 = wantBytes - len1;
    }
    
    memcpy(dst, shm->buffer + pos, len1);
    if (len2 > 0)
        memcpy((byte *)dst + len1, shm->buffer, len2);
    
    shm->samplepos += wantFrames * shm->channels; /* interleaved units! */
    while (shm->samplepos >= shm->samples)
        shm->samplepos -= shm->samples;
    
    pthread_mutex_unlock(&s_ringMutex);
}

/*
 * Streaming linear resampler state ([D3c]).
 * Phase persists across buffers: resetting it every buffer produced a phase
 * discontinuity every ~12ms (periodic buzz/"хрип") whenever device rate
 * differed from snd_mixspeed. The prev/cur pair carries the seam.
 */
static double	s_rsPhase = 0.0;	/* fractional position between prev..cur */
static float	s_prevL = 0.f, s_prevR = 0.f;
static float	s_curL  = 0.f, s_curR  = 0.f;
static qboolean	s_rsInit = false;

static void AV_ResetResampler (void)
{
    s_rsPhase = 0.0;
    s_prevL = s_prevR = s_curL = s_curR = 0.f;
    s_rsInit = false;
}

/*
 * Convert one chunk and hand it to the player node.
 *
 * [D3b] AVAudioConverter returned OutputStatus_Error for int16-interleaved
 * -> float32-deinterleaved (channel layout metadata issue), so conversion
 * is done MANUALLY: int16 ring -> float32 deinterleaved, with a streaming
 * linear interpolator when snd_mixspeed differs from the device rate.
 *
 * [D3c] Conversions are serialized with trylock: completion handler and
 * watchdog may both arrive; whoever loses just skips (watchdog recovers).
 *
 * [H1a] Queue-depth cap: repeated Block/Unblock cycles used to stack extra
 * preroll buffers on top of the live chain (queue grew without bound).
 * Now conversions are refused once the chain holds more than PREROLL+2.
 *
 * Accounting: on SUCCESS this function does s_inFlight++ before scheduling;
 * the completion handler does s_inFlight-- before invoking the next
 * conversion. Failure paths leave the counter untouched.
 */
static void AV_ConvertAndSchedule (void)
{
    if (s_avTeardown)
        return;
    if (!av_active || !shm || !shm->buffer ||
        !s_engine.running || !s_player)
        return;
    
    if (s_inFlight >= AV_PREROLL_BUFFERS + 2)
        return; /* queue already deep enough; nothing to top up */
    
    if (pthread_mutex_trylock(&s_convMutex) != 0)
        return; /* another conversion in flight; watchdog will recover */
    
    double	ratio = s_dstFmt.sampleRate / (double)shm->speed;
    AVAudioFrameCount outFrames = (AVAudioFrameCount)(AV_SRC_FRAMES * ratio);
    if (outFrames < 16)
        outFrames = 16;
    
    /* src frames to consume for outFrames outputs (+1 lookahead sample) */
    int	needFrames = (int)(outFrames / ratio) + 2;
    
    static int16_t	*scratch = nil;
    static int	 scratchCap = 0;
    if (scratchCap < needFrames)
    {
        int16_t *ns = (int16_t *) realloc(scratch,
                                          needFrames * shm->channels * sizeof(int16_t));
        if (!ns)
        {
            pthread_mutex_unlock(&s_convMutex);
            return;
        }
        scratch = ns;
        scratchCap = needFrames;
    }
    AV_TakeSrcChunkRaw(scratch, needFrames);
    
    AVAudioPCMBuffer *out =
    [[AVAudioPCMBuffer alloc] initWithPCMFormat:s_dstFmt frameCapacity:outFrames];
    if (!out)
    {
        pthread_mutex_unlock(&s_convMutex);
        return;
    }
    
    float	*L = out.floatChannelData[0];
    float	*R = (s_dstFmt.channelCount > 1) ? out.floatChannelData[1] : L;
    const float gain = 1.0f / 32768.0f;
    
    if (ratio == 1.0)
    {
        /* fast path: straight int16 -> float32 deinterleave */
        for (AVAudioFrameCount i = 0; i < outFrames; i++)
        {
            L[i] = (float)(scratch[i*2]   * gain);
            R[i] = (float)(scratch[i*2+1] * gain);
        }
    }
    else
    {
        const double step = 1.0 / ratio;
        float prevL = s_prevL, prevR = s_prevR;
        float curL  = s_curL,  curR  = s_curR;
        double phase = s_rsPhase;
        int	srcIdx = 0;
        
        if (!s_rsInit && needFrames > 0)
        {	/* seed "cur" with the very first frame of the stream */
            curL = (float)(scratch[0]   * gain);
            curR = (float)(scratch[1]   * gain);
            srcIdx = 1;
            s_rsInit = true;
        }
        
        for (AVAudioFrameCount i = 0; i < outFrames; i++)
        {
            while (phase >= 1.0 && srcIdx < needFrames)
            {
                prevL = curL;
                prevR = curR;
                curL = (float)(scratch[srcIdx*2]   * gain);
                curR = (float)(scratch[srcIdx*2+1] * gain);
                srcIdx++;
                phase -= 1.0;
            }
            float t = (float)((phase >= 1.0) ? 1.0 : phase);
            L[i] = prevL + (curL - prevL) * t;
            R[i] = prevR + (curR - prevR) * t;
            phase += step;
        }
        
        /* drain pending folds so no src frame is lost across chunks
         * (otherwise the stream would drift/pitch up over time) */
        while (phase >= 1.0 && srcIdx < needFrames)
        {
            prevL = curL;
            prevR = curR;
            curL = (float)(scratch[srcIdx*2]   * gain);
            curR = (float)(scratch[srcIdx*2+1] * gain);
            srcIdx++;
            phase -= 1.0;
        }
        
        s_prevL = prevL; s_prevR = prevR;
        s_curL  = curL;  s_curR  = curR;
        s_rsPhase = phase;
    }
    
    out.frameLength = outFrames;
    
    int64_t fl = out.frameLength;
    s_inFlight++;
    [s_player scheduleBuffer:out completionHandler:^{
        s_consumedFrames += fl;
        s_inFlight--;
        if (!s_avTeardown)
            AV_ConvertAndSchedule(); /* keep the chain alive */
    }];
    s_schedFrames += fl;
    
    pthread_mutex_unlock(&s_convMutex);
}

/* Watchdog: revives the chain after stalls (focus loss, route change,
 * transient engine hiccups), processes route restarts, prints telemetry. */
static void AV_StartWatchdog (void)
{
    if (s_watchTimer)
        return;
    s_watchQueue = dispatch_queue_create("mq.audio.avwatch", DISPATCH_QUEUE_SERIAL);
    s_watchTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, s_watchQueue);
    dispatch_source_set_timer(s_watchTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              250 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(s_watchTimer, ^{ @autoreleasepool {
        if (!av_active || !shm)
            return;
        
        AV_TelemetryTick();
        
        if (s_routeRestart)
        {
            s_routeRestart = 0;
            AV_LogAsync("[AVCORE] audio route change, rebuilding graph");
            s_rebuilds++;
            AV_TearDownGraph();
            if (!AV_BuildAndStartGraph())
                AV_LogAsync("[AVCORE] graph rebuild FAILED");
            return;
        }
        
        if (s_inFlight <= 0 && !snd_blocked && s_engine.running)
        {
            AV_LogAsync("[AVCORE] watchdog re-priming chain");
            for (int i = 0; i < AV_PREROLL_BUFFERS; i++)
            {
                int64_t before = s_schedFrames;
                AV_ConvertAndSchedule();
                if (s_schedFrames == before)
                    break; /* conversion failed: retry next tick */
            }
        }
    }});
    dispatch_resume(s_watchTimer);
}

static void AV_StopWatchdog (void)
{
    if (s_routeObserver)
    {
        [[NSNotificationCenter defaultCenter] removeObserver:s_routeObserver];
        s_routeObserver = nil;
    }
    if (s_watchTimer)
    {
        dispatch_source_cancel(s_watchTimer);
        dispatch_sync(s_watchQueue, ^{ s_watchTimer = nil; });
    }
}

/* ------------------------------------------------------------------ */
/* DMA contract                                                        */
/* ------------------------------------------------------------------ */

static qboolean SNDDMA_AV_Init (dma_t *dma)
{
    int	tmp, val;
    
    pthread_mutexattr_t mattr;
    pthread_mutexattr_init(&mattr);
    pthread_mutexattr_settype(&mattr, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&s_ringMutex, &mattr);
    pthread_mutex_init(&s_convMutex, &mattr);
    pthread_mutexattr_destroy(&mattr);
    
    memset ((void *) dma, 0, sizeof(dma_t));
    shm = dma;
    
    shm->samplebits = 16;		/* AV path is always 16-bit signed */
    shm->signed8 = 0;
    shm->speed = (int) snd_mixspeed.value;
    shm->channels = 2;
    tmp = (AV_SRC_FRAMES * shm->channels) * 10;
    if (tmp & (tmp - 1))
    {
        val = 1;
        while (val < tmp)
            val <<= 1;
        tmp = val;
    }
    shm->samples = tmp;
    shm->samplepos = 0;
    shm->submission_chunk = 1;
    
    shm->buffer = (unsigned char *) calloc (1, shm->samples * (shm->samplebits / 8));
    if (!shm->buffer)
    {
        Con_Printf ("[AVCORE] failed allocating ring\n");
        shm = NULL;
        return false;
    }
    
    s_engine = [[AVAudioEngine alloc] init];
    
    __weak AVAudioEngine *weakEngine = s_engine;
    s_routeObserver = [[NSNotificationCenter defaultCenter]
                       addObserverForName:AVAudioEngineConfigurationChangeNotification
                       object:weakEngine
                       queue:nil
                       usingBlock:^(NSNotification *note)
                       {
        s_routeRestart = 1; /* processed by the watchdog */
    }];
    
    if (!AV_BuildAndStartGraph())
    {
        Con_Printf ("[AVCORE] graph setup failed, AV backend unavailable\n");
        AV_TearDownGraph();
        s_engine = nil;
        free (shm->buffer);
        shm->buffer = NULL;
        shm = NULL;
        return false;
    }
    
    av_active = true;
    AV_StartWatchdog();
    
    Con_Printf ("[AVCORE] AVAudioEngine: %.0f Hz float32 out, src %d Hz int16stereo, "
                "ring %d samples\n",
                s_dstFmt.sampleRate, shm->speed, shm->samples);
    Con_Printf ("[AVCORE] spatial: AVAudioEnvironmentNode active "
                "(AirPods head tracking)\n");
    return true;
}

static void SNDDMA_AV_Shutdown (void)
{
    if (!av_active)
        return;
    
    Con_Printf ("Shutting down AVAudioEngine sound "
                "(sched %lld, consumed %lld, starved %d, rebuilds %d)\n",
                (long long)s_schedFrames, (long long)s_consumedFrames,
                s_starved, s_rebuilds);
    s_avTeardown = true;   /* [FIX Q3] handlers become trivial before stop */
    AV_DrainLogs();
    AV_StopWatchdog();
    AV_TearDownGraph();
    s_routeObserver = nil;
    s_engine = nil;		/* releases graph + nodes */
    s_player = nil;
    s_env = nil;
    s_srcFmt = nil;
    s_dstFmt = nil;
    av_active = false;
    
    if (shm)
    {
        if (shm->buffer)
            free (shm->buffer);
        shm->buffer = NULL;
        shm = NULL;
    }
    
    pthread_mutex_destroy(&s_ringMutex);
    pthread_mutex_destroy(&s_convMutex);
}

qboolean SNDDMA_Init (dma_t *dma)
{
    av_active = false;
    
    if (strcasecmp(s_backend.string, "av") != 0)
        Con_Printf ("Unknown s_backend \"%s\" (want av), using av\n",
                    s_backend.string);
#ifndef MQ_NO_SDL
    if (strcasecmp(s_backend.string, "av") == 0)
    {
        if (SNDDMA_AV_Init(dma))
            return true;
        Con_Printf ("s_backend=av failed, falling back to SDL audio\n");
    }
    else if (strcasecmp(s_backend.string, "sdl") != 0)
    {
        Con_Printf ("Unknown s_backend \"%s\" (want av|sdl), using sdl\n",
                    s_backend.string);
    }
    return SNDDMA_SDL_Init(dma);
#else /* [MQ-NATIVE] av — единственный бэкенд */
    if (SNDDMA_AV_Init(dma))
        return true;
    return false;
#endif
}

int SNDDMA_GetDMAPos (void)
{
    if (av_active)
        return shm ? shm->samplepos : 0;
#ifndef MQ_NO_SDL
    return SNDDMA_SDL_GetDMAPos();
#else
    return 0;
#endif
}

void SNDDMA_Shutdown (void)
{
    if (av_active)
    {
        SNDDMA_AV_Shutdown();
        return;
    }
#ifndef MQ_NO_SDL
    SNDDMA_SDL_Shutdown();
#endif
}

void SNDDMA_LockBuffer (void)
{
    if (av_active)
    {
        /* [D3c] protect the ring while snd_mix paints (SDL used
         * SDL_LockAudio here; a torn concurrent memcpy = crackle) */
        pthread_mutex_lock(&s_ringMutex);
        return;
    }
#ifndef MQ_NO_SDL
    SNDDMA_SDL_LockBuffer();
#endif
}

void SNDDMA_Submit (void)
{
    if (av_active)
    {
        pthread_mutex_unlock(&s_ringMutex);
        return;
    }
#ifndef MQ_NO_SDL
    SNDDMA_SDL_Submit();
#endif
}

void SNDDMA_BlockSound (void)
{
    if (av_active)
    {
        [s_player pause];
        return;
    }
#ifndef MQ_NO_SDL
    SNDDMA_SDL_BlockSound();
#endif
}

void SNDDMA_UnblockSound (void)
{
    if (av_active)
    {
        [s_player play];
        /* [H1a] top up to preroll only -- unconditional priming used to
         * stack +PREROLL buffers on every focus flap */
        while (s_inFlight < AV_PREROLL_BUFFERS)
        {
            int64_t before = s_schedFrames;
            AV_ConvertAndSchedule();
            if (s_schedFrames == before)
                break;
        }
        return;
    }
#ifndef MQ_NO_SDL
    SNDDMA_SDL_UnblockSound();
#endif
}
