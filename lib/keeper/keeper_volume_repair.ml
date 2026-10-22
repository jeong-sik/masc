module Fs = Keeper_volume_filesystem
module Watch = Keeper_volume_filesystem_watch

type outcome =
  | Helper_unavailable of string
  | Backup_present
  | Teardown_refused of string
  | Not_needed
  | Unreadable_before of Fs.read_failure
  | Backup_unavailable of string
  | Helper_refused of string
  | Repaired
  | Repair_incomplete of
      { count : int
      ; first : Fs.error_site option
      ; last : Fs.error_site option
      }
  | Unreadable_after of Fs.read_failure
  | Recreated_at_next_boot

type receipt =
  { repair_id : string
  ; keeper : string
  ; volume : string
  ; kind : Watch.volume_kind
  ; image : string
  ; started_at : float
  ; finished_at : float
  ; before : (Fs.state, Fs.read_failure) result option
  ; backup : string option
  ; helper_status : string option
  ; helper_output : string option
  ; helper_cleanup : string option
  ; outcome : outcome
  }

type helper_finished =
  { status : Unix.process_status
  ; stdout : string
  ; stderr : string
  ; cleanup : (unit, string) result
  }

type helper_run = unit -> (helper_finished, string) result

let schema = "masc.keeper.volume_repair.v1"
let store_dirname = "keeper-volume-repairs"
let backup_suffix = ".pre-repair"
let backup_path ~image = image ^ backup_suffix

let clone_image ~source ~target =
  match Fs_compat.clone_file source target with
  | () -> Ok ()
  | exception Unix.Unix_error (error, _, _) -> Error (Unix.error_message error)
;;

(* Once the helper has run, the superblock decides; the status only tells a
   run that ended early apart from one whose e2fsck could not finish. *)
let outcome_after_helper (run : helper_finished) ~status_label read =
  match run.status, read with
  | (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), Ok Fs.Clean -> Repaired
  | Unix.WEXITED 0, Ok (Fs.Errors_recorded { count; first; last }) ->
    Repair_incomplete { count; first; last }
  | (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), Ok (Fs.Errors_recorded _) ->
    Helper_refused (Printf.sprintf "helper %s: %s" status_label (String.trim run.stderr))
  | (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), Error failure -> Unreadable_after failure
;;

let repair
      ~now
      ~repair_id
      ~helper
      ~backup_exists
      ~teardown
      ~read_image
      ~clone
      ~keeper
      ~(volume : Watch.volume)
      ~image
  =
  let started_at = now () in
  let finish ?before ?backup ?helper_status ?helper_output ?helper_cleanup outcome =
    { repair_id
    ; keeper
    ; volume = volume.name
    ; kind = volume.kind
    ; image
    ; started_at
    ; finished_at = now ()
    ; before
    ; backup
    ; helper_status
    ; helper_output
    ; helper_cleanup
    ; outcome
    }
  in
  match volume.kind with
  | Watch.Build ->
    (match teardown () with
     | Error detail -> finish (Teardown_refused detail)
     | Ok () -> finish Recreated_at_next_boot)
  | Watch.Work ->
    let backup = backup_path ~image in
    (match helper with
     | Error detail -> finish (Helper_unavailable detail)
     | Ok run_helper ->
       if backup_exists ~path:backup
       then finish Backup_present
       else (
         match teardown () with
         | Error detail -> finish (Teardown_refused detail)
         | Ok () ->
           let before = read_image ~path:image in
           (match before with
            | Error failure -> finish ~before (Unreadable_before failure)
            | Ok Fs.Clean -> finish ~before Not_needed
            | Ok (Fs.Errors_recorded _) ->
              (match clone ~source:image ~target:backup with
               | Error detail -> finish ~before (Backup_unavailable detail)
               | Ok () ->
                 (match run_helper () with
                  | Error detail -> finish ~before ~backup (Helper_refused detail)
                  | Ok run ->
                    let helper_status = Keeper_sandbox_exec_failure.status_label run.status in
                    let helper_cleanup = Result.fold ~ok:(fun () -> None) ~error:Option.some run.cleanup in
                    finish
                      ~before
                      ~backup
                      ~helper_status
                      ~helper_output:(String.concat "\n" [ run.stdout; run.stderr ])
                      ?helper_cleanup
                      (outcome_after_helper run ~status_label:helper_status (read_image ~path:image)))))))
