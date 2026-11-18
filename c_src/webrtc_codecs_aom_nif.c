/* libaom (AV1 encoding) for webrtc_codecs_av1.
 *
 * An encoder lives in a resource, freed by its destructor. Every call
 * that touches it runs on a dirty CPU scheduler and holds its lock.
 * Pictures come in as three I420 planes without padding; frames come
 * out as temporal units in the low overhead format.
 */
#include <aom/aom_encoder.h>
#include <aom/aomcx.h>

#include "webrtc_codecs_nif.h"

#define MAX_DIMENSION 16384

typedef struct {
    aom_codec_ctx_t ctx;
    aom_codec_enc_cfg_t cfg;
    int open;
    ErlNifMutex *lock;
} encoder_t;

static ErlNifResourceType *encoder_type;

static void encoder_dtor(ErlNifEnv *env, void *obj)
{
    encoder_t *e = obj;
    (void)env;
    if (e->open)
        aom_codec_destroy(&e->ctx);
    if (e->lock)
        enif_mutex_destroy(e->lock);
}

static const char *aom_reason(aom_codec_err_t err)
{
    switch (err) {
    case AOM_CODEC_MEM_ERROR:
        return "alloc_fail";
    case AOM_CODEC_ABI_MISMATCH:
        return "abi_mismatch";
    case AOM_CODEC_INCAPABLE:
        return "incapable";
    case AOM_CODEC_UNSUP_BITSTREAM:
        return "unsupported_bitstream";
    case AOM_CODEC_UNSUP_FEATURE:
        return "unsupported_feature";
    case AOM_CODEC_CORRUPT_FRAME:
        return "corrupt_frame";
    case AOM_CODEC_INVALID_PARAM:
        return "invalid_param";
    default:
        return "internal_error";
    }
}

static ERL_NIF_TERM version(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    (void)argv;
    return wc_binary(env, aom_codec_version_str());
}

/* Real time settings. The speed has to apply; the tools switched off
 * below only cost time in a call, so a libaom without one of them is
 * not an error. */
static aom_codec_err_t encoder_controls(encoder_t *e, int cpu_used)
{
    aom_codec_err_t err = aom_codec_control(&e->ctx, AOME_SET_CPUUSED, cpu_used);

    if (err != AOM_CODEC_OK)
        return err;
    (void)aom_codec_control(&e->ctx, AV1E_SET_AQ_MODE, 3);
    (void)aom_codec_control(&e->ctx, AV1E_SET_ROW_MT, 1);
    (void)aom_codec_control(&e->ctx, AV1E_SET_TILE_COLUMNS, e->cfg.g_w >= 1280 ? 2 : (e->cfg.g_w >= 640));
    (void)aom_codec_control(&e->ctx, AV1E_SET_ENABLE_CDEF, 1);
    (void)aom_codec_control(&e->ctx, AV1E_SET_ENABLE_TPL_MODEL, 0);
    (void)aom_codec_control(&e->ctx, AV1E_SET_DELTAQ_MODE, 0);
    (void)aom_codec_control(&e->ctx, AV1E_SET_ENABLE_ORDER_HINT, 0);
    (void)aom_codec_control(&e->ctx, AV1E_SET_ENABLE_OBMC, 0);
    (void)aom_codec_control(&e->ctx, AV1E_SET_ENABLE_WARPED_MOTION, 0);
    (void)aom_codec_control(&e->ctx, AV1E_SET_ENABLE_GLOBAL_MOTION, 0);
    (void)aom_codec_control(&e->ctx, AV1E_SET_ENABLE_REF_FRAME_MVS, 0);
    return AOM_CODEC_OK;
}

