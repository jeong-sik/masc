(** Applies Code surface replies. These functions perform no terminal or
    network IO; the caller executes layout and file-read followups. *)

(** The Code pane's async answers. [Masc_tui_async_protocol.async_msg]
    carries them in [Code_msg]. *)
type msg =
  (* The scope travels with the directory. Without it a reply names a
     relative path, which two scopes can both have, and the handler had no
     way to tell a late answer for the scope just left from an answer for the
     scope now open (#33946). *)
  | Code_catalog_loaded of
      (Masc_tui_types.code_workspace_scope * string) Masc_tui_fetched.request
      * (Masc.Tui_decode.workspace_file_catalog, string) result
  | Code_branches_loaded of
      (Masc_tui_types.code_workspace_scope * string) Masc_tui_fetched.request
      * (Masc.Tui_decode.git_branches, string) result
  | Code_worktrees_loaded of
      (Masc_tui_types.code_workspace_scope * string) Masc_tui_fetched.request
      * (Masc.Tui_decode.git_worktrees, string) result
  | Code_search_loaded of
      Masc_tui_types.code_search_key Masc_tui_fetched.request
      * (Masc.Tui_decode.workspace_search, string) result
  | Code_finder_file_loaded of
      (Masc_tui_types.code_workspace_scope * string) Masc_tui_fetched.request
      * (Masc.Tui_decode.workspace_file_source, string) result
  | Code_entries_loaded of
      (Masc_tui_types.code_workspace_scope * string) Masc_tui_fetched.request
      * (Masc.Tui_decode.workspace_tree_node list, string) result
  | Code_draft_saved of Masc_tui_types.code_save_request * Masc_tui_code_draft.outcome
  | Code_file_loaded of
      Masc_tui_types.code_file_load_intent
      * string Masc_tui_fetched.request
      * (Masc.Tui_decode.workspace_file_source, string) result
  | Code_history_loaded of
      (Masc_tui_types.code_workspace_scope * string) Masc_tui_fetched.request
      * (Masc_tui_types.code_history_listing, string) result
  | Code_diff_loaded of
      Masc_tui_types.code_diff_target Masc_tui_fetched.request
      * (Masc.Tui_decode.git_diff, string) result
  (* The path the margin describes; stamped so a late answer cannot caption
     another file. *)
  | Code_blame_loaded of
      string Masc_tui_fetched.request
      * (Masc.Tui_decode.blame_block list, string) result
  | Code_lsp_answered of
      Masc_tui_types.code_lsp_query Masc_tui_fetched.request
      * (Masc.Tui_decode.lsp_answer, string) result

(** The protocol and the loop decide by kind, not by answer: whether an answer
    is a read, whether it waits for input, whether it carries an operation
    receipt, what is left to clean up when its workspace has changed, and
    whether it is stamped with the workspace that asked. A new answer that
    takes an existing kind takes all of that kind's decisions without a
    compile error. An answer that needs another decision adds a kind, and
    then each match on the kind stops compiling until it decides. *)
type answer_kind =
  | Read  (** Reads the workspace that asked, and is stamped with it. *)
  | Save
      (** The outcome of the draft save. It is not stamped, so navigation
          cannot lose it. *)

val answer_kind : msg -> answer_kind

(** What is left for the loop after {!apply}. *)
type answer_followup =
  | No_answer_followup
  | Reload_saved_file of string
      (** The save committed while its file was the reading on screen. The
          loop reads the file again unless input is waiting; then the demand
          waits for {!saved_refresh_path}. *)

val apply : Masc_tui_types.state -> msg -> answer_followup
(** Apply one answer to the Code pane's state. *)

type followup =
  | No_followup
  | Reveal_cursor
  | Choose_location
  | Read_location_file of Masc_tui_types.code_navigation_owner * string Masc_tui_fetched.request

val push_code_jump : Masc_tui_types.state -> unit
type return_followup =
  | No_return
  | Return_committed
  | Read_navigation_file of Masc_tui_types.code_navigation_owner * string Masc_tui_fetched.request

val start_return : Masc_tui_types.state -> return_followup
(** Keep history and the current reading until the destination is available.
    Repeated requests share the pending return. A readable current destination
    or a tree-only destination commits immediately. Pending activity belongs to
    the navigation owner; starting a return does not overwrite the settled note. *)
val take_ready_navigation_file : Masc_tui_types.state -> input_pending:bool -> bool
(** Commit an owned return or different-file LSP location after queued input.
    Return consumes an entry; a location records the source only on success.
    Failure, cancellation and superseded owners preserve the source/history. *)
val apply_entries : Masc_tui_types.state ->
  (Masc_tui_types.code_workspace_scope * string) Masc_tui_fetched.request ->
  (Masc.Tui_decode.workspace_tree_node list, string) result -> unit
val apply_catalog : Masc_tui_types.state ->
  (Masc_tui_types.code_workspace_scope * string) Masc_tui_fetched.request ->
  (Masc.Tui_decode.workspace_file_catalog, string) result -> unit
val apply_branches : Masc_tui_types.state ->
  (Masc_tui_types.code_workspace_scope * string) Masc_tui_fetched.request ->
  (Masc.Tui_decode.git_branches, string) result -> unit
(** Lands only while the branch palette that asked is still open over the same
    directory; a late list for another key is dropped. *)
val apply_worktrees : Masc_tui_types.state ->
  (Masc_tui_types.code_workspace_scope * string) Masc_tui_fetched.request ->
  (Masc.Tui_decode.git_worktrees, string) result -> unit
(** Lands only while the worktree palette that asked is still open over the
    same directory; a late list for another key is dropped. *)
val apply_search : Masc_tui_types.state ->
  Masc_tui_types.code_search_key Masc_tui_fetched.request ->
  (Masc.Tui_decode.workspace_search, string) result -> unit
(** Lands only while the search palette that asked is still open in the
    directory it opened in; a late answer for an older key is dropped. *)
val choose_search_match : Masc_tui_types.state ->
  Masc.Tui_decode.workspace_search_match -> followup
(** Open a match of the answer the search palette shows, at its line. Selection
    closes the palette; anything that is not a member of that answer changes
    nothing. *)
val apply_found_file : ?input_pending:bool -> Masc_tui_types.state ->
  (Masc_tui_types.code_workspace_scope * string) Masc_tui_fetched.request ->
  (Masc.Tui_decode.workspace_file_source, string) result -> bool
(** [true] only when successful navigation was committed. Failure and stale
    replies preserve the original file, sibling panes, cursor and directory. *)
val take_ready_found_file : Masc_tui_types.state -> input_pending:bool -> bool
(** Commit a deferred successful reading only after queued input, paste and
    incomplete terminal sequences have had the opportunity to retire it. *)
val apply_file : ?intent:Masc_tui_types.code_file_load_intent ->
  Masc_tui_types.state -> string Masc_tui_fetched.request ->
  (Masc.Tui_decode.workspace_file_source, string) result -> unit
val copy_file_source : Masc_tui_types.state -> ((string * string), string) result
(** The current readable file's path and original response bytes, without
    display sanitation, syntax colours, gutters or line-ending reconstruction.
    Requires confirmed workspace authority and focused file content; initial,
    failed and suspended readings or file overlays never supply clipboard bytes.
    A same-file refresh retains the readable source until new bytes arrive.
    The caller owns OSC 52 delivery and cannot infer terminal acknowledgement. *)
val apply_blame : Masc_tui_types.state -> string Masc_tui_fetched.request ->
  (Masc.Tui_decode.blame_block list, string) result -> unit
val start_lsp_question : ?line:int -> Masc_tui_types.state -> question:string -> symbol:string ->
  Masc_tui_types.code_lsp_query Masc_tui_fetched.request option
(** Capture the source file and scope. Identical in-flight questions are
    suppressed; a different question owns a new request identity. An accepted
    request clears the previous settled note; pending status comes from its
    owned fetched source. *)
val apply_lsp_answer : Masc_tui_types.state ->
  Masc_tui_types.code_lsp_query Masc_tui_fetched.request ->
  (Masc.Tui_decode.lsp_answer, string) result -> unit
(** Admit only the latest question for the still-current source reading and
    scope. Location answers are staged until input has had priority. *)
val scroll_hover : Masc_tui_types.state -> count:int -> height:int ->
  [ `Up | `Down | `Page_up | `Page_down | `First | `Last ] -> unit
(** Scroll only the retained hover belonging to the current source reading.
    Code cursor, position, jump history and source requests are unchanged. *)
val retire_lsp_input : Masc_tui_types.state -> unit
(** Retire an in-flight answer, its recovery key and an unopened location offer
    before handling operator input. An already open owned location picker
    keeps its query ticket and filter until selection or close. *)
val take_ready_lsp_locations : Masc_tui_types.state -> input_pending:bool -> followup
(** Open a multiple-location picker or follow a single location only after
    queued input. Another modal, source or authority cannot borrow the offer. *)
val choose_lsp_location : Masc_tui_types.state ->
  Masc_tui_types.code_location_offer -> Masc.Tui_decode.lsp_location -> followup
(** Follow only an actual member of the current owned offer. Selection closes
    the picker; unsuccessful navigation still preserves the source/history. *)
val apply_diff : Masc_tui_types.state ->
  Masc_tui_types.code_diff_target Masc_tui_fetched.request ->
  (Masc.Tui_decode.git_diff, string) result -> unit
(** An admitted diff's horizontal extent uses the body's tab expansion and
    single-line sanitation, matching the text rendered in the Code pane. *)
val apply_history : Masc_tui_types.state ->
  (Masc_tui_types.code_workspace_scope * string) Masc_tui_fetched.request ->
  (Masc_tui_types.code_history_listing, string) result -> unit

val prepare_draft : Masc_tui_types.state -> (Masc_tui_code_draft.t, string) result
val edit_draft : Masc_tui_types.state -> Masc_tui_code_draft.t -> string -> (unit, string) result
val discard_draft : Masc_tui_types.state -> (unit, string) result
val adopt_draft_revision : Masc_tui_types.state -> (unit, string) result
val begin_draft_save : Masc_tui_types.state -> (Masc_tui_types.code_save_request * Masc_tui_code_draft.t, string) result
val complete_draft_save : Masc_tui_types.state -> Masc_tui_types.code_save_request -> Masc_tui_code_draft.outcome -> bool
(** Settle only the submitted draft regardless of the current view. [true] means
    the original reading still owns an optional post-save refresh. *)

val saved_refresh_path : Masc_tui_types.state -> input_pending:bool -> string option
(** One post-save read demand waits for queued input and newer navigation/read
    ownership. It is consumed by a newly dispatched file read, never by an old reply. *)
