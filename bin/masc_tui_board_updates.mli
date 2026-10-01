(** Apply Board readings and write completions on the UI state owner fiber.
    Transport, refresh scheduling and logging are caller-owned callbacks. *)

val leave_board_detail : Masc_tui_types.state -> unit
(** Clear detail selection, history and both reading scroll positions. *)

val apply_board_hearths_load :
  Masc_tui_types.state -> ((string * int) list, string) result -> unit
(** A failed census retains the last successful reading. *)

val apply_board_list_load :
  Masc_tui_types.state -> remember_error:(string -> unit) ->
  (Masc_tui_types.board_post list, string) result -> unit
(** Success reconciles list selection. [remember_error] records the list error
    and reports it using the caller's existing deduplication policy. A filtered
    list cannot establish that an exact-ID detail target disappeared. *)

val apply_board_post_load :
  Masc_tui_types.state -> report_error:(string -> unit) ->
  Masc_tui_board_detail.request ->
  (Masc_tui_types.board_post * Masc_tui_types.board_comment list, string) result -> unit
(** Only the current request and selected post may populate detail. Success
    enriches the matching list row without reranking. Failure is reported to
    [report_error] only when the operator is away from the Board surface. *)

val new_post_done :
  Masc_tui_types.state -> reply_to:string option -> sent_draft:string ->
  report:(string -> string -> unit) -> refresh:(unit -> unit) ->
  refresh_detail:(string -> unit) -> (string, string) result -> unit
(** Completion clears only an unchanged submitted draft. Success reports first,
    then updates that draft's compose state, refreshes the list and refreshes a
    reply's detail. Failure keeps the text and records its refusal. *)

val vote_done :
  Masc_tui_types.state -> report:(string -> string -> unit) ->
  refresh:(unit -> unit) -> (string, string) result -> unit
(** Disarm the vote on either outcome; success reports before refreshing. *)
