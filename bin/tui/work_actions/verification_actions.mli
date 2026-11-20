(** Verification evidence image cache/loading/export and verdict submission
    actions. *)

val ensure_img_cache_dir : unit -> string

val image_process_deadline_seconds : float

val verification_evidence_outcome
  :  ('a, Masc_tui_types.Verification_evidence_read.failure) result
  -> string

val log_verification_evidence_read
  :  Masc_tui_types.verification_evidence_request
  -> phase:string
  -> outcome:string
  -> unit

val cancel_verification_evidence_load
  :  Masc_tui_types.state
  -> reason:Masc_tui_types.Verification_evidence_read.failure
  -> unit

val launch_verification_evidence_load
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> Masc_tui_types.verification_evidence_key
  -> unit

val start_verification_verdict
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> task_id:string
  -> verification_id:string
  -> verdict:[ `Approve | `Reject of string ]
  -> unit

val verification_cursor_row
  :  Masc_tui_types.state
  -> Masc.Tui_decode.verification_request option

val step_verification_evidence : Masc_tui_types.state -> int -> unit

val export_verification_evidence
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> open_file:bool
  -> unit

val handle_verification_approve_key
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit
