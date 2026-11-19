/* libopus for webrtc_codecs_opus.
 *
 * A decoder or an encoder lives in a resource, freed by its destructor.
 * Every call that touches one runs on a dirty CPU scheduler and holds
 * the lock of that resource, so two processes sharing a reference cannot
 * corrupt it. Samples cross the boundary as signed 16 bit little endian.
 */
#include <opus.h>

#include "webrtc_codecs_nif.h"

/* The longest Opus frame is 120 ms. */
#define MAX_FRAME_MS 120
/* Enough for 120 ms at the highest bitrate. */
#define MAX_PACKET 7680

typedef struct {
    OpusDecoder *dec;
    ErlNifMutex *lock;
    int rate;
    int channels;
} decoder_t;

typedef struct {
    OpusEncoder *enc;
    ErlNifMutex *lock;
    int rate;
    int channels;
} encoder_t;

static ErlNifResourceType *decoder_type;
static ErlNifResourceType *encoder_type;

static void decoder_dtor(ErlNifEnv *env, void *obj)
{
    decoder_t *d = obj;
    (void)env;
    if (d->dec)
        opus_decoder_destroy(d->dec);
    if (d->lock)
        enif_mutex_destroy(d->lock);
}

static void encoder_dtor(ErlNifEnv *env, void *obj)
{
    encoder_t *e = obj;
    (void)env;
    if (e->enc)
        opus_encoder_destroy(e->enc);
    if (e->lock)
        enif_mutex_destroy(e->lock);
}

static const char *opus_reason(int err)
{
    switch (err) {
    case OPUS_BAD_ARG:
        return "bad_arg";
    case OPUS_BUFFER_TOO_SMALL:
        return "buffer_too_small";
    case OPUS_INVALID_PACKET:
        return "invalid_packet";
    case OPUS_UNIMPLEMENTED:
        return "unimplemented";
    case OPUS_INVALID_STATE:
        return "invalid_state";
    case OPUS_ALLOC_FAIL:
        return "alloc_fail";
    default:
        return "internal_error";
    }
}

static int valid_format(int rate, int channels)
{
    return (rate == 8000 || rate == 12000 || rate == 16000 || rate == 24000 || rate == 48000) &&
           (channels == 1 || channels == 2);
}

static ERL_NIF_TERM version(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    (void)argv;
    return wc_binary(env, opus_get_version_string());
}

static ERL_NIF_TERM decoder_new(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    int rate, channels, err;
    decoder_t *d;
    (void)argc;

    if (!enif_get_int(env, argv[0], &rate) || !enif_get_int(env, argv[1], &channels) ||
        !valid_format(rate, channels))
        return enif_make_badarg(env);

    d = wc_resource(decoder_type, sizeof(*d));
    if (!d)
        return wc_error(env, "alloc_fail");
    d->rate = rate;
    d->channels = channels;
    err = OPUS_ALLOC_FAIL;
    d->dec = wc_fail() ? NULL : opus_decoder_create(rate, channels, &err);
    d->lock = wc_mutex("webrtc_codecs_opus_decoder");
    if (!d->dec || !d->lock) {
        /* The reason is read before the release, which frees d. */
        const char *reason = d->dec ? "alloc_fail" : opus_reason(err);

        return wc_new_failed(env, d, reason);
    }
    return wc_new_ok(env, d);
}

/* Decode into a new binary of little endian samples. data is NULL to
 * conceal a lost frame of `frame` samples. */
static ERL_NIF_TERM run_decoder(ErlNifEnv *env, decoder_t *d, const unsigned char *data, size_t len, int frame,
                                int fec)
{
    opus_int16 *pcm;
    unsigned char *out;
    ERL_NIF_TERM term;
    int got, count, i;

    pcm = enif_alloc(sizeof(opus_int16) * (size_t)frame * (size_t)d->channels);
    if (!pcm)
        return wc_error(env, "alloc_fail");

    enif_mutex_lock(d->lock);
    got = opus_decode(d->dec, data, (opus_int32)len, pcm, frame, fec);
    enif_mutex_unlock(d->lock);

    if (got < 0) {
        enif_free(pcm);
        return wc_error(env, opus_reason(got));
    }
    count = got * d->channels;
    out = enif_make_new_binary(env, (size_t)count * 2, &term);
    for (i = 0; i < count; i++) {
        out[2 * i] = (unsigned char)(pcm[i] & 0xFF);
        out[2 * i + 1] = (unsigned char)((pcm[i] >> 8) & 0xFF);
    }
    enif_free(pcm);
    return wc_ok(env, term);
}

