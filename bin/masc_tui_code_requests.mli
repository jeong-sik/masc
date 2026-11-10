(** Code request execution. The caller owns dispatch-captured workspace-stamped completion delivery
    and reporting.
    These operations keep request admission, state capture and Eio launch order
    together; response state transitions belong to {!Masc_tui_code_results}. *)

(** Capture scope and directory before launching; an already loading key is shared. *)
val launch_entries_load
  :  Masc_tui_types.state
  -> host:string
  -> deliver:(Masc_tui_code_results.msg -> unit)
  -> unit

(** Start the path request and deliver its whole-file response with its request key. *)
val launch_file_finder :
  Masc_tui_types.state -> host:string ->
  deliver:(Masc_tui_code_results.msg -> unit) -> unit

val launch_branches :
  Masc_tui_types.state -> host:string ->
  deliver:(Masc_tui_code_results.msg -> unit) -> unit
(** Open the branch palette over Code and read the branches of the checkout
    that owns the directory shown. A late list for another directory is dropped
    by the reading key. *)

val launch_worktrees :
  Masc_tui_types.state -> host:string ->
  deliver:(Masc_tui_code_results.msg -> unit) -> unit
(** Open the worktree palette over Code and read the worktrees of the
    repository that owns the directory shown. A late list for another directory
    is dropped by the reading key. *)

val launch_search :
  Masc_tui_types.state -> host:string ->
  deliver:(Masc_tui_code_results.msg -> unit) -> unit
(** Send the search prompt's text as one content search from the directory the
    search palette opened in. Text under the server's minimum is reported, not
    sent. A late answer for older text is dropped by the answer key. *)

val open_found_file :
  Masc_tui_types.state -> host:string ->
  deliver:(Masc_tui_code_results.msg -> unit) -> path:string -> unit
(** Read and prepare a selected file without replacing the original file or
    cursor. Whole-file preparation runs in the shared CPU worker before delivery.
    Only an admitted successful reply commits navigation through Code results. *)

val return_to_reading :
  Masc_tui_types.state -> host:string ->
  deliver:(Masc_tui_code_results.msg -> unit) -> unit
(** Return through jump history using the destination scope and confirmed
    workspace identity, without replacing the current file while reading. *)

val launch_navigation_read :
  Masc_tui_types.state -> host:string ->
  deliver:(Masc_tui_code_results.msg -> unit) ->
  Masc_tui_types.code_navigation_owner -> string Masc_tui_fetched.request -> unit
(** Send an already-owned return/location read under its destination scope and
    prepare the immutable document on the shared CPU worker before delivery. *)

val launch_file_load
  :  ?intent:Masc_tui_types.code_file_load_intent
  -> Masc_tui_types.state
  -> host:string
  -> deliver:(Masc_tui_code_results.msg -> unit)
  -> path:string
  -> unit
(** Capture the path and workspace before launching the read. Prepare the whole
    file on the shared CPU worker before delivering the original request; the UI
    only admits that request and installs its prepared document. After HTTP
    returns, the caller checks original workspace/read epoch and request ownership
    before submitting preparation. A same-scope retained immutable document can
    be reused for the same source object/revision returned by a validated 304.
    This neither cancels already submitted work nor replaces final admission. *)

(** Capture the workspace scope and activity address, then combine stable git and
    Keeper history. A failed source leaves the other source visible, with its
    failure reported in the listing. *)
val launch_history_load
  :  Masc_tui_types.state
  -> host:string
  -> deliver:(Masc_tui_code_results.msg -> unit)
  -> path:string
  -> unit

(** Read one diff target. The target is the fetched state's key, so an answer
    for any other target is dropped. *)
val launch_diff_load
  :  Masc_tui_types.state
  -> host:string
  -> deliver:(Masc_tui_code_results.msg -> unit)
  -> target:Masc_tui_types.code_diff_target
  -> unit

(** Capture workspace axes before launching the margin read. *)
val launch_blame_load
  :  Masc_tui_types.state
  -> host:string
  -> deliver:(Masc_tui_code_results.msg -> unit)
  -> path:string
  -> unit

(** With no open file, report the refusal. Otherwise capture the cursor and scope
    before the daemon starts; the LSP request generation travels with completion.
    Cancellation propagates; a missing switch delivers
    the existing error response instead of blocking on the request. *)
val start_lsp_question
  :  ?line:int
  -> Masc_tui_types.state
  -> host:string
  -> deliver:(Masc_tui_code_results.msg -> unit)
  -> report:(string -> string -> unit)
  -> question:string
  -> symbol:string
  -> unit

val save_draft : Masc_tui_types.state -> host:string ->
  deliver:(Masc_tui_code_results.msg -> unit) -> (unit, string) result
(** The outcome is a [Save] answer, which the loop delivers without a
    workspace stamp so navigation cannot lose the submitted draft's outcome.
    The UI still settles only its original ticket. *)

val reread_draft : Masc_tui_types.state -> host:string ->
  deliver:(Masc_tui_code_results.msg -> unit) -> (unit, string) result
(** Supersede an earlier file read and own a new comparison request after a
    conflict/uncertainty. A pre-submission GET cannot supply that comparison. *)
