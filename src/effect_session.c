/*
 * effect_session.c -- the native apt-effect session for the runix common core.
 *
 * An unprivileged mutation issuer needs a single-use, broker-minted EFFECT
 * RECEIPT to authorize committing an apt change through the pkexec entrypoint,
 * and a separate single-use OUTCOME BINDING to close the durable audit record
 * afterwards (broker-effect-receipt-contract.md). Both are 128-bit secrets. The
 * whole reason this lives in C is custody: the receipt and binding are
 * extracted from the broker response and held in wipeable heap, and NEVER
 * become R objects -- no RAWSXP, no CHARSXP, nothing the GC retains, copies, or
 * serializes. R only ever sees the non-secret correlation id, the parsed
 * status, and an opaque EXTPTRSXP handle whose address is not serialized.
 *
 * The handle is bound to the opening process (owner_pid); a forked or
 * unserialized handle is refused. The session runs the contract state machine
 * (open -> commit -> write_outcome -> closed); each call checks the exact
 * expected state, so a reused handle is refused. The finalizer only WIPES
 * (receipt, binding, buffers) -- it never writes an outcome and never fabricates
 * a result, so a dropped handle leaves the intent open, the correct fail-closed
 * state (contract §4.8).
 *
 * The commit path (posix_spawn of the immutable pkexec entrypoint) lands in a
 * later slice; this file provides open, write_outcome, and state, all reusing
 * the shared byte-level transport in unix_socket.c (rab_internal.h).
 *
 * Linux-only, like the broker client: SO_PEERCRED and the socket-activated
 * broker are Linux features. Off Linux the entry points compile and register
 * but return a typed "unsupported" status, so package load never fails.
 */
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE /* explicit_bzero, getpid via _GNU_SOURCE feature set */
#endif

#include <R.h>
#include <Rinternals.h>

#include <string.h>

#include "rab_internal.h"

/* ---- runix-owned contract constants (never borrowed pkgexec PKGX_* names;
 * the two repos version independently) ------------------------------------ */
#define RUNIX_RECEIPT_HEXLEN 32   /* 128-bit effect receipt, lowercase hex   */
#define RUNIX_BINDING_HEXLEN 32   /* 128-bit outcome binding, lowercase hex  */
#define RUNIX_PLAN_HASH_HEXLEN 64 /* SHA-256 plan digest, lowercase hex      */
#define RUNIX_CID_LEN 37          /* 20 digits '-' 16 hex                    */
#define RUNIX_CID_CAP 38          /* + NUL                                   */
#define RUNIX_APT_RES_CAP 256     /* bound resource string cap               */
#define RUNIX_SOCKPATH_CAP 108    /* AF_UNIX sun_path bound                  */
#define RUNIX_ERRCODE_CAP 40      /* broker error-code buffer                */

/* Build list(status=<chr>, detail=<chr|NA>). Cross-platform (no secret). */
static SEXP es_status_result(const char *status, const char *detail) {
    SEXP out = PROTECT(allocVector(VECSXP, 2));
    SET_VECTOR_ELT(out, 0, mkString(status));
    SET_VECTOR_ELT(out, 1,
                   detail == NULL ? ScalarString(NA_STRING) : mkString(detail));
    SEXP nm = PROTECT(allocVector(STRSXP, 2));
    SET_STRING_ELT(nm, 0, mkChar("status"));
    SET_STRING_ELT(nm, 1, mkChar("detail"));
    setAttrib(out, R_NamesSymbol, nm);
    UNPROTECT(2);
    return out;
}

/* Build list(handle=<extptr|NULL>, correlation_id=<chr|NA>, status, detail).
 * `handle` must be PROTECTed by the caller. Cross-platform. */
static SEXP es_open_result(SEXP handle, const char *cid, const char *status,
                           const char *detail) {
    SEXP out = PROTECT(allocVector(VECSXP, 4));
    SET_VECTOR_ELT(out, 0, handle == NULL ? R_NilValue : handle);
    SET_VECTOR_ELT(out, 1,
                   cid == NULL ? ScalarString(NA_STRING) : mkString(cid));
    SET_VECTOR_ELT(out, 2, mkString(status));
    SET_VECTOR_ELT(out, 3,
                   detail == NULL ? ScalarString(NA_STRING) : mkString(detail));
    SEXP nm = PROTECT(allocVector(STRSXP, 4));
    SET_STRING_ELT(nm, 0, mkChar("handle"));
    SET_STRING_ELT(nm, 1, mkChar("correlation_id"));
    SET_STRING_ELT(nm, 2, mkChar("status"));
    SET_STRING_ELT(nm, 3, mkChar("detail"));
    setAttrib(out, R_NamesSymbol, nm);
    UNPROTECT(2);
    return out;
}

