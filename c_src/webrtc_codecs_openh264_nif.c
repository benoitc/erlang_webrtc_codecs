/* OpenH264 for webrtc_codecs_h264.
 *
 * A decoder or an encoder lives in a resource, freed by its destructor.
 * Every call that touches one runs on a dirty CPU scheduler and holds
 * the lock of that resource. Pictures cross the boundary as three I420
 * planes without padding; frames are access units in Annex B.
 */
#include <stdbool.h>
#include <stdio.h>

#include <wels/codec_api.h>

#include "webrtc_codecs_nif.h"

/* Larger than any frame the frame buffer of erlang_webrtc releases. */
#define MAX_FRAME_BYTES (8 * 1024 * 1024)
#define MAX_DIMENSION 16384

typedef struct {
    ISVCDecoder *dec;
    ErlNifMutex *lock;
    unsigned long max_pixels;
} decoder_t;

typedef struct {
    ISVCEncoder *enc;
    ErlNifMutex *lock;
    int width;
    int height;
} encoder_t;

static ErlNifResourceType *decoder_type;
static ErlNifResourceType *encoder_type;

static void decoder_dtor(ErlNifEnv *env, void *obj)
{
    decoder_t *d = obj;
    (void)env;
    if (d->dec) {
        (*d->dec)->Uninitialize(d->dec);
        WelsDestroyDecoder(d->dec);
    }
    if (d->lock)
        enif_mutex_destroy(d->lock);
}

static void encoder_dtor(ErlNifEnv *env, void *obj)
{
    encoder_t *e = obj;
    (void)env;
    if (e->enc) {
        (*e->enc)->Uninitialize(e->enc);
        WelsDestroySVCEncoder(e->enc);
    }
    if (e->lock)
        enif_mutex_destroy(e->lock);
}

static ERL_NIF_TERM version(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    OpenH264Version v = WelsGetCodecVersion();
    char text[64];
    (void)argc;
    (void)argv;
    snprintf(text, sizeof(text), "%u.%u.%u", v.uMajor, v.uMinor, v.uRevision);
    return wc_binary(env, text);
}

/* The first thing wrong in a decoding state, as a reason. */
static const char *decode_reason(DECODING_STATE state)
{
    if (state & dsOutOfMemory)
        return "alloc_fail";
    if (state & dsNoParamSets)
        return "no_parameter_sets";
    if (state & dsRefLost)
        return "reference_lost";
    if (state & dsBitstreamError)
        return "corrupt_frame";
    if (state & dsDataErrorConcealed)
        return "corrupt_frame";
    return "invalid_frame";
}

/* decoder_new(MaxPixels) */
static ERL_NIF_TERM decoder_new(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    unsigned long max_pixels;
    SDecodingParam param;
    int quiet = WELS_LOG_QUIET;
    decoder_t *d;
    ERL_NIF_TERM term;
    (void)argc;

    if (!enif_get_ulong(env, argv[0], &max_pixels) || max_pixels == 0)
        return enif_make_badarg(env);

    d = enif_alloc_resource(decoder_type, sizeof(*d));
    if (!d)
        return wc_error(env, "alloc_fail");
    memset(d, 0, sizeof(*d));
    d->max_pixels = max_pixels;
    d->lock = enif_mutex_create("webrtc_codecs_openh264_decoder");
    if (!d->lock || WelsCreateDecoder(&d->dec) != 0 || !d->dec) {
        d->dec = NULL;
        enif_release_resource(d);
        return wc_error(env, "alloc_fail");
    }
    /* Bad media is reported to the caller, not printed. Should the
     * option not take, the decoder works all the same, with its log. */
    (void)(*d->dec)->SetOption(d->dec, DECODER_OPTION_TRACE_LEVEL, &quiet);
    memset(&param, 0, sizeof(param));
    param.sVideoProperty.eVideoBsType = VIDEO_BITSTREAM_AVC;
    /* No concealment: a frame that does not decode is an error, and the
     * caller waits for a key frame. */
    param.eEcActiveIdc = ERROR_CON_DISABLE;
    if ((*d->dec)->Initialize(d->dec, &param) != 0) {
        WelsDestroyDecoder(d->dec);
        d->dec = NULL;
        enif_release_resource(d);
        return wc_error(env, "internal_error");
    }
    term = enif_make_resource(env, d);
    enif_release_resource(d);
    return wc_ok(env, term);
}

