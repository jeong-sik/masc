(** Read-only inventory of a publication recovery store: the lane residues
    and the entries of the [Active], [Owned] and [Forensic] areas as typed
    rows. Entries of an unexpected kind or name, records that cannot be read
    or decoded, and the failure of one area are kept as rows and do not stop
    the inventory of the others. Nothing is created, changed, or removed.

    This module is private to [fs_compat_internal] and has no interface file.
    [Capability_recovery_obligation] includes it. *)

open Capability_recovery_record
open Capability_recovery_record_codec
open Capability_recovery_store_model
open Capability_recovery_store_layout
open Capability_recovery_record_io

type corrupt_record =
  { area : area
  ; operation_id : operation_id
  ; raw : string
  ; validation_error : validation_error
  }

type inventory_row =
  | Unexpected_lane_entry of
      { name : string
      ; kind : Eio.File.Stat.kind
      }
  | Missing_lane_entry of { name : string }
  | Lane_entry_unavailable of
      { name : string
      ; error : transition_error
      }
  | Area_inventory_unavailable of
      { area : area
      ; error : transition_error
      }
  | Active_record of prepared
  | Owned_record of bound
  | Forensic_record of forensic
  | Invalid_record_name of
      { area : area
      ; name : string
      }
  | Unexpected_record_kind of
      { area : area
      ; operation_id : operation_id
      ; kind : Eio.File.Stat.kind
      }
  | Missing_record_entry of
      { area : area
      ; operation_id : operation_id
      }
  | Record_entry_unavailable of
      { area : area
      ; operation_id : operation_id
      ; error : transition_error
      }
  | Corrupt_record of corrupt_record

type inventory = inventory_row list

let corrupt_if_identity_invalid
      ~store
      ~area
      ~operation_id
      ~raw
      ~record_owner
      ~record_id
      make_row
  =
  match
    validate_record_owner_and_id
      ~owner:store.owner
      ~operation_id
      ~record_owner
      ~record_id
  with
  | Ok () -> make_row ()
  | Error validation_error ->
    Corrupt_record { area; operation_id; raw; validation_error }
;;

let inventory_regular_record ~store ~area ~operation_id =
  let raw, _ =
    read_raw_record
      ~store
      ~area
      ~operation_id
      ~store_effect:No_record_change
  in
  match area with
  | Active ->
    (match decode_prepared raw with
     | Error validation_error ->
       Corrupt_record { area; operation_id; raw; validation_error }
     | Ok prepared ->
       corrupt_if_identity_invalid
         ~store
         ~area
         ~operation_id
         ~raw
         ~record_owner:prepared.owner
         ~record_id:prepared.operation_id
         (fun () -> Active_record prepared))
  | Owned ->
    (match decode_bound raw with
     | Error validation_error ->
       Corrupt_record { area; operation_id; raw; validation_error }
     | Ok bound ->
       corrupt_if_identity_invalid
         ~store
         ~area
         ~operation_id
         ~raw
         ~record_owner:bound.prepared.owner
         ~record_id:bound.prepared.operation_id
         (fun () -> Owned_record bound))
  | Forensic ->
    (match decode_forensic raw with
     | Error validation_error ->
       Corrupt_record { area; operation_id; raw; validation_error }
     | Ok forensic ->
       corrupt_if_identity_invalid
         ~store
         ~area
         ~operation_id
         ~raw
         ~record_owner:(forensic_owner forensic)
         ~record_id:(forensic_operation_id forensic)
         (fun () -> Forensic_record forensic))
;;

let inventory_area ~store area =
  let directory = area_directory store area in
  let subject = Area (area, store.owner) in
  let names =
    raise_io ~operation:Read_directory ~subject (fun () ->
      Eio.Path.read_dir directory)
  in
  List.map
    (fun name ->
       match operation_id_of_string name with
       | Error _ -> Invalid_record_name { area; name }
       | Ok operation_id ->
         (try
            match record_kind ~store ~area ~operation_id with
            | `Not_found -> Missing_record_entry { area; operation_id }
            | `Regular_file ->
              inventory_regular_record ~store ~area ~operation_id
            | ( ( `Unknown
                | `Fifo
                | `Character_special
                | `Directory
                | `Block_device
                | `Symbolic_link
                | `Socket ) as
                kind ) ->
              Unexpected_record_kind { area; operation_id; kind }
          with
          | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
          | Transition_failed error ->
            Record_entry_unavailable { area; operation_id; error }
          | Store_failure failure ->
            Record_entry_unavailable
              { area
              ; operation_id
              ; error = transition_error ~store_effect:No_record_change failure
              }))
    names
;;

let inventory_row_of_lane_residue = function
  | Lane_residue_present { name; kind } ->
    Unexpected_lane_entry { name; kind }
  | Lane_residue_missing { name } -> Missing_lane_entry { name }
  | Lane_residue_unavailable { name; error } ->
    Lane_entry_unavailable { name; error }
;;

let inventory_area_rows ~store area =
  try inventory_area ~store area with
  | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
  | Transition_failed error -> [ Area_inventory_unavailable { area; error } ]
  | Store_failure failure ->
    [ Area_inventory_unavailable
        { area
        ; error = transition_error ~store_effect:No_record_change failure
        }
    ]
;;

let inventory store =
  protect_result ~store_effect:No_record_change (fun () ->
    List.map inventory_row_of_lane_residue store.lane_residues
    @ inventory_area_rows ~store Active
    @ inventory_area_rows ~store Owned
    @ inventory_area_rows ~store Forensic)
;;