#ifdef __linux__

#include <jansson.h>
#include <stdlib.h>
#include <sys/types.h> /* pid_t */
#include <unistd.h>    /* getpid */

/* The nine contracted apt verbs, in a runix-owned closed enum. */
typedef enum {
    RUNIX_VERB_INSTALL = 0,
    RUNIX_VERB_REMOVE,
    RUNIX_VERB_PURGE,
    RUNIX_VERB_UPGRADE,
    RUNIX_VERB_DIST_UPGRADE,
    RUNIX_VERB_UPDATE,
    RUNIX_VERB_HOLD,
    RUNIX_VERB_UNHOLD,
    RUNIX_VERB_CONFIGURE,
    RUNIX_VERB_COUNT
} runix_verb;

/* verb -> {operation string, immutable entrypoint path}. The ONLY source of
 * entrypoint paths; R never names one, so a substitutable root-exec'd path can
 * never cross from R. `operation` is the request form apt.<verb> (underscored
 * dist_upgrade); `entrypoint` is the packaged hyphenated basename (pkgexec
 * v0.0.3, Appendix A.4). The entrypoint column is used by the commit path in a
 * later slice; open/write_outcome use only the operation column. */
typedef struct {
    const char *operation;
    const char *entrypoint;
} runix_verb_entry;

static const runix_verb_entry RUNIX_VERBS[RUNIX_VERB_COUNT] = {
    {"apt.install", "/usr/libexec/pkgexec/runix-apt-install"},
    {"apt.remove", "/usr/libexec/pkgexec/runix-apt-remove"},
    {"apt.purge", "/usr/libexec/pkgexec/runix-apt-purge"},
    {"apt.upgrade", "/usr/libexec/pkgexec/runix-apt-upgrade"},
    {"apt.dist_upgrade", "/usr/libexec/pkgexec/runix-apt-dist-upgrade"},
    {"apt.update", "/usr/libexec/pkgexec/runix-apt-update"},
    {"apt.hold", "/usr/libexec/pkgexec/runix-apt-hold"},
    {"apt.unhold", "/usr/libexec/pkgexec/runix-apt-unhold"},
    {"apt.configure", "/usr/libexec/pkgexec/runix-apt-configure"}};

static int runix_verb_lookup(const char *operation) {
    for (int i = 0; i < RUNIX_VERB_COUNT; i++) {
        if (strcmp(operation, RUNIX_VERBS[i].operation) == 0) {
            return i;
        }
    }
    return -1;
}

typedef enum {
    ES_OPENED,
    ES_RECEIPT_SENT,
    ES_RESULT_KNOWN,
    ES_EFFECT_UNKNOWN,
    ES_OUTCOME_ATTEMPTED,
    ES_CLOSED
} es_state;

typedef struct {
    pid_t owner_pid; /* PID binding; every call re-checks getpid()          */
    es_state state;
    unsigned char *receipt; /* 32 hex + NUL, wipeable heap, for commit      */
    unsigned char *binding; /* 32 hex + NUL, wipeable heap, for write_outcome */
    char correlation_id[RUNIX_CID_CAP]; /* sanitized, R-exposable           */
    int verb;                           /* runix_verb, not a path           */
    int plan_schema;
    char resource[RUNIX_APT_RES_CAP];
    char plan_hash[RUNIX_PLAN_HASH_HEXLEN + 1];
    char socket_path[RUNIX_SOCKPATH_CAP]; /* to reconnect for write_outcome */
    int expected_uid;                     /* server peer uid to re-auth      */
} runix_effect_session;

/* The broker's closed error-code set (PROTOCOL.md + the effect-receipt
 * capability's seven codes). Anything else in an error response is itself a
 * malformed response, mirroring R/audit_broker_sink.R:.BROKER_ERROR_CODES. */