static ERL_NIF_TERM plane(ErlNifEnv *env, const unsigned char *src, int stride, unsigned int w, unsigned int h)
{
    ERL_NIF_TERM term;
    unsigned char *dst = enif_make_new_binary(env, (size_t)w * h, &term);
    unsigned int row;

    for (row = 0; row < h; row++)
        memcpy(dst + (size_t)row * w, src + (size_t)row * stride, w);
    return term;
}

/* decode(Decoder, AccessUnit) -> {ok, [{Width, Height, Y, U, V}]} | {error, Reason} */
static ERL_NIF_TERM decode(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    decoder_t *d;
    ErlNifBinary data;
    unsigned char *dst[3] = {NULL, NULL, NULL};
    SBufferInfo info;
    DECODING_STATE state;
    ERL_NIF_TERM list;
    const char *reason = NULL;
    (void)argc;

    if (!enif_get_resource(env, argv[0], decoder_type, (void **)&d) || !enif_inspect_binary(env, argv[1], &data))
        return enif_make_badarg(env);
    if (data.size == 0 || data.size > MAX_FRAME_BYTES)
        return wc_error(env, "invalid_frame");

    list = enif_make_list(env, 0);
    memset(&info, 0, sizeof(info));
    enif_mutex_lock(d->lock);
    state = (*d->dec)->DecodeFrameNoDelay(d->dec, data.data, (int)data.size, dst, &info);
    if (state != dsErrorFree) {
        reason = decode_reason(state);
    } else if (info.iBufferStatus == 1) {
        int w = info.UsrData.sSystemBuffer.iWidth, h = info.UsrData.sSystemBuffer.iHeight;

        if (w <= 0 || h <= 0 || (unsigned long)w * (unsigned long)h > d->max_pixels) {
            reason = "too_large";
        } else if (info.UsrData.sSystemBuffer.iFormat != videoFormatI420 || !dst[0] || !dst[1] || !dst[2]) {
            reason = "unsupported_format";
        } else {
            unsigned int cw = ((unsigned int)w + 1) / 2, ch = ((unsigned int)h + 1) / 2;
            int ys = info.UsrData.sSystemBuffer.iStride[0], cs = info.UsrData.sSystemBuffer.iStride[1];

            list = enif_make_list_cell(
                env,
                enif_make_tuple5(env, enif_make_int(env, w), enif_make_int(env, h),
                                 plane(env, dst[0], ys, (unsigned int)w, (unsigned int)h), plane(env, dst[1], cs, cw, ch),
                                 plane(env, dst[2], cs, cw, ch)),
                list);
        }
    }
    enif_mutex_unlock(d->lock);

    if (reason)
        return wc_error(env, reason);
    return wc_ok(env, list);
}

