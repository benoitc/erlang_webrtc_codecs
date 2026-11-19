/* Helpers shared by the codec NIFs. */
#ifndef WEBRTC_CODECS_NIF_H
#define WEBRTC_CODECS_NIF_H

#include <erl_nif.h>
#include <stddef.h>
#include <string.h>

/* Fault injection, for tests only (CMake option
 * WEBRTC_CODECS_FAULT_INJECTION): fail_after(N) makes the Nth call of
 * wc_fail() from then on answer 1, once. Constructors ask it before each
 * allocation, so a test can make any one of them fail. Not thread safe:
 * a test arms it and calls one constructor. */
#ifdef WEBRTC_CODECS_FAULT_INJECTION
static int wc_fail_countdown = 0;

static inline int wc_fail(void)
{
    return wc_fail_countdown > 0 && --wc_fail_countdown == 0;
}
#else
#define wc_fail() 0
#endif

static inline ERL_NIF_TERM wc_atom(ErlNifEnv *env, const char *name)
{
    ERL_NIF_TERM atom;
    if (enif_make_existing_atom(env, name, &atom, ERL_NIF_LATIN1))
        return atom;
    return enif_make_atom(env, name);
}

static inline ERL_NIF_TERM wc_ok(ErlNifEnv *env, ERL_NIF_TERM term)
{
    return enif_make_tuple2(env, wc_atom(env, "ok"), term);
}

static inline ERL_NIF_TERM wc_error(ErlNifEnv *env, const char *reason)
{
    return enif_make_tuple2(env, wc_atom(env, "error"), wc_atom(env, reason));
}

static inline ERL_NIF_TERM wc_binary(ErlNifEnv *env, const char *text)
{
    ERL_NIF_TERM term;
    size_t len = strlen(text);
    unsigned char *data = enif_make_new_binary(env, len, &term);
    memcpy(data, text, len);
    return term;
}

/* Read Map[Key] as an int; leaves *value alone when the key is absent.
 * Returns 0 when the key is there and is not an int. */
static inline int wc_map_int(ErlNifEnv *env, ERL_NIF_TERM map, const char *key, int *value)
{
    ERL_NIF_TERM term;
    if (!enif_get_map_value(env, map, wc_atom(env, key), &term))
        return 1;
    return enif_get_int(env, term, value);
}

/* A boolean atom as 0 or 1. Returns 0 when the term is neither. */
static inline int wc_get_bool(ErlNifEnv *env, ERL_NIF_TERM term, int *value)
{
    if (enif_is_identical(term, wc_atom(env, "true")))
        *value = 1;
    else if (enif_is_identical(term, wc_atom(env, "false")))
        *value = 0;
    else
        return 0;
    return 1;
}

/* Same for a boolean, stored as 0 or 1. */
static inline int wc_map_bool(ErlNifEnv *env, ERL_NIF_TERM map, const char *key, int *value)
{
    ERL_NIF_TERM term;
    if (!enif_get_map_value(env, map, wc_atom(env, key), &term))
        return 1;
    return wc_get_bool(env, term, value);
}

/* What every constructor does, written once.
 *
 *     obj = wc_resource(type, sizeof(*obj));     zeroed, or NULL
 *     obj->lock = wc_mutex("name");              or NULL
 *     ... create the codec, asking wc_fail() first ...
 *     if (it failed)
 *         return wc_new_failed(env, obj, reason);
 *     return wc_new_ok(env, obj);
 *
 * The destructor of the resource frees whatever was created, so a
 * constructor that fails only has to release. wc_new_failed takes the
 * reason as an argument so that it is chosen before the release, which
 * may free the resource: nothing is read from it afterwards. */
static inline void *wc_resource(ErlNifResourceType *type, size_t size)
{
    void *obj = wc_fail() ? NULL : enif_alloc_resource(type, size);

    if (obj)
        memset(obj, 0, size);
    return obj;
}

static inline ErlNifMutex *wc_mutex(char *name)
{
    return wc_fail() ? NULL : enif_mutex_create(name);
}

static inline ERL_NIF_TERM wc_new_failed(ErlNifEnv *env, void *obj, const char *reason)
{
    enif_release_resource(obj);
    return wc_error(env, reason);
}

static inline ERL_NIF_TERM wc_new_ok(ErlNifEnv *env, void *obj)
{
    ERL_NIF_TERM term = enif_make_resource(env, obj);

    enif_release_resource(obj);
    return wc_ok(env, term);
}

/* One plane of a picture as a new binary, without its padding. */
static inline ERL_NIF_TERM wc_plane(ErlNifEnv *env, const unsigned char *src, ptrdiff_t stride, unsigned int w,
                                    unsigned int h)
{
    ERL_NIF_TERM term;
    unsigned char *dst = enif_make_new_binary(env, (size_t)w * h, &term);
    unsigned int row;

    for (row = 0; row < h; row++)
        memcpy(dst + (size_t)row * w, src + (ptrdiff_t)row * stride, w);
    return term;
}

#ifdef WEBRTC_CODECS_FAULT_INJECTION
static ERL_NIF_TERM wc_fail_after(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    int count;
    (void)argc;
    if (!enif_get_int(env, argv[0], &count) || count < 0)
        return enif_make_badarg(env);
    wc_fail_countdown = count;
    return wc_atom(env, "ok");
}

#define WC_FAULT_NIF {"fail_after", 1, wc_fail_after, 0},
#else
#define WC_FAULT_NIF
#endif

#endif
