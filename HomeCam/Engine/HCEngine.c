// HCEngine — 見 HCEngine.h
#include "HCEngine.h"

#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#ifdef __APPLE__
#include <CoreVideo/CoreVideo.h>
#include <Libavcodec/avcodec.h>
#include <Libavformat/avformat.h>
#include <Libavutil/avutil.h>
#include <Libavutil/channel_layout.h>
#include <Libavutil/hwcontext.h>
#include <Libavutil/opt.h>
#include <Libavutil/pixdesc.h>
#include <Libswresample/swresample.h>
#else
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/channel_layout.h>
#include <libavutil/hwcontext.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libswresample/swresample.h>
#endif

#define HC_AUDIO_RATE 16000
#define HC_PREROLL_US (4 * 1000000LL)      // 移動錄影會包含觸發前約 4 秒
#define HC_PREROLL_MAX_PKTS 2000
#define HC_READ_TIMEOUT_US (10 * 1000000LL)
#define MOTION_W 96
#define MOTION_H 54

static int64_t now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000LL + ts.tv_nsec / 1000;
}

typedef struct PktNode {
    AVPacket *pkt;
    int64_t t_us;          // 以影像時間軸換算的微秒
    int is_video_key;
    struct PktNode *next;
} PktNode;

struct HCEngine {
    char *url;
    HCCallbacks cb;
    pthread_t thread;
    int thread_started;
    pthread_mutex_t lock;

    volatile int want_run;
    volatile int video_enabled;
    volatile int audio_enabled;
    volatile int motion_enabled;
    volatile int motion_sensitivity;
    volatile int want_hw;          // 前景用硬體解碼；背景 iOS 不允許時自動改軟體解碼
    int using_hw;
    int decode_failures;
    int64_t last_activity_us;
    int64_t open_deadline_us;

    // 錄影指令（由其他執行緒設定，讀取執行緒處理）
    int rec_requested;
    int rec_stop_requested;
    char rec_dir[1024];
    char rec_prefix[64];
    int rec_segment_s;
    int64_t rec_stop_at_us;    // 0 = 不自動停止

    // 讀取執行緒內部狀態
    AVFormatContext *in;
    int vidx, aidx;
    AVCodecContext *vdec, *adec;
    AVBufferRef *hw_device;
    SwrContext *swr;
    AVFrame *frame;
    int need_keyframe;

    // 錄影
    AVFormatContext *out;
    int out_vidx, out_aidx;
    int64_t out_t0_us;
    int64_t out_last_dts[2];
    int64_t seg_start_us;
    char out_path[1200];
    PktNode *pre_head, *pre_tail;
    int pre_count;

    // 移動偵測
    float bg[MOTION_W * MOTION_H];
    int bg_ready;
    int motion_hits;
    int motion_active;
    int64_t last_motion_check_us;

    // 統計
    HCInfo info;
    int64_t stat_t0;
    int stat_frames;
    int64_t stat_bytes;
};

// ---------------------------------------------------------------- 工具

static void emit_state(HCEngine *e, int state, const char *msg) {
    if (e->cb.on_state) e->cb.on_state(e->cb.ctx, state, msg ? msg : "");
}

static int interrupt_cb(void *opaque) {
    HCEngine *e = (HCEngine *)opaque;
    if (!e->want_run) return 1;
    int64_t t = now_us();
    if (e->open_deadline_us && t > e->open_deadline_us) return 1;
    if (!e->open_deadline_us && e->last_activity_us && t - e->last_activity_us > HC_READ_TIMEOUT_US) return 1;
    return 0;
}

static int is_network_url(const char *url) {
    return strncmp(url, "rtsp", 4) == 0 || strncmp(url, "http", 4) == 0;
}

static void set_input_options(AVDictionary **opts, const char *url, int timeout_ms) {
    if (strncmp(url, "rtsp", 4) == 0) {
        char buf[32];
        av_dict_set(opts, "rtsp_transport", "tcp", 0);           // WiFi 下 TCP 不花屏
        snprintf(buf, sizeof buf, "%lld", (long long)timeout_ms * 1000LL);
        av_dict_set(opts, "timeout", buf, 0);
        av_dict_set(opts, "max_delay", "500000", 0);
    }
    av_dict_set(opts, "analyzeduration", "2000000", 0);
    av_dict_set(opts, "probesize", "1000000", 0);
}