/* encoder_new(Width, Height, #{bitrate, threads, keyframe_interval}) */
static ERL_NIF_TERM encoder_new(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    int w, h;
    int bitrate = 300000, threads = 1, interval = 3000;
    int quiet = WELS_LOG_QUIET, format = videoFormatI420;
    SEncParamExt param;
    encoder_t *e;
    ERL_NIF_TERM term;
    (void)argc;

    if (!enif_get_int(env, argv[0], &w) || !enif_get_int(env, argv[1], &h) || w < 2 || h < 2 ||
        w > MAX_DIMENSION || h > MAX_DIMENSION || !enif_is_map(env, argv[2]))
        return enif_make_badarg(env);
    if (!wc_map_int(env, argv[2], "bitrate", &bitrate) || !wc_map_int(env, argv[2], "threads", &threads) ||
        !wc_map_int(env, argv[2], "keyframe_interval", &interval) || bitrate < 1000 || threads < 1 ||
        threads > 64 || interval < 1)
        return enif_make_badarg(env);

    e = enif_alloc_resource(encoder_type, sizeof(*e));
    if (!e)
        return wc_error(env, "alloc_fail");
    memset(e, 0, sizeof(*e));
    e->width = w;
    e->height = h;
    e->lock = enif_mutex_create("webrtc_codecs_openh264_encoder");
    if (!e->lock || WelsCreateSVCEncoder(&e->enc) != 0 || !e->enc) {
        e->enc = NULL;
        enif_release_resource(e);
        return wc_error(env, "alloc_fail");
    }
    /* Should the option not take, the encoder works all the same, with
     * its log. */
    (void)(*e->enc)->SetOption(e->enc, ENCODER_OPTION_TRACE_LEVEL, &quiet);

    /* Real time, one layer, constrained baseline, one frame out for each
     * picture in. */
    memset(&param, 0, sizeof(param));
    if ((*e->enc)->GetDefaultParams(e->enc, &param) != 0) {
        WelsDestroySVCEncoder(e->enc);
        e->enc = NULL;
        enif_release_resource(e);
        return wc_error(env, "internal_error");
    }
    param.iUsageType = CAMERA_VIDEO_REAL_TIME;
    param.iPicWidth = w;
    param.iPicHeight = h;
    param.iTargetBitrate = bitrate;
    param.iMaxBitrate = UNSPECIFIED_BIT_RATE;
    param.iRCMode = RC_BITRATE_MODE;
    param.fMaxFrameRate = 30.0f;
    param.iTemporalLayerNum = 1;
    param.iSpatialLayerNum = 1;
    param.uiIntraPeriod = (unsigned int)interval;
    param.iMultipleThreadIdc = (unsigned short)threads;
    param.bEnableFrameSkip = false;
    param.bEnableDenoise = false;
    param.iEntropyCodingModeFlag = 0;
    param.eSpsPpsIdStrategy = CONSTANT_ID;
    param.uiMaxNalSize = 0;
    param.sSpatialLayers[0].iVideoWidth = w;
    param.sSpatialLayers[0].iVideoHeight = h;
    param.sSpatialLayers[0].fFrameRate = 30.0f;
    param.sSpatialLayers[0].iSpatialBitrate = bitrate;
    param.sSpatialLayers[0].iMaxSpatialBitrate = UNSPECIFIED_BIT_RATE;
    param.sSpatialLayers[0].uiProfileIdc = PRO_BASELINE;
    param.sSpatialLayers[0].sSliceArgument.uiSliceMode = SM_SINGLE_SLICE;
    if ((*e->enc)->InitializeExt(e->enc, &param) != 0) {
        WelsDestroySVCEncoder(e->enc);
        e->enc = NULL;
        enif_release_resource(e);
        return wc_error(env, "invalid_param");
    }
    if ((*e->enc)->SetOption(e->enc, ENCODER_OPTION_DATAFORMAT, &format) != 0) {
        /* The destructor uninitializes and destroys the encoder. */
        enif_release_resource(e);
        return wc_error(env, "invalid_param");
    }
    term = enif_make_resource(env, e);
    enif_release_resource(e);
    return wc_ok(env, term);
}

/* encoder_bitrate(Encoder, BitsPerSecond) */
static ERL_NIF_TERM encoder_bitrate(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    encoder_t *e;
    int bitrate, res;
    SBitrateInfo info;
    (void)argc;

    if (!enif_get_resource(env, argv[0], encoder_type, (void **)&e) || !enif_get_int(env, argv[1], &bitrate) ||
        bitrate < 1000)
        return enif_make_badarg(env);
    memset(&info, 0, sizeof(info));
    info.iLayer = SPATIAL_LAYER_ALL;
    info.iBitrate = bitrate;
    enif_mutex_lock(e->lock);
    res = (*e->enc)->SetOption(e->enc, ENCODER_OPTION_BITRATE, &info);
    enif_mutex_unlock(e->lock);
    return res == 0 ? wc_atom(env, "ok") : wc_error(env, "invalid_param");
}

/* encode(Encoder, Y, U, V, Pts, ForceKey) -> {ok, [{AccessUnit, Key}]} | {error, Reason}
 * Pts is in 90 kHz units. A picture the encoder skips gives no frame. */
