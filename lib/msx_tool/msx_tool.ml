type t =
  | Load
  | Eject
  | Save
  | Restore
  | Export_disk
  | Change_disk
  | Screen
  | Meta
  | Checkpoint_info
  | Press
  | Step
  | Step_until_change
  | Peek
  | Ram_diff
[@@deriving enumerate]

let name = function
  | Load -> "masc_msx_load"
  | Eject -> "masc_msx_eject"
  | Save -> "masc_msx_save"
  | Restore -> "masc_msx_restore"
  | Export_disk -> "masc_msx_export_disk"
  | Change_disk -> "masc_msx_change_disk"
  | Screen -> "masc_msx_screen"
  | Meta -> "masc_msx_meta"
  | Checkpoint_info -> "masc_msx_checkpoint_info"
  | Press -> "masc_msx_press"
  | Step -> "masc_msx_step"
  | Step_until_change -> "masc_msx_step_until_change"
  | Peek -> "masc_msx_peek"
  | Ram_diff -> "masc_msx_ram_diff"
;;

let of_name value = List.find_opt (fun tool -> String.equal (name tool) value) all

let reads_only = function
  (* Reads the machine without moving its time. *)
  | Screen -> true
  (* RAM introspection reads memory and moves nothing. *)
  | Peek | Ram_diff -> true
  (* A core digest and a slot's metadata read constants and files; neither
     touches the machine, the ledger or the activity gate. *)
  | Meta | Checkpoint_info -> true
  (* Loading, ejecting, pressing and stepping change the shared machine;
     saving and exporting write a file. *)
  | Load | Eject | Save | Restore | Export_disk | Change_disk | Press | Step
  | Step_until_change ->
    false
;;

let default_checkpoint_slot = "quick"