static int es_known_error_code(const char *ec) {
    static const char *codes[] = {
        "bad_frame", "too_large", "bad_json", "unknown_request",
        "schema_invalid", "unknown_intent", "actor_mismatch", "rate_limited",
        "persist_failed", "internal", "receipt_invalid", "receipt_expired",
        "receipt_redeemed", "receipt_mismatch", "receipt_unauthorized",
        "receipt_actor_mismatch", "effect_without_receipt"};
    size_t n = sizeof codes / sizeof codes[0];
    for (size_t i = 0; i < n; i++) {
        if (strcmp(ec, codes[i]) == 0) {
            return 1;
        }
    }
    return 0;
}

/* A jansson string of exactly `want` lowercase-hex characters. */
static int json_is_lc_hex(json_t *s, size_t want) {
    if (!json_is_string(s) || json_string_length(s) != want) {
        return 0;
    }
    const char *p = json_string_value(s);
    for (size_t i = 0; i < want; i++) {
        char c = p[i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) {
            return 0;
        }
    }
    return 1;
}

/* A jansson string matching ^[0-9]{20}-[0-9a-f]{16}$ (the correlation id). */
static int json_is_cid(json_t *s) {
    if (!json_is_string(s) || json_string_length(s) != RUNIX_CID_LEN) {
        return 0;
    }
    const char *p = json_string_value(s);
    for (int i = 0; i < 20; i++) {
        if (p[i] < '0' || p[i] > '9') {
            return 0;
        }
    }
    if (p[20] != '-') {
        return 0;
    }
    for (int i = 21; i < RUNIX_CID_LEN; i++) {
        char c = p[i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) {
            return 0;
        }
    }
    return 1;
}

/* ---- wipeable custody + the EXTPTRSXP handle ----------------------------- */

static SEXP runix_es_tag(void) {
    /* install() interns into the permanent symbol table; idempotent. */
    static SEXP tag = NULL;
    if (tag == NULL) {
        tag = install("runix_effect_session");
    }
    return tag;
}

static void es_wipe(unsigned char **p, size_t n) {
    if (*p != NULL) {
        explicit_bzero(*p, n);
        free(*p);
        *p = NULL;
    }
}

static void es_free(runix_effect_session *s) {
    if (s == NULL) {
        return;
    }
    es_wipe(&s->receipt, RUNIX_RECEIPT_HEXLEN + 1);
    es_wipe(&s->binding, RUNIX_BINDING_HEXLEN + 1);
    explicit_bzero(s, sizeof *s);
    free(s);
}

/* Finalizer: WIPE only. Never writes an outcome, never fabricates a result. */
static void es_finalize(SEXP handle) {
    if (TYPEOF(handle) != EXTPTRSXP) {
        return;
    }
    es_free((runix_effect_session *) R_ExternalPtrAddr(handle));
    R_ClearExternalPtr(handle);
}

static SEXP es_make_handle(runix_effect_session *s) {
    SEXP h = PROTECT(R_MakeExternalPtr(s, runix_es_tag(), R_NilValue));
    R_RegisterCFinalizerEx(h, es_finalize, TRUE); /* also on R shutdown */
    UNPROTECT(1);
    return h;
}

/* Resolve a handle to its session, enforcing: correct external-pointer tag; a
 * live address (an unserialized handle has a NULL address -> stale); and the
 * PID binding (a forked handle mismatches getpid()). Any violation is a hard
 * refusal -- these are misuse or a fork/restore, never a transport outcome. */
static runix_effect_session *es_from_handle(SEXP handle) {
    if (TYPEOF(handle) != EXTPTRSXP ||
        R_ExternalPtrTag(handle) != runix_es_tag()) {
        error("not a runix effect session handle");
    }
    runix_effect_session *s = (runix_effect_session *) R_ExternalPtrAddr(handle);
    if (s == NULL) {
        error("effect session handle is closed or was restored from disk");
    }
    if (s->owner_pid != getpid()) {
        error("effect session handle belongs to another process");
    }
    return s;
}

/* Map a non-OK transport status to a session status tag. */
static const char *es_transport_tag(int st) {
    switch (st) {
    case RAB_ST_UNAVAILABLE:
        return "unavailable";
    case RAB_ST_UNSUPPORTED:
        return "unsupported";
    case RAB_ST_TIMEOUT:
        return "timeout";
    case RAB_ST_BAD_FRAME:
        return "bad_response";
    case RAB_ST_PEER:
        return "untrusted_peer";
    case RAB_ST_IO:
    default:
        return "io";
    }
}

/* Read a length-3 integer deadline vector (connect, recv, send), all non-NA
 * and non-negative. Errors on misuse. */
