/* libvpx (VP8 and VP9) for webrtc_codecs_vpx.
 *
 * A decoder or an encoder lives in a resource, freed by its destructor.
 * Every call that touches one runs on a dirty CPU scheduler and holds
 * the lock of that resource. Pictures cross the boundary as three I420
 * planes without padding.
 *
 * The Erlang side reads the frame size from the bitstream and refuses a
 * frame larger than max_pixels before it gets here, so libvpx never
 * allocates for a size a peer made up; decode/2 checks again what
 * comes out.
 */
#include <vpx/vp8cx.h>
#include <vpx/vp8dx.h>
#include <vpx/vpx_decoder.h>
#include <vpx/vpx_encoder.h>

#include "webrtc_codecs_nif.h"

/* Larger than any frame the frame buffer of erlang_webrtc releases. */
#define MAX_FRAME_BYTES (8 * 1024 * 1024)
#define MAX_DIMENSION 16384

typedef struct {
    vpx_codec_ctx_t ctx;
    int open;
    ErlNifMutex *lock;
    unsigned long max_pixels;
} decoder_t;

typedef struct {
    vpx_codec_ctx_t ctx;
    vpx_codec_enc_cfg_t cfg;
    int open;
    ErlNifMutex *lock;
} encoder_t;

static ErlNifResourceType *decoder_type;
static ErlNifResourceType *encoder_type;

static void decoder_dtor(ErlNifEnv *env, void *obj)
{
    decoder_t *d = obj;
    (void)env;
    if (d->open)
        vpx_codec_destroy(&d->ctx);
    if (d->lock)
        enif_mutex_destroy(d->lock);
}

static void encoder_dtor(ErlNifEnv *env, void *obj)
{
    encoder_t *e = obj;
    (void)env;
    if (e->open)
        vpx_codec_destroy(&e->ctx);
    if (e->lock)
        enif_mutex_destroy(e->lock);
}

static const char *vpx_reason(vpx_codec_err_t err)
{
    switch (err) {
    case VPX_CODEC_MEM_ERROR:
        return "alloc_fail";
    case VPX_CODEC_ABI_MISMATCH:
        return "abi_mismatch";
    case VPX_CODEC_INCAPABLE:
        return "incapable";
    case VPX_CODEC_UNSUP_BITSTREAM:
        return "unsupported_bitstream";
    case VPX_CODEC_UNSUP_FEATURE:
        return "unsupported_feature";
    case VPX_CODEC_CORRUPT_FRAME:
        return "corrupt_frame";
    case VPX_CODEC_INVALID_PARAM:
        return "invalid_param";
    default:
        return "internal_error";
    }
}

/* vp8 -> 0, vp9 -> 1, anything else -> -1 */
static int codec_arg(ErlNifEnv *env, ERL_NIF_TERM term)
{
    if (enif_is_identical(term, wc_atom(env, "vp8")))
        return 0;
    if (enif_is_identical(term, wc_atom(env, "vp9")))
        return 1;
    return -1;
}

static ERL_NIF_TERM version(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    (void)argv;
    return wc_binary(env, vpx_codec_version_str());
}

/* decoder_new(vp8 | vp9, Threads, MaxPixels) */
static ERL_NIF_TERM decoder_new(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    int vp9 = codec_arg(env, argv[0]);
    int threads;
    unsigned long max_pixels;
    vpx_codec_dec_cfg_t cfg;
    vpx_codec_err_t err;
    decoder_t *d;
    (void)argc;

    if (vp9 < 0 || !enif_get_int(env, argv[1], &threads) || threads < 1 || threads > 64 ||
        !enif_get_ulong(env, argv[2], &max_pixels) || max_pixels == 0)
        return enif_make_badarg(env);

    d = wc_resource(decoder_type, sizeof(*d));
    if (!d)
        return wc_error(env, "alloc_fail");
    d->max_pixels = max_pixels;
    d->lock = wc_mutex("webrtc_codecs_vpx_decoder");
    if (!d->lock) {
        return wc_new_failed(env, d, "alloc_fail");
    }
    memset(&cfg, 0, sizeof(cfg));
    cfg.threads = (unsigned int)threads;
    err = wc_fail() ? VPX_CODEC_MEM_ERROR : vpx_codec_dec_init(&d->ctx, vp9 ? vpx_codec_vp9_dx() : vpx_codec_vp8_dx(), &cfg, 0);
    if (err != VPX_CODEC_OK) {
        return wc_new_failed(env, d, vpx_reason(err));
    }
    d->open = 1;
    return wc_new_ok(env, d);
}

