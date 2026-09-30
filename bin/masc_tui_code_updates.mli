(** Apply Code responses on the UI state owner fiber. State mutation belongs
    here; navigation effects are caller-supplied. These operations do not
    schedule fibers, fetch data, read clocks or draw terminal output themselves. *)

val entries_loaded :
  Masc_tui_types.state ->
  (Masc_tui_types.code_workspace_scope * string) Masc_tui_fetched.request ->
  (Masc.Tui_decode.workspace_tree_node list, string) result -> unit
(** Complete the scoped listing and reconcile its cursor for the matching key. *)

val file_loaded :
  Masc_tui_types.state -> string Masc_tui_fetched.request ->
  (string, string) result -> unit
(** Drop an obsolete file request before changing cursor, memo or sibling panes.
    A current success lexes and sanitizes once, applies the pending line jump,
    and clears readings belonging to the previous file. *)

val blame_loaded :
  Masc_tui_types.state -> string Masc_tui_fetched.request ->
  (Masc.Tui_decode.blame_block list, string) result -> unit
(** Complete only the current file margin request. *)

val lsp_answered :
  Masc_tui_types.state -> question:string -> symbol:string ->
  push_jump:(unit -> unit) -> content_height:(unit -> int) ->
  load_file:(path:string -> unit) ->
  (Masc.Tui_decode.lsp_answer, string) result -> unit
(** Record the language-server answer. An inside-workspace location records
    the departure with [push_jump] before moving the current cursor or setting
    the line target and calling [load_file]. [content_height] is read only for
    a jump within the already readable file. Outside locations remain notes. *)

val diff_loaded :
  Masc_tui_types.state -> string Masc_tui_fetched.request ->
  (Masc.Tui_decode.git_diff, string) result -> unit
(** Reset diff scroll only for a successful current request. *)

val history_loaded :
  Masc_tui_types.state ->
  (Masc_tui_types.code_workspace_scope * string) Masc_tui_fetched.request ->
  (Masc_tui_types.code_history_listing, string) result -> unit
(** Scope and path both select the reading; reset scroll only on current success. *)
