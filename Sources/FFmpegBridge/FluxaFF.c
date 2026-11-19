// Fluxa's in-process FFmpeg (LGPL build) wrapper. libav* calls only: no command line, no shell, no exit().
//
// fx_execute() understands the exact FFmpeg-style option subset that FFmpegCommandBuilder.swift produces, so the
// command for every format is unit tested in Swift and this file only has to run it faithfully.
#include "FluxaFF.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <math.h>
#include <errno.h>

#if defined(__has_include)
#  if __has_include("libavformat/avformat.h")
#    define FX_HAVE_FFMPEG 1
#  endif
#endif

#ifndef FX_HAVE_FFMPEG

// Built without the FFmpeg libraries: the app falls back to Apple's engine and says so.
int fx_available(void) { return 0; }
const char *fx_license(void) { return "FFmpeg is not included in this build."; }
const char *fx_configuration(void) { return ""; }
int fx_has_encoder(const char *name) { (void)name; return 0; }
int fx_has_decoder(const char *name) { (void)name; return 0; }
int fx_has_filter(const char *name) { (void)name; return 0; }
char *fx_probe_json(const char *path) { (void)path; return NULL; }
void fx_free(void *pointer) { free(pointer); }
int fx_execute(int argc, const char *const *argv, FxProgress progress, void *context, volatile int *cancel) {
    (void)argc; (void)argv; (void)progress; (void)context; (void)cancel;
    return -1;
}
const char *fx_last_error(void) { return "FFmpeg is not included in this build."; }

#else

#include "libavutil/avutil.h"
#include "libavutil/eval.h"
#include "libavutil/opt.h"
#include "libavutil/display.h"
#include "libavutil/channel_layout.h"
#include "libavutil/pixdesc.h"
#include "libavutil/samplefmt.h"
#include "libavutil/mathematics.h"
#include "libavutil/time.h"
#include "libavutil/log.h"
#include "libavcodec/avcodec.h"
#include "libavcodec/bsf.h"
#include "libavformat/avformat.h"
#include "libavfilter/avfilter.h"
#include "libavfilter/buffersrc.h"
#include "libavfilter/buffersink.h"

// MARK: - Errors and logging

static char g_error[512];

static void log_callback(void *avcl, int level, const char *fmt, va_list vl) {
    (void)avcl;
    if (level > AV_LOG_ERROR) return;
    char line[512];
    vsnprintf(line, sizeof(line), fmt, vl);
    size_t n = strlen(line);
    while (n > 0 && (line[n - 1] == '\n' || line[n - 1] == '\r' || line[n - 1] == ' ')) line[--n] = 0;
    if (n == 0 || strstr(line, "Last message repeated")) return;
    snprintf(g_error, sizeof(g_error), "%s", line);
}

static void install_logging(void) {
    av_log_set_callback(log_callback);
}

static int fail(int code, const char *what) {
    char buf[160] = {0};
    if (code < 0) av_strerror(code, buf, sizeof(buf));
    // Keep a more specific message from the log when there is one.
    if (g_error[0] == 0 || strstr(g_error, "Error while") != NULL) {
        snprintf(g_error, sizeof(g_error), "%s%s%s", what ? what : "", (what && buf[0]) ? ": " : "", buf);
    }
    return code < 0 ? code : -1;
}

const char *fx_last_error(void) { return g_error; }
int fx_available(void) { return 1; }
const char *fx_license(void) { return avformat_license(); }
const char *fx_configuration(void) { return avformat_configuration(); }
int fx_has_encoder(const char *name) { return avcodec_find_encoder_by_name(name) != NULL; }
int fx_has_decoder(const char *name) { return avcodec_find_decoder_by_name(name) != NULL; }
int fx_has_filter(const char *name) { return avfilter_get_by_name(name) != NULL; }
void fx_free(void *pointer) { free(pointer); }

// MARK: - Helpers

static int display_rotation(const AVStream *st) {
    const AVPacketSideData *sd = av_packet_side_data_get(st->codecpar->coded_side_data, st->codecpar->nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX);
    if (!sd || sd->size < 9 * 4) return 0;
    double theta = -av_display_rotation_get((const int32_t *)sd->data);
    int rot = (int)lround(theta);
    rot %= 360;
    if (rot < 0) rot += 360;
    return rot;
}

static const AVCodec *find_decoder(enum AVCodecID id) {
    const AVCodec *dec = NULL;
    if (id == AV_CODEC_ID_AV1) dec = avcodec_find_decoder_by_name("libdav1d");
    if (!dec) dec = avcodec_find_decoder(id);
    return dec;
}

static int open_decoder(AVStream *st, AVCodecContext **out) {
    const AVCodec *dec = find_decoder(st->codecpar->codec_id);
    if (!dec) return AVERROR_DECODER_NOT_FOUND;
    AVCodecContext *ctx = avcodec_alloc_context3(dec);
    if (!ctx) return AVERROR(ENOMEM);
    int ret = avcodec_parameters_to_context(ctx, st->codecpar);
    if (ret < 0) { avcodec_free_context(&ctx); return ret; }
    ctx->pkt_timebase = st->time_base;
    ctx->thread_count = 0;
    ret = avcodec_open2(ctx, dec, NULL);
    if (ret < 0) { avcodec_free_context(&ctx); return ret; }
    *out = ctx;
    return 0;
}

// MARK: - Probe (JSON in the shape of ffprobe)

typedef struct { char *p; size_t n, cap; } Buf;

