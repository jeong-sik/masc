(** Docker daemon client over the Unix Domain Socket HTTP API.

    RFC-0107 Phase E step 1 — skeleton + decision only. All functions
    in [docker_api.ml] currently [raise Failure] and have no production
    callers. Phase E step 2 will land the actual UDS HTTP transport
    (see RFC-0107 §3.4 and RFC-0097 — container reuse).

    Design intent (recorded here so the interface does not drift):

    - Connection: connect to [/var/run/docker.sock] via
      [Eio.Net.connect] (Eio gives us [Eio_unix.Net.unix-addr]). The
      [piaf] library — used by the rest of RFC-0107 — does not support
      a [`Unix] scheme in [Piaf.Scheme.t] (HTTP/HTTPS only), so the UDS
      path stays outside [masc_http_pool]. We layer HTTP/1.1 framing
      directly on the Eio flow, reusing [cohttp-eio]'s parser if the
      shape allows; the fallback is a minimal handwritten request /
      response loop.
    - Concurrency: a single [t] holds one daemon endpoint. Multiple
      requests *may* multiplex on the same socket via HTTP/1.1
      pipelining or, more conservatively, via a per-request connect
      (still no subprocess fork). RFC-0107 Phase E step 2 decides.
    - Errors: every function returns [(_, string) result]. The string
      is intended for [Error_event] / [logs/] only; do not pattern-match
      on its contents. Structured error variants are deferred to step 2
      once the real surface is known (cf. RFC-0042 — no string-as-tag).
    - Scope: only the endpoints below. Image build, volume mount,
      network management are out of scope for step 1 and will only be
      added by an explicit RFC follow-up.

    Subprocess fallback ([docker run] / [docker exec]) is unchanged.
    Selection happens via [MASC_DOCKER_TRANSPORT] in
    [worker_runtime_docker.ml] / [keeper_sandbox_runtime.ml] — wired in
    step 2. *)

type t
(** Opaque handle to a Docker daemon over a UDS HTTP transport.
    Closed when the parent [Eio.Switch.t] exits. *)

type exec_response =
  { exit_code : int
  ; stdout : string
  ; stderr : string
  }
(** Result of [container_exec]. The [exit_code] is the command's exit
    status as reported by the daemon, not the daemon's own HTTP status. *)

val create
  :  sw:Eio.Switch.t
  -> env:Eio_unix.Stdenv.base
  -> ?socket_path:string
  -> unit
  -> t
(** [create ~sw ~env ?socket_path ()] establishes the daemon endpoint.
    [socket_path] defaults to ["/var/run/docker.sock"]. The handle is
    bound to [sw] and any transport-level resources are released on
    switch exit. *)

val ping : t -> (unit, string) result
(** [ping t] hits the daemon's [GET /_ping] endpoint for a liveness
    probe. Returns [Ok ()] if the daemon answers ["OK"]. *)

val container_create
  :  t
  -> image:string
  -> ?cmd:string list
  -> ?env:(string * string) list
  -> unit
  -> (string, string) result
(** [container_create t ~image ?cmd ?env ()] posts to
    [/containers/create] and returns the new container id. The
    container is created in a stopped state; call [container_start]
    next. Image must already be present on the daemon — image pull is
    out of scope for step 1. *)

val container_start
  :  t
  -> container_id:string
  -> (unit, string) result
(** [container_start t ~container_id] posts to
    [/containers/<id>/start]. Idempotent on the daemon side: an
    already-started container returns [Ok ()]. *)

val container_exec
  :  t
  -> container_id:string
  -> cmd:string list
  -> ?stdin:string
  -> unit
  -> (exec_response, string) result
(** [container_exec t ~container_id ~cmd ?stdin ()] runs [cmd] inside
    the existing container via [/containers/<id>/exec] + [/exec/<id>/start].
    Captures stdout/stderr and the command's exit code. This is the
    primary surface that RFC-0097's container reuse activates: instead
    of one [docker run] per turn, the same container handles N
    [container_exec] calls. *)

val container_remove
  :  t
  -> container_id:string
  -> ?force:bool
  -> unit
  -> (unit, string) result
(** [container_remove t ~container_id ?force ()] deletes the container
    via [DELETE /containers/<id>]. With [?force:true] the daemon stops
    a running container first. *)
