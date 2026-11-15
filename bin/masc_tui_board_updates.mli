(** Apply Board readings and write completions on the UI state owner fiber.
    Transport, refresh scheduling and logging are caller-owned callbacks. *)

val leave_board_detail : Masc_tui_types.state -> unit
(** Clear detail selection, history and both reading scroll positions. *)

val apply_board_post_load :
  Masc_tui_types.state -> report_error:(string -> unit) ->
  Masc_tui_board_detail.request ->
  (Masc_tui_types.board_post * Masc_tui_types.board_comment list * string option, string) result -> unit
(** Only the current request for the post being read or replied to may populate
    detail. Entering reply composition retains that read; a new post or a
    different reply target cannot consume it. Success enriches the matching list
    row without reranking. Failure is reported to [report_error] only when the
    operator is away from the Board surface. *)

val apply_publication :
  Masc_tui_types.state -> report:(string -> string -> unit) ->
  refresh:(unit -> unit) ->
  Masc_tui_types.workspace_authority Masc_tui_board_publication.outcome -> unit
(** Archive a registered request's first outcome before checking current UI
    authority. Only that exact current request may release the write or change
    its draft. A proven publication removes its original staged objects even
    when a later step failed. Unknown outcomes retain the draft and files.
    Draft protection compares submitted bytes; it does not track revisions. *)

val comment_outcome_unknown : ko:bool -> string
(** A comment that may or may not have landed: its dispatch did not run, or
    was interrupted after the request could have reached the server. The
    operator looks at the thread before sending it again. *)

val comment_launch_failed :
  Masc_tui_types.state -> request_id:Masc_tui_types.board_comment_request_id -> unit
(** Release only the matching request after launch failure. Dispatch failure
    does not prove whether the remote comment was sent; retain the draft and
    ask the user to check the thread before retrying. *)

val comment_done :
  Masc_tui_types.state -> request_id:Masc_tui_types.board_comment_request_id ->
  post_id:string -> sent_draft:string ->
  report:(string -> string -> unit) -> refresh:(unit -> unit) ->
  refresh_detail:(string -> unit) -> (string, string) result -> unit
(** Only the exact current comment request may release its write. Success
    clears an unchanged draft and refreshes the list and its post detail.
    Failure retains the text. Comments carry no staged attachments. *)

val vote_done :
  Masc_tui_types.state -> report:(string -> string -> unit) ->
  refresh:(unit -> unit) -> refresh_detail:(string -> unit) ->
  Masc_tui_types.board_vote_target -> (string, string) result -> unit
(** Disarm the vote on either outcome. Success reports, refreshes the list,
    and refreshes the reading of the post the target lands on or under when
    that post is still the one open. *)