static void bput(Buf *b, const char *fmt, ...) {
    char tmp[512];
    va_list ap;
    va_start(ap, fmt);
    int len = vsnprintf(tmp, sizeof(tmp), fmt, ap);
    va_end(ap);
    if (len < 0) return;
    if (len >= (int)sizeof(tmp)) len = (int)sizeof(tmp) - 1;
    if (b->n + (size_t)len + 1 > b->cap) {
        size_t cap = b->cap ? b->cap * 2 : 2048;
        while (cap < b->n + (size_t)len + 1) cap *= 2;
        char *np = (char *)realloc(b->p, cap);
        if (!np) return;
        b->p = np;
        b->cap = cap;
    }
    memcpy(b->p + b->n, tmp, (size_t)len);
    b->n += (size_t)len;
    b->p[b->n] = 0;
}

static void put_rate(Buf *b, const char *key, AVRational r) {
    if (r.num > 0 && r.den > 0) bput(b, "\"%s\":\"%d/%d\",", key, r.num, r.den);
    else bput(b, "\"%s\":\"0/0\",", key);
}

char *fx_probe_json(const char *path) {
    install_logging();
    g_error[0] = 0;
    AVFormatContext *fmt = NULL;
    if (avformat_open_input(&fmt, path, NULL, NULL) < 0) return NULL;
    if (avformat_find_stream_info(fmt, NULL) < 0) { avformat_close_input(&fmt); return NULL; }

    Buf b = {0};
    double duration = 0;
    if (fmt->duration != AV_NOPTS_VALUE && fmt->duration > 0) duration = (double)fmt->duration / AV_TIME_BASE;
    int64_t size = fmt->pb ? avio_size(fmt->pb) : 0;
    if (size < 0) size = 0;

    bput(&b, "{\"format\":{\"format_name\":\"%s\",\"duration\":\"%.6f\",\"size\":\"%lld\",\"bit_rate\":\"%lld\"},\"streams\":[",
         fmt->iformat ? fmt->iformat->name : "unknown", duration, (long long)size, (long long)(fmt->bit_rate > 0 ? fmt->bit_rate : 0));

    for (unsigned i = 0; i < fmt->nb_streams; i++) {
        AVStream *st = fmt->streams[i];
        AVCodecParameters *cp = st->codecpar;
        const char *type = "data";
        if (cp->codec_type == AVMEDIA_TYPE_VIDEO) type = "video";
        else if (cp->codec_type == AVMEDIA_TYPE_AUDIO) type = "audio";
        else if (cp->codec_type == AVMEDIA_TYPE_SUBTITLE) type = "subtitle";
        bput(&b, "%s{\"index\":%u,\"codec_type\":\"%s\",\"codec_name\":\"%s\",", i ? "," : "", i, type, avcodec_get_name(cp->codec_id));
        if (cp->codec_type == AVMEDIA_TYPE_VIDEO) {
            const char *pix = av_get_pix_fmt_name((enum AVPixelFormat)cp->format);
            bput(&b, "\"width\":%d,\"height\":%d,\"pix_fmt\":\"%s\",", cp->width, cp->height, pix ? pix : "");
            put_rate(&b, "avg_frame_rate", st->avg_frame_rate);
            put_rate(&b, "r_frame_rate", st->r_frame_rate);
            const char *trc = av_color_transfer_name(cp->color_trc);
            bput(&b, "\"color_transfer\":\"%s\",", trc ? trc : "");
            int rot = (int)lround(0.0);
            const AVPacketSideData *sd = av_packet_side_data_get(cp->coded_side_data, cp->nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX);
            if (sd && sd->size >= 9 * 4) rot = (int)lround(av_display_rotation_get((const int32_t *)sd->data));
            if (rot != 0) bput(&b, "\"side_data_list\":[{\"rotation\":%d}],", rot);
        } else if (cp->codec_type == AVMEDIA_TYPE_AUDIO) {
            bput(&b, "\"sample_rate\":\"%d\",\"channels\":%d,", cp->sample_rate, cp->ch_layout.nb_channels);
        }
        bput(&b, "\"bit_rate\":\"%lld\",\"disposition\":{\"attached_pic\":%d}}", (long long)(cp->bit_rate > 0 ? cp->bit_rate : 0), (st->disposition & AV_DISPOSITION_ATTACHED_PIC) ? 1 : 0);
    }
    bput(&b, "]}");
    avformat_close_input(&fmt);
    return b.p;
}

// MARK: - Option parsing

typedef struct { char key[48]; char val[128]; } KV;

typedef struct {
    const char *input;
    const char *output;
    char format[32];
    double ss, t;
    int has_t;
    int no_video, no_audio;
    int want_v, want_a;
    int strip_meta;
    char vcodec[48], acodec[48];
    char vf[3072];
    int ar, ac;
    uint32_t vtag;
    int has_qv; double qv;
    KV vopts[24]; int nv;
    KV aopts[8]; int na;
    KV mopts[8]; int nm;
} Opts;

static void kv_add(KV *list, int *n, int max, const char *key, const char *val) {
    if (*n >= max) return;
    snprintf(list[*n].key, sizeof(list[*n].key), "%s", key);
    snprintf(list[*n].val, sizeof(list[*n].val), "%s", val);
    (*n)++;
}

static uint32_t fourcc(const char *s) {
    uint32_t tag = 0;
    for (int i = 0; i < 4 && s[i]; i++) tag |= (uint32_t)(unsigned char)s[i] << (8 * i);
    return tag;
}

