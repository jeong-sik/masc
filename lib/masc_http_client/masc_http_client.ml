(** Masc_http_client — typed pool front-end for outbound HTTP.

    All callers go through the per-process [Pool.t] singleton via
    [post_sync] / [get_sync] / [get_response_sync]; the pool owns the
    underlying piaf transport, keep-alive, and TLS context cache.

    The [~net] and [?https] arguments are accepted for source-level
    backwards compatibility with callers that still pass them, but are
    ignored — the pool, not the caller, owns the network resource.
    Those arguments will be dropped in a follow-up API cleanup once
    every callsite has been audited. *)

(** POST with structured error handling.
    DNS resolution, TLS, and I/O errors return Error instead of crashing the fiber. *)
type response = {
  status : int;
  headers : (string * string) list;
  body : string;
}

(** Apply an optional Eio wall-clock timeout around a request. When both
    [clock] and [timeout_sec] are supplied, a sleep fiber races the request
    fiber; whichever finishes first wins and the loser is cancelled. On
    timeout the caller receives [Error "timeout after ..."] instead of the
    underlying HTTP result. When either argument is omitted the behaviour
    is identical to the pre-timeout implementation, so existing callers
    need not be updated.

    We use [Eio.Fiber.first] instead of [Eio.Time.with_timeout] because the
    latter requires the inner function's Error constructor to be a
    polymorphic variant compatible with [> `Timeout], while our callers use
    plain [string] error payloads. *)
let with_optional_timeout ?clock ?timeout_sec f =
  match clock, timeout_sec with
  | Some clock, Some timeout_sec when timeout_sec > 0.0 ->
      Eio.Fiber.first
        (fun () -> f ())
        (fun () ->
          Eio.Time.sleep clock timeout_sec;
          Error (Printf.sprintf "timeout after %.1fs" timeout_sec))
  | _ -> f ()

(* Per-process Pool singleton, lazily initialised on first use by
   reading [sw] and [env] from [Eio_context]. *)
let pool_ref : Pool.t option ref = ref None
let pool_mu = Eio.Mutex.create ()

let pool_init_error () =
  Error
    "masc_http_client: Eio_context.set_env not called — \
     RFC-0107 Phase D pool cannot be initialized.  This indicates a \
     bootstrap-order bug (Pool.request from before \
     Server_runtime_bootstrap.create_server_state)."

let with_pool f =
  match !pool_ref with
  | Some p -> f p
  | None ->
    Eio.Mutex.use_rw ~protect:false pool_mu (fun () ->
      match !pool_ref with
      | Some p -> f p
      | None ->
        (match Eio_context.get_switch_opt (), Eio_context.get_env_opt () with
         | Some sw, Some env ->
           let p = Pool.create ~sw ~env () in
           pool_ref := Some p;
           f p
         | _ -> pool_init_error ()))

let post_sync ?clock ?timeout_sec ~net:_ ?https:_ ~url ~headers ~body () =
  with_optional_timeout ?clock ?timeout_sec @@ fun () ->
  with_pool @@ fun pool ->
  match Pool.request pool ?clock ?timeout_seconds:timeout_sec
          ~method_:`POST ~url ~headers ~body () with
  | Ok { Pool.status; body; _ } -> Ok (status, body)
  | Error e -> Error e

(** GET with structured error handling. *)
let get_response_sync ?clock ?timeout_sec ~net:_ ?https:_ ~url ~headers () =
  with_optional_timeout ?clock ?timeout_sec @@ fun () ->
  with_pool @@ fun pool ->
  match Pool.request pool ?clock ?timeout_seconds:timeout_sec
          ~method_:`GET ~url ~headers () with
  | Ok { Pool.status; headers; body } ->
    Ok { status; headers; body }
  | Error e -> Error e

(** GET with structured error handling. *)
let get_sync ?clock ?timeout_sec ~net ?https ~url ~headers () =
  match get_response_sync ?clock ?timeout_sec ~net ?https ~url ~headers ()
  with
  | Ok response -> Ok (response.status, response.body)
  | Error _ as error -> error

(* Read-only accessor on the per-process pool singleton.  Returns
   [None] before the first HTTP call so callers like [Pool_metrics]
   can no-op instead of forcing the pool open just to read zeros. *)
let pool_singleton_opt () : Pool.t option = !pool_ref

module Pool = Pool