/* decode(Decoder, Data) -> {ok, [{Width, Height, Y, U, V}], Qp} | {error, Reason} */
static ERL_NIF_TERM decode(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    decoder_t *d;
    ErlNifBinary data;
    vpx_codec_err_t err;
    vpx_codec_iter_t iter = NULL;
    vpx_image_t *img;
    ERL_NIF_TERM list, result;
    const char *reason = NULL;
    int qp = 0;
    (void)argc;

    if (!enif_get_resource(env, argv[0], decoder_type, (void **)&d) || !enif_inspect_binary(env, argv[1], &data))
        return enif_make_badarg(env);
    if (data.size == 0 || data.size > MAX_FRAME_BYTES)
        return wc_error(env, "invalid_frame");

    list = enif_make_list(env, 0);
    enif_mutex_lock(d->lock);
    err = vpx_codec_decode(&d->ctx, data.data, (unsigned int)data.size, NULL, 0);
    if (err != VPX_CODEC_OK) {
        reason = vpx_reason(err);
    } else {
        while ((img = vpx_codec_get_frame(&d->ctx, &iter)) != NULL) {
            unsigned int w = img->d_w, h = img->d_h;
            unsigned int cw = (w + 1) / 2, ch = (h + 1) / 2;

            if (img->fmt != VPX_IMG_FMT_I420) {
                reason = "unsupported_format";
                break;
            }
            if (w == 0 || h == 0 || (unsigned long)w * h > d->max_pixels) {
                reason = "too_large";
                break;
            }
            list = enif_make_list_cell(
                env,
                enif_make_tuple5(env, enif_make_uint(env, w), enif_make_uint(env, h),
                                 wc_plane(env, img->planes[VPX_PLANE_Y], img->stride[VPX_PLANE_Y], w, h),
                                 wc_plane(env, img->planes[VPX_PLANE_U], img->stride[VPX_PLANE_U], cw, ch),
                                 wc_plane(env, img->planes[VPX_PLANE_V], img->stride[VPX_PLANE_V], cw, ch)),
                list);
        }
        if (!reason && vpx_codec_control(&d->ctx, VPXD_GET_LAST_QUANTIZER, &qp) != VPX_CODEC_OK)
            qp = 0;
    }
    enif_mutex_unlock(d->lock);

    if (reason)
        return wc_error(env, reason);
    if (!enif_make_reverse_list(env, list, &result))
        return wc_error(env, "internal_error");
    return enif_make_tuple3(env, wc_atom(env, "ok"), result, enif_make_int(env, qp));
}

/* Settings applied after the encoder is open. */
static vpx_codec_err_t encoder_controls(encoder_t *e, int vp9, int cpu_used)
{
    vpx_codec_err_t err;

    err = vpx_codec_control(&e->ctx, VP8E_SET_CPUUSED, cpu_used);
    if (err == VPX_CODEC_OK)
        err = vpx_codec_control(&e->ctx, VP8E_SET_STATIC_THRESHOLD, 1);
    if (err != VPX_CODEC_OK)
        return err;
    if (vp9) {
        err = vpx_codec_control(&e->ctx, VP9E_SET_AQ_MODE, 3);
        if (err == VPX_CODEC_OK)
            err = vpx_codec_control(&e->ctx, VP9E_SET_ROW_MT, 1);
        if (err == VPX_CODEC_OK)
            err = vpx_codec_control(&e->ctx, VP9E_SET_TILE_COLUMNS, e->cfg.g_w >= 1280 ? 2 : (e->cfg.g_w >= 640));
    } else {
        err = vpx_codec_control(&e->ctx, VP8E_SET_NOISE_SENSITIVITY, 0);
    }
    return err;
}