static void es_read_deadlines(SEXP d, int *connect_ms, int *recv_ms,
                              int *send_ms) {
    if (TYPEOF(d) != INTSXP || LENGTH(d) != 3) {
        error("deadlines must be an integer vector of length 3");
    }
    int c = INTEGER(d)[0], r = INTEGER(d)[1], s = INTEGER(d)[2];
    if (c == NA_INTEGER || r == NA_INTEGER || s == NA_INTEGER || c < 0 ||
        r < 0 || s < 0) {
        error("deadlines must be non-negative and non-NA");
    }
    *connect_ms = c;
    *recv_ms = r;
    *send_ms = s;
}

/* Parse + classify a broker response. Returns:
 *   0 success: fills receipt[33], binding[33], cid[38]
 *   1 broker error response: fills errcode[]
 *   2 malformed / invalid / not the exact open_ok_effect shape
 * Strict, mirroring the R adapter: duplicate keys rejected at parse, an exact
 * closed key set, correct scalar types, documented value formats, and the two
 * tokens required distinct. Never allocates R. */
static int es_extract(const unsigned char *resp, size_t resplen, char *receipt,
                      char *binding, char *cid, char *errcode,
                      size_t errcode_cap) {
    json_error_t jerr;
    json_t *root =
        json_loadb((const char *) resp, resplen, JSON_REJECT_DUPLICATES, &jerr);
    if (root == NULL) {
        return 2;
    }
    int rc = 2;
    json_t *ok = json_object_get(root, "ok");
    if (!json_is_object(root) || !json_is_boolean(ok)) {
        goto done;
    }
    if (!json_boolean_value(ok)) {
        /* error response: exactly {ok, error, message} with a contract code */
        if (json_object_size(root) != 3) {
            goto done;
        }
        json_t *err = json_object_get(root, "error");
        json_t *msg = json_object_get(root, "message");
        if (!json_is_string(err) || !json_is_string(msg)) {
            goto done;
        }
        const char *ec = json_string_value(err);
        if (!es_known_error_code(ec)) {
            goto done;
        }
        strncpy(errcode, ec, errcode_cap - 1);
        errcode[errcode_cap - 1] = '\0';
        rc = 1;
        goto done;
    }
    /* success must be the exact open_ok_effect shape: six keys, no more. */
    if (json_object_size(root) != 6) {
        goto done;
    }
    json_t *scope = json_object_get(root, "audit_scope");
    json_t *bnd = json_object_get(root, "binding");
    json_t *cidj = json_object_get(root, "correlation_id");
    json_t *rcpt = json_object_get(root, "effect_receipt");
    json_t *pers = json_object_get(root, "persisted");
    if (!json_is_string(scope) || !json_is_boolean(pers)) {
        goto done;
    }
    if (!json_boolean_value(pers)) {
        goto done;
    }
    if (strcmp(json_string_value(scope), "system") != 0) {
        goto done;
    }
    if (!json_is_lc_hex(bnd, RUNIX_BINDING_HEXLEN) ||
        !json_is_lc_hex(rcpt, RUNIX_RECEIPT_HEXLEN) || !json_is_cid(cidj)) {
        goto done;
    }
    /* the two tokens have different redeemers, times, and purposes: identical
     * values are a malformed response, never a valid receipt-bearing open. */
    if (strcmp(json_string_value(bnd), json_string_value(rcpt)) == 0) {
        goto done;
    }
    memcpy(binding, json_string_value(bnd), RUNIX_BINDING_HEXLEN);
    binding[RUNIX_BINDING_HEXLEN] = '\0';
    memcpy(receipt, json_string_value(rcpt), RUNIX_RECEIPT_HEXLEN);
    receipt[RUNIX_RECEIPT_HEXLEN] = '\0';
    memcpy(cid, json_string_value(cidj), RUNIX_CID_LEN);
    cid[RUNIX_CID_LEN] = '\0';
    rc = 0;
done:
    json_decref(root);
    return rc;
}

/* ---- .Call: open ---------------------------------------------------------
 * Sends an effect-bearing open_intent over the SHARED byte transport (so the
 * receipt-bearing response is a malloc buffer, not a RAWSXP), extracts the
 * receipt/binding/correlation_id in C into wipeable heap, wipes the transport
 * buffer, and returns only the handle + correlation id + status to R. */