static int parse_options(int argc, const char *const *argv, Opts *o) {
    memset(o, 0, sizeof(*o));
    for (int i = 0; i < argc; i++) {
        const char *a = argv[i];
        const char *v = (i + 1 < argc) ? argv[i + 1] : "";
        #define IS(x) (strcmp(a, x) == 0)
        if (IS("-hide_banner") || IS("-nostdin") || IS("-y") || IS("-sn") || IS("-dn")) continue;
        else if (IS("-vn")) o->no_video = 1;
        else if (IS("-an")) o->no_audio = 1;
        else if (IS("-ss")) { o->ss = av_strtod(v, NULL); i++; }
        else if (IS("-t")) { o->t = av_strtod(v, NULL); o->has_t = 1; i++; }
        else if (IS("-i")) { o->input = v; i++; }
        else if (IS("-map_metadata")) { o->strip_meta = strcmp(v, "-1") == 0; i++; }
        else if (IS("-map_chapters")) i++;
        else if (IS("-map")) { if (strcmp(v, "0:v:0") == 0) o->want_v = 1; else if (strcmp(v, "0:a:0") == 0) o->want_a = 1; i++; }
        else if (IS("-c:v")) { snprintf(o->vcodec, sizeof(o->vcodec), "%s", v); i++; }
        else if (IS("-c:a")) { snprintf(o->acodec, sizeof(o->acodec), "%s", v); i++; }
        else if (IS("-vf")) { snprintf(o->vf, sizeof(o->vf), "%s", v); i++; }
        else if (IS("-ar")) { o->ar = atoi(v); i++; }
        else if (IS("-ac")) { o->ac = atoi(v); i++; }
        else if (IS("-tag:v") || IS("-vtag")) { o->vtag = fourcc(v); i++; }
        else if (IS("-q:v")) { o->has_qv = 1; o->qv = av_strtod(v, NULL); i++; }
        else if (IS("-b:v")) { kv_add(o->vopts, &o->nv, 24, "b", v); i++; }
        else if (IS("-profile:v")) { kv_add(o->vopts, &o->nv, 24, "profile", v); i++; }
        else if (IS("-maxrate") || IS("-bufsize") || IS("-qmin") || IS("-allow_sw") || IS("-deadline") || IS("-cpu-used") ||
                 IS("-row-mt") || IS("-lossless") || IS("-vendor") || IS("-threads")) {
            kv_add(o->vopts, &o->nv, 24, a + 1, v); i++;
        }
        else if (IS("-b:a")) { kv_add(o->aopts, &o->na, 8, "b", v); i++; }
        else if (IS("-vbr")) { kv_add(o->aopts, &o->na, 8, "vbr", v); i++; }
        else if (IS("-movflags") || IS("-loop") || IS("-plays")) { kv_add(o->mopts, &o->nm, 8, a + 1, v); i++; }
        else if (IS("-f")) { snprintf(o->format, sizeof(o->format), "%s", v); i++; }
        else if (a[0] != '-') o->output = a;
        else return AVERROR(EINVAL);
        #undef IS
    }
    if (!o->input || !o->output || !o->format[0]) return AVERROR(EINVAL);
    return 0;
}

static AVDictionary *dict_from(const KV *list, int n) {
    AVDictionary *d = NULL;
    for (int i = 0; i < n; i++) av_dict_set(&d, list[i].key, list[i].val, 0);
    return d;
}

// MARK: - Job

typedef struct {
    int is_video;
    int copy;
    int idx;
    AVStream *in, *out;
    AVCodecContext *dec, *enc;
    AVFilterGraph *graph;
    AVFilterContext *src, *sink;
    AVBSFContext *bsf;
    int64_t offset;       // start of the file (plus trim) in this stream's input time base
    int64_t last_dts;
    int done;
    int sample_rate;      // audio filter time base
} Lane;

typedef struct {
    Opts o;
    AVFormatContext *ifmt, *ofmt;
    Lane v, a;
    int has_v, has_a;
    int64_t base;          // file start in AV_TIME_BASE
    double span;           // seconds of output expected
    FxProgress progress;
    void *context;
    volatile int *cancel;
    double last_report;
    int64_t t0;
} Job;

static void report(Job *j, double seconds) {
    if (!j->progress) return;
    if (seconds < 0) seconds = 0;
    if (seconds - j->last_report < 0.05) return;
    j->last_report = seconds;
    double wall = (double)(av_gettime_relative() - j->t0) / 1e6;
    j->progress(seconds, wall > 0.2 ? seconds / wall : 0, j->context);
}

static double packet_seconds(const AVPacket *pkt, const AVStream *ost) {
    int64_t t = pkt->pts != AV_NOPTS_VALUE ? pkt->pts : pkt->dts;
    if (t == AV_NOPTS_VALUE) return -1;
    return (double)t * av_q2d(ost->time_base);
}

static int write_packet(Job *j, Lane *l, AVPacket *pkt) {
    pkt->stream_index = l->out->index;
    double t = packet_seconds(pkt, l->out);
    int ret = av_interleaved_write_frame(j->ofmt, pkt);
    if (ret >= 0 && t >= 0) report(j, t);
    return ret;
}

// MARK: Encode