/* encoder_new(vp8 | vp9, Width, Height, #{bitrate, threads, cpu_used, keyframe_interval}) */
static ERL_NIF_TERM encoder_new(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    int vp9 = codec_arg(env, argv[0]);
    int w, h;
    int bitrate = 300000, threads = 1, cpu_used = 0, interval = 3000;
    vpx_codec_iface_t *iface;
    vpx_codec_err_t err;
    encoder_t *e;
    (void)argc;

    if (vp9 < 0 || !enif_get_int(env, argv[1], &w) || !enif_get_int(env, argv[2], &h) || w < 2 || h < 2 ||
        w > MAX_DIMENSION || h > MAX_DIMENSION || !enif_is_map(env, argv[3]))
        return enif_make_badarg(env);
    cpu_used = vp9 ? 7 : -6;
    if (!wc_map_int(env, argv[3], "bitrate", &bitrate) || !wc_map_int(env, argv[3], "threads", &threads) ||
        !wc_map_int(env, argv[3], "cpu_used", &cpu_used) || !wc_map_int(env, argv[3], "keyframe_interval", &interval) ||
        bitrate < 1000 || threads < 1 || threads > 64 || cpu_used < -16 || cpu_used > 16 || interval < 1)
        return enif_make_badarg(env);

    e = wc_resource(encoder_type, sizeof(*e));
    if (!e)
        return wc_error(env, "alloc_fail");
    e->lock = wc_mutex("webrtc_codecs_vpx_encoder");
    if (!e->lock) {
        return wc_new_failed(env, e, "alloc_fail");
    }

    iface = vp9 ? vpx_codec_vp9_cx() : vpx_codec_vp8_cx();
    err = vpx_codec_enc_config_default(iface, &e->cfg, 0);
    if (err == VPX_CODEC_OK) {
        /* Real time, one pass, constant bitrate, no frame held back. */
        e->cfg.g_w = (unsigned int)w;
        e->cfg.g_h = (unsigned int)h;
        e->cfg.g_timebase.num = 1;
        e->cfg.g_timebase.den = 90000;
        e->cfg.g_threads = (unsigned int)threads;
        e->cfg.g_pass = VPX_RC_ONE_PASS;
        e->cfg.g_lag_in_frames = 0;
        e->cfg.g_error_resilient = VPX_ERROR_RESILIENT_DEFAULT;
        e->cfg.rc_end_usage = VPX_CBR;
        e->cfg.rc_target_bitrate = (unsigned int)(bitrate / 1000);
        e->cfg.rc_min_quantizer = 2;
        e->cfg.rc_max_quantizer = vp9 ? 52 : 56;
        e->cfg.rc_undershoot_pct = 100;
        e->cfg.rc_overshoot_pct = 15;
        e->cfg.rc_buf_initial_sz = 500;
        e->cfg.rc_buf_optimal_sz = 600;
        e->cfg.rc_buf_sz = 1000;
        e->cfg.rc_dropframe_thresh = 0;
        e->cfg.rc_resize_allowed = 0;
        e->cfg.kf_mode = VPX_KF_AUTO;
        e->cfg.kf_min_dist = 0;
        e->cfg.kf_max_dist = (unsigned int)interval;
        err = wc_fail() ? VPX_CODEC_MEM_ERROR : vpx_codec_enc_init(&e->ctx, iface, &e->cfg, 0);
    }
    if (err == VPX_CODEC_OK) {
        e->open = 1;
        err = encoder_controls(e, vp9, cpu_used);
    }
    if (err != VPX_CODEC_OK) {
        return wc_new_failed(env, e, vpx_reason(err));
    }
    return wc_new_ok(env, e);
}

/* encoder_bitrate(Encoder, BitsPerSecond) */
static ERL_NIF_TERM encoder_bitrate(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    encoder_t *e;
    int bitrate;
    vpx_codec_err_t err;
    (void)argc;

    if (!enif_get_resource(env, argv[0], encoder_type, (void **)&e) || !enif_get_int(env, argv[1], &bitrate) ||
        bitrate < 1000)
        return enif_make_badarg(env);
    enif_mutex_lock(e->lock);
    e->cfg.rc_target_bitrate = (unsigned int)(bitrate / 1000);
    err = vpx_codec_enc_config_set(&e->ctx, &e->cfg);
    enif_mutex_unlock(e->lock);
    return err == VPX_CODEC_OK ? wc_atom(env, "ok") : wc_error(env, vpx_reason(err));
}

/* encode(Encoder, Y, U, V, Pts, Duration, ForceKey) -> {ok, [{Data, Key}], Qp} | {error, Reason}
 * Pts and Duration are in 90 kHz units; Pts grows from one call to the next. */