static int map_error(int err) {
    if (err == AVERROR_HTTP_UNAUTHORIZED || err == AVERROR_HTTP_FORBIDDEN || err == AVERROR(EACCES)) return HC_ERR_AUTH;
    if (err == AVERROR_HTTP_NOT_FOUND || err == AVERROR(ENOENT)) return HC_ERR_NOT_FOUND;
    if (err == AVERROR_EXIT || err == AVERROR(ETIMEDOUT)) return HC_ERR_TIMEOUT;
    if (err == AVERROR(ECONNREFUSED) || err == AVERROR(EHOSTUNREACH) || err == AVERROR(ENETUNREACH)) return HC_ERR_REFUSED;
    return HC_ERR_OTHER;
}

static const char *error_text(int code) {
    switch (code) {
        case HC_ERR_AUTH: return "帳號或密碼錯誤";
        case HC_ERR_NOT_FOUND: return "串流路徑不存在";
        case HC_ERR_TIMEOUT: return "連線逾時";
        case HC_ERR_REFUSED: return "連不到攝影機";
        case HC_ERR_NO_VIDEO: return "沒有影像";
        default: return "無法開啟串流";
    }
}

// ---------------------------------------------------------------- 預錄緩衝

static void pre_clear(HCEngine *e) {
    PktNode *n = e->pre_head;
    while (n) {
        PktNode *next = n->next;
        av_packet_free(&n->pkt);
        free(n);
        n = next;
    }
    e->pre_head = e->pre_tail = NULL;
    e->pre_count = 0;
}

static void pre_drop_front(HCEngine *e) {
    PktNode *n = e->pre_head;
    if (!n) return;
    e->pre_head = n->next;
    if (!e->pre_head) e->pre_tail = NULL;
    av_packet_free(&n->pkt);
    free(n);
    e->pre_count--;
}

static void pre_push(HCEngine *e, const AVPacket *pkt, int64_t t_us, int is_video_key) {
    PktNode *n = (PktNode *)calloc(1, sizeof(PktNode));
    if (!n) return;
    n->pkt = av_packet_clone(pkt);
    if (!n->pkt) { free(n); return; }
    n->t_us = t_us;
    n->is_video_key = is_video_key;
    if (e->pre_tail) e->pre_tail->next = n; else e->pre_head = n;
    e->pre_tail = n;
    e->pre_count++;
    // 緩衝一定從關鍵畫面開始：若第二個關鍵畫面已經夠舊，丟掉它之前的所有封包
    for (;;) {
        PktNode *second = NULL;
        for (PktNode *p = e->pre_head ? e->pre_head->next : NULL; p; p = p->next) {
            if (p->is_video_key) { second = p; break; }
        }
        if (!second) break;
        if (t_us - second->t_us < HC_PREROLL_US && e->pre_count < HC_PREROLL_MAX_PKTS) break;
        while (e->pre_head != second) pre_drop_front(e);
    }
    if (e->pre_count >= HC_PREROLL_MAX_PKTS * 2) pre_clear(e);   // GOP 極長的保險
    // 開頭若不是關鍵畫面（剛連線時）就丟掉
    while (e->pre_head && !e->pre_head->is_video_key) pre_drop_front(e);
}

// ---------------------------------------------------------------- 錄影

static int64_t pkt_time_us(HCEngine *e, const AVPacket *pkt) {
    int64_t ts = pkt->dts != AV_NOPTS_VALUE ? pkt->dts : pkt->pts;
    if (ts == AV_NOPTS_VALUE) return AV_NOPTS_VALUE;
    return av_rescale_q(ts, e->in->streams[pkt->stream_index]->time_base, AV_TIME_BASE_Q);
}

static void close_output(HCEngine *e, const char *error) {
    if (!e->out) return;
    av_write_trailer(e->out);
    if (!(e->out->oformat->flags & AVFMT_NOFILE)) avio_closep(&e->out->pb);
    avformat_free_context(e->out);
    e->out = NULL;
    if (e->cb.on_record) e->cb.on_record(e->cb.ctx, 0, e->out_path, error);
}

static int audio_copyable(enum AVCodecID id) {
    return id == AV_CODEC_ID_AAC || id == AV_CODEC_ID_PCM_ALAW || id == AV_CODEC_ID_PCM_MULAW;
}

