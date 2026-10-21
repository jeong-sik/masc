(** Applies Code surface replies. These functions perform no terminal or
    network IO; the caller executes layout and file-read followups. *)

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
val apply_diff : Masc_tui_types.state -> string Masc_tui_fetched.request ->
  (Masc.Tui_decode.git_diff, string) result -> unit
val apply_history : Masc_tui_types.state ->
  (Masc_tui_types.code_workspace_scope * string) Masc_tui_fetched.request ->
  (Masc_tui_types.code_history_listing, string) result -> unit
