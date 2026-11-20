(** Diff width measurement, horizontal scroll bounds, bundle-relative change
    paths, and working-tree git-diff loading. *)

val git_diff_body_max_width : Masc.Tui_decode.git_diff -> int

val refresh_recorded_diff_bounds : Masc_tui_types.state -> reset:bool -> unit

val change_absolute_path
  :  base_path:string
  -> Masc.Tui_decode.file_change
  -> string

val change_bundle_relative_path : Masc.Tui_decode.file_change -> string option

val launch_git_diff_load
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> keeper:string option
  -> path:string
  -> unit