static int encode_frame(Job *j, Lane *l, AVFrame *frame) {
    int ret = avcodec_send_frame(l->enc, frame);
    if (ret < 0 && ret != AVERROR_EOF) return ret;
    AVPacket *pkt = av_packet_alloc();
    if (!pkt) return AVERROR(ENOMEM);
    while (1) {
        ret = avcodec_receive_packet(l->enc, pkt);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) { ret = 0; break; }
        if (ret < 0) break;
        av_packet_rescale_ts(pkt, l->enc->time_base, l->out->time_base);
        ret = write_packet(j, l, pkt);
        av_packet_unref(pkt);
        if (ret < 0) break;
    }
    av_packet_free(&pkt);
    return ret;
}

static int drain_sink(Job *j, Lane *l, AVFrame *filt) {
    while (1) {
        int ret = av_buffersink_get_frame(l->sink, filt);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) return 0;
        if (ret < 0) return ret;
        if (l->is_video) filt->pict_type = AV_PICTURE_TYPE_NONE;
        ret = encode_frame(j, l, filt);
        av_frame_unref(filt);
        if (ret < 0) return ret;
    }
}

// MARK: Frames

static int feed_video_frame(Job *j, AVFrame *frame, AVFrame *filt) {
    Lane *l = &j->v;
    int64_t pts = frame->best_effort_timestamp;
    if (pts == AV_NOPTS_VALUE) { av_frame_unref(frame); return 0; }
    pts -= l->offset;
    double t = (double)pts * av_q2d(l->in->time_base);
    if (j->o.ss > 0.05 && t < -1e-4) { av_frame_unref(frame); return 0; }
    if (j->o.has_t && t > j->o.t + 1e-4) { l->done = 1; av_frame_unref(frame); return 0; }
    frame->pts = pts;
    av_frame_remove_side_data(frame, AV_FRAME_DATA_DISPLAYMATRIX);
    int ret = av_buffersrc_add_frame_flags(l->src, frame, AV_BUFFERSRC_FLAG_KEEP_REF);
    av_frame_unref(frame);
    if (ret < 0) return ret;
    return drain_sink(j, l, filt);
}

static int feed_audio_frame(Job *j, AVFrame *frame, AVFrame *filt) {
    Lane *l = &j->a;
    int64_t pts = frame->pts != AV_NOPTS_VALUE ? frame->pts : frame->best_effort_timestamp;
    if (pts == AV_NOPTS_VALUE) { av_frame_unref(frame); return 0; }
    pts -= l->offset;
    double t = (double)pts * av_q2d(l->in->time_base);
    if (j->o.ss > 0.05 && t < -1e-4) { av_frame_unref(frame); return 0; }
    if (j->o.has_t && t > j->o.t + 1e-4) { l->done = 1; av_frame_unref(frame); return 0; }
    frame->pts = av_rescale_q(pts, l->in->time_base, (AVRational){1, l->sample_rate});
    int ret = av_buffersrc_add_frame_flags(l->src, frame, AV_BUFFERSRC_FLAG_KEEP_REF);
    av_frame_unref(frame);
    if (ret < 0) return ret;
    return drain_sink(j, l, filt);
}

static int decode_packet(Job *j, Lane *l, AVPacket *pkt, AVFrame *frame, AVFrame *filt) {
    int ret = avcodec_send_packet(l->dec, pkt);
    if (ret < 0 && ret != AVERROR(EAGAIN) && ret != AVERROR_EOF) return 0; // a damaged packet is skipped, not fatal
    while (1) {
        ret = avcodec_receive_frame(l->dec, frame);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) return 0;
        if (ret < 0) return 0;
        ret = l->is_video ? feed_video_frame(j, frame, filt) : feed_audio_frame(j, frame, filt);
        if (ret < 0) return ret;
    }
}

// MARK: Copy

static int finish_copy_packet(Job *j, Lane *l, AVPacket *pkt) {
    if (pkt->dts != AV_NOPTS_VALUE && l->last_dts != AV_NOPTS_VALUE && pkt->dts <= l->last_dts) {
        pkt->dts = l->last_dts + 1;
        if (pkt->pts != AV_NOPTS_VALUE && pkt->pts < pkt->dts) pkt->pts = pkt->dts;
    }
    if (pkt->dts != AV_NOPTS_VALUE) l->last_dts = pkt->dts;
    pkt->pos = -1;
    return write_packet(j, l, pkt);
}

static int copy_packet(Job *j, Lane *l, AVPacket *pkt) {
    if (pkt->pts != AV_NOPTS_VALUE) pkt->pts -= l->offset;
    if (pkt->dts != AV_NOPTS_VALUE) pkt->dts -= l->offset;
    if (j->o.has_t) {
        int64_t t = pkt->pts != AV_NOPTS_VALUE ? pkt->pts : pkt->dts;
        if (t != AV_NOPTS_VALUE && (double)t * av_q2d(l->in->time_base) > j->o.t) { l->done = 1; return 0; }
    }
    av_packet_rescale_ts(pkt, l->in->time_base, l->out->time_base);
    if (!l->bsf) return finish_copy_packet(j, l, pkt);

    int ret = av_bsf_send_packet(l->bsf, pkt);
    if (ret < 0) return ret;
    AVPacket *out = av_packet_alloc();
    if (!out) return AVERROR(ENOMEM);
    while ((ret = av_bsf_receive_packet(l->bsf, out)) >= 0) {
        ret = finish_copy_packet(j, l, out);
        av_packet_unref(out);
        if (ret < 0) break;
    }
    av_packet_free(&out);
    if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) ret = 0;
    return ret;
}

// MARK: Filters