/* A number of samples a decoder can produce in one call: a multiple of
 * 2.5 ms, at most 120 ms. */
static int valid_frame(const decoder_t *d, int frame)
{
    return frame > 0 && frame <= d->rate / 1000 * MAX_FRAME_MS && frame % (d->rate / 400) == 0;
}

static ERL_NIF_TERM decode(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    decoder_t *d;
    ErlNifBinary packet;
    (void)argc;

    if (!enif_get_resource(env, argv[0], decoder_type, (void **)&d) ||
        !enif_inspect_binary(env, argv[1], &packet))
        return enif_make_badarg(env);
    if (packet.size == 0 || packet.size > MAX_PACKET)
        return wc_error(env, "invalid_packet");
    return run_decoder(env, d, packet.data, packet.size, d->rate / 1000 * MAX_FRAME_MS, 0);
}

/* The frame before `packet`, from the redundancy the packet carries, or
 * concealment when it carries none. */
static ERL_NIF_TERM decode_fec(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    decoder_t *d;
    ErlNifBinary packet;
    int frame;
    (void)argc;

    if (!enif_get_resource(env, argv[0], decoder_type, (void **)&d) ||
        !enif_inspect_binary(env, argv[1], &packet) || !enif_get_int(env, argv[2], &frame) ||
        !valid_frame(d, frame))
        return enif_make_badarg(env);
    if (packet.size == 0 || packet.size > MAX_PACKET)
        return wc_error(env, "invalid_packet");
    return run_decoder(env, d, packet.data, packet.size, frame, 1);
}

static ERL_NIF_TERM conceal(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    decoder_t *d;
    int frame;
    (void)argc;

    if (!enif_get_resource(env, argv[0], decoder_type, (void **)&d) || !enif_get_int(env, argv[1], &frame) ||
        !valid_frame(d, frame))
        return enif_make_badarg(env);
    return run_decoder(env, d, NULL, 0, frame, 0);
}

/* Apply the settings present in the map. Returns an Opus error code. */
static int encoder_apply(ErlNifEnv *env, encoder_t *e, ERL_NIF_TERM opts, int *badarg)
{
    int bitrate = 0, complexity = -1, fec = -1, dtx = -1, loss = -1;
    int err = OPUS_OK;

    *badarg = !wc_map_int(env, opts, "bitrate", &bitrate) || !wc_map_int(env, opts, "complexity", &complexity) ||
              !wc_map_bool(env, opts, "fec", &fec) || !wc_map_bool(env, opts, "dtx", &dtx) ||
              !wc_map_int(env, opts, "packet_loss", &loss);
    if (*badarg)
        return OPUS_BAD_ARG;

    if (bitrate > 0)
        err = opus_encoder_ctl(e->enc, OPUS_SET_BITRATE(bitrate));
    if (err == OPUS_OK && complexity >= 0)
        err = opus_encoder_ctl(e->enc, OPUS_SET_COMPLEXITY(complexity));
    if (err == OPUS_OK && fec >= 0)
        err = opus_encoder_ctl(e->enc, OPUS_SET_INBAND_FEC(fec));
    if (err == OPUS_OK && dtx >= 0)
        err = opus_encoder_ctl(e->enc, OPUS_SET_DTX(dtx));
    if (err == OPUS_OK && loss >= 0)
        err = opus_encoder_ctl(e->enc, OPUS_SET_PACKET_LOSS_PERC(loss));
    return err;
}

static ERL_NIF_TERM encoder_new(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    int rate, channels, err, badarg, application;
    encoder_t *e;
    (void)argc;

    if (!enif_get_int(env, argv[0], &rate) || !enif_get_int(env, argv[1], &channels) ||
        !valid_format(rate, channels) || !enif_is_map(env, argv[3]))
        return enif_make_badarg(env);
    if (enif_is_identical(argv[2], wc_atom(env, "voip")))
        application = OPUS_APPLICATION_VOIP;
    else if (enif_is_identical(argv[2], wc_atom(env, "audio")))
        application = OPUS_APPLICATION_AUDIO;
    else if (enif_is_identical(argv[2], wc_atom(env, "lowdelay")))
        application = OPUS_APPLICATION_RESTRICTED_LOWDELAY;
    else
        return enif_make_badarg(env);

    e = wc_resource(encoder_type, sizeof(*e));
    if (!e)
        return wc_error(env, "alloc_fail");
    e->rate = rate;
    e->channels = channels;
    err = OPUS_ALLOC_FAIL;
    e->enc = wc_fail() ? NULL : opus_encoder_create(rate, channels, application, &err);
    e->lock = wc_mutex("webrtc_codecs_opus_encoder");
    if (!e->enc || !e->lock) {
        /* The reason is read before the release, which frees e. */
        const char *reason = e->enc ? "alloc_fail" : opus_reason(err);

        return wc_new_failed(env, e, reason);
    }
    err = encoder_apply(env, e, argv[3], &badarg);
    if (err != OPUS_OK) {
        enif_release_resource(e);
        return badarg ? enif_make_badarg(env) : wc_error(env, opus_reason(err));
    }
    return wc_new_ok(env, e);
}

