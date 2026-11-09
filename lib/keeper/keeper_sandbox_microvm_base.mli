(** The pieces the other [Keeper_sandbox_microvm_*] modules build on: the
    build link types and planners ({!Keeper_microvm_build_plan}), the CLI
    prefix of a backend, the Docker flags [container run] rejects, the guest
    mount point of the work volume and the form of a command's output in a log
    line.

    [Keeper_sandbox_microvm] includes this module. *)

type build_link_state = Keeper_microvm_build_plan.build_link_state =
  | Build_absent
  | Build_symlink of string
  | Build_real_directory

type build_link_plan = Keeper_microvm_build_plan.build_link_plan =
  | Link_create of string
  | Link_preserve_symlink of { existing : string; expected : string }
  | Link_already_correct
  | Link_refused_real_directory
  | Link_refused_invalid_path of { detail : string; state : build_link_state }

type build_scan_row = Keeper_microvm_build_plan.build_scan_row =
  { checkout : string
  ; state : build_link_state
  }

type build_link_row = Keeper_microvm_build_plan.build_link_row =
  { checkout : string
  ; target : string option
  ; plan : build_link_plan
  }

val build_volume_guest_root : string

val build_link_target : playground_relative:string -> (string, string) result

val plan_build_link : target:string -> build_link_state -> build_link_plan

val build_scan_rows_of_output : string -> (build_scan_row list, string) result

val build_link_rows_of_scan : build_scan_row list -> build_link_row list

val build_link_actions : build_link_row list -> (string * string) list

val build_link_targets : build_link_row list -> string list

val command_argv_for : Keeper_microvm_backend.t -> string list

val unsupported_docker_flags : string list

val work_volume_guest_root : string

val output_for_log : stdout:string -> stderr:string -> string