static int link_graph(Lane *l, const char *chain) {
    AVFilterInOut *outputs = avfilter_inout_alloc();
    AVFilterInOut *inputs = avfilter_inout_alloc();
    if (!outputs || !inputs) { avfilter_inout_free(&outputs); avfilter_inout_free(&inputs); return AVERROR(ENOMEM); }
    outputs->name = av_strdup("in");  outputs->filter_ctx = l->src;  outputs->pad_idx = 0; outputs->next = NULL;
    inputs->name = av_strdup("out");  inputs->filter_ctx = l->sink;  inputs->pad_idx = 0; inputs->next = NULL;
    int ret = avfilter_graph_parse_ptr(l->graph, chain, &inputs, &outputs, NULL);
    avfilter_inout_free(&inputs);
    avfilter_inout_free(&outputs);
    if (ret < 0) return ret;
    return avfilter_graph_config(l->graph, NULL);
}

static int build_video_graph(Job *j, AVRational fps) {
    Lane *l = &j->v;
    char args[512], chain[4096];
    l->graph = avfilter_graph_alloc();
    if (!l->graph) return AVERROR(ENOMEM);
    AVRational tb = l->in->time_base;
    AVRational sar = l->dec->sample_aspect_ratio.num > 0 ? l->dec->sample_aspect_ratio : (AVRational){1, 1};
    AVRational avg = l->in->avg_frame_rate.num > 0 ? l->in->avg_frame_rate : fps;
    snprintf(args, sizeof(args), "video_size=%dx%d:pix_fmt=%d:time_base=%d/%d:pixel_aspect=%d/%d:frame_rate=%d/%d",
             l->dec->width, l->dec->height, (int)l->dec->pix_fmt, tb.num, tb.den, sar.num, sar.den, avg.num, avg.den);
    int ret = avfilter_graph_create_filter(&l->src, avfilter_get_by_name("buffer"), "in", args, NULL, l->graph);
    if (ret < 0) return ret;
    ret = avfilter_graph_create_filter(&l->sink, avfilter_get_by_name("buffersink"), "out", NULL, NULL, l->graph);
    if (ret < 0) return ret;

    // The stored rotation is applied here (the libav decoders do not), so the output has no display matrix.
    const char *rot = "";
    int rotation = display_rotation(l->in);
    if (rotation == 90) rot = "transpose=clock,";
    else if (rotation == 180) rot = "hflip,vflip,";
    else if (rotation == 270) rot = "transpose=cclock,";

    char tail[64] = "";
    if (!strstr(j->o.vf, "fps=")) snprintf(tail, sizeof(tail), "fps=%d/%d", fps.num, fps.den);
    const char *user = j->o.vf;
    if (user[0] && tail[0]) snprintf(chain, sizeof(chain), "%s%s,%s", rot, user, tail);
    else if (user[0]) snprintf(chain, sizeof(chain), "%s%s", rot, user);
    else if (tail[0]) snprintf(chain, sizeof(chain), "%s%s", rot, tail);
    else snprintf(chain, sizeof(chain), "%snull", rot);
    // A trailing comma (rotation with nothing after it) cannot happen: every branch ends with a filter.
    return link_graph(l, chain);
}

static int build_audio_graph(Job *j, enum AVSampleFormat fmt, int rate, const AVChannelLayout *layout) {
    Lane *l = &j->a;
    char args[512], desc[128], chain[512], src_layout[128];
    l->graph = avfilter_graph_alloc();
    if (!l->graph) return AVERROR(ENOMEM);
    if (l->dec->ch_layout.order == AV_CHANNEL_ORDER_UNSPEC) {
        av_channel_layout_default(&l->dec->ch_layout, l->dec->ch_layout.nb_channels > 0 ? l->dec->ch_layout.nb_channels : 2);
    }
    av_channel_layout_describe(&l->dec->ch_layout, src_layout, sizeof(src_layout));
    snprintf(args, sizeof(args), "time_base=1/%d:sample_rate=%d:sample_fmt=%s:channel_layout=%s",
             l->dec->sample_rate, l->dec->sample_rate, av_get_sample_fmt_name(l->dec->sample_fmt), src_layout);
    l->sample_rate = l->dec->sample_rate;
    int ret = avfilter_graph_create_filter(&l->src, avfilter_get_by_name("abuffer"), "ain", args, NULL, l->graph);
    if (ret < 0) return ret;
    ret = avfilter_graph_create_filter(&l->sink, avfilter_get_by_name("abuffersink"), "aout", NULL, NULL, l->graph);
    if (ret < 0) return ret;
    av_channel_layout_describe(layout, desc, sizeof(desc));
    snprintf(chain, sizeof(chain), "aformat=sample_fmts=%s:sample_rates=%d:channel_layouts=%s", av_get_sample_fmt_name(fmt), rate, desc);
    return link_graph(l, chain);
}

// MARK: Encoders