/* encoder_new(Width, Height, #{bitrate, threads, cpu_used, keyframe_interval}) */
static ERL_NIF_TERM encoder_new(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    int w, h;
    int bitrate = 300000, threads = 1, cpu_used = 9, interval = 3000;
    aom_codec_iface_t *iface = aom_codec_av1_cx();
    aom_codec_err_t err;
    encoder_t *e;
    ERL_NIF_TERM term;
    (void)argc;

    if (!enif_get_int(env, argv[0], &w) || !enif_get_int(env, argv[1], &h) || w < 2 || h < 2 ||
        w > MAX_DIMENSION || h > MAX_DIMENSION || !enif_is_map(env, argv[2]))
        return enif_make_badarg(env);
    if (!wc_map_int(env, argv[2], "bitrate", &bitrate) || !wc_map_int(env, argv[2], "threads", &threads) ||
        !wc_map_int(env, argv[2], "cpu_used", &cpu_used) || !wc_map_int(env, argv[2], "keyframe_interval", &interval) ||
        bitrate < 1000 || threads < 1 || threads > 64 || interval < 1)
        return enif_make_badarg(env);
    /* The range libaom takes in real time. */
    if (cpu_used < 0)
        cpu_used = 0;
    if (cpu_used > 11)
        cpu_used = 11;

    e = enif_alloc_resource(encoder_type, sizeof(*e));
    if (!e)
        return wc_error(env, "alloc_fail");
    memset(e, 0, sizeof(*e));
    e->lock = enif_mutex_create("webrtc_codecs_aom_encoder");
    if (!e->lock) {
        enif_release_resource(e);
        return wc_error(env, "alloc_fail");
    }

    err = aom_codec_enc_config_default(iface, &e->cfg, AOM_USAGE_REALTIME);
    if (err == AOM_CODEC_OK) {
        /* One pass, constant bitrate, no frame held back, 8 bit 4:2:0. */
        e->cfg.g_w = (unsigned int)w;
        e->cfg.g_h = (unsigned int)h;
        e->cfg.g_timebase.num = 1;
        e->cfg.g_timebase.den = 90000;
        e->cfg.g_threads = (unsigned int)threads;
        e->cfg.g_pass = AOM_RC_ONE_PASS;
        e->cfg.g_lag_in_frames = 0;
        e->cfg.g_error_resilient = 0;
        e->cfg.g_profile = 0;
        e->cfg.g_bit_depth = AOM_BITS_8;
        e->cfg.g_input_bit_depth = 8;
        e->cfg.rc_end_usage = AOM_CBR;
        e->cfg.rc_target_bitrate = (unsigned int)(bitrate / 1000);
        e->cfg.rc_min_quantizer = 2;
        e->cfg.rc_max_quantizer = 56;
        e->cfg.rc_undershoot_pct = 50;
        e->cfg.rc_overshoot_pct = 50;
        e->cfg.rc_buf_initial_sz = 600;
        e->cfg.rc_buf_optimal_sz = 600;
        e->cfg.rc_buf_sz = 1000;
        e->cfg.rc_dropframe_thresh = 0;
        e->cfg.kf_mode = AOM_KF_AUTO;
        e->cfg.kf_min_dist = 0;
        e->cfg.kf_max_dist = (unsigned int)interval;
        err = aom_codec_enc_init(&e->ctx, iface, &e->cfg, 0);
    }
    if (err == AOM_CODEC_OK) {
        e->open = 1;
        err = encoder_controls(e, cpu_used);
    }
    if (err != AOM_CODEC_OK) {
        enif_release_resource(e);
        return wc_error(env, aom_reason(err));
    }
    term = enif_make_resource(env, e);
    enif_release_resource(e);
    return wc_ok(env, term);
}

