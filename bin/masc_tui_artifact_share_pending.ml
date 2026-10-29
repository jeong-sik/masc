module Share = Masc.Published_artifact_share
type entry = {
  base_path : string; masc_root : string; artifact_id : string;
  request : Share.request;
}
type cursor = { device : int; inode : int; content : string }
let same_cursor a b = a.device = b.device && a.inode = b.inode && String.equal a.content b.content
type preparation = Prepared | Already_pending of entry | Not_prepared of string
  | Already_pending_with_storage_failure of entry * string
type prepare_stage = Before_decision | Append_requested | Existing of entry
open Result.Syntax

let journal_path ~masc_root = Filename.concat masc_root "tui-artifact-share-pending.jsonl"

let same_resource a b =
  a.base_path = b.base_path && a.masc_root = b.masc_root && a.artifact_id = b.artifact_id

(* Session witnesses survive a missing or replaced journal. Only an exact
   verified operation receipt can retire a witnessed tuple. *)
let witness entry entries = if List.mem entry entries then entries else entry :: entries
let resolve entry entries = List.filter ((<>) entry) entries
let for_resource entry entries = List.filter (same_resource entry) entries

let valid entry =
  let request = entry.request in
  not (Filename.is_relative entry.base_path) && not (Filename.is_relative entry.masc_root)
  && Masc.Published_artifact.valid_id entry.artifact_id
  && Share.valid_operation_id request.operation_id
  && Share.valid_version request.expected_version
  && request.expected_artifact_revision > 0
  && Share.valid_version request.expected_artifact_revision
  && Share.valid_sha256 request.expected_artifact_sha256

let decode_entry fields =
  match List.assoc_opt "base_path" fields, List.assoc_opt "masc_root" fields,
        List.assoc_opt "artifact_id" fields, List.assoc_opt "operation_id" fields,
        List.assoc_opt "expected_version" fields, List.assoc_opt "requested" fields,
        List.assoc_opt "expected_artifact_revision" fields,
        List.assoc_opt "expected_artifact_sha256" fields with
  | Some (`String base_path), Some (`String masc_root), Some (`String artifact_id),
    Some (`String operation_id), Some (`Int expected_version), Some (`Bool requested),
    Some (`Int expected_artifact_revision), Some (`String expected_artifact_sha256) ->
      let request : Share.request = { operation_id; expected_version; requested;
        expected_artifact_revision; expected_artifact_sha256 } in
      let entry = {base_path; masc_root; artifact_id; request} in
      if valid entry then Ok entry else Error "Invalid artifact-share recovery fields"
  | _ -> Error "Invalid artifact-share recovery fields"