SEXP effect_session_open(SEXP socket_path_, SEXP operation_, SEXP resource_,
                         SEXP plan_schema_, SEXP plan_hash_, SEXP deadlines_,
                         SEXP expected_uid_) {
    const char *socket_path = rab_arg_string(socket_path_, "socket_path");
    const char *operation = rab_arg_string(operation_, "operation");
    const char *resource = rab_arg_string(resource_, "resource");
    int plan_schema = rab_arg_nonneg_int(plan_schema_, "plan_schema");
    const char *plan_hash = rab_arg_string(plan_hash_, "plan_hash");
    int expected_uid = rab_arg_nonneg_int(expected_uid_, "expected_uid");
    int connect_ms, recv_ms, send_ms;
    es_read_deadlines(deadlines_, &connect_ms, &recv_ms, &send_ms);

    int verb = runix_verb_lookup(operation);
    if (verb < 0) {
        error("unknown apt operation");
    }
    if (plan_schema < 1) {
        return es_open_result(NULL, NULL, "bad_request", "plan_schema");
    }
    size_t rlen = strlen(resource);
    if (rlen == 0 || rlen >= RUNIX_APT_RES_CAP) {
        return es_open_result(NULL, NULL, "bad_request", "resource");
    }
    if (strlen(socket_path) >= RUNIX_SOCKPATH_CAP) {
        return es_open_result(NULL, NULL, "bad_request", "socket_path");
    }
    if (strlen(plan_hash) != RUNIX_PLAN_HASH_HEXLEN) {
        return es_open_result(NULL, NULL, "bad_request", "plan_hash");
    }
    for (const char *p = plan_hash; *p != '\0'; p++) {
        char c = *p;
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) {
            return es_open_result(NULL, NULL, "bad_request", "plan_hash");
        }
    }

    /* build {type, record:{operation,resource}, effect:{required,plan_schema,
     * plan_hash}} with jansson so `resource` is properly escaped. */
    json_t *root = json_object();
    json_t *record = json_object();
    json_t *effect = json_object();
    if (root == NULL || record == NULL || effect == NULL) {
        json_decref(root);
        json_decref(record);
        json_decref(effect);
        return es_open_result(NULL, NULL, "io", "alloc");
    }
    json_object_set_new(record, "operation",
                        json_string(RUNIX_VERBS[verb].operation));
    json_object_set_new(record, "resource", json_string(resource));
    json_object_set_new(effect, "required", json_true());
    json_object_set_new(effect, "plan_schema", json_integer(plan_schema));
    json_object_set_new(effect, "plan_hash", json_string(plan_hash));
    json_object_set_new(root, "type", json_string("open_intent"));
    json_object_set_new(root, "record", record);
    json_object_set_new(root, "effect", effect);
    char *req = json_dumps(root, JSON_COMPACT);
    json_decref(root);
    if (req == NULL) {
        return es_open_result(NULL, NULL, "io", "encode");
    }

    unsigned char *resp = NULL;
    size_t resplen = 0;
    int st = rab_transport(socket_path, (const unsigned char *) req, strlen(req),
                           connect_ms, recv_ms, send_ms, expected_uid, &resp,
                           &resplen);
    free(req); /* the request carries no secret (the receipt comes back) */
    if (st != RAB_ST_OK) {
        return es_open_result(NULL, NULL, es_transport_tag(st), NULL);
    }

    char receipt[RUNIX_RECEIPT_HEXLEN + 1];
    char binding[RUNIX_BINDING_HEXLEN + 1];
    char cid[RUNIX_CID_CAP];
    char errcode[RUNIX_ERRCODE_CAP];
    int ex = es_extract(resp, resplen, receipt, binding, cid, errcode,
                        sizeof errcode);
    /* the response carried the receipt: wipe it out of the transport buffer */
    if (resp != NULL) {
        explicit_bzero(resp, resplen);
        free(resp);
    }
    if (ex != 0) {
        explicit_bzero(receipt, sizeof receipt);
        explicit_bzero(binding, sizeof binding);
        if (ex == 1) {
            return es_open_result(NULL, NULL, "broker_error", errcode);
        }
        return es_open_result(NULL, NULL, "bad_response", NULL);
    }

    /* success: move the secrets into wipeable session heap, wipe the stack */
    runix_effect_session *s = calloc(1, sizeof *s);
    unsigned char *rc_buf = malloc(RUNIX_RECEIPT_HEXLEN + 1);
    unsigned char *bd_buf = malloc(RUNIX_BINDING_HEXLEN + 1);
    if (s == NULL || rc_buf == NULL || bd_buf == NULL) {
        explicit_bzero(receipt, sizeof receipt);
        explicit_bzero(binding, sizeof binding);
        free(rc_buf);
        free(bd_buf);
        free(s);
        return es_open_result(NULL, NULL, "io", "alloc");
    }
    memcpy(rc_buf, receipt, RUNIX_RECEIPT_HEXLEN + 1);
    memcpy(bd_buf, binding, RUNIX_BINDING_HEXLEN + 1);
    explicit_bzero(receipt, sizeof receipt);
    explicit_bzero(binding, sizeof binding);
    s->owner_pid = getpid();
    s->state = ES_OPENED;
    s->receipt = rc_buf;
    s->binding = bd_buf;
    s->verb = verb;
    s->plan_schema = plan_schema;
    memcpy(s->correlation_id, cid, RUNIX_CID_LEN + 1);
    memcpy(s->resource, resource, rlen + 1);
    memcpy(s->plan_hash, plan_hash, RUNIX_PLAN_HASH_HEXLEN + 1);
    memcpy(s->socket_path, socket_path, strlen(socket_path) + 1);
    s->expected_uid = expected_uid;

    SEXP h = PROTECT(es_make_handle(s));
    SEXP res = es_open_result(h, s->correlation_id, "ok", NULL);
    UNPROTECT(1);
    return res;
}

