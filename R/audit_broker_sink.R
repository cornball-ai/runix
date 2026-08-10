## The AF_UNIX audit-broker client sink (audit-broker-contract.md, PROTOCOL.md).
## An unprivileged R process talks to the privileged, socket-activated broker
## daemon over a local AF_UNIX socket to obtain a SYSTEM-durable audit record it
## could not write itself. This is the ordinary R client of that daemon; the
## daemon lives in the separate `runix-audit-broker` package.
##
## The transport is a small guarded C client (src/unix_socket.c): base R cannot
## speak AF_UNIX. Every transport/protocol failure is fail-closed here -- a
## missing socket, a timeout, a malformed response, or a broker error never
## falls back to a caller-owned sink and never reports system-durable audit.

## Transport status codes (must match src/unix_socket.c).
.RAB_ST_OK <- 0L
.RAB_ST_UNAVAILABLE <- 1L
.RAB_ST_TIMEOUT <- 2L
.RAB_ST_BAD_FRAME <- 3L
.RAB_ST_IO <- 4L
.RAB_ST_UNSUPPORTED <- 5L

## Low-level framed request/response. Returns list(status = <int>, body =
## <raw|NULL>); never throws for a broker-side or transport failure.
.broker_call <- function(path, body, connect_ms = 2000L, recv_ms = 5000L,
                         send_ms = 5000L) {
    .Call(C_rab_broker_call, path, body, as.integer(connect_ms),
          as.integer(recv_ms), as.integer(send_ms))
}
