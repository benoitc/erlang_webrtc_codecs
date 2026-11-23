/* dav1d (AV1 decoding) for webrtc_codecs_av1.
 *
 * A decoder lives in a resource, freed by its destructor. Every call
 * that touches it runs on a dirty CPU scheduler and holds its lock.
 * dav1d is told the largest picture to accept (frame_size_limit), so it
 * refuses a larger one before allocating for it. Pictures come out as
 * three I420 planes without padding.
 */
#include <dav1d/dav1d.h>
#include <errno.h>
#include <limits.h>

#include "webrtc_codecs_nif.h"

/* Larger than any frame the frame buffer of erlang_webrtc releases. */
#define MAX_FRAME_BYTES (8 * 1024 * 1024)
/* A temporal unit shows one picture, one per spatial layer at most. */
#define MAX_PICTURES 8

typedef struct {
    Dav1dContext *ctx;
    ErlNifMutex *lock;
    unsigned long max_pixels;
} decoder_t;

static ErlNifResourceType *decoder_type;

/* Destroys the codec and leaves the context closed. Called with the
 * lock held, or from the destructor. */
static void decoder_free(decoder_t *d)
{
    if (d->ctx)
        dav1d_close(&d->ctx);
    d->ctx = NULL;
}

static void decoder_dtor(ErlNifEnv *env, void *obj)
{
    decoder_t *d = obj;
    (void)env;
    decoder_free(d);
    if (d->lock)
        enif_mutex_destroy(d->lock);
}

/* decoder_close(Decoder) -> ok. The calls after it give {error, closed}. */
static ERL_NIF_TERM decoder_close(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    decoder_t *d;
    (void)argc;

    if (!enif_get_resource(env, argv[0], decoder_type, (void **)&d))
        return enif_make_badarg(env);
    enif_mutex_lock(d->lock);
    decoder_free(d);
    enif_mutex_unlock(d->lock);
    return wc_atom(env, "ok");
}

static const char *dav1d_reason(int err)
{
    if (err == DAV1D_ERR(ENOMEM))
        return "alloc_fail";
    if (err == DAV1D_ERR(ERANGE))
        return "too_large";
    if (err == DAV1D_ERR(ENOPROTOOPT))
        return "unsupported_bitstream";
    if (err == DAV1D_ERR(EINVAL))
        return "invalid_frame";
    return "internal_error";
}

static ERL_NIF_TERM version(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    (void)argv;
    return wc_binary(env, dav1d_version());
}

/* decoder_new(Threads, MaxPixels) */
static ERL_NIF_TERM decoder_new(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    int threads, err;
    unsigned long max_pixels;
    Dav1dSettings settings;
    decoder_t *d;
    (void)argc;

    if (!enif_get_int(env, argv[0], &threads) || threads < 1 || threads > 64 ||
        !enif_get_ulong(env, argv[1], &max_pixels) || max_pixels == 0)
        return enif_make_badarg(env);

    d = wc_resource(decoder_type, sizeof(*d));
    if (!d)
        return wc_error(env, "alloc_fail");
    d->max_pixels = max_pixels;
    d->lock = wc_mutex("webrtc_codecs_dav1d_decoder");
    if (!d->lock) {
        return wc_new_failed(env, d, "alloc_fail");
    }

    dav1d_default_settings(&settings);
    settings.n_threads = threads;
    /* A picture comes out with the frame that completes it. */
    settings.max_frame_delay = 1;
    settings.all_layers = 0;
    settings.frame_size_limit = max_pixels > UINT_MAX ? UINT_MAX : (unsigned)max_pixels;
    /* Bad media is reported to the caller, not printed. */
    settings.logger.callback = NULL;
    err = wc_fail() ? DAV1D_ERR(ENOMEM) : dav1d_open(&d->ctx, &settings);
    if (err < 0) {
        d->ctx = NULL;
        return wc_new_failed(env, d, dav1d_reason(err));
    }
    return wc_new_ok(env, d);
}

static ERL_NIF_TERM grey(ErlNifEnv *env, unsigned int w, unsigned int h)
{
    ERL_NIF_TERM term;
    unsigned char *dst = enif_make_new_binary(env, (size_t)w * h, &term);

    memset(dst, 128, (size_t)w * h);
    return term;
}