static int open_output(HCEngine *e, int64_t t0_us) {
    char stamp[32];
    time_t t = time(NULL);
    struct tm lt;
    localtime_r(&t, &lt);
    strftime(stamp, sizeof stamp, "%Y%m%d_%H%M%S", &lt);
    mkdir(e->rec_dir, 0700);
    snprintf(e->out_path, sizeof e->out_path, "%s/%s_%s.mov", e->rec_dir, e->rec_prefix, stamp);

    int ret = avformat_alloc_output_context2(&e->out, NULL, "mov", e->out_path);
    if (ret < 0 || !e->out) { e->out = NULL; return -1; }

    AVStream *vin = e->in->streams[e->vidx];
    AVStream *vs = avformat_new_stream(e->out, NULL);
    avcodec_parameters_copy(vs->codecpar, vin->codecpar);
    vs->codecpar->codec_tag = 0;
    if (vin->codecpar->codec_id == AV_CODEC_ID_HEVC)
        vs->codecpar->codec_tag = MKTAG('h', 'v', 'c', '1');     // iPhone 播 H.265 必須是 hvc1
    vs->time_base = vin->time_base;
    e->out_vidx = vs->index;
    e->out_aidx = -1;
    if (e->aidx >= 0 && audio_copyable(e->in->streams[e->aidx]->codecpar->codec_id)) {
        AVStream *ain = e->in->streams[e->aidx];
        AVStream *as = avformat_new_stream(e->out, NULL);
        avcodec_parameters_copy(as->codecpar, ain->codecpar);
        as->codecpar->codec_tag = 0;
        as->time_base = ain->time_base;
        e->out_aidx = as->index;
    }
    ret = avio_open(&e->out->pb, e->out_path, AVIO_FLAG_WRITE);
    if (ret < 0) { avformat_free_context(e->out); e->out = NULL; return -1; }
    AVDictionary *mo = NULL;
    // 分段寫入（fragmented）：App 被系統關掉或沒電時，已錄的部分仍可播放
    av_dict_set(&mo, "movflags", "frag_keyframe+empty_moov+default_base_moof", 0);
    ret = avformat_write_header(e->out, &mo);
    av_dict_free(&mo);
    if (ret < 0) {
        avio_closep(&e->out->pb);
        avformat_free_context(e->out);
        e->out = NULL;
        unlink(e->out_path);
        return -1;
    }
    e->out_t0_us = t0_us;
    e->out_last_dts[0] = e->out_last_dts[1] = AV_NOPTS_VALUE;
    e->seg_start_us = t0_us;
    if (e->cb.on_record) e->cb.on_record(e->cb.ctx, 1, e->out_path, NULL);
    return 0;
}

static void write_packet(HCEngine *e, const AVPacket *src) {
    if (!e->out) return;
    int which, out_idx;
    if (src->stream_index == e->vidx) { which = 0; out_idx = e->out_vidx; }
    else if (src->stream_index == e->aidx && e->out_aidx >= 0) { which = 1; out_idx = e->out_aidx; }
    else return;

    AVStream *ist = e->in->streams[src->stream_index];
    AVStream *ost = e->out->streams[out_idx];
    int64_t pts = src->pts, dts = src->dts;
    if (pts == AV_NOPTS_VALUE) pts = dts;
    if (dts == AV_NOPTS_VALUE) dts = pts;
    if (dts == AV_NOPTS_VALUE) return;
    int64_t off = av_rescale_q(e->out_t0_us, AV_TIME_BASE_Q, ist->time_base);
    pts -= off;
    dts -= off;
    if (dts < 0) return;                         // 比第一個關鍵畫面還早的聲音
    pts = av_rescale_q(pts, ist->time_base, ost->time_base);
    dts = av_rescale_q(dts, ist->time_base, ost->time_base);
    if (e->out_last_dts[which] != AV_NOPTS_VALUE && dts <= e->out_last_dts[which])
        dts = e->out_last_dts[which] + 1;      // 時間戳必須遞增
    if (pts < dts) pts = dts;
    e->out_last_dts[which] = dts;

    AVPacket *p = av_packet_clone(src);
    if (!p) return;
    p->pts = pts;
    p->dts = dts;
    p->duration = av_rescale_q(src->duration, ist->time_base, ost->time_base);
    p->stream_index = out_idx;
    p->pos = -1;
    int ret = av_interleaved_write_frame(e->out, p);
    av_packet_free(&p);
    if (ret < 0) {
        close_output(e, "寫入失敗（儲存空間可能不足）");
        pthread_mutex_lock(&e->lock);
        e->rec_requested = 0;
        pthread_mutex_unlock(&e->lock);
    }
}

