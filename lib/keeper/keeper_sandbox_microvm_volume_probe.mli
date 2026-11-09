(** Whether a keeper's volume exists, and making it exist: the listing of
    each runtime and how its answer is read, the outcome of a volume probe, the
    ensure functions that create a missing work or build volume, the build
    volume's name and mount, and the removal of a keeper's Apple volumes.

    [Keeper_sandbox_microvm] includes this module. *)

val volume_names_of_json : Yojson.Safe.t -> (string list, string) result

val apple_volume_list_argv : unit -> string list

type volume_probe_outcome =
  | Volume_present
  | Volume_absent
  | Volume_probe_failed of string

val classify_volume_probe :
  volume_name:string ->
  inspect:Unix.process_status * string * string ->
  listing:(Unix.process_status * string * string) option ->
  volume_probe_outcome

val apple_volume_probe :
  volume_name:string -> timeout_sec:float -> volume_probe_outcome

(** Which of a keeper's two Apple volumes a call is about. The probe and the
    create are the same [container volume] commands for both; only the error
    code a failure is reported under differs. *)
type apple_volume_role =
  | Work_volume
  | Build_volume

val apple_volume_error_code : apple_volume_role -> string

val ensure_apple_volume :
  apple_volume_role ->
  volume_name:string ->
  size:string ->
  timeout_sec:float -> ([> `Already_present | `Created ], string) result

val ensure_work_volume_for :
  Keeper_microvm_backend.t ->
  volume_name:string ->
  size:string ->
  timeout_sec:float ->
  ([> `Already_present | `Created | `Ensured ], string) result

val build_volume_name : keeper_name:string -> (string, string) result

val build_volume_mount_args : volume_name:string -> string list

val apple_volume_delete_argv : volume_name:string -> string list

val remove_apple_keeper_volumes :
  run:(timeout_sec:float -> string list -> Unix.process_status * string * string)
  -> timeout_sec:float
  -> keeper_name:string
  -> (unit, string) result
