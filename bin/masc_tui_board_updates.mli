(** Apply Board readings and write completions on the UI state owner fiber.
    Transport, refresh scheduling and logging are caller-owned callbacks. *)

val leave_board_detail : Masc_tui_types.state -> unit
(** Clear detail selection, history and both reading scroll positions. *)

val apply_board_post_load :
  Masc_tui_types.state -> report_error:(string -> unit) ->
  Masc_tui_board_detail.request ->
  (Masc_tui_types.board_post * Masc_tui_types.board_comment list * string option, string) result -> unit
(** Only the current request and selected post may populate detail. Success
    enriches the matching list row without reranking. Failure is reported to
    [report_error] only when the operator is away from the Board surface. *)

val new_post_done :
  Masc_tui_types.state -> reply_to:string option -> sent_draft:string ->
  sent_attachments:Masc_tui_types.board_staged_attachment list ->
  report:(string -> string -> unit) -> refresh:(unit -> unit) ->
  refresh_detail:(string -> unit) -> (string, string) result -> unit
(** Completion clears only an unchanged submitted draft. Success reports first,
    then updates that draft's compose state, refreshes the list and refreshes a
    reply's detail. The staged files that were sent leave the list even when
    the draft changed meanwhile; one staged during the send stays, and a
    comment carried none. Failure keeps the text and the staged files, and
    records its refusal. *)

val vote_done :
  Masc_tui_types.state -> report:(string -> string -> unit) ->
  refresh:(unit -> unit) -> refresh_detail:(string -> unit) ->
  Masc_tui_types.board_vote_target -> (string, string) result -> unit
(** Disarm the vote on either outcome. Success reports, refreshes the list,
    and refreshes the reading of the post the target lands on or under when
    that post is still the one open. *)