// 每個封包都會進來：維護預錄緩衝、處理錄影開始/分段/停止
static void handle_recording(HCEngine *e, const AVPacket *pkt) {
    int is_video = pkt->stream_index == e->vidx;
    int is_key = is_video && (pkt->flags & AV_PKT_FLAG_KEY);
    int64_t t = pkt_time_us(e, pkt);
    if (t == AV_NOPTS_VALUE) return;

    pthread_mutex_lock(&e->lock);
    int stop_req = e->rec_stop_requested;
    int start_req = e->rec_requested;
    int64_t stop_at = e->rec_stop_at_us;
    int seg_s = e->rec_segment_s;
    e->rec_stop_requested = 0;
    pthread_mutex_unlock(&e->lock);

    if (stop_req || (stop_at && now_us() > stop_at)) {
        close_output(e, NULL);
        pthread_mutex_lock(&e->lock);
        e->rec_requested = 0;
        e->rec_stop_at_us = 0;
        pthread_mutex_unlock(&e->lock);
        start_req = 0;
    }

    if (!e->out && start_req && e->pre_head) {
        // 從預錄緩衝的第一個關鍵畫面開始寫
        if (open_output(e, e->pre_head->t_us) == 0) {
            for (PktNode *n = e->pre_head; n && e->out; n = n->next) write_packet(e, n->pkt);
        } else {
            pthread_mutex_lock(&e->lock);
            e->rec_requested = 0;
            pthread_mutex_unlock(&e->lock);
            if (e->cb.on_record) e->cb.on_record(e->cb.ctx, 0, e->out_path, "無法建立錄影檔");
        }
        pre_push(e, pkt, t, is_key);
        if (e->out) write_packet(e, pkt);
        return;
    }

    if (e->out && is_key && seg_s > 0 && t - e->seg_start_us >= (int64_t)seg_s * 1000000LL) {
        close_output(e, NULL);                   // 分段：在關鍵畫面切檔
        open_output(e, t);
    }

    pre_push(e, pkt, t, is_key);
    if (e->out) write_packet(e, pkt);
}

// ---------------------------------------------------------------- 移動偵測

static void motion_feed(HCEngine *e, const uint8_t *luma, int stride, int w, int h, int bpp) {
    if (w < MOTION_W || h < MOTION_H) return;
    float cur[MOTION_W * MOTION_H];
    int bw = w / MOTION_W, bh = h / MOTION_H;
    for (int y = 0; y < MOTION_H; y++) {
        for (int x = 0; x < MOTION_W; x++) {
            // 每格取 4 點平均，降低雜訊
            int sx = x * bw, sy = y * bh, sum = 0;
            for (int k = 0; k < 4; k++) {
                int px = sx + (k & 1) * (bw / 2), py = sy + (k >> 1) * (bh / 2);
                const uint8_t *p = luma + (size_t)py * stride + (size_t)px * bpp;
                sum += bpp == 2 ? p[1] : p[0];   // 10-bit 取高位元組
            }
            cur[y * MOTION_W + x] = sum / 4.0f;
        }
    }
    const int n = MOTION_W * MOTION_H;
    if (!e->bg_ready) {
        memcpy(e->bg, cur, sizeof cur);
        e->bg_ready = 1;
        return;
    }
    int changed = 0;
    for (int i = 0; i < n; i++) {
        float d = cur[i] - e->bg[i];
        if (d > 22.0f || d < -22.0f) changed++;
        e->bg[i] = e->bg[i] * 0.93f + cur[i] * 0.07f;
    }
    float ratio = (float)changed / n;
    int sens = e->motion_sensitivity < 1 ? 1 : (e->motion_sensitivity > 100 ? 100 : e->motion_sensitivity);
    float threshold = 0.004f + (100 - sens) / 100.0f * 0.06f;
    if (ratio > 0.6f) {                       // 開關燈、日夜切換：整個畫面突變 → 重設背景
        memcpy(e->bg, cur, sizeof cur);
        e->motion_hits = 0;
        ratio = 0;
    }
    e->motion_hits = ratio > threshold ? e->motion_hits + 1 : 0;
    int active = e->motion_hits >= 3;
    if (!active && e->motion_active && ratio > threshold / 2) active = 1;   // 遲滯
    e->motion_active = active;
    if (e->cb.on_motion) e->cb.on_motion(e->cb.ctx, ratio, active);
}

