(** LSP Overlay Provider — inject MASC annotations into LSP protocol responses.

    Public interface for [Lsp_overlay_provider]. Internal JSON construction
    helpers ([codelens_to_json], [inlay_hint_to_json]) are intentionally
    not exposed. *)

val codelenses : base_dir:string -> file_path:string -> Yojson.Safe.t list
(** Generate LSP CodeLens entries for a file from MASC annotations. *)

val inlay_hints : base_dir:string -> file_path:string -> Yojson.Safe.t list
(** Generate LSP InlayHint entries for annotations with goal/task bindings. *)

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
