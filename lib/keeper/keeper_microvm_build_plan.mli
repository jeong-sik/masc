type build_link_state =
  | Build_absent
  | Build_symlink of string
  | Build_real_directory

type build_link_plan =
  | Link_create of string
  | Link_retarget of string
  | Link_already_correct
  | Link_refused_real_directory
  | Link_refused_invalid_path of { detail : string; state : build_link_state }
      (** The checkout's path names no build target ({!build_link_target}'s
          [Error] is [detail]). [state] is what the scan found, so a real
          [_build] the next boot removes is still reported. *)

type build_scan_row =
  { checkout : string
  ; state : build_link_state
  }

type build_link_row =
  { checkout : string
  ; target : string option
  ; plan : build_link_plan
  }

val build_volume_guest_root : string
val build_link_target : playground_relative:string -> (string, string) result
val plan_build_link : target:string -> build_link_state -> build_link_plan
val build_scan_rows_of_output : string -> build_scan_row list
val build_link_rows_of_scan : build_scan_row list -> build_link_row list
val build_link_actions : build_link_row list -> (string * string) list
val build_link_targets : build_link_row list -> string list
