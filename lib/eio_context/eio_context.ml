(** Global Eio context for shared network/clock access.
    Set once during server startup (main_eio.ml), read from any context.

    Uses Atomic.t (lock-free WORM pattern): each field is written once at
    init and read many times from Eio fibers, CI tests, and OAS callbacks.
    No mutex needed — Atomic.get/set are single-instruction operations. *)

type eio_net = [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t

type state_snapshot =
  { net : eio_net option
  ; clock : float Eio.Time.clock_ty Eio.Resource.t option
  ; mono_clock : Eio.Time.Mono.ty Eio.Resource.t option
  ; sw : Eio.Switch.t option
  ; net_initialized : bool
  }

let current_net : eio_net option Atomic.t = Atomic.make None

let current_clock : float Eio.Time.clock_ty Eio.Resource.t option Atomic.t =
  Atomic.make None
;;

let current_mono_clock : Eio.Time.Mono.ty Eio.Resource.t option Atomic.t =
  Atomic.make None
;;

let current_sw : Eio.Switch.t option Atomic.t = Atomic.make None
let net_initialized : bool Atomic.t = Atomic.make false
let with_test_env_lock = Eio.Mutex.create ()

let snapshot_state () =
  { net = Atomic.get current_net
  ; clock = Atomic.get current_clock
  ; mono_clock = Atomic.get current_mono_clock
  ; sw = Atomic.get current_sw
  ; net_initialized = Atomic.get net_initialized
  }
;;

let restore_state snapshot =
  Atomic.set current_net snapshot.net;
  Atomic.set current_clock snapshot.clock;
  Atomic.set current_mono_clock snapshot.mono_clock;
  Atomic.set current_sw snapshot.sw;
  Atomic.set net_initialized snapshot.net_initialized
;;

let set_net net =
  Atomic.set current_net (Some (net :> eio_net));
  Atomic.set net_initialized true
;;

let set_clock clock = Atomic.set current_clock (Some clock)
let set_mono_clock mc = Atomic.set current_mono_clock (Some mc)

let get_mono_clock () : (Eio.Time.Mono.ty Eio.Resource.t, string) result =
  match Atomic.get current_mono_clock with
  | Some mc -> Ok mc
  | None -> Error "Eio mono_clock not initialized"
;;

let get_mono_clock_opt () = Atomic.get current_mono_clock
let set_switch sw = Atomic.set current_sw (Some sw)

let with_test_env ~net ~clock ~mono_clock ~sw f =
  Eio.Mutex.use_rw ~protect:false with_test_env_lock (fun () ->
    let snapshot = snapshot_state () in
    set_net net;
    set_clock clock;
    set_mono_clock mono_clock;
    set_switch sw;
    Fun.protect ~finally:(fun () -> restore_state snapshot) f)
;;

let get_net_opt () : eio_net option = Atomic.get current_net
let get_clock_opt () = Atomic.get current_clock
let get_switch_opt () = Atomic.get current_sw

let get_net () : (eio_net, string) result =
  match Atomic.get current_net with
  | Some net -> Ok net
  | None ->
    if Atomic.get net_initialized
    then Error "Eio net was set but is now None (unexpected state)"
    else Error "Eio net not initialized - ensure set_net is called during server startup"
;;

let get_clock () : (float Eio.Time.clock_ty Eio.Resource.t, string) result =
  match Atomic.get current_clock with
  | Some clock -> Ok clock
  | None ->
    Error "Eio clock not initialized - ensure set_clock is called during server startup"
;;

let get_switch () : (Eio.Switch.t, string) result =
  match Atomic.get current_sw with
  | Some sw -> Ok sw
  | None ->
    Error "Eio switch not initialized - ensure set_switch is called during server startup"
;;

(** TLS connector for Cohttp_eio HTTPS support. *)
let _https_connector_cache
  : (Uri.t
     -> [ `Generic ] Eio.Net.stream_socket_ty Eio.Resource.t
     -> [> Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t)
      option
      ref
  =
  ref None
;;

let https_error message = Error message

let build_https_connector_result () =
  match Ca_certs.authenticator () with
  | Error (`Msg msg) -> https_error ("CA certs unavailable: " ^ msg)
  | Error _ -> https_error "CA certs unavailable: unknown error"
  | Ok authenticator ->
    (match Tls.Config.client ~authenticator () with
     | Error (`Msg msg) -> https_error ("TLS config error: " ^ msg)
     | Ok tls_config ->
       Ok
         (fun uri (raw : [ `Generic ] Eio.Net.stream_socket_ty Eio.Resource.t) ->
           let flow =
             (raw :> [> Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t)
           in
           let host =
             match Uri.host uri with
             | None -> None
             | Some h ->
               (match Domain_name.of_string h with
                | Ok d -> Some (Domain_name.host_exn d)
                | Error _ -> None)
           in
           match host with
           | None -> raise (Invalid_argument "TLS host missing/invalid")
           | Some host -> Tls_eio.client_of_flow tls_config ~host flow))
;;

let get_https_connector_result () =
  match !_https_connector_cache with
  | Some c -> Ok c
  | None ->
    (match build_https_connector_result () with
     | Ok c ->
       _https_connector_cache := Some c;
       Ok c
     | Error _ as error -> error)
;;

(* get_https_connector (crash variant) removed — all callers use
   get_https_connector_result which returns (connector, string) result. *)
