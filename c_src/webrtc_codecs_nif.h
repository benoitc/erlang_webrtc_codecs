/* Helpers shared by the codec NIFs. */
#ifndef WEBRTC_CODECS_NIF_H
#define WEBRTC_CODECS_NIF_H

#include <erl_nif.h>
#include <string.h>

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

/* Same for a boolean, stored as 0 or 1. */
static inline int wc_map_bool(ErlNifEnv *env, ERL_NIF_TERM map, const char *key, int *value)
{
    ERL_NIF_TERM term;
    if (!enif_get_map_value(env, map, wc_atom(env, key), &term))
        return 1;
    if (enif_is_identical(term, wc_atom(env, "true")))
        *value = 1;
    else if (enif_is_identical(term, wc_atom(env, "false")))
        *value = 0;
    else
        return 0;
    return 1;
}

#endif
