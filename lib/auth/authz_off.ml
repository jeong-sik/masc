(* HIGH-RISK-UNREVIEWED: see the interface. *)

module B = Authz_boot_mode
module H = Authz_high_water
module I = Authz_install_record
module Z = Authz_zone

let ( let* ) = Result.bind

type error =
  | Never_activated
  | Already_off
  | Log_unreadable of string
  | Store_absent
  | Store_mismatch of H.reason * H.reason list
  | Store_unreadable of string
  | Zone_not_opened of Z.open_error
  | Mode_moved of Authz_mode_state.t
  | Body_not_built of Authz_body.error
  | Commit_failed of Z.error

let error_to_string = function
  | Never_activated ->
    "the authorization log holds no mode event: the accounts of this base path were never \
     activated"
  | Already_off ->
    "the last mode event of the authorization log is Off: the accounts of this base path are \
     turned off already"
  | Log_unreadable detail -> "the authorization log cannot be read: " ^ detail
  | Store_absent ->
    "the authorization log made Multi_account and the external store holds no answer to it \
     (its install record or its file is gone), so a boot would refuse after an Off"
  | Store_mismatch (first, rest) ->
    "the external store does not match the authorization log, so a boot would refuse after \
     an Off: "
    ^ String.concat "; " (List.map H.reason_to_string (first :: rest))
  | Store_unreadable detail -> "the install record or the external store cannot be read: " ^ detail
  | Zone_not_opened error -> "the authorization zone did not open: " ^ Z.open_error_to_string error
  | Mode_moved mode ->
    "the authorization log is no longer in Multi_account but in "
    ^ Authz_mode_state.to_string mode
    ^ ", although it was a moment before"
  | Body_not_built error -> "the body of the Off was refused: " ^ Authz_body.error_to_string error
  | Commit_failed error -> "the Off was not committed: " ^ Z.error_detail error
;;

(* Design 5.1: the log made Multi_account and the store matches it, whatever
   the config asks. *)
let on_and_matching ~base_path ~config_dir =
  match Authz_boot_mode_read.read_log_and_store ~base_path ~config_dir with
  | B.Log_unreadable detail, (_ : B.high_water) -> Error (Log_unreadable detail)
  | B.No_mode_event, (_ : B.high_water) -> Error Never_activated
  | B.Made_off (_ : Authz_state.t), (_ : B.high_water) -> Error Already_off
  | B.Made_multi_account, B.Judged H.Matches -> Ok ()
  | B.Made_multi_account, B.Judged H.Absent -> Error Store_absent
  | B.Made_multi_account, B.Judged (H.Mismatch (first, rest)) -> Error (Store_mismatch (first, rest))
  | B.Made_multi_account, B.Store_unreadable detail -> Error (Store_unreadable detail)
;;

let store_path ~config_dir ~base_path =
  match I.locate ~config_dir ~base_path with
  | Error error -> Error (Store_unreadable (I.locate_error_to_string error))
  | Ok located ->
    (match I.read located with
     | Error error -> Error (Store_unreadable (I.read_error_to_string error))
     | Ok None -> Error Store_absent
     | Ok (Some store) -> Ok (store : I.Store_path.t :> string))
;;

let turn_off ~base_path ~config_dir ~now_ms =
  let* () = on_and_matching ~base_path ~config_dir in
  let* store_path = store_path ~config_dir ~base_path in
  let* zone =
    Result.map_error
      (fun error -> Zone_not_opened error)
      (Z.open_at_start ~now_ms ~log_path:(Authz_log.path_of_base_path ~base_path) ~store_path)
  in
  let* workspace_id =
    match (Z.snapshot zone).Z.state.Authz_state.mode with
    | Authz_mode_state.Multi_account workspace_id -> Ok workspace_id
    | (Authz_mode_state.Not_bootstrapped | Authz_mode_state.Off _) as mode -> Error (Mode_moved mode)
  in
  let* body =
    Result.map_error
      (fun error -> Body_not_built error)
      (Authz_mode_event.to_body { Authz_mode_event.event = Authz_mode_event.Off; workspace_id })
  in
  let* (_ : Z.committed) =
    Result.map_error
      (fun error -> Commit_failed error)
      (Z.commit
         zone
         { Z.author = Authz_records.Author.Local_operator; kind = Authz_record.Kind.Mode_event; body })
  in
  Ok workspace_id
;;
