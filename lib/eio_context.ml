[@@@warning "-32"]

(** Global Eio context for shared network/clock access.
    Set during server startup (main_eio.ml). *)

type eio_net = [`Generic] Eio.Net.ty Eio.Resource.t

let current_net : eio_net option ref = ref None
let current_clock : float Eio.Time.clock_ty Eio.Resource.t option ref = ref None

let set_net net = current_net := Some (net :> eio_net)
let set_clock clock = current_clock := Some clock

let get_net_opt () : eio_net option = !current_net
let get_clock_opt () = !current_clock

let get_net () : eio_net =
  match !current_net with
  | Some net -> net
  | None -> invalid_arg "Eio net not initialized - ensure set_net is called during server startup"

let get_clock () =
  match !current_clock with
  | Some clock -> clock
  | None -> invalid_arg "Eio clock not initialized - ensure set_clock is called during server startup"

(** TLS connector for Cohttp_eio HTTPS support. *)
let https_connector :
  (Uri.t ->
   [ `Generic ] Eio.Net.stream_socket_ty Eio.Resource.t ->
   [> Eio.Flow.two_way_ty ] Eio.Resource.t) lazy_t =
  lazy (
    let authenticator =
      match Ca_certs.authenticator () with
      | Ok a -> a
      | Error _ -> (fun ?ip:_ ~host:_ _certs -> Ok None)
    in
    let tls_config =
      match Tls.Config.client ~authenticator () with
      | Ok cfg -> cfg
      | Error (`Msg msg) -> failwith ("TLS config error: " ^ msg)
    in
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
      Tls_eio.client_of_flow tls_config ?host flow
  )

let get_https_connector () =
  Lazy.force https_connector