static int open_video_encoder(Job *j, AVRational fps) {
    Lane *l = &j->v;
    const AVCodec *codec = avcodec_find_encoder_by_name(j->o.vcodec);
    if (!codec) { snprintf(g_error, sizeof(g_error), "Encoder %s not found", j->o.vcodec); return AVERROR_ENCODER_NOT_FOUND; }
    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    if (!ctx) return AVERROR(ENOMEM);
    l->enc = ctx;
    ctx->width = av_buffersink_get_w(l->sink);
    ctx->height = av_buffersink_get_h(l->sink);
    ctx->pix_fmt = (enum AVPixelFormat)av_buffersink_get_format(l->sink);
    ctx->sample_aspect_ratio = av_buffersink_get_sample_aspect_ratio(l->sink);
    if (ctx->sample_aspect_ratio.num <= 0) ctx->sample_aspect_ratio = (AVRational){1, 1};
    ctx->time_base = av_buffersink_get_time_base(l->sink);
    AVRational rate = av_buffersink_get_frame_rate(l->sink);
    ctx->framerate = rate.num > 0 ? rate : fps;
    ctx->color_range = l->dec->color_range;
    ctx->color_primaries = l->dec->color_primaries;
    ctx->color_trc = l->dec->color_trc;
    ctx->colorspace = l->dec->colorspace;
    switch (codec->id) {
        case AV_CODEC_ID_GIF: case AV_CODEC_ID_APNG: case AV_CODEC_ID_WEBP: case AV_CODEC_ID_MJPEG: case AV_CODEC_ID_PRORES: break;
        default: ctx->gop_size = (int)lround(av_q2d(ctx->framerate) * 2); if (ctx->gop_size < 1) ctx->gop_size = 12; break;
    }
    if (j->o.has_qv) {
        ctx->flags |= AV_CODEC_FLAG_QSCALE;
        ctx->global_quality = (int)lround(j->o.qv * FF_QP2LAMBDA);
    }
    if (j->ofmt->oformat->flags & AVFMT_GLOBALHEADER) ctx->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    AVDictionary *opts = dict_from(j->o.vopts, j->o.nv);
    int ret = avcodec_open2(ctx, codec, &opts);
    av_dict_free(&opts);
    if (ret < 0) return ret;
    l->out = avformat_new_stream(j->ofmt, NULL);
    if (!l->out) return AVERROR(ENOMEM);
    ret = avcodec_parameters_from_context(l->out->codecpar, ctx);
    if (ret < 0) return ret;
    l->out->time_base = ctx->time_base;
    l->out->avg_frame_rate = ctx->framerate;
    l->out->sample_aspect_ratio = ctx->sample_aspect_ratio;
    if (j->o.vtag) l->out->codecpar->codec_tag = j->o.vtag;
    return 0;
}

static int closest_rate(const int *rates, int n, int wanted) {
    int best = rates[0];
    for (int i = 0; i < n; i++) {
        if (rates[i] == wanted) return wanted;
        if (abs(rates[i] - wanted) < abs(best - wanted)) best = rates[i];
    }
    return best;
}

static int open_audio_encoder(Job *j) {
    Lane *l = &j->a;
    const AVCodec *codec = avcodec_find_encoder_by_name(j->o.acodec);
    if (!codec) { snprintf(g_error, sizeof(g_error), "Encoder %s not found", j->o.acodec); return AVERROR_ENCODER_NOT_FOUND; }
    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    if (!ctx) return AVERROR(ENOMEM);
    l->enc = ctx;

    // Sample format.
    enum AVSampleFormat fmt = l->dec->sample_fmt;
    const enum AVSampleFormat *formats = NULL; int nformats = 0;
    if (avcodec_get_supported_config(ctx, codec, AV_CODEC_CONFIG_SAMPLE_FORMAT, 0, (const void **)&formats, &nformats) >= 0 && formats && nformats > 0) {
        fmt = formats[0];
        for (int i = 0; i < nformats; i++) { if (formats[i] == AV_SAMPLE_FMT_FLTP) { fmt = formats[i]; break; } }
    }
    // Sample rate.
    int rate = j->o.ar > 0 ? j->o.ar : l->dec->sample_rate;
    const int *rates = NULL; int nrates = 0;
    if (avcodec_get_supported_config(ctx, codec, AV_CODEC_CONFIG_SAMPLE_RATE, 0, (const void **)&rates, &nrates) >= 0 && rates && nrates > 0) {
        rate = closest_rate(rates, nrates, rate);
    }
    // Channel layout.
    AVChannelLayout layout = {0};
    int channels = j->o.ac > 0 ? j->o.ac : (l->dec->ch_layout.nb_channels > 0 ? l->dec->ch_layout.nb_channels : 2);
    av_channel_layout_default(&layout, channels);
    const AVChannelLayout *layouts = NULL; int nlayouts = 0;
    if (avcodec_get_supported_config(ctx, codec, AV_CODEC_CONFIG_CHANNEL_LAYOUT, 0, (const void **)&layouts, &nlayouts) >= 0 && layouts && nlayouts > 0) {
        int found = 0;
        for (int i = 0; i < nlayouts; i++) { if (av_channel_layout_compare(&layouts[i], &layout) == 0) { found = 1; break; } }
        if (!found) {
            AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
            av_channel_layout_uninit(&layout);
            for (int i = 0; i < nlayouts; i++) { if (av_channel_layout_compare(&layouts[i], &stereo) == 0) { found = 1; break; } }
            if (found) av_channel_layout_copy(&layout, &stereo);
            else av_channel_layout_copy(&layout, &layouts[0]);
        }
    }

    int ret = build_audio_graph(j, fmt, rate, &layout);
    if (ret < 0) { av_channel_layout_uninit(&layout); return ret; }

    ctx->sample_fmt = fmt;
    ctx->sample_rate = rate;
    ctx->time_base = (AVRational){1, rate};
    av_channel_layout_copy(&ctx->ch_layout, &layout);
    av_channel_layout_uninit(&layout);
    if (j->ofmt->oformat->flags & AVFMT_GLOBALHEADER) ctx->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    AVDictionary *opts = dict_from(j->o.aopts, j->o.na);
    ret = avcodec_open2(ctx, codec, &opts);
    av_dict_free(&opts);
    if (ret < 0) return ret;
    if (ctx->frame_size > 0) av_buffersink_set_frame_size(l->sink, ctx->frame_size);

    l->out = avformat_new_stream(j->ofmt, NULL);
    if (!l->out) return AVERROR(ENOMEM);
    ret = avcodec_parameters_from_context(l->out->codecpar, ctx);
    if (ret < 0) return ret;
    l->out->time_base = ctx->time_base;
    return 0;
}

