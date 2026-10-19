(** Applies Code surface replies. These functions perform no terminal or
    network IO; the caller executes layout and file-read followups. *)

type followup = No_followup | Reveal_cursor | Load_file of string

val push_code_jump : Masc_tui_types.state -> unit
val apply_entries : Masc_tui_types.state ->
  (Masc_tui_types.code_workspace_scope * string) Masc_tui_fetched.request ->
  (Masc.Tui_decode.workspace_tree_node list, string) result -> unit
val apply_catalog : Masc_tui_types.state ->
  (Masc_tui_types.code_workspace_scope * string) Masc_tui_fetched.request ->
  (Masc.Tui_decode.workspace_file_catalog, string) result -> unit
val apply_found_file : ?input_pending:bool -> Masc_tui_types.state ->
  (Masc_tui_types.code_workspace_scope * string) Masc_tui_fetched.request ->
  (string, string) result -> bool
(** [true] only when successful navigation was committed. Failure and stale
    replies preserve the original file, sibling panes, cursor and directory. *)
val take_ready_found_file : Masc_tui_types.state -> input_pending:bool -> bool
(** Commit a deferred successful reading only after queued input, paste and
    incomplete terminal sequences have had the opportunity to retire it. *)
val apply_file : ?intent:Masc_tui_types.code_file_load_intent ->
  Masc_tui_types.state -> string Masc_tui_fetched.request ->
  (string, string) result -> unit
val apply_blame : Masc_tui_types.state -> string Masc_tui_fetched.request ->
  (Masc.Tui_decode.blame_block list, string) result -> unit
val start_lsp_question : ?line:int -> Masc_tui_types.state -> question:string -> symbol:string ->
  Masc_tui_types.code_lsp_query Masc_tui_fetched.request option
(** Capture the source file and scope. Identical in-flight questions are
    suppressed; a different question owns a new request identity. *)
val apply_lsp_answer : Masc_tui_types.state ->
  Masc_tui_types.code_lsp_query Masc_tui_fetched.request ->
  (Masc.Tui_decode.lsp_answer, string) result -> followup
(** Admit only the latest question for the still-current source reading and
    scope. A stale success or failure changes neither state nor followups. *)
val apply_diff : Masc_tui_types.state -> string Masc_tui_fetched.request ->
  (Masc.Tui_decode.git_diff, string) result -> unit
val apply_history : Masc_tui_types.state ->
  (Masc_tui_types.code_workspace_scope * string) Masc_tui_fetched.request ->
  (Masc_tui_types.code_history_listing, string) result -> unit
