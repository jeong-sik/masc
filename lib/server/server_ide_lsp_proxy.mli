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
  val inbound_dispatch_worker_count : int

  (** [resolve_lang relative] classifies a workspace-relative path's language
      (task-1691): [Known_lang lang_id] when a language server is mapped, else
      [Unknown_lang]. *)
  type lang =
    | Known_lang of string
    | Unknown_lang

  val resolve_lang : string -> lang

  (** Fixed size of the inbound LSP dispatch worker pool
      ([Lsp_proxy_limits.inbound_dispatch_worker_count]); >1 keeps slow LSP
      init off the socket read path. *)
  val inbound_dispatch_worker_count : int

  type resolved_lang =
    | Known_lang of string
    | Unknown_lang

  (** [resolve_lang relative] classifies a workspace-relative path into a typed
      language verdict; unknown extensions are [Unknown_lang] rather than a
      permissive default. *)
  val resolve_lang : string -> resolved_lang

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

  (** Disposition of a catch-all forwarded LSP method (task-1692).
      [Forward_read_only] methods are proxied to the language server;
      [Reject_write_adjacent] (rename / formatting / executeCommand /
      applyEdit) are refused so the observation plane stays read-only;
      [Unknown_forwarded_method] preserves unclassified wire methods for
      diagnostics before the caller rejects them. *)
  type disposition =
    | Forward_read_only
    | Reject_write_adjacent
    | Unknown_forwarded_method of string

  (** [classify_forwarded_method m] is the read-only allowlist decision for a
      method reaching the catch-all forwarder. Default-deny: only listed read
      methods forward, while unknown wire strings remain visible. *)
  val classify_forwarded_method : string -> disposition
end
