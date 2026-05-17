(** Masc_http_client — cohttp-eio wrapper with explicit socket close.

    cohttp-eio 6.1.1 does not reliably close the underlying TCP socket fd
    when the Eio.Switch exits (observed on macOS). This module intercepts
    the connection factory via [make_generic] to capture the raw socket and
    close it explicitly on switch release.

    All MASC code that makes outbound HTTP requests should use this module
    instead of [Cohttp_eio.Client.make] directly.

    @see <https://github.com/jeong-sik/masc-mcp/issues/3221> *)

let make_closing_client ~sw ~net ~https =
  let net = (net :> [ `Generic ] Eio.Net.ty Eio.Resource.t) in
  let tracked_flows :
    [ `Close | `Flow | `R | `Shutdown | `W ] Eio.Resource.t list ref =
    ref []
  in
  let clone_resource resource =
    let Eio.Resource.T (value, ops) = resource in
    Eio.Resource.T (value, ops)
  in
  let register_flow flow =
    tracked_flows := clone_resource flow :: !tracked_flows;
    flow
  in
  let close_flow flow =
    try Eio.Resource.close flow
    with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Printf.eprintf "[masc_http_client] close flow failed: %s\n%!" (Printexc.to_string exn)
  in
  let connect ~sw:conn_sw uri =
    let service =
      match Uri.port uri with
      | Some port -> Int.to_string port
      | _ -> Uri.scheme uri |> Option.value ~default:"http"
    in
    let addr =
      match
        Eio.Net.getaddrinfo_stream ~service net
          (Uri.host_with_default ~default:"localhost" uri)
      with
      | ip :: _ -> ip
      | [] -> raise (Invalid_argument "masc_http_client: failed to resolve hostname")
    in
    let sock = Eio.Net.connect ~sw:conn_sw net addr in
    (* Return type must include `Close for cohttp-eio make_generic. *)
    match Uri.scheme uri with
    | Some "https" -> (
        match https with
        | Some wrap -> (
            let wrapped =
              try
                wrap uri sock
              with exn ->
                close_flow
                  (clone_resource
                     (sock :> [ `Close | `Flow | `R | `Shutdown | `W ] Eio.Resource.t));
                raise exn
            in
            tracked_flows :=
              (clone_resource wrapped
                :> [ `Close | `Flow | `R | `Shutdown | `W ] Eio.Resource.t)
              :: !tracked_flows;
            (wrapped :> [ `Close | `Flow | `R | `Shutdown | `W ] Eio.Resource.t))
        | None -> raise (Invalid_argument "masc_http_client: HTTPS requested but not enabled"))
    | _ ->
        register_flow
          (sock :> [ `Close | `Flow | `R | `Shutdown | `W ] Eio.Resource.t)
  in
  let client = Cohttp_eio.Client.make_generic connect in
  Eio.Switch.on_release sw (fun () ->
    let flows = !tracked_flows in
    tracked_flows := [];
    List.iter close_flow flows);
  client

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

(* ── Pool singleton ─────────────────────────────────────────────────

   RFC-0107 Phase D.2c — the per-process [Pool.t] is lazy-initialized
   on first use, reading [sw] and [env] from [Eio_context].  This
   keeps the existing [post_sync] / [get_sync] / [get_response_sync]
   signatures stable: 13 callsites in lib/ continue to pass [~net]
   and optionally [?https], but those are now ignored (pool owns the
   transport).  Once D.2c bis migrates [voice_bridge_core] +
   [opentelemetry_client_cohttp_eio] off [make_closing_client],
   [~net] and [~https] can be dropped from the public mli (planned
   for D.2c.2 follow-up). *)
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

(* RFC-0107 Phase D.2d — re-export Pool under Masc_http_client.Pool
   so the test suite (and any direct consumer that wants the
   typed surface rather than the legacy shim) can name it without
   reaching into the wrapped library's mangled module path. *)
module Pool = Pool
