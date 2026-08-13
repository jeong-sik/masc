(** LSP Overlay Provider — inject MASC annotations into LSP protocol responses.

    Public interface for [Lsp_overlay_provider]. Internal JSON construction
    helpers ([codelens_to_json], [inlay_hint_to_json]) are intentionally
    not exposed.

    [partition] names the [.masc-ide/] store being read and is explicit on
    every entry point: annotations live in per-codebase partitions, so a
    reader that does not name one addresses the wrong rows. [None] means the
    caller addresses no store — an LSP connection opened without an IDE
    scope — and yields the empty overlay. It is never coerced to a default
    partition.

    [base_dir] is the directory that holds [.masc-ide/]. [document_root] is
    the absolute root a stored annotation's relative [file_path] hangs off,
    which is the workspace tree the reader opened — a different directory.
    Only the entry points that return LSP [Location]s need it. *)

val codelenses : base_dir:string -> partition:Ide_paths.partition option -> file_path:string -> Yojson.Safe.t list
(** Generate LSP CodeLens entries for a file from MASC annotations. *)

val inlay_hints : base_dir:string -> partition:Ide_paths.partition option -> file_path:string -> Yojson.Safe.t list
(** Generate LSP InlayHint entries for annotations with route-context bindings. *)

val diagnostics :
  base_dir:string ->
  partition:Ide_paths.partition option ->
  file_path:string ->
  lsp_diagnostics:Yojson.Safe.t list ->
  Yojson.Safe.t list
(** Merge MASC annotation diagnostics with LSP server diagnostics. *)

val invalidate_cache : base_dir:string -> partition:Ide_paths.partition option -> file_path:string -> unit
(** Remove cached annotations for a specific file. Call on didSave. *)

val clear_cache : unit -> unit
(** Remove all cached annotations. *)

val enrich_hover :
  base_dir:string -> partition:Ide_paths.partition option -> file_path:string -> line:int -> Yojson.Safe.t -> Yojson.Safe.t
(** Append MASC annotation context to an LSP Hover response.
    Handles all Hover.contents forms: MarkupContent, MarkedString, MarkedString[].
    Returns the original response unchanged if no annotations overlap. *)

val has_annotations_at_line : base_dir:string -> partition:Ide_paths.partition option -> file_path:string -> line:int -> bool
(** Check if any MASC annotations overlap the given LSP position (0-based line). *)

val definition_links :
  base_dir:string ->
  partition:Ide_paths.partition option ->
  document_root:string ->
  file_path:string ->
  line:int ->
  Yojson.Safe.t list
(** Generate LSP Location links for annotations overlapping [line].
    Used by textDocument/definition. *)

val reference_locations :
  base_dir:string ->
  partition:Ide_paths.partition option ->
  document_root:string ->
  file_path:string ->
  line:int ->
  include_declaration:bool ->
  Yojson.Safe.t list
(** Generate LSP Location[] for annotations related to those at [line].
    Finds annotations sharing the same goal_id or task_id.
    Used by textDocument/references. *)

val completion_items : base_dir:string -> partition:Ide_paths.partition option -> file_path:string -> line:int -> Yojson.Safe.t list
(** Generate CompletionItem[] for MASC annotation snippets.
    Used by textDocument/completion. *)

val code_actions :
  base_dir:string -> partition:Ide_paths.partition option -> file_path:string -> line:int -> diagnostics:Yojson.Safe.t list ->
  Yojson.Safe.t list
(** Generate CodeAction[] for annotation operations.
    Used by textDocument/codeAction. *)

val document_symbols : base_dir:string -> partition:Ide_paths.partition option -> file_path:string -> Yojson.Safe.t list
(** Generate SymbolInformation[] for MASC annotations.
    Used by textDocument/documentSymbol. *)

val folding_ranges : base_dir:string -> partition:Ide_paths.partition option -> file_path:string -> Yojson.Safe.t list
(** Generate FoldingRange[] for consecutive annotation blocks.
    Used by textDocument/foldingRange. *)

val document_highlights : base_dir:string -> partition:Ide_paths.partition option -> file_path:string -> line:int -> Yojson.Safe.t list
(** Generate DocumentHighlight[] for annotations sharing goal/task context.
    Used by textDocument/documentHighlight. *)
