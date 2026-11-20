(** Local write-authority guard shared by editor form handlers. *)

val workspace_write_ready
  :  Masc_tui_types.state
  -> request:Masc_tui_words.Kept_request.t
  -> bool