/* encoder_bitrate(Encoder, BitsPerSecond) */
static ERL_NIF_TERM encoder_bitrate(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    encoder_t *e;
    int bitrate;
    aom_codec_err_t err;
    (void)argc;

    if (!enif_get_resource(env, argv[0], encoder_type, (void **)&e) || !enif_get_int(env, argv[1], &bitrate) ||
        bitrate < 1000)
        return enif_make_badarg(env);
    enif_mutex_lock(e->lock);
    e->cfg.rc_target_bitrate = (unsigned int)(bitrate / 1000);
    err = aom_codec_enc_config_set(&e->ctx, &e->cfg);
    enif_mutex_unlock(e->lock);
    return err == AOM_CODEC_OK ? wc_atom(env, "ok") : wc_error(env, aom_reason(err));
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
    aom_image_t img;
    aom_codec_err_t err;
    aom_codec_iter_t iter = NULL;
    const aom_codec_cx_pkt_t *pkt;
    ERL_NIF_TERM list, result;
    int qp = 0;
    (void)argc;

    if (!enif_get_resource(env, argv[0], encoder_type, (void **)&e) || !enif_inspect_binary(env, argv[1], &y) ||
        !enif_inspect_binary(env, argv[2], &u) || !enif_inspect_binary(env, argv[3], &v) ||
        !enif_get_uint64(env, argv[4], &pts) || !enif_get_ulong(env, argv[5], &duration) || duration == 0)
        return enif_make_badarg(env);
    if (enif_is_identical(argv[6], wc_atom(env, "true")))
        force = 1;
    else if (enif_is_identical(argv[6], wc_atom(env, "false")))
        force = 0;
    else
        return enif_make_badarg(env);

    w = e->cfg.g_w;
    h = e->cfg.g_h;
    cw = (w + 1) / 2;
    ch = (h + 1) / 2;
    if (y.size != (size_t)w * h || u.size != (size_t)cw * ch || v.size != (size_t)cw * ch)
        return wc_error(env, "bad_planes");

    /* The planes are read in place: libaom copies what it keeps. */
    if (!aom_img_wrap(&img, AOM_IMG_FMT_I420, w, h, 1, y.data))
        return wc_error(env, "internal_error");
    img.planes[AOM_PLANE_Y] = y.data;
    img.planes[AOM_PLANE_U] = u.data;
    img.planes[AOM_PLANE_V] = v.data;
    img.stride[AOM_PLANE_Y] = (int)w;
    img.stride[AOM_PLANE_U] = (int)cw;
    img.stride[AOM_PLANE_V] = (int)cw;

    list = enif_make_list(env, 0);
    enif_mutex_lock(e->lock);
    err = aom_codec_encode(&e->ctx, &img, (aom_codec_pts_t)pts, duration, force ? AOM_EFLAG_FORCE_KF : 0);
    if (err == AOM_CODEC_OK) {
        while ((pkt = aom_codec_get_cx_data(&e->ctx, &iter)) != NULL) {
            ERL_NIF_TERM data;
            unsigned char *out;

            if (pkt->kind != AOM_CODEC_CX_FRAME_PKT)
                continue;
            out = enif_make_new_binary(env, pkt->data.frame.sz, &data);
            memcpy(out, pkt->data.frame.buf, pkt->data.frame.sz);
            list = enif_make_list_cell(
                env,
                enif_make_tuple2(env, data,
                                 wc_atom(env, (pkt->data.frame.flags & AOM_FRAME_IS_KEY) ? "true" : "false")),
                list);
        }
        if (aom_codec_control(&e->ctx, AOME_GET_LAST_QUANTIZER, &qp) != AOM_CODEC_OK)
            qp = 0;
    }
    enif_mutex_unlock(e->lock);

    if (err != AOM_CODEC_OK)
        return wc_error(env, aom_reason(err));
    if (!enif_make_reverse_list(env, list, &result))
        return wc_error(env, "internal_error");
    return enif_make_tuple3(env, wc_atom(env, "ok"), result, enif_make_int(env, qp));
}

static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info)
{
    (void)priv;
    (void)info;
    encoder_type = enif_open_resource_type(env, NULL, "webrtc_codecs_aom_encoder", encoder_dtor,
                                           ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER, NULL);
    return encoder_type ? 0 : -1;
}

static int upgrade(ErlNifEnv *env, void **priv, void **old_priv, ERL_NIF_TERM info)
{
    (void)old_priv;
    return load(env, priv, info);
}

static ErlNifFunc nif_funcs[] = {
    {"version", 0, version, 0},
    {"encoder_new", 3, encoder_new, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"encoder_bitrate", 2, encoder_bitrate, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"encode", 7, encode, ERL_NIF_DIRTY_JOB_CPU_BOUND},
};

ERL_NIF_INIT(webrtc_codecs_aom_nif, nif_funcs, load, NULL, upgrade, NULL)
