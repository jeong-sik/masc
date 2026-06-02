(** Server IDE LSP Proxy — WebSocket bridge for Language Server Protocol
    with MASC observational overlays. *)

(** Add LSP proxy routes to the router.
    Exposes [/api/v1/ide/lsp] WebSocket endpoint for LSP traffic. *)
val add_routes :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Http_server_eio.Router.t -> Http_server_eio.Router.t

module For_testing : sig
  val resolve_relative : base:string -> string -> string option
  val workspace_root_for_initialize : base_path:string -> string -> string
  val initialize_result_json : unit -> Yojson.Safe.t

  type route_admission =
    | Upgrade_websocket
    | Missing_process_manager

  val route_admission : has_proc_mgr:bool -> route_admission
end