// MARK: Streams

static int add_copy_stream(Job *j, Lane *l) {
    AVCodecParameters *source = l->in->codecpar;
    // AAC from ADTS (MPEG-TS, .aac) needs its headers rewritten before MP4 or MKV can hold it.
    if (source->codec_id == AV_CODEC_ID_AAC && source->extradata_size == 0) {
        const AVBitStreamFilter *f = av_bsf_get_by_name("aac_adtstoasc");
        if (f && av_bsf_alloc(f, &l->bsf) >= 0) {
            avcodec_parameters_copy(l->bsf->par_in, source);
            l->bsf->time_base_in = l->out ? l->out->time_base : l->in->time_base;
            if (av_bsf_init(l->bsf) < 0) av_bsf_free(&l->bsf);
        }
    }
    l->out = avformat_new_stream(j->ofmt, NULL);
    if (!l->out) return AVERROR(ENOMEM);
    int ret = avcodec_parameters_copy(l->out->codecpar, l->bsf ? l->bsf->par_out : source);
    if (ret < 0) return ret;
    l->out->codecpar->codec_tag = 0;
    if (l->is_video && j->o.vtag) l->out->codecpar->codec_tag = j->o.vtag;
    l->out->time_base = l->in->time_base;
    l->out->avg_frame_rate = l->in->avg_frame_rate;
    l->out->sample_aspect_ratio = l->in->sample_aspect_ratio;
    return 0;
}

// MARK: - fx_execute

static void free_lane(Lane *l) {
    avfilter_graph_free(&l->graph);
    avcodec_free_context(&l->dec);
    avcodec_free_context(&l->enc);
    av_bsf_free(&l->bsf);
}

