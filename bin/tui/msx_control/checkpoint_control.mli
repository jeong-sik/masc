(** MSX view-generation tokens, durable checkpoint intent tracking, and
    workspace-guarded machine mutation admission. *)

type view_token

val capture_machine_view : Masc_tui_types.state -> view_token

val machine_view_is_current : Masc_tui_types.state -> view_token -> bool

val live_request_is_current
  :  Masc_tui_types.state
  -> Masc_tui_types.machine_live_request
  -> bool

val retire_machine_view : Masc_tui_types.state -> unit

val checkpoint_for_workspace
  :  Masc_tui_types.state
  -> Masc_tui_types.pending_msx_checkpoint option

val remember_checkpoint
  :  Masc_tui_types.state
  -> Masc_tui_types.pending_msx_checkpoint
  -> (unit, string) result

val forget_checkpoint
  :  Masc_tui_types.state
  -> Masc_tui_types.pending_msx_checkpoint
  -> unit

val machine_changes_allowed : Masc_tui_types.state -> bool

val machine_change_refusal : string

val run_machine_change
  :  ?checkpoint_boundary:bool
  -> Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> refused:(string -> 'err)
  -> unknown:(string -> 'err)
  -> withdrawn:(Masc_tui_types.workspace_refusal -> unit)
  -> deliver:(Masc.Tui_decode.server_identity option -> ('ok, 'err) result -> unit)
  -> (port:int -> expected_workspace:Masc.Tui_decode.server_identity -> ('ok, 'err) result)
  -> unit