let decode bytes =
  if bytes = "" then Ok []
  else if bytes.[String.length bytes - 1] <> '\n' then Error "Incomplete artifact-share recovery journal"
  else
    let apply result line =
      let* pending = result in
      match Yojson.Safe.from_string line with
      | `Assoc fields when List.sort String.compare (List.map fst fields) =
          ["artifact_id"; "base_path"; "event"; "expected_artifact_revision";
           "expected_artifact_sha256"; "expected_version"; "masc_root"; "operation_id"; "requested"] ->
        let* entry = decode_entry fields in
        (match List.assoc_opt "event" fields with
         | Some (`String "pending") when not (List.exists (same_resource entry) pending) -> Ok (entry :: pending)
         | Some (`String "settled") when List.mem entry pending -> Ok (List.filter ((<>) entry) pending)
         | _ -> Error "Conflicting artifact-share recovery event")
      | _ -> Error "Malformed artifact-share recovery event" in
    try
      let lines = String.split_on_char '\n' bytes in
      List.fold_left apply (Ok []) (List.take (List.length lines - 1) lines)
    with Yojson.Json_error detail -> Error ("Malformed artifact-share recovery journal: " ^ detail)

let event event entry =
  let request = entry.request in
  Yojson.Safe.to_string (`Assoc ["event", `String event;
    "base_path", `String entry.base_path; "masc_root", `String entry.masc_root;
    "artifact_id", `String entry.artifact_id; "operation_id", `String request.operation_id;
    "expected_version", `Int request.expected_version; "requested", `Bool request.requested;
    "expected_artifact_revision", `Int request.expected_artifact_revision;
    "expected_artifact_sha256", `String request.expected_artifact_sha256]) ^ "\n"

let transact ?(on_observed = fun _ -> ()) ~path decide =
  try
    match Fs_compat.recover_and_update_private_jsonl_durable_locked_result
      ~locking:Fs_compat.Try_lock
      ~validate_prefix:(fun bytes -> match decode bytes with
        | Ok pending -> on_observed pending; Fs_compat.Recovery_authorized
        | Error detail -> Fs_compat.Recovery_refused (Error detail)) path (fun bytes ->
      match decode bytes with
      | Error detail -> None, Error detail
      | Ok pending -> on_observed pending; decide bytes pending) with
    | Fs_compat.Private_file_succeeded result -> result
    | Fs_compat.Private_file_succeeded_with_cleanup_failure {value; cleanup_failure} ->
      let detail = Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure in
      Error (match value with Ok _ -> detail | Error primary -> primary ^ "; " ^ detail)
    | Fs_compat.Private_file_failed error -> Error (Fs_compat.durable_append_error_to_string error)
    | Fs_compat.Private_file_failed_with_cleanup_failure {error; cleanup_failure} ->
      Error (Fs_compat.durable_append_error_to_string error ^ "; " ^
        Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)
  with
  | Sys_error detail -> Error detail
  | Unix.Unix_error (error, call, arg) -> Error (call ^ " " ^ arg ^ ": " ^ Unix.error_message error)

let observe ?on_observed ~path () = transact ?on_observed ~path (fun bytes pending ->
  (* This callback runs between the transaction's open-path binding checks. *)
  let stats = Unix.lstat path in
  None, Ok ({device=stats.st_dev; inode=stats.st_ino; content=bytes}, pending))
let read ?on_observed ~path () = Result.map snd (observe ?on_observed ~path ())
let confirm ?(on_observed = fun _ -> ()) ~path entry =
  let* _ = read ~on_observed ~path () in
  try
    match Fs_compat.reconcile_private_file_durable_locked_result ~locking:Fs_compat.Try_lock path (fun bytes ->
      match decode bytes with
      | Error detail -> Fs_compat.Refuse_update (Error detail)
      | Ok pending ->
        on_observed pending;
        if List.mem entry pending then Fs_compat.Confirm_existing (Ok true)
        else Fs_compat.Refuse_update (Ok false)) with
    | Fs_compat.Private_file_succeeded result -> result
    | Fs_compat.Private_file_succeeded_with_cleanup_failure {value; cleanup_failure} ->
      let detail = Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure in
      Error (match value with Ok _ -> detail | Error primary -> primary ^ "; " ^ detail)
    | Fs_compat.Private_file_failed error -> Error (Fs_compat.durable_append_error_to_string error)
    | Fs_compat.Private_file_failed_with_cleanup_failure {error; cleanup_failure} ->
      Error (Fs_compat.durable_append_error_to_string error ^ "; " ^
        Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)
  with
  | Sys_error detail -> Error detail
  | Unix.Unix_error (error, call, arg) -> Error (call ^ " " ^ arg ^ ": " ^ Unix.error_message error)
let prepare_checked ?on_observed ~path entry =
  if not (valid entry) then Ok (Not_prepared "Invalid artifact-share recovery fields")
  else
    let stage = Atomic.make Before_decision in
    let result = transact ?on_observed ~path (fun _ pending ->
      match List.find_opt (same_resource entry) pending with
      | Some existing -> Atomic.set stage (Existing existing); None, Ok (Already_pending existing)
      | None -> Atomic.set stage Append_requested; Some (event "pending" entry), Ok Prepared) in
    match result with
    | Ok _ -> result
    | Error detail ->
      (match Atomic.get stage with
       | Before_decision -> Ok (Not_prepared detail)
       | Existing existing -> Ok (Already_pending_with_storage_failure (existing, detail))
       | Append_requested -> Error detail)

let prepare ?on_observed ~path entry =
  let* result = prepare_checked ?on_observed ~path entry in
  match result with
  | Prepared -> Ok ()
  | Not_prepared detail -> Error detail
  | Already_pending _ -> Error "A share operation for this artifact is unresolved; recover it before another change."
  | Already_pending_with_storage_failure (_, detail) ->
    Error ("A share operation is unresolved and journal storage failed: " ^ detail)
let restore ?on_observed ~path entry =
  let* confirmed = confirm ?on_observed ~path entry in
  if confirmed then Ok () else prepare ?on_observed ~path entry

let settle ?on_observed ~path entry = transact ?on_observed ~path (fun _ pending ->
  if List.mem entry pending then Some (event "settled" entry), Ok true else None, Ok false)