static ERL_NIF_TERM encoder_set(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    encoder_t *e;
    int err, badarg;
    (void)argc;

    if (!enif_get_resource(env, argv[0], encoder_type, (void **)&e) || !enif_is_map(env, argv[1]))
        return enif_make_badarg(env);
    enif_mutex_lock(e->lock);
    err = encoder_apply(env, e, argv[1], &badarg);
    enif_mutex_unlock(e->lock);
    if (badarg)
        return enif_make_badarg(env);
    return err == OPUS_OK ? wc_atom(env, "ok") : wc_error(env, opus_reason(err));
}

static ERL_NIF_TERM encoder_bitrate(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    encoder_t *e;
    opus_int32 bitrate = 0;
    int err;
    (void)argc;

    if (!enif_get_resource(env, argv[0], encoder_type, (void **)&e))
        return enif_make_badarg(env);
    enif_mutex_lock(e->lock);
    err = opus_encoder_ctl(e->enc, OPUS_GET_BITRATE(&bitrate));
    enif_mutex_unlock(e->lock);
    return err == OPUS_OK ? wc_ok(env, enif_make_int(env, bitrate)) : wc_error(env, opus_reason(err));
}

static ERL_NIF_TERM encode(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    encoder_t *e;
    ErlNifBinary in;
    opus_int16 *pcm;
    unsigned char *packet, *out;
    ERL_NIF_TERM term;
    size_t count, i;
    int frame, len;
    (void)argc;

    if (!enif_get_resource(env, argv[0], encoder_type, (void **)&e) || !enif_inspect_binary(env, argv[1], &in))
        return enif_make_badarg(env);

    /* Whole samples for every channel, at most 120 ms; libopus checks
     * that the duration is one it can encode. */
    count = in.size / 2;
    if (in.size == 0 || in.size % (2 * (size_t)e->channels) != 0 ||
        count / (size_t)e->channels > (size_t)(e->rate / 1000 * MAX_FRAME_MS))
        return wc_error(env, "bad_arg");
    frame = (int)(count / (size_t)e->channels);

    pcm = enif_alloc(sizeof(opus_int16) * count + MAX_PACKET);
    if (!pcm)
        return wc_error(env, "alloc_fail");
    packet = (unsigned char *)(pcm + count);
    for (i = 0; i < count; i++)
        pcm[i] = (opus_int16)(in.data[2 * i] | (in.data[2 * i + 1] << 8));

    enif_mutex_lock(e->lock);
    len = opus_encode(e->enc, pcm, frame, packet, MAX_PACKET);
    enif_mutex_unlock(e->lock);

    if (len < 0) {
        enif_free(pcm);
        return wc_error(env, opus_reason(len));
    }
    out = enif_make_new_binary(env, (size_t)len, &term);
    memcpy(out, packet, (size_t)len);
    enif_free(pcm);
    return wc_ok(env, term);
}

static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info)
{
    ErlNifResourceFlags flags = ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER;
    (void)priv;
    (void)info;

    decoder_type = enif_open_resource_type(env, NULL, "webrtc_codecs_opus_decoder", decoder_dtor, flags, NULL);
    encoder_type = enif_open_resource_type(env, NULL, "webrtc_codecs_opus_encoder", encoder_dtor, flags, NULL);
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
    {"decoder_new", 2, decoder_new, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"decode", 2, decode, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"decode_fec", 3, decode_fec, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"conceal", 2, conceal, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"encoder_new", 4, encoder_new, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"encoder_set", 2, encoder_set, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"encoder_bitrate", 1, encoder_bitrate, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"encode", 2, encode, ERL_NIF_DIRTY_JOB_CPU_BOUND},
};

ERL_NIF_INIT(webrtc_codecs_opus_nif, nif_funcs, load, NULL, upgrade, NULL)
