(** LSP Overlay Provider — inject MASC annotations into LSP protocol responses.

    Public interface for [Lsp_overlay_provider]. Internal JSON construction
    helpers ([codelens_to_json], [inlay_hint_to_json]) are intentionally
    not exposed. *)

val codelenses : base_dir:string -> file_path:string -> Yojson.Safe.t list
(** Generate LSP CodeLens entries for a file from MASC annotations. *)

val inlay_hints : base_dir:string -> file_path:string -> Yojson.Safe.t list
(** Generate LSP InlayHint entries for annotations with route-context bindings. *)

val diagnostics :
  base_dir:string ->
  file_path:string ->
  lsp_diagnostics:Yojson.Safe.t list ->
  Yojson.Safe.t list
(** Merge MASC annotation diagnostics with LSP server diagnostics. *)

val invalidate_cache : base_dir:string -> file_path:string -> unit
(** Remove cached annotations for a specific file. Call on didSave. *)

val clear_cache : unit -> unit
(** Remove all cached annotations. *)

val enrich_hover :
  base_dir:string -> file_path:string -> line:int -> Yojson.Safe.t -> Yojson.Safe.t
(** Append MASC annotation context to an LSP Hover response.
    Handles all Hover.contents forms: MarkupContent, MarkedString, MarkedString[].
    Returns the original response unchanged if no annotations overlap. *)

val has_annotations_at_line : base_dir:string -> file_path:string -> line:int -> bool
(** Check if any MASC annotations overlap the given LSP position (0-based line). *)

val definition_links : base_dir:string -> file_path:string -> line:int -> Yojson.Safe.t list
(** Generate LSP Location links for annotations overlapping [line].
    Used by textDocument/definition. *)

val reference_locations :
  base_dir:string -> file_path:string -> line:int -> include_declaration:bool ->
  Yojson.Safe.t list
(** Generate LSP Location[] for annotations related to those at [line].
    Finds annotations sharing the same task_id.
    Used by textDocument/references. *)

val completion_items : base_dir:string -> file_path:string -> line:int -> Yojson.Safe.t list
(** Generate CompletionItem[] for MASC annotation snippets.
    Used by textDocument/completion. *)

val code_actions :
  base_dir:string -> file_path:string -> line:int -> diagnostics:Yojson.Safe.t list ->
  Yojson.Safe.t list
(** Generate CodeAction[] for annotation operations.
    Used by textDocument/codeAction. *)

val document_symbols : base_dir:string -> file_path:string -> Yojson.Safe.t list
(** Generate SymbolInformation[] for MASC annotations.
    Used by textDocument/documentSymbol. *)

val folding_ranges : base_dir:string -> file_path:string -> Yojson.Safe.t list
(** Generate FoldingRange[] for consecutive annotation blocks.
    Used by textDocument/foldingRange. *)

val document_highlights : base_dir:string -> file_path:string -> line:int -> Yojson.Safe.t list
(** Generate DocumentHighlight[] for annotations sharing task context.
    Used by textDocument/documentHighlight. *)