/* Classify a write_outcome response: 0 = outcome_ok ({ok,persisted} both true,
 * exactly two keys), 1 = broker error (fills errcode), 2 = malformed. */
static int es_classify_outcome(const unsigned char *resp, size_t resplen,
                               char *errcode, size_t errcode_cap) {
    json_error_t jerr;
    json_t *root =
        json_loadb((const char *) resp, resplen, JSON_REJECT_DUPLICATES, &jerr);
    if (root == NULL) {
        return 2;
    }
    int rc = 2;
    json_t *ok = json_object_get(root, "ok");
    if (!json_is_object(root) || !json_is_boolean(ok)) {
        goto done;
    }
    if (!json_boolean_value(ok)) {
        if (json_object_size(root) != 3) {
            goto done;
        }
        json_t *err = json_object_get(root, "error");
        json_t *msg = json_object_get(root, "message");
        if (!json_is_string(err) || !json_is_string(msg)) {
            goto done;
        }
        const char *ec = json_string_value(err);
        if (!es_known_error_code(ec)) {
            goto done;
        }
        strncpy(errcode, ec, errcode_cap - 1);
        errcode[errcode_cap - 1] = '\0';
        rc = 1;
        goto done;
    }
    if (json_object_size(root) != 2) {
        goto done;
    }
    json_t *pers = json_object_get(root, "persisted");
    if (!json_is_boolean(pers) || !json_boolean_value(pers)) {
        goto done;
    }
    rc = 0;
done:
    json_decref(root);
    return rc;
}

/* ---- .Call: write_outcome ------------------------------------------------
 * Closes the durable intent with the C-held outcome binding. The caller passes
 * the outcome RECORD as a JSON object string (no binding -- that is C-owned and
 * inserted here). The binding is spent by the attempt regardless of result and
 * wiped; the session moves to closed. */
