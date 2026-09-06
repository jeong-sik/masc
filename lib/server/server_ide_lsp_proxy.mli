(** Server IDE LSP Proxy — WebSocket bridge for Language Server Protocol. *)

(** Add LSP proxy routes to the router.
    Exposes [/api/v1/ide/lsp] WebSocket endpoint for LSP traffic. *)
val add_routes :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Http_server_eio.Router.t -> Http_server_eio.Router.t

module For_testing : sig
  val resolve_relative : base:string -> string -> string option
  val workspace_root_for_initialize : base_path:string -> string -> string
  val initialize_result_json : workspace_root:string -> unit -> Yojson.Safe.t
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

  type document_request_error =
    | Missing_document_uri
    | Document_uri_outside_workspace

  type resolved_document_request =
    { uri : string
    ; relative_path : string
    ; line : int option
    ; language : resolved_lang
    }

  (** Decode the document URI, workspace-relative path, optional non-negative
      line, and language verdict once. Missing/out-of-workspace documents stay
      typed errors rather than becoming [""] paths, and malformed/negative
      positions stay [None] rather than [-1]. *)
  val resolve_document_request :
    anchor:string ->
    Yojson.Safe.t ->
    (resolved_document_request, document_request_error) result

  (** Per-language LSP health (task-1691). [Overlay_only] carries the last
      error that left the language without a server; the proxy answers its
      requests with empty results until one comes up. *)
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

  (** Classification for methods handled directly by the proxy command catalog
      (task-1694). [Mutation] covers document-sync notifications forwarded by
      the proxy; write-adjacent request methods remain outside this catalog and
      are denied by {!classify_forwarded_method}. *)
  type method_class =
    | Read_only
    | Mutation
    | Lifecycle
    | Status

  (** Canonical handled LSP method catalog as [(wire_method, class)]. *)
  val handled_lsp_methods : unit -> (string * method_class) list

  (** Methods the proxy does not answer itself, and what happens to them.
      Disjoint from {!handled_lsp_methods} by construction: a method the
      catalog knows is classified from the catalog, so naming it here too
      would be two tables deciding the same thing (#28686). *)
  val relayed_lsp_methods : unit -> (string * disposition) list

  (** Classify a handled method by wire name, or [None] when the method is not
      in the direct proxy catalog. *)
  val classify_handled_lsp_method : string -> method_class option
end
