// HCEngine — 單一攝影機的影音核心（FFmpeg）。
// 一條 RTSP 連線同時供應：畫面（iOS 用 VideoToolbox 硬體解碼）、聲音（16kHz 單聲道）、
// 移動偵測、手機端錄影（含事前預錄、不重新編碼、自動分段、斷電不毀檔）。
#ifndef HCENGINE_H
#define HCENGINE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct HCEngine HCEngine;

// 用 #define（Swift 會匯入成 Int32，可直接和 C 函式的回傳值比較）
#define HC_STATE_CONNECTING 0
#define HC_STATE_PLAYING 1
#define HC_STATE_RETRYING 2
#define HC_STATE_STOPPED 3
#define HC_STATE_AUTH_FAILED 4

#define HC_OK 0
#define HC_ERR_AUTH (-1)
#define HC_ERR_NOT_FOUND (-2)
#define HC_ERR_TIMEOUT (-3)
#define HC_ERR_REFUSED (-4)
#define HC_ERR_NO_VIDEO (-5)
#define HC_ERR_OTHER (-9)

typedef struct {
    void *pixel_buffer;     // iOS：CVPixelBufferRef（借用，要保留請自行 retain）；其他平台為 NULL
    int width;
    int height;
    int64_t pts_us;
} HCVideoFrame;

typedef struct {
    char video_codec[16];   // "h264" / "hevc"
    char audio_codec[16];   // "aac" / "pcm_alaw" / "" ...
    int width;
    int height;
    float fps;              // 實測
    float kbps;             // 實測
    int has_audio;
    int recording;
} HCInfo;

typedef struct {
    void *ctx;
    void (*on_state)(void *ctx, int state, const char *message);
    void (*on_video_frame)(void *ctx, const HCVideoFrame *frame);
    void (*on_audio)(void *ctx, const int16_t *samples, int count);      // 16 kHz 單聲道
    void (*on_motion)(void *ctx, float ratio, int active);                // 開啟偵測時約每秒 5 次
    void (*on_record)(void *ctx, int opened, const char *path, const char *error);
} HCCallbacks;

HCEngine *hc_engine_create(const char *url, HCCallbacks callbacks);
void hc_engine_start(HCEngine *e);
void hc_engine_stop(HCEngine *e);          // 會等執行緒結束；錄影中的檔案會正常收尾
void hc_engine_destroy(HCEngine *e);

void hc_engine_set_video_enabled(HCEngine *e, int enabled);   // 沒人看且沒開偵測時關掉省電
void hc_engine_set_audio_enabled(HCEngine *e, int enabled);
void hc_engine_set_hw_decode(HCEngine *e, int enabled);    // App 回前景時設 1；背景硬體解碼失效會自動改軟體
void hc_engine_set_motion(HCEngine *e, int enabled, int sensitivity /* 1~100 */);

// 開始錄影。stop_after_seconds = 0 代表手動停止；> 0 代表該秒數後自動停止（移動錄影用）。
int  hc_engine_start_recording(HCEngine *e, const char *dir, const char *prefix,
                               int segment_seconds, int stop_after_seconds);
void hc_engine_extend_recording(HCEngine *e, int seconds);
void hc_engine_stop_recording(HCEngine *e);
void hc_engine_get_info(HCEngine *e, HCInfo *out);

// 測試串流能否開啟（新增攝影機時用）。回傳 HC_OK 或 HC_ERR_*。
int hc_probe(const char *url, int timeout_ms, HCInfo *out);

#ifdef __cplusplus
}
#endif
#endif
