
(** Global Eio context for shared network/clock access.
    Set during server startup (main_eio.ml). *)

type eio_net = [`Generic | `Unix] Eio.Net.ty Eio.Resource.t

let current_net : eio_net option ref = ref None
let current_clock : float Eio.Time.clock_ty Eio.Resource.t option ref = ref None
let current_mono_clock : Eio.Time.Mono.ty Eio.Resource.t option ref = ref None
let current_sw : Eio.Switch.t option ref = ref None
let net_initialized : bool ref = ref false
let global_ctx_mutex = Eio.Mutex.create ()

let set_net net =
  Eio.Mutex.use_rw ~protect:true global_ctx_mutex (fun () ->
      current_net := Some (net :> eio_net);
      net_initialized := true)

let set_clock clock =
  Eio.Mutex.use_rw ~protect:true global_ctx_mutex (fun () ->
      current_clock := Some clock)

let set_mono_clock mc =
  Eio.Mutex.use_rw ~protect:true global_ctx_mutex (fun () ->
      current_mono_clock := Some mc)

let get_mono_clock () =
  Eio.Mutex.use_ro global_ctx_mutex (fun () ->
      match !current_mono_clock with
      | Some mc -> mc
      | None -> invalid_arg "Eio mono_clock not initialized")

let set_switch sw =
  Eio.Mutex.use_rw ~protect:true global_ctx_mutex (fun () ->
      current_sw := Some sw)

let get_net_opt () : eio_net option =
  Eio.Mutex.use_ro global_ctx_mutex (fun () -> !current_net)

let get_clock_opt () =
  Eio.Mutex.use_ro global_ctx_mutex (fun () -> !current_clock)

let get_switch_opt () =
  Eio.Mutex.use_ro global_ctx_mutex (fun () -> !current_sw)

let get_net () : eio_net =
  Eio.Mutex.use_ro global_ctx_mutex (fun () ->
      match !current_net with
      | Some net -> net
      | None ->
          if !net_initialized then
            invalid_arg "Eio net was set but is now None (unexpected state)"
          else
            invalid_arg
              "Eio net not initialized - ensure set_net is called during server startup")

let get_clock () =
  Eio.Mutex.use_ro global_ctx_mutex (fun () ->
      match !current_clock with
      | Some clock -> clock
      | None ->
          invalid_arg
            "Eio clock not initialized - ensure set_clock is called during server startup")

let get_switch () =
  Eio.Mutex.use_ro global_ctx_mutex (fun () ->
      match !current_sw with
      | Some sw -> sw
      | None ->
          invalid_arg
            "Eio switch not initialized - ensure set_switch is called during server startup")

(** TLS connector for Cohttp_eio HTTPS support. *)
let https_connector :
  (Uri.t ->
   [ `Generic ] Eio.Net.stream_socket_ty Eio.Resource.t ->
   [> Eio.Flow.two_way_ty ] Eio.Resource.t) Eio.Lazy.t =
  Eio.Lazy.from_fun ~cancel:`Protect (fun () ->
    let fail_closed msg =
      Log.Misc.info "%s" msg;
      (fun _uri _raw -> failwith msg)
    in
    match Ca_certs.authenticator () with
    | Error (`Msg msg) ->
        fail_closed ("CA certs unavailable: " ^ msg)
    | Error _ ->
        fail_closed "CA certs unavailable: unknown error"
    | Ok authenticator ->
        (match Tls.Config.client ~authenticator () with
         | Error (`Msg msg) ->
             fail_closed ("TLS config error: " ^ msg)
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
  )

let get_https_connector () =
  Eio.Lazy.force https_connector
