type kind = Issue_invite of string | Revoke_invite of string
type entry = { id : string; base_path : string; masc_root : string; kind : kind }

let ( let* ) = Result.bind
let same_origin a b = a.base_path = b.base_path && a.masc_root = b.masc_root
let decode_entry fields =
  let text key = match List.assoc_opt key fields with
    | Some (`String value) when String.trim value <> "" -> Ok value
    | _ -> Error ("Invalid Play recovery " ^ key) in
  let* id = text "request_id" in
  let* base_path = text "base_path" in
  let* masc_root = text "masc_root" in
  let* name = text "name" in
  let* kind = match List.assoc_opt "action" fields with
    | Some (`String "issue") -> Ok (Issue_invite name)
    | Some (`String "revoke") -> Ok (Revoke_invite name)
    | _ -> Error "Invalid Play recovery action" in
  Ok {id; base_path; masc_root; kind}

let decode bytes =
  if bytes = "" then Ok []
  else if bytes.[String.length bytes - 1] <> '\n' then Error "Incomplete Play recovery journal"
  else
    let apply result line =
      let* pending = result in
      match Yojson.Safe.from_string line with
      | `Assoc fields when List.sort String.compare (List.map fst fields)
          = ["action"; "base_path"; "event"; "masc_root"; "name"; "request_id"] ->
          let* entry = decode_entry fields in
          (match List.assoc_opt "event" fields with
           | Some (`String "pending") when not (List.exists (same_origin entry) pending) ->
               Ok (entry :: pending)
           | Some (`String "settled") when List.exists ((=) entry) pending ->
               Ok (List.filter (fun held -> held <> entry) pending)
           | _ -> Error "Conflicting Play recovery event")
      | _ -> Error "Malformed Play recovery event" in
    try
      let lines = String.split_on_char '\n' bytes in
      List.fold_left apply (Ok []) (List.take (List.length lines - 1) lines)
    with Yojson.Json_error detail -> Error ("Malformed Play recovery journal: " ^ detail)

let event name entry =
  let action, invite = match entry.kind with
    | Issue_invite invite -> "issue", invite
    | Revoke_invite invite -> "revoke", invite in
  Yojson.Safe.to_string (`Assoc ["event", `String name; "request_id", `String entry.id;
    "base_path", `String entry.base_path; "masc_root", `String entry.masc_root;
    "action", `String action; "name", `String invite]) ^ "\n"

let transact ~path decide =
  try
    match Fs_compat.update_private_file_durable_locked_result path (fun bytes ->
      match decode bytes with Error detail -> None, Error detail | Ok pending -> decide pending) with
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

let read ~path = transact ~path (fun pending -> None, Ok pending)
let prepare ~path entry = transact ~path (fun pending ->
  if List.exists (same_origin entry) pending then
    None, Error "An invite change for this workspace is already recorded; reconcile it before another change."
  else Some (event "pending" entry), Ok ())
let settle ~path entry = transact ~path (fun pending ->
  if List.exists ((=) entry) pending then Some (event "settled" entry), Ok true
  else None, Ok false)