/* Returns NULL and sets *term, or the reason the picture is refused. */
static const char *picture(ErlNifEnv *env, const decoder_t *d, const Dav1dPicture *pic, ERL_NIF_TERM *term)
{
    unsigned int w = (unsigned int)pic->p.w, h = (unsigned int)pic->p.h;
    unsigned int cw = (w + 1) / 2, ch = (h + 1) / 2;
    ERL_NIF_TERM u, v;

    if (pic->p.w <= 0 || pic->p.h <= 0 || (unsigned long)w * h > d->max_pixels)
        return "too_large";
    if (pic->p.bpc != 8)
        return "unsupported_format";
    if (pic->p.layout == DAV1D_PIXEL_LAYOUT_I420) {
        u = wc_plane(env, pic->data[1], pic->stride[1], cw, ch);
        v = wc_plane(env, pic->data[2], pic->stride[1], cw, ch);
    } else if (pic->p.layout == DAV1D_PIXEL_LAYOUT_I400) {
        u = grey(env, cw, ch);
        v = grey(env, cw, ch);
    } else {
        return "unsupported_format";
    }
    *term = enif_make_tuple5(env, enif_make_uint(env, w), enif_make_uint(env, h),
                             wc_plane(env, pic->data[0], pic->stride[0], w, h), u, v);
    return NULL;
}

/* decode(Decoder, TemporalUnit) -> {ok, [{Width, Height, Y, U, V}], Qp} | {error, Reason} */
static ERL_NIF_TERM decode(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    decoder_t *d;
    ErlNifBinary in;
    Dav1dData data;
    unsigned char *buf;
    ERL_NIF_TERM list, result;
    const char *reason = NULL;
    int qp = 0, count = 0;
    (void)argc;

    if (!enif_get_resource(env, argv[0], decoder_type, (void **)&d) || !enif_inspect_binary(env, argv[1], &in))
        return enif_make_badarg(env);
    if (in.size == 0 || in.size > MAX_FRAME_BYTES)
        return wc_error(env, "invalid_frame");

    memset(&data, 0, sizeof(data));
    buf = dav1d_data_create(&data, in.size);
    if (!buf)
        return wc_error(env, "alloc_fail");
    memcpy(buf, in.data, in.size);

    list = enif_make_list(env, 0);
    if (!WC_ENTER(d, d->ctx))
        return wc_error(env, "closed");
    while (!reason && data.sz > 0) {
        int sent = dav1d_send_data(d->ctx, &data);
        int got = 0;

        if (sent < 0 && sent != DAV1D_ERR(EAGAIN)) {
            reason = dav1d_reason(sent);
            break;
        }
        for (;;) {
            Dav1dPicture pic;
            ERL_NIF_TERM term;
            int res;

            memset(&pic, 0, sizeof(pic));
            res = dav1d_get_picture(d->ctx, &pic);
            if (res == DAV1D_ERR(EAGAIN))
                break;
            if (res < 0) {
                reason = dav1d_reason(res);
                break;
            }
            got++;
            if (++count > MAX_PICTURES)
                reason = "invalid_frame";
            else
                reason = picture(env, d, &pic, &term);
            if (!reason) {
                list = enif_make_list_cell(env, term, list);
                if (pic.frame_hdr)
                    qp = pic.frame_hdr->quant.yac;
            }
            dav1d_picture_unref(&pic);
            if (reason)
                break;
        }
        /* The decoder took nothing and gave nothing: it would never end. */
        if (!reason && sent == DAV1D_ERR(EAGAIN) && got == 0)
            reason = "internal_error";
    }
    if (reason) {
        if (data.sz > 0)
            dav1d_data_unref(&data);
        dav1d_flush(d->ctx);
    }
    enif_mutex_unlock(d->lock);

    if (reason)
        return wc_error(env, reason);
    if (!enif_make_reverse_list(env, list, &result))
        return wc_error(env, "internal_error");
    return enif_make_tuple3(env, wc_atom(env, "ok"), result, enif_make_int(env, qp));
}

static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info)
{
    (void)priv;
    (void)info;
    decoder_type = enif_open_resource_type(env, NULL, "webrtc_codecs_dav1d_decoder", decoder_dtor,
                                           ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER, NULL);
    return decoder_type ? 0 : -1;
}

static int upgrade(ErlNifEnv *env, void **priv, void **old_priv, ERL_NIF_TERM info)
{
    (void)old_priv;
    return load(env, priv, info);
}

static ErlNifFunc nif_funcs[] = {
    WC_FAULT_NIF
    {"version", 0, version, 0},
    {"decoder_close", 1, decoder_close, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"decoder_new", 2, decoder_new, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"decode", 2, decode, ERL_NIF_DIRTY_JOB_CPU_BOUND},
};

ERL_NIF_INIT(webrtc_codecs_dav1d_nif, nif_funcs, load, NULL, upgrade, NULL)
