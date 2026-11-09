(** The keeper's work volume as the CLI sees it: its name, creation and mount
    argv, the build root markers, the scripts that trim, reclaim and repair
    it, and the discard setting read back from it.

    [Keeper_sandbox_microvm] includes this module. *)

val valid_volume_segment : string -> bool

val apple_volume_create_argv : volume_name:string -> size:string -> string list

val msb_volume_create_argv : volume_name:string -> string list

val work_volume_name : keeper_name:string -> (string, string) result

val work_volume_mount_args : volume_name:string -> string list

val build_root_scan_depth : int

val build_root_marker : string

val build_output_dir_name : string

val build_keep_marker : string

val trim_guest_root : string

val work_volume_trim_name : keeper_name:string -> string

val first_handoff_build_cleanup_script : keeper_work_root:string -> string

val discard_configuration_script_with : findmnt:string -> tune2fs:string -> guest_root:string -> string

val apple_work_volume_trim_argv :
  keeper_name:string -> volume_name:string -> image:string -> string list

val apple_container_list_argv : unit -> string list

val apple_listing_row_id :
  (string *
   Yojson.Safe.t)
  list -> string option

val remove_apple_work_volume_trim :
  run:(timeout_sec:float -> string list -> Unix.process_status * string * string)
  -> timeout_sec:float
  -> remove_timeout_sec:float
  -> keeper_name:string
  -> (unit, string) result

type discard_read_failure =
  | Discard_backend_unsupported of Keeper_microvm_backend.t
  | Discard_volume_name_invalid of string
  | Discard_inspect_unavailable of Keeper_microvm_cli_output.error
  | Discard_inspect_failed of Unix.process_status
  | Discard_inspect_invalid_json
  | Discard_inspect_invalid of Keeper_volume_filesystem.inspect_failure
  | Discard_volume_mismatch of { expected : string; actual : string }
  | Discard_image_unreadable of Keeper_volume_filesystem.read_failure

type work_volume_discard_default =
  | Discard_default_set
  | Discard_default_absent
  | Superblock_unreadable of discard_read_failure

val apple_volume_inspect_argv : volume_name:string -> string list

val read_work_volume_discard_default :
  backend:Keeper_microvm_backend.t -> keeper_name:string -> timeout_sec:float ->
  work_volume_discard_default

val discard_read_failure_message : discard_read_failure -> string

type discard_configuration =
  | Discard_already_set
  | Discard_unreadable of discard_read_failure
  | Discard_helper_finished of
      { status : Unix.process_status; output : string; after : work_volume_discard_default }

val reclaim_apple_work_volume :
  run:(timeout_sec:float -> string list -> Unix.process_status * string * string)
  -> on_cleanup_error:(string -> unit)
  -> timeout_sec:float
  -> remove_timeout_sec:float
  -> keeper_name:string
  -> volume_name:string
  -> image:string
  -> (discard_configuration, string) result

val volume_repair_guest_root : string

val volume_repair_name : keeper_name:string -> string

val volume_repair_script_with :
  findmnt:string -> umount:string -> e2fsck:string -> guest_root:string -> string

val volume_repair_script : string

val apple_volume_repair_argv :
  keeper_name:string -> volume_name:string -> image:string -> string list

val remove_apple_volume_repair :
  run:(timeout_sec:float -> string list -> Unix.process_status * string * string)
  -> timeout_sec:float
  -> remove_timeout_sec:float
  -> keeper_name:string
  -> (unit, string) result

type volume_repair_run =
  { status : Unix.process_status
  ; stdout : string
  ; stderr : string
  ; cleanup : (unit, string) result
  }

val repair_apple_volume :
  run:(timeout_sec:float -> string list -> Unix.process_status * string * string)
  -> run_helper:(string list -> Unix.process_status * string * string)
  -> on_start:(unit -> unit)
  -> on_cleanup_error:(string -> unit)
  -> timeout_sec:float
  -> remove_timeout_sec:float
  -> keeper_name:string
  -> volume_name:string
  -> image:string
  -> (volume_repair_run, string) result