static ERL_NIF_TERM encode(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    encoder_t *e;
    ErlNifBinary y, u, v;
    ErlNifUInt64 pts;
    int force, res, layer, nal;
    unsigned int w, h, cw, ch;
    SSourcePicture pic;
    SFrameBSInfo info;
    ERL_NIF_TERM list, data;
    unsigned char *out;
    size_t total = 0, offset = 0;
    (void)argc;

    if (!enif_get_resource(env, argv[0], encoder_type, (void **)&e) || !enif_inspect_binary(env, argv[1], &y) ||
        !enif_inspect_binary(env, argv[2], &u) || !enif_inspect_binary(env, argv[3], &v) ||
        !enif_get_uint64(env, argv[4], &pts))
        return enif_make_badarg(env);
    if (enif_is_identical(argv[5], wc_atom(env, "true")))
        force = 1;
    else if (enif_is_identical(argv[5], wc_atom(env, "false")))
        force = 0;
    else
        return enif_make_badarg(env);

    w = (unsigned int)e->width;
    h = (unsigned int)e->height;
    cw = (w + 1) / 2;
    ch = (h + 1) / 2;
    if (y.size != (size_t)w * h || u.size != (size_t)cw * ch || v.size != (size_t)cw * ch)
        return wc_error(env, "bad_planes");

    /* The planes are read in place: the encoder copies what it keeps. */
    memset(&pic, 0, sizeof(pic));
    pic.iColorFormat = videoFormatI420;
    pic.iPicWidth = (int)w;
    pic.iPicHeight = (int)h;
    pic.iStride[0] = (int)w;
    pic.iStride[1] = (int)cw;
    pic.iStride[2] = (int)cw;
    pic.pData[0] = y.data;
    pic.pData[1] = u.data;
    pic.pData[2] = v.data;
    pic.uiTimeStamp = (long long)(pts / 90);
    memset(&info, 0, sizeof(info));

    list = enif_make_list(env, 0);
    enif_mutex_lock(e->lock);
    /* A key frame that was asked for and cannot be made is an error, not
     * an ordinary frame in its place. */
    res = force ? (*e->enc)->ForceIntraFrame(e->enc, true) : 0;
    if (res == 0)
        res = (*e->enc)->EncodeFrame(e->enc, &pic, &info);
    if (res == 0 && info.eFrameType != videoFrameTypeSkip && info.eFrameType != videoFrameTypeInvalid) {
        for (layer = 0; layer < info.iLayerNum; layer++)
            for (nal = 0; nal < info.sLayerInfo[layer].iNalCount; nal++)
                total += (size_t)info.sLayerInfo[layer].pNalLengthInByte[nal];
        if (total > 0 && total <= MAX_FRAME_BYTES) {
            out = enif_make_new_binary(env, total, &data);
            for (layer = 0; layer < info.iLayerNum; layer++) {
                size_t size = 0;

                for (nal = 0; nal < info.sLayerInfo[layer].iNalCount; nal++)
                    size += (size_t)info.sLayerInfo[layer].pNalLengthInByte[nal];
                memcpy(out + offset, info.sLayerInfo[layer].pBsBuf, size);
                offset += size;
            }
            list = enif_make_list_cell(
                env, enif_make_tuple2(env, data, wc_atom(env, info.eFrameType == videoFrameTypeIDR ? "true" : "false")),
                list);
        }
    }
    enif_mutex_unlock(e->lock);

    if (res != 0)
        return wc_error(env, "internal_error");
    return wc_ok(env, list);
}

static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info)
{
    ErlNifResourceFlags flags = ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER;
    (void)priv;
    (void)info;

    decoder_type = enif_open_resource_type(env, NULL, "webrtc_codecs_openh264_decoder", decoder_dtor, flags, NULL);
    encoder_type = enif_open_resource_type(env, NULL, "webrtc_codecs_openh264_encoder", encoder_dtor, flags, NULL);
    return decoder_type && encoder_type ? 0 : -1;
}

static int upgrade(ErlNifEnv *env, void **priv, void **old_priv, ERL_NIF_TERM info)
{
    (void)old_priv;
    return load(env, priv, info);
}

static ErlNifFunc nif_funcs[] = {
    {"version", 0, version, 0},
    {"decoder_new", 1, decoder_new, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"decode", 2, decode, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"encoder_new", 3, encoder_new, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"encoder_bitrate", 2, encoder_bitrate, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"encode", 6, encode, ERL_NIF_DIRTY_JOB_CPU_BOUND},
};

ERL_NIF_INIT(webrtc_codecs_openh264_nif, nif_funcs, load, NULL, upgrade, NULL)