SEXP effect_session_write_outcome(SEXP handle_, SEXP record_, SEXP deadlines_) {
    runix_effect_session *s = es_from_handle(handle_);
    const char *record = rab_arg_string(record_, "record");
    int connect_ms, recv_ms, send_ms;
    es_read_deadlines(deadlines_, &connect_ms, &recv_ms, &send_ms);

    if (s->state == ES_OUTCOME_ATTEMPTED || s->state == ES_CLOSED) {
        error("effect session outcome already written");
    }
    if (s->state == ES_RECEIPT_SENT) {
        error("effect session commit is in progress");
    }
    if (s->binding == NULL) {
        error("effect session has no outcome binding");
    }

    /* the caller's record must be a JSON object; parse it before spending the
     * binding, so a bad record is a retryable caller error, not a spent token */
    json_error_t jerr;
    json_t *rec =
        json_loadb(record, strlen(record), JSON_REJECT_DUPLICATES, &jerr);
    if (rec == NULL || !json_is_object(rec)) {
        json_decref(rec);
        error("outcome record must be a JSON object");
    }
    json_t *root = json_object();
    if (root == NULL) {
        json_decref(rec);
        error("failed to build outcome request");
    }
    json_object_set_new(root, "type", json_string("write_outcome"));
    json_object_set_new(root, "binding",
                        json_string((const char *) s->binding));
    json_object_set_new(root, "record", rec); /* steals rec */
    char *req = json_dumps(root, JSON_COMPACT);
    json_decref(root);
    if (req == NULL) {
        error("failed to encode outcome request");
    }
    size_t reqlen = strlen(req);

    unsigned char *resp = NULL;
    size_t resplen = 0;
    int st = rab_transport(s->socket_path, (const unsigned char *) req, reqlen,
                           connect_ms, recv_ms, send_ms, s->expected_uid, &resp,
                           &resplen);
    explicit_bzero(req, reqlen); /* the request carried the binding */
    free(req);
    /* the binding is spent by this attempt, success or not: wipe it now */
    es_wipe(&s->binding, RUNIX_BINDING_HEXLEN + 1);
    s->state = ES_OUTCOME_ATTEMPTED;

    const char *status;
    char errcode[RUNIX_ERRCODE_CAP];
    const char *detail = NULL;
    if (st != RAB_ST_OK) {
        status = es_transport_tag(st);
    } else {
        int cls = es_classify_outcome(resp, resplen, errcode, sizeof errcode);
        if (cls == 0) {
            status = "ok";
        } else if (cls == 1) {
            status = "broker_error";
            detail = errcode;
        } else {
            status = "bad_response";
        }
    }
    if (resp != NULL) {
        explicit_bzero(resp, resplen);
        free(resp);
    }
    s->state = ES_CLOSED;
    return es_status_result(status, detail);
}

/* ---- .Call: state (inspection for tests/asserts) -------------------------
 * Exposes only booleans for receipt/binding presence, never the secrets. */
SEXP effect_session_state(SEXP handle_) {
    runix_effect_session *s = es_from_handle(handle_);
    const char *st;
    switch (s->state) {
    case ES_OPENED:
        st = "opened";
        break;
    case ES_RECEIPT_SENT:
        st = "receipt_sent";
        break;
    case ES_RESULT_KNOWN:
        st = "result_known";
        break;
    case ES_EFFECT_UNKNOWN:
        st = "effect_unknown";
        break;
    case ES_OUTCOME_ATTEMPTED:
        st = "outcome_attempted";
        break;
    case ES_CLOSED:
    default:
        st = "closed";
        break;
    }
    SEXP out = PROTECT(allocVector(VECSXP, 5));
    SET_VECTOR_ELT(out, 0, mkString(st));
    SET_VECTOR_ELT(out, 1, ScalarInteger((int) s->owner_pid));
    SET_VECTOR_ELT(out, 2, mkString(s->correlation_id));
    SET_VECTOR_ELT(out, 3, ScalarLogical(s->receipt != NULL));
    SET_VECTOR_ELT(out, 4, ScalarLogical(s->binding != NULL));
    SEXP nm = PROTECT(allocVector(STRSXP, 5));
    SET_STRING_ELT(nm, 0, mkChar("state"));
    SET_STRING_ELT(nm, 1, mkChar("owner_pid"));
    SET_STRING_ELT(nm, 2, mkChar("correlation_id"));
    SET_STRING_ELT(nm, 3, mkChar("has_receipt"));
    SET_STRING_ELT(nm, 4, mkChar("has_binding"));
    setAttrib(out, R_NamesSymbol, nm);
    UNPROTECT(2);
    return out;
}

#else /* not __linux__: the effect session is Linux-only */

SEXP effect_session_open(SEXP socket_path_, SEXP operation_, SEXP resource_,
                         SEXP plan_schema_, SEXP plan_hash_, SEXP deadlines_,
                         SEXP expected_uid_) {
    (void) socket_path_;
    (void) operation_;
    (void) resource_;
    (void) plan_schema_;
    (void) plan_hash_;
    (void) deadlines_;
    (void) expected_uid_;
    return es_open_result(NULL, NULL, "unsupported", NULL);
}

SEXP effect_session_write_outcome(SEXP handle_, SEXP record_, SEXP deadlines_) {
    (void) handle_;
    (void) record_;
    (void) deadlines_;
    return es_status_result("unsupported", NULL);
}

SEXP effect_session_state(SEXP handle_) {
    (void) handle_;
    error("effect sessions are Linux-only");
    return R_NilValue; /* unreached */
}

#endif