;;

let outcome_to_string = function
  | Helper_unavailable detail -> "not repaired: no helper image: " ^ detail
  | Backup_present -> "not repaired: a backup from an earlier repair is still beside the image"
  | Teardown_refused detail -> "not repaired: the Keeper's guests were not removed: " ^ detail
  | Not_needed -> "not needed: with no guest attached the superblock is clean"
  | Unreadable_before failure -> "not repaired: " ^ Fs.read_failure_to_string failure
  | Backup_unavailable detail -> "not repaired: the backup clone failed: " ^ detail
  | Helper_refused detail -> "not repaired: " ^ detail
  | Repaired -> "repaired: the superblock is clean"
  | Repair_incomplete { count; _ } ->
    Printf.sprintf "repair incomplete: the superblock still records %d errors" count
  | Unreadable_after failure -> "repair unconfirmed: " ^ Fs.read_failure_to_string failure
  | Recreated_at_next_boot ->
    "the Keeper's guests were removed; the next boot recreates this build volume"
;;

let read_result_to_yojson = function
  | Ok state -> Fs.state_to_yojson state
  | Error failure ->
    `Assoc [ "state", `String "unreadable"; "detail", `String (Fs.read_failure_to_string failure) ]
;;

let outcome_to_yojson outcome =
  let kind, fields =
    match outcome with
    | Helper_unavailable detail -> "helper_unavailable", [ "detail", `String detail ]
    | Backup_present -> "backup_present", []
    | Teardown_refused detail -> "teardown_refused", [ "detail", `String detail ]
    | Not_needed -> "not_needed", []
    | Unreadable_before failure ->
      "unreadable_before", [ "detail", `String (Fs.read_failure_to_string failure) ]
    | Backup_unavailable detail -> "backup_unavailable", [ "detail", `String detail ]
    | Helper_refused detail -> "helper_refused", [ "detail", `String detail ]
    | Repaired -> "repaired", []
    | Repair_incomplete { count; first; last } ->
      ( "repair_incomplete"
      , [ "filesystem", Fs.state_to_yojson (Fs.Errors_recorded { count; first; last }) ] )
    | Unreadable_after failure ->
      "unreadable_after", [ "detail", `String (Fs.read_failure_to_string failure) ]
    | Recreated_at_next_boot -> "recreated_at_next_boot", []
  in
  `Assoc (("kind", `String kind) :: fields)
;;

let volume_kind_to_string = function
  | Watch.Work -> "work"
  | Watch.Build -> "build"
;;

let receipt_to_yojson receipt =
  `Assoc
    [ "schema", `String schema
    ; "repair_id", `String receipt.repair_id
    ; "keeper", `String receipt.keeper
    ; "volume", `String receipt.volume
    ; "volume_kind", `String (volume_kind_to_string receipt.kind)
    ; "image", `String receipt.image
    ; "started_at", `Float receipt.started_at
    ; "finished_at", `Float receipt.finished_at
    ; "before", Option.fold ~none:`Null ~some:read_result_to_yojson receipt.before
    ; "backup", Json_util.string_opt_to_json receipt.backup
    ; "helper_status", Json_util.string_opt_to_json receipt.helper_status
    ; "helper_output", Json_util.string_opt_to_json receipt.helper_output
    ; "helper_cleanup", Json_util.string_opt_to_json receipt.helper_cleanup
    ; "outcome", outcome_to_yojson receipt.outcome
    ]
;;

let sha256 value = Digestif.SHA256.(digest_string value |> to_hex)

let receipt_path ~masc_dir ~keeper ~repair_id =
  Filename.concat
    (Filename.concat (Filename.concat masc_dir store_dirname) ("keeper-" ^ sha256 keeper))
    (repair_id ^ ".json")
;;

let write_receipt ~masc_dir receipt =
  let path = receipt_path ~masc_dir ~keeper:receipt.keeper ~repair_id:receipt.repair_id in
  match Fs_compat.mkdir_p (Filename.dirname path) with
  | exception Unix.Unix_error (error, _, _) -> Error (Unix.error_message error)
  | exception Sys_error detail -> Error detail
  | () ->
    Result.map
      (fun () -> path)
      (Fs_compat.save_file_atomic path (Yojson.Safe.pretty_to_string (receipt_to_yojson receipt)))
;;
