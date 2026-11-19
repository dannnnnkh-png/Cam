// Linux 上測試 HCEngine（iOS 以外沒有 VideoToolbox，走軟體解碼）
#include "../HomeCam/Engine/HCEngine.h"
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stdlib.h>

typedef struct { int frames, audio_samples, motion_calls, motion_active_calls, opened, closed; float max_ratio; char last_path[1200]; int state; } Stats;
static void on_state(void *c, int s, const char *m) { ((Stats*)c)->state = s; if (s != 1 && s != 0) printf("  state %d %s\n", s, m); }
static void on_video(void *c, const HCVideoFrame *f) { ((Stats*)c)->frames++; (void)f; }
static void on_audio(void *c, const int16_t *x, int n) { ((Stats*)c)->audio_samples += n; (void)x; }
static void on_motion(void *c, float r, int a) { Stats *s = c; s->motion_calls++; if (a) s->motion_active_calls++; if (r > s->max_ratio) s->max_ratio = r; }
static void on_record(void *c, int o, const char *p, const char *err) { Stats *s = c; if (o) s->opened++; else s->closed++; snprintf(s->last_path, sizeof s->last_path, "%s", p); printf("  record %s %s %s\n", o ? "open " : "close", p, err ? err : ""); }

static HCEngine *mk(const char *url, Stats *s) {
    memset(s, 0, sizeof *s);
    HCCallbacks cb = { s, on_state, on_video, on_audio, on_motion, on_record };
    return hc_engine_create(url, cb);
}

int main(void) {
    Stats s; HCInfo info;
    system("rm -rf /tmp/hcrec && mkdir -p /tmp/hcrec");

    puts("[1] probe");
    printf("  file ok=%d ", hc_probe("/tmp/testmedia/cam.mp4", 5000, &info)); printf("%s %dx%d audio=%s\n", info.video_codec, info.width, info.height, info.audio_codec);
    printf("  hevc ok=%d %s audio=%s\n", hc_probe("/tmp/testmedia/hevc.mkv", 5000, &info), info.video_codec, info.audio_codec);
    printf("  missing=%d (expect -2)\n", hc_probe("/tmp/testmedia/none.mp4", 3000, &info));
    printf("  refused=%d (expect -4)\n", hc_probe("rtsp://127.0.0.1:5599/x", 3000, &info));

    puts("[2] live: motion + audio + manual recording w/ segments (cam.mp4)");
    HCEngine *e = mk("/tmp/testmedia/cam.mp4", &s);
    hc_engine_set_motion(e, 1, 60);
    hc_engine_set_audio_enabled(e, 1);
    hc_engine_start(e);
    sleep(2);
    hc_engine_start_recording(e, "/tmp/hcrec", "cam", 3, 0);
    sleep(7);
    system("for f in /tmp/hcrec/cam_*.mov; do cp \"$f\" /tmp/hcrec/crashcopy.mov; break; done");
    hc_engine_stop_recording(e);
    sleep(1);
    hc_engine_get_info(e, &info);
    printf("  frames=%d audio=%d (≈%ds) motion_calls=%d active=%d max_ratio=%.3f fps=%.1f kbps=%.0f rec=%d\n",
           s.frames, s.audio_samples, s.audio_samples / 16000, s.motion_calls, s.motion_active_calls, s.max_ratio, info.fps, info.kbps, info.recording);
    hc_engine_destroy(e);

    puts("[3] motion-style recording: pre-roll + auto stop after 2s (hevc + alaw)");
    e = mk("/tmp/testmedia/hevc_gop.mkv", &s);
    hc_engine_start(e);
    sleep(6);
    hc_engine_start_recording(e, "/tmp/hcrec", "hevc", 600, 2);
    sleep(1);
    hc_engine_extend_recording(e, 2);   // 延長到觸發後約 3 秒
    sleep(4);
    hc_engine_get_info(e, &info);
    printf("  opened=%d closed=%d recording_flag=%d\n", s.opened, s.closed, info.recording);
    hc_engine_destroy(e);

    puts("[4] static scene: no motion");
    e = mk("/tmp/testmedia/static.mp4", &s);
    hc_engine_set_motion(e, 1, 60);
    hc_engine_start(e);
    sleep(4);
    printf("  motion_calls=%d active=%d max_ratio=%.4f\n", s.motion_calls, s.motion_active_calls, s.max_ratio);
    hc_engine_destroy(e);

    puts("[5] stop while recording closes file cleanly");
    e = mk("/tmp/testmedia/cam.mp4", &s);
    hc_engine_start(e);
    sleep(1);
    hc_engine_start_recording(e, "/tmp/hcrec", "stop", 600, 0);
    sleep(3);
    hc_engine_destroy(e);
    printf("  opened=%d closed=%d\n", s.opened, s.closed);
    return 0;
}
