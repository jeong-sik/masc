
(** Global Eio context for shared network/clock access.
    Set once during server startup (main_eio.ml), read from any context.

    Uses Atomic.t (lock-free WORM pattern): each field is written once at
    init and read many times from Eio fibers, CI tests, and OAS callbacks.
    No mutex needed — Atomic.get/set are single-instruction operations. *)

type eio_net = [`Generic | `Unix] Eio.Net.ty Eio.Resource.t

let current_net : eio_net option Atomic.t = Atomic.make None
let current_clock : float Eio.Time.clock_ty Eio.Resource.t option Atomic.t = Atomic.make None
let current_mono_clock : Eio.Time.Mono.ty Eio.Resource.t option Atomic.t = Atomic.make None
let current_sw : Eio.Switch.t option Atomic.t = Atomic.make None
let net_initialized : bool Atomic.t = Atomic.make false

let set_net net =
  Atomic.set current_net (Some (net :> eio_net));
  Atomic.set net_initialized true

let set_clock clock =
  Atomic.set current_clock (Some clock)

let set_mono_clock mc =
  Atomic.set current_mono_clock (Some mc)

let get_mono_clock () =
  match Atomic.get current_mono_clock with
  | Some mc -> mc
  | None -> invalid_arg "Eio mono_clock not initialized"

let set_switch sw =
  Atomic.set current_sw (Some sw)

let get_net_opt () : eio_net option =
  Atomic.get current_net

let get_clock_opt () =
  Atomic.get current_clock

let get_switch_opt () =
  Atomic.get current_sw

let get_net () : eio_net =
  match Atomic.get current_net with
  | Some net -> net
  | None ->
      if Atomic.get net_initialized then
        invalid_arg "Eio net was set but is now None (unexpected state)"
      else
        invalid_arg
          "Eio net not initialized - ensure set_net is called during server startup"

let get_clock () =
  match Atomic.get current_clock with
  | Some clock -> clock
  | None ->
      invalid_arg
        "Eio clock not initialized - ensure set_clock is called during server startup"

let get_switch () =
  match Atomic.get current_sw with
  | Some sw -> sw
  | None ->
      invalid_arg
        "Eio switch not initialized - ensure set_switch is called during server startup"

(** TLS connector for Cohttp_eio HTTPS support. *)
let _https_connector_cache :
  (Uri.t ->
   [ `Generic ] Eio.Net.stream_socket_ty Eio.Resource.t ->
   [> Eio.Flow.two_way_ty ] Eio.Resource.t) option ref = ref None

let build_https_connector () =
  match Ca_certs.authenticator () with
  | Error (`Msg msg) ->
      failwith ("CA certs unavailable: " ^ msg)
  | Error _ ->
      failwith "CA certs unavailable: unknown error"
  | Ok authenticator ->
      (match Tls.Config.client ~authenticator () with
       | Error (`Msg msg) ->
           failwith ("TLS config error: " ^ msg)
       | Ok tls_config ->
           fun uri (raw : [ `Generic ] Eio.Net.stream_socket_ty Eio.Resource.t) ->
             let flow : [> Eio.Flow.two_way_ty ] Eio.Resource.t = (raw :> _) in
           let host =
             match Uri.host uri with
             | None -> None
             | Some h ->
                 (match Domain_name.of_string h with
                  | Ok d -> Some (Domain_name.host_exn d)
                  | Error _ -> None)
           in
           match host with
           | None -> failwith "TLS host missing/invalid"
           | Some host -> Tls_eio.client_of_flow tls_config ~host flow)

let get_https_connector () =
  match !_https_connector_cache with
  | Some c -> c
  | None ->
    let c = build_https_connector () in
    _https_connector_cache := Some c;
    c