static ERL_NIF_TERM encode(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    encoder_t *e;
    ErlNifBinary y, u, v;
    ErlNifUInt64 pts;
    unsigned long duration;
    int force;
    unsigned int w, h, cw, ch;
    vpx_image_t img;
    vpx_codec_err_t err;
    vpx_codec_iter_t iter = NULL;
    const vpx_codec_cx_pkt_t *pkt;
    ERL_NIF_TERM list, result;
    int qp = 0;
    (void)argc;

    if (!enif_get_resource(env, argv[0], encoder_type, (void **)&e) || !enif_inspect_binary(env, argv[1], &y) ||
        !enif_inspect_binary(env, argv[2], &u) || !enif_inspect_binary(env, argv[3], &v) ||
        !enif_get_uint64(env, argv[4], &pts) || !enif_get_ulong(env, argv[5], &duration) || duration == 0)
        return enif_make_badarg(env);
    if (!wc_get_bool(env, argv[6], &force))
        return enif_make_badarg(env);

    w = e->cfg.g_w;
    h = e->cfg.g_h;
    cw = (w + 1) / 2;
    ch = (h + 1) / 2;
    if (y.size != (size_t)w * h || u.size != (size_t)cw * ch || v.size != (size_t)cw * ch)
        return wc_error(env, "bad_planes");

    /* The planes are read in place: libvpx copies what it keeps. */
    if (!vpx_img_wrap(&img, VPX_IMG_FMT_I420, w, h, 1, y.data))
        return wc_error(env, "internal_error");
    img.planes[VPX_PLANE_Y] = y.data;
    img.planes[VPX_PLANE_U] = u.data;
    img.planes[VPX_PLANE_V] = v.data;
    img.stride[VPX_PLANE_Y] = (int)w;
    img.stride[VPX_PLANE_U] = (int)cw;
    img.stride[VPX_PLANE_V] = (int)cw;

    list = enif_make_list(env, 0);
    enif_mutex_lock(e->lock);
    err = vpx_codec_encode(&e->ctx, &img, (vpx_codec_pts_t)pts, duration, force ? VPX_EFLAG_FORCE_KF : 0,
                           VPX_DL_REALTIME);
    if (err == VPX_CODEC_OK) {
        while ((pkt = vpx_codec_get_cx_data(&e->ctx, &iter)) != NULL) {
            ERL_NIF_TERM data;
            unsigned char *out;

            if (pkt->kind != VPX_CODEC_CX_FRAME_PKT)
                continue;
            out = enif_make_new_binary(env, pkt->data.frame.sz, &data);
            memcpy(out, pkt->data.frame.buf, pkt->data.frame.sz);
            list = enif_make_list_cell(
                env,
                enif_make_tuple2(env, data,
                                 wc_atom(env, (pkt->data.frame.flags & VPX_FRAME_IS_KEY) ? "true" : "false")),
                list);
        }
        if (vpx_codec_control(&e->ctx, VP8E_GET_LAST_QUANTIZER, &qp) != VPX_CODEC_OK)
            qp = 0;
    }
    enif_mutex_unlock(e->lock);

    if (err != VPX_CODEC_OK)
        return wc_error(env, vpx_reason(err));
    if (!enif_make_reverse_list(env, list, &result))
        return wc_error(env, "internal_error");
    return enif_make_tuple3(env, wc_atom(env, "ok"), result, enif_make_int(env, qp));
}

static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info)
{
    ErlNifResourceFlags flags = ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER;
    (void)priv;
    (void)info;

    decoder_type = enif_open_resource_type(env, NULL, "webrtc_codecs_vpx_decoder", decoder_dtor, flags, NULL);
    encoder_type = enif_open_resource_type(env, NULL, "webrtc_codecs_vpx_encoder", encoder_dtor, flags, NULL);
    return decoder_type && encoder_type ? 0 : -1;
}

static int upgrade(ErlNifEnv *env, void **priv, void **old_priv, ERL_NIF_TERM info)
{
    (void)old_priv;
    return load(env, priv, info);
}

static ErlNifFunc nif_funcs[] = {
    WC_FAULT_NIF
    {"version", 0, version, 0},
    {"decoder_new", 3, decoder_new, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"decode", 2, decode, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"encoder_new", 4, encoder_new, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"encoder_bitrate", 2, encoder_bitrate, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"encode", 7, encode, ERL_NIF_DIRTY_JOB_CPU_BOUND},
};

ERL_NIF_INIT(webrtc_codecs_vpx_nif, nif_funcs, load, NULL, upgrade, NULL)