static void motion_from_frame(HCEngine *e, AVFrame *f) {
    int64_t t = now_us();
    if (t - e->last_motion_check_us < 200000) return;
    e->last_motion_check_us = t;
#ifdef __APPLE__
    if (f->format == AV_PIX_FMT_VIDEOTOOLBOX) {
        CVPixelBufferRef pb = (CVPixelBufferRef)f->data[3];
        if (!pb || CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return;
        int planar = CVPixelBufferIsPlanar(pb);
        const uint8_t *base = planar ? CVPixelBufferGetBaseAddressOfPlane(pb, 0) : CVPixelBufferGetBaseAddress(pb);
        size_t stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(pb, 0) : CVPixelBufferGetBytesPerRow(pb);
        int w = (int)(planar ? CVPixelBufferGetWidthOfPlane(pb, 0) : CVPixelBufferGetWidth(pb));
        int h = (int)(planar ? CVPixelBufferGetHeightOfPlane(pb, 0) : CVPixelBufferGetHeight(pb));
        int bpp = (w > 0 && stride >= (size_t)w * 2) ? 2 : 1;
        if (base) motion_feed(e, base, (int)stride, w, h, bpp);
        CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
        return;
    }
#endif
    const AVPixFmtDescriptor *d = av_pix_fmt_desc_get((enum AVPixelFormat)f->format);
    if (!d || (d->flags & AV_PIX_FMT_FLAG_RGB) || (d->flags & AV_PIX_FMT_FLAG_HWACCEL)) return;
    int bpp = d->comp[0].depth > 8 ? 2 : 1;
    motion_feed(e, f->data[0], f->linesize[0], f->width, f->height, bpp);
}

// ---------------------------------------------------------------- 解碼

#ifdef __APPLE__
static enum AVPixelFormat get_hw_format(AVCodecContext *ctx, const enum AVPixelFormat *fmts) {
    (void)ctx;
    for (const enum AVPixelFormat *p = fmts; *p != AV_PIX_FMT_NONE; p++)
        if (*p == AV_PIX_FMT_VIDEOTOOLBOX) return *p;
    return fmts[0];                              // 不支援硬體解碼時退回軟體
}
#endif

static int open_video_decoder(HCEngine *e, int hw) {
    avcodec_free_context(&e->vdec);
    av_buffer_unref(&e->hw_device);
    AVStream *vs = e->in->streams[e->vidx];
    const AVCodec *vc = avcodec_find_decoder(vs->codecpar->codec_id);
    if (!vc) return -1;
    e->vdec = avcodec_alloc_context3(vc);
    avcodec_parameters_to_context(e->vdec, vs->codecpar);
    e->vdec->pkt_timebase = vs->time_base;
    e->vdec->flags |= AV_CODEC_FLAG_LOW_DELAY;
    e->using_hw = 0;
#ifdef __APPLE__
    if (hw && av_hwdevice_ctx_create(&e->hw_device, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0) == 0) {
        e->vdec->hw_device_ctx = av_buffer_ref(e->hw_device);
        e->vdec->get_format = get_hw_format;
        e->using_hw = 1;
    }
#else
    (void)hw;
#endif
    if (!e->using_hw) e->vdec->thread_count = 2;
    e->want_hw = e->using_hw;                    // 要求硬體但不可用時不要反覆重開
    e->decode_failures = 0;
    e->need_keyframe = 1;
    return avcodec_open2(e->vdec, vc, NULL) < 0 ? -1 : 0;
}

static int open_decoders(HCEngine *e) {
    if (open_video_decoder(e, e->want_hw) < 0) return -1;

    if (e->aidx >= 0) {
        AVStream *as = e->in->streams[e->aidx];
        const AVCodec *ac = avcodec_find_decoder(as->codecpar->codec_id);
        if (ac) {
            e->adec = avcodec_alloc_context3(ac);
            avcodec_parameters_to_context(e->adec, as->codecpar);
            e->adec->pkt_timebase = as->time_base;
            if (avcodec_open2(e->adec, ac, NULL) < 0) avcodec_free_context(&e->adec);
        }
    }
    return 0;
}

static void decode_failed(HCEngine *e) {
    avcodec_flush_buffers(e->vdec);
    e->need_keyframe = 1;
    if (e->using_hw && ++e->decode_failures >= 5) {
        e->want_hw = 0;                          // 硬體解碼器失效（App 進背景）→ 改軟體
        open_video_decoder(e, 0);
    }
}

static void decode_video(HCEngine *e, const AVPacket *pkt) {
    if (e->using_hw != e->want_hw) open_video_decoder(e, e->want_hw);
    if (!e->vdec) return;
    if (e->need_keyframe) {
        if (!(pkt->flags & AV_PKT_FLAG_KEY)) return;
        e->need_keyframe = 0;
    }
    if (avcodec_send_packet(e->vdec, pkt) < 0) {
        decode_failed(e);
        return;
    }
    for (;;) {
        int r = avcodec_receive_frame(e->vdec, e->frame);
        if (r == AVERROR(EAGAIN) || r == AVERROR_EOF) break;
        if (r < 0) { decode_failed(e); break; }
        e->decode_failures = 0;
        e->stat_frames++;
        if (e->motion_enabled) motion_from_frame(e, e->frame);
        if (e->cb.on_video_frame) {
            HCVideoFrame vf = {0};
#ifdef __APPLE__
            if (e->frame->format == AV_PIX_FMT_VIDEOTOOLBOX) vf.pixel_buffer = e->frame->data[3];
#endif
            vf.width = e->frame->width;
            vf.height = e->frame->height;
            vf.pts_us = e->frame->best_effort_timestamp == AV_NOPTS_VALUE ? 0 :
                av_rescale_q(e->frame->best_effort_timestamp, e->in->streams[e->vidx]->time_base, AV_TIME_BASE_Q);
            e->cb.on_video_frame(e->cb.ctx, &vf);
        }
        av_frame_unref(e->frame);
    }
}

static void decode_audio(HCEngine *e, const AVPacket *pkt) {
    if (!e->adec || avcodec_send_packet(e->adec, pkt) < 0) return;
    while (avcodec_receive_frame(e->adec, e->frame) == 0) {
        if (!e->swr) {
            AVChannelLayout mono = AV_CHANNEL_LAYOUT_MONO;
            AVChannelLayout in_layout;
            if (e->frame->ch_layout.nb_channels > 0) av_channel_layout_copy(&in_layout, &e->frame->ch_layout);
            else av_channel_layout_default(&in_layout, 1);
            int r = swr_alloc_set_opts2(&e->swr, &mono, AV_SAMPLE_FMT_S16, HC_AUDIO_RATE,
                                        &in_layout, (enum AVSampleFormat)e->frame->format, e->frame->sample_rate, 0, NULL);
            av_channel_layout_uninit(&in_layout);
            if (r < 0 || swr_init(e->swr) < 0) { swr_free(&e->swr); av_frame_unref(e->frame); return; }
        }
        int max_out = (int)av_rescale_rnd(e->frame->nb_samples, HC_AUDIO_RATE, e->frame->sample_rate, AV_ROUND_UP) + 64;
        int16_t *buf = (int16_t *)malloc(sizeof(int16_t) * max_out);
        if (buf) {
            uint8_t *outp[1] = {(uint8_t *)buf};
            int n = swr_convert(e->swr, outp, max_out, (const uint8_t **)e->frame->extended_data, e->frame->nb_samples);
            if (n > 0 && e->cb.on_audio) e->cb.on_audio(e->cb.ctx, buf, n);
            free(buf);
        }
        av_frame_unref(e->frame);
    }
}

// ---------------------------------------------------------------- 連線生命週期

static void close_input(HCEngine *e) {
    close_output(e, NULL);
    pre_clear(e);
    avcodec_free_context(&e->vdec);
    avcodec_free_context(&e->adec);
    av_buffer_unref(&e->hw_device);
    swr_free(&e->swr);
    if (e->in) avformat_close_input(&e->in);
    e->bg_ready = 0;
    e->motion_hits = 0;
    if (e->motion_active && e->cb.on_motion) e->cb.on_motion(e->cb.ctx, 0, 0);
    e->motion_active = 0;
}

static int open_input(HCEngine *e) {
    e->in = avformat_alloc_context();
    e->in->interrupt_callback.callback = interrupt_cb;
    e->in->interrupt_callback.opaque = e;
    AVDictionary *opts = NULL;
    set_input_options(&opts, e->url, 8000);
    e->open_deadline_us = now_us() + 15 * 1000000LL;
    int ret = avformat_open_input(&e->in, e->url, NULL, &opts);
    av_dict_free(&opts);
    if (ret < 0) { e->open_deadline_us = 0; return map_error(ret); }
    ret = avformat_find_stream_info(e->in, NULL);
    e->open_deadline_us = 0;
    if (ret < 0) return map_error(ret);
    e->vidx = av_find_best_stream(e->in, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    e->aidx = av_find_best_stream(e->in, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (e->vidx < 0) return HC_ERR_NO_VIDEO;
    if (e->aidx < 0) e->aidx = -1;
    for (unsigned i = 0; i < e->in->nb_streams; i++)
        if ((int)i != e->vidx && (int)i != e->aidx) e->in->streams[i]->discard = AVDISCARD_ALL;
    if (open_decoders(e) < 0) return HC_ERR_OTHER;

    AVCodecParameters *vp = e->in->streams[e->vidx]->codecpar;
    pthread_mutex_lock(&e->lock);
    snprintf(e->info.video_codec, sizeof e->info.video_codec, "%s", avcodec_get_name(vp->codec_id));
    e->info.width = vp->width;
    e->info.height = vp->height;
    e->info.has_audio = e->aidx >= 0;
    if (e->aidx >= 0)
        snprintf(e->info.audio_codec, sizeof e->info.audio_codec, "%s",
                 avcodec_get_name(e->in->streams[e->aidx]->codecpar->codec_id));
    else
        e->info.audio_codec[0] = 0;
    pthread_mutex_unlock(&e->lock);
    e->need_keyframe = 1;
    return HC_OK;
}

static void *run_loop(void *arg) {
    HCEngine *e = (HCEngine *)arg;
    int backoff_ms = 1000;
    int realtime = !is_network_url(e->url);      // 本機檔案（測試用）以實際速度播放
    AVPacket *pkt = av_packet_alloc();
    e->frame = av_frame_alloc();

    while (e->want_run) {
        emit_state(e, HC_STATE_CONNECTING, "連線中");
        int rc = open_input(e);
        if (rc != HC_OK) {
            close_input(e);
            if (!e->want_run) break;
            emit_state(e, rc == HC_ERR_AUTH ? HC_STATE_AUTH_FAILED : HC_STATE_RETRYING, error_text(rc));
            int wait = rc == HC_ERR_AUTH ? 30000 : backoff_ms;
            for (int t = 0; t < wait && e->want_run; t += 100) usleep(100 * 1000);
            backoff_ms = backoff_ms * 2 > 30000 ? 30000 : backoff_ms * 2;
            continue;
        }
        emit_state(e, HC_STATE_PLAYING, "");
        int64_t opened_at = now_us();
        int64_t first_pts_us = AV_NOPTS_VALUE, wall0 = 0;
        e->last_activity_us = now_us();
        e->stat_t0 = now_us();
        e->stat_frames = 0;
        e->stat_bytes = 0;

        while (e->want_run) {
            int ret = av_read_frame(e->in, pkt);
            if (ret < 0) break;
            e->last_activity_us = now_us();
            e->stat_bytes += pkt->size;
            if (pkt->stream_index == e->vidx || pkt->stream_index == e->aidx) {
                if (realtime && pkt->stream_index == e->vidx) {
                    int64_t t = pkt_time_us(e, pkt);
                    if (t != AV_NOPTS_VALUE) {
                        if (first_pts_us == AV_NOPTS_VALUE) { first_pts_us = t; wall0 = now_us(); }
                        int64_t ahead = (t - first_pts_us) - (now_us() - wall0);
                        if (ahead > 0 && ahead < 2000000) usleep((useconds_t)ahead);
                    }
                }
                handle_recording(e, pkt);
                if (pkt->stream_index == e->vidx) {
                    if (e->video_enabled || e->motion_enabled) decode_video(e, pkt);
                    else e->need_keyframe = 1;
                } else if (e->audio_enabled) {
                    decode_audio(e, pkt);
                }
            }
            av_packet_unref(pkt);

            int64_t dt = now_us() - e->stat_t0;
            if (dt > 2000000) {
                pthread_mutex_lock(&e->lock);
                e->info.fps = e->stat_frames * 1e6f / dt;
                e->info.kbps = e->stat_bytes * 8e3f / dt;
                pthread_mutex_unlock(&e->lock);
                e->stat_t0 = now_us();
                e->stat_frames = 0;
                e->stat_bytes = 0;
            }
        }
        close_input(e);   // 錄影中斷線：rec_requested 仍在，重新連上後會自動開新檔續錄
        if (!e->want_run) break;
        if (now_us() - opened_at > 60 * 1000000LL) backoff_ms = 1000;
        emit_state(e, HC_STATE_RETRYING, "串流中斷，重新連線中");
        for (int t = 0; t < (realtime ? 300 : backoff_ms) && e->want_run; t += 100) usleep(100 * 1000);
        backoff_ms = backoff_ms * 2 > 30000 ? 30000 : backoff_ms * 2;
    }
    av_packet_free(&pkt);
    av_frame_free(&e->frame);
    emit_state(e, HC_STATE_STOPPED, "");
    return NULL;
}

// ---------------------------------------------------------------- 公開 API

// 隱私：FFmpeg 日誌可能含帶帳密的網址，一律不輸出（除錯時設環境變數 HC_FFMPEG_LOG）
static void quiet_logs(void) {
    av_log_set_level(getenv("HC_FFMPEG_LOG") ? AV_LOG_WARNING : AV_LOG_QUIET);
}

HCEngine *hc_engine_create(const char *url, HCCallbacks callbacks) {
    quiet_logs();
    HCEngine *e = (HCEngine *)calloc(1, sizeof(HCEngine));
    if (!e) return NULL;
    e->url = strdup(url);
    e->cb = callbacks;
    e->vidx = e->aidx = -1;
    e->video_enabled = 1;
    e->motion_sensitivity = 50;
    e->want_hw = 1;
    pthread_mutex_init(&e->lock, NULL);
    return e;
}

void hc_engine_start(HCEngine *e) {
    if (!e || e->thread_started) return;
    e->want_run = 1;
    if (pthread_create(&e->thread, NULL, run_loop, e) == 0) e->thread_started = 1;
}

void hc_engine_stop(HCEngine *e) {
    if (!e || !e->thread_started) return;
    e->want_run = 0;
    pthread_join(e->thread, NULL);
    e->thread_started = 0;
}

void hc_engine_destroy(HCEngine *e) {
    if (!e) return;
    hc_engine_stop(e);
    pthread_mutex_destroy(&e->lock);
    free(e->url);
    free(e);
}

void hc_engine_set_video_enabled(HCEngine *e, int enabled) { if (e) e->video_enabled = enabled; }
void hc_engine_set_audio_enabled(HCEngine *e, int enabled) { if (e) e->audio_enabled = enabled; }
void hc_engine_set_hw_decode(HCEngine *e, int enabled) { if (e) e->want_hw = enabled; }

void hc_engine_set_motion(HCEngine *e, int enabled, int sensitivity) {
    if (!e) return;
    e->motion_sensitivity = sensitivity;
    if (enabled && !e->motion_enabled) e->bg_ready = 0;
    e->motion_enabled = enabled;
}

int hc_engine_start_recording(HCEngine *e, const char *dir, const char *prefix, int segment_seconds, int stop_after_seconds) {
    if (!e || !dir) return -1;
    pthread_mutex_lock(&e->lock);
    if (e->rec_requested && !e->rec_stop_at_us) {          // 手動錄影中：不被移動錄影覆蓋
        pthread_mutex_unlock(&e->lock);
        return 0;
    }
    snprintf(e->rec_dir, sizeof e->rec_dir, "%s", dir);
    snprintf(e->rec_prefix, sizeof e->rec_prefix, "%s", prefix ? prefix : "rec");
    e->rec_segment_s = segment_seconds;
    int64_t until = stop_after_seconds > 0 ? now_us() + (int64_t)stop_after_seconds * 1000000LL : 0;
    if (e->rec_requested && e->rec_stop_at_us && until) {
        if (until > e->rec_stop_at_us) e->rec_stop_at_us = until;   // 移動中再觸發 → 延長
    } else {
        e->rec_stop_at_us = until;
    }
    e->rec_requested = 1;
    e->rec_stop_requested = 0;
    pthread_mutex_unlock(&e->lock);
    return 0;
}

void hc_engine_extend_recording(HCEngine *e, int seconds) {
    if (!e) return;
    pthread_mutex_lock(&e->lock);
    if (e->rec_requested && e->rec_stop_at_us) {
        int64_t until = now_us() + (int64_t)seconds * 1000000LL;
        if (until > e->rec_stop_at_us) e->rec_stop_at_us = until;
    }
    pthread_mutex_unlock(&e->lock);
}

void hc_engine_stop_recording(HCEngine *e) {
    if (!e) return;
    pthread_mutex_lock(&e->lock);
    e->rec_requested = 0;
    e->rec_stop_at_us = 0;
    e->rec_stop_requested = 1;
    pthread_mutex_unlock(&e->lock);
}

void hc_engine_get_info(HCEngine *e, HCInfo *out) {
    if (!e || !out) return;
    pthread_mutex_lock(&e->lock);
    *out = e->info;
    out->recording = e->rec_requested;
    pthread_mutex_unlock(&e->lock);
}

typedef struct { int64_t deadline; } ProbeCtx;
static int probe_interrupt(void *opaque) { return now_us() > ((ProbeCtx *)opaque)->deadline; }

int hc_probe(const char *url, int timeout_ms, HCInfo *out) {
    quiet_logs();
    if (out) memset(out, 0, sizeof *out);
    ProbeCtx pc = {now_us() + (int64_t)timeout_ms * 1000LL};
    AVFormatContext *in = avformat_alloc_context();
    in->interrupt_callback.callback = probe_interrupt;
    in->interrupt_callback.opaque = &pc;
    AVDictionary *opts = NULL;
    set_input_options(&opts, url, timeout_ms);
    int ret = avformat_open_input(&in, url, NULL, &opts);
    av_dict_free(&opts);
    if (ret < 0) return map_error(ret);
    ret = avformat_find_stream_info(in, NULL);
    if (ret < 0) { avformat_close_input(&in); return map_error(ret); }
    int v = av_find_best_stream(in, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    int a = av_find_best_stream(in, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (v < 0) { avformat_close_input(&in); return HC_ERR_NO_VIDEO; }
    if (out) {
        AVCodecParameters *vp = in->streams[v]->codecpar;
        snprintf(out->video_codec, sizeof out->video_codec, "%s", avcodec_get_name(vp->codec_id));
        out->width = vp->width;
        out->height = vp->height;
        out->has_audio = a >= 0;
        if (a >= 0) snprintf(out->audio_codec, sizeof out->audio_codec, "%s",
                             avcodec_get_name(in->streams[a]->codecpar->codec_id));
    }
    avformat_close_input(&in);
    return HC_OK;
}
