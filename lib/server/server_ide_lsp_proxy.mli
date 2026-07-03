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

  (** Per-language LSP health (task-1691). [Overlay_only] carries the last
      error that forced the language into overlay-only mode. *)
  type health =
    | Connected
    | Overlay_only of string

  (** [lang_status_json ~lang_id health] projects one language's health into
      the [masc/lspStatus] wire object: [lang] / [connected] / [overlay_only]
      / [command] (the configured LSP executable, [null] when none is mapped)
      / [last_error]. *)
  val lang_status_json : lang_id:string -> health -> Yojson.Safe.t

  (** [status_snapshot_json healths] renders the full per-language snapshot
      (the [masc/lspStatus] response/notification payload), languages sorted
      by id for a stable wire order. *)
  val status_snapshot_json : (string * health) list -> Yojson.Safe.t
end