int fx_execute(int argc, const char *const *argv, FxProgress progress, void *context, volatile int *cancel) {
    install_logging();
    g_error[0] = 0;
    Job J;
    memset(&J, 0, sizeof(J));
    J.progress = progress;
    J.context = context;
    J.cancel = cancel;
    J.last_report = -1;
    J.t0 = av_gettime_relative();
    J.v.is_video = 1;
    J.v.last_dts = J.a.last_dts = AV_NOPTS_VALUE;

    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    AVFrame *filt = av_frame_alloc();
    AVDictionary *mux_opts = NULL;
    int ret = 0, header_written = 0, cancelled = 0;

    if (!pkt || !frame || !filt) { ret = AVERROR(ENOMEM); goto end; }
    if ((ret = parse_options(argc, argv, &J.o)) < 0) { fail(ret, "Invalid conversion options"); goto end; }

    if ((ret = avformat_open_input(&J.ifmt, J.o.input, NULL, NULL)) < 0) { fail(ret, "Cannot open the file"); goto end; }
    if ((ret = avformat_find_stream_info(J.ifmt, NULL)) < 0) { fail(ret, "Cannot read the file"); goto end; }
    J.base = J.ifmt->start_time != AV_NOPTS_VALUE ? J.ifmt->start_time : 0;

    // Choose the streams.
    J.has_v = J.o.want_v && !J.o.no_video;
    J.has_a = J.o.want_a && !J.o.no_audio;
    if (J.has_v) {
        J.v.idx = av_find_best_stream(J.ifmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
        if (J.v.idx < 0) { ret = J.v.idx; fail(ret, "This file has no video"); goto end; }
        J.v.in = J.ifmt->streams[J.v.idx];
        J.v.copy = strcmp(J.o.vcodec, "copy") == 0;
    }
    if (J.has_a) {
        J.a.idx = av_find_best_stream(J.ifmt, AVMEDIA_TYPE_AUDIO, -1, J.has_v ? J.v.idx : -1, NULL, 0);
        if (J.a.idx < 0) {
            if (J.has_v) { J.has_a = 0; }
            else { ret = J.a.idx; fail(ret, "This file has no audio"); goto end; }
        } else {
            J.a.in = J.ifmt->streams[J.a.idx];
            J.a.copy = strcmp(J.o.acodec, "copy") == 0;
        }
    }
    if (!J.has_v && !J.has_a) { ret = AVERROR(EINVAL); fail(ret, "Nothing to convert"); goto end; }

    // Expected output length for progress.
    double total = J.ifmt->duration != AV_NOPTS_VALUE && J.ifmt->duration > 0 ? (double)J.ifmt->duration / AV_TIME_BASE : 0;
    J.span = total - J.o.ss;
    if (J.o.has_t && (J.span <= 0 || J.o.t < J.span)) J.span = J.o.t;

    // Offsets: every stream starts at zero (plus the trim start).
    int64_t start_us = J.base + (int64_t)(J.o.ss * AV_TIME_BASE);
    if (J.has_v) J.v.offset = av_rescale_q(start_us, AV_TIME_BASE_Q, J.v.in->time_base);
    if (J.has_a) J.a.offset = av_rescale_q(start_us, AV_TIME_BASE_Q, J.a.in->time_base);

    if ((ret = avformat_alloc_output_context2(&J.ofmt, NULL, J.o.format, J.o.output)) < 0 || !J.ofmt) { fail(ret, "Cannot create the output"); goto end; }

    // Video lane.
    AVRational fps = {30, 1};
    if (J.has_v) {
        AVRational guess = av_guess_frame_rate(J.ifmt, J.v.in, NULL);
        if (guess.num > 0 && guess.den > 0) fps = guess;
        if (av_q2d(fps) > 120) fps = (AVRational){60, 1};
        if (J.v.copy) {
            if ((ret = add_copy_stream(&J, &J.v)) < 0) { fail(ret, "Cannot copy the video"); goto end; }
        } else {
            if ((ret = open_decoder(J.v.in, &J.v.dec)) < 0) { fail(ret, "This video format can't be decoded"); goto end; }
            if ((ret = build_video_graph(&J, fps)) < 0) { fail(ret, "Cannot prepare the picture"); goto end; }
            if ((ret = open_video_encoder(&J, fps)) < 0) { fail(ret, "The video encoder could not start"); goto end; }
        }
    }
    // Audio lane.
    if (J.has_a) {
        if (J.a.copy) {
            if ((ret = add_copy_stream(&J, &J.a)) < 0) { fail(ret, "Cannot copy the audio"); goto end; }
        } else {
            if ((ret = open_decoder(J.a.in, &J.a.dec)) < 0) { fail(ret, "This audio format can't be decoded"); goto end; }
            if ((ret = open_audio_encoder(&J)) < 0) { fail(ret, "The audio encoder could not start"); goto end; }
        }
    }

    if (!J.o.strip_meta) {
        av_dict_copy(&J.ofmt->metadata, J.ifmt->metadata, 0);
        if (J.has_a && J.a.out) av_dict_copy(&J.a.out->metadata, J.a.in->metadata, 0);
    }

    if (!(J.ofmt->oformat->flags & AVFMT_NOFILE)) {
        if ((ret = avio_open(&J.ofmt->pb, J.o.output, AVIO_FLAG_WRITE)) < 0) { fail(ret, "Cannot write the output file"); goto end; }
    }
    mux_opts = dict_from(J.o.mopts, J.o.nm);
    if ((ret = avformat_write_header(J.ofmt, &mux_opts)) < 0) { fail(ret, "Cannot start the output file"); goto end; }
    header_written = 1;

    if (J.o.ss > 0.05) {
        av_seek_frame(J.ifmt, -1, start_us, AVSEEK_FLAG_BACKWARD);
    }

    // Main loop.
    while (1) {
        if (cancel && *cancel) { cancelled = 1; break; }
        ret = av_read_frame(J.ifmt, pkt);
        if (ret < 0) { ret = 0; break; }
        Lane *lane = NULL;
        if (J.has_v && pkt->stream_index == J.v.idx) lane = &J.v;
        else if (J.has_a && pkt->stream_index == J.a.idx) lane = &J.a;
        if (lane) {
            if (lane->done) { /* skip */ }
            else if (lane->copy) ret = copy_packet(&J, lane, pkt);
            else ret = decode_packet(&J, lane, pkt, frame, filt);
        }
        av_packet_unref(pkt);
        if (ret < 0) { fail(ret, "The file could not be converted"); goto end; }
        if ((!J.has_v || J.v.done) && (!J.has_a || J.a.done)) break;
    }
    if (cancelled) goto end;

    // Flush decoders, filters and encoders.
    Lane *lanes[2] = {&J.v, &J.a};
    for (int i = 0; i < 2; i++) {
        Lane *l = lanes[i];
        if (!(i == 0 ? J.has_v : J.has_a) || l->copy) continue;
        avcodec_send_packet(l->dec, NULL);
        while (avcodec_receive_frame(l->dec, frame) >= 0) {
            ret = l->is_video ? feed_video_frame(&J, frame, filt) : feed_audio_frame(&J, frame, filt);
            if (ret < 0) break;
        }
        if (ret < 0) { fail(ret, "Finishing the conversion failed"); goto end; }
        (void)av_buffersrc_add_frame_flags(l->src, NULL, 0);
        if ((ret = drain_sink(&J, l, filt)) < 0) { fail(ret, "Finishing the conversion failed"); goto end; }
        if ((ret = encode_frame(&J, l, NULL)) < 0) { fail(ret, "Finishing the conversion failed"); goto end; }
    }
    ret = av_write_trailer(J.ofmt);
    header_written = 0;
    if (ret < 0) { fail(ret, "Finishing the file failed"); goto end; }
    if (progress) progress(J.span > 0 ? J.span : 0, 0, context);

end:
    if (J.ofmt && header_written) av_write_trailer(J.ofmt);
    if (J.ofmt && !(J.ofmt->oformat->flags & AVFMT_NOFILE) && J.ofmt->pb) avio_closep(&J.ofmt->pb);
    av_dict_free(&mux_opts);
    free_lane(&J.v);
    free_lane(&J.a);
    if (J.ofmt) avformat_free_context(J.ofmt);
    avformat_close_input(&J.ifmt);
    av_packet_free(&pkt);
    av_frame_free(&frame);
    av_frame_free(&filt);
    if (cancelled) return 1;
    return ret < 0 ? ret : 0;
}

#endif // FX_HAVE_FFMPEG
