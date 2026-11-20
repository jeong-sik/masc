(** Action-line and error-text formatting for workspace-guarded requests
    and kept-back operations. *)

val report_kept_back
  :  Masc_tui_types.state
  -> request:Masc_tui_words.Kept_request.t
  -> (ko:bool -> string)
  -> Masc_tui_words.kept
  -> unit

val report_withdrawn
  :  Masc_tui_types.state
  -> request:Masc_tui_words.Kept_request.t
  -> Masc_tui_types.workspace_refusal
  -> unit

val said_read_result
  :  Masc_tui_types.state
  -> request:Masc_tui_words.Kept_request.t
  -> ('a, Masc_tui_types.request_failure) result
  -> ('a, string) result

val workspace_response_refusal_text
  :  Masc_tui_types.state
  -> request:Masc_tui_words.Kept_request.t
  -> Masc_tui_types.workspace_refusal
  -> string

val request_failure_after_read
  :  Masc_tui_types.state
  -> request:Masc_tui_words.Kept_request.t
  -> Masc_tui_types.request_failure
  -> Masc_tui_types.request_failure

val kept_back_until_reconnect
  :  ko:bool
  -> request:Masc_tui_words.Kept_request.t
  -> string
