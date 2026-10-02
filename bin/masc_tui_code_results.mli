(** Applies Code surface replies. These functions perform no terminal or
    network IO; the caller executes layout and file-read followups. *)

type followup = No_followup | Reveal_cursor | Load_file of string

val push_code_jump : Masc_tui_types.state -> unit
val apply_entries : Masc_tui_types.state ->
  (Masc_tui_types.code_workspace_scope * string) Masc_tui_fetched.request ->
  (Masc.Tui_decode.workspace_tree_node list, string) result -> unit
val apply_file : Masc_tui_types.state -> string Masc_tui_fetched.request ->
  (string, string) result -> unit
val apply_blame : Masc_tui_types.state -> string Masc_tui_fetched.request ->
  (Masc.Tui_decode.blame_block list, string) result -> unit
val start_lsp_question : Masc_tui_types.state -> question:string -> symbol:string ->
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
