let ( let* ) = Result.bind
let field key = function `Assoc fields -> List.assoc_opt key fields | _ -> None
let nonblank = function `String text when String.trim text<>"" -> Ok text
  | _ -> Error "Broadcast recovery identity must be nonblank text"
let selection json =
  match field "instance_id" json,field "row_ids" json with
  | Some instance,Some (`List rows) ->
      let* instance=nonblank instance in
      let* rows=List.fold_right (fun value acc ->
        let* rest=acc in let* value=nonblank value in Ok (value::rest)) rows (Ok []) in
      if rows=[] then Error "Broadcast recovery selection is empty" else
      Ok (`Assoc ["instance_id",`String instance;
        "row_ids",`List (List.sort_uniq String.compare rows |> List.map (fun row -> `String row))])
  | _ -> Error "Broadcast recovery selection is malformed"
let request_identity request = match field "broadcast" request with
  | Some (`Bool true) ->
      let* selected=selection request in
      let* id=match field "request_id" request with Some value -> nonblank value
        | None -> Error "Broadcast request identity is missing" in
      Ok (Some (selected,id))
  | Some (`Bool false) | None -> Ok None
  | Some _ -> Error "Broadcast flag must be boolean"
let decode bytes =
  let apply pending line =
    let* pending=pending in
    let json=Yojson.Safe.from_string line in
    match json with
    | `Assoc fields when let keys=List.sort String.compare (List.map fst fields) in
        keys=["event";"request_id";"scope";"selection"]
        || keys=["credential";"event";"request_id";"scope";"selection"] ->
        let* credential=match List.assoc_opt "credential" fields with
          | None -> Ok None
          | Some value -> Result.map Option.some (nonblank value) in
        let* scope=nonblank (List.assoc "scope" fields) in
        let* id=nonblank (List.assoc "request_id" fields) in
        let* selected=selection (List.assoc "selection" fields) in
        let key=scope,selected in
        (match List.assoc "event" fields with
         | `String "pending" ->
             if List.mem_assoc key pending then Error "Conflicting pending Broadcast journal entry"
             else Ok ((key,(id,credential))::pending)
         | `String "acknowledged" ->
             if List.assoc_opt key pending=Some (id,credential) then Ok (List.remove_assoc key pending)
             else Error "Broadcast acknowledgement does not match pending identity"
         | _ -> Error "Unknown Broadcast recovery journal event")
    | _ -> Error "Malformed Broadcast recovery journal event" in
  if bytes="" then Ok []
  else if bytes.[String.length bytes-1]<>'\n' then Error "Incomplete Broadcast recovery journal"
  else try
    let lines=String.split_on_char '\n' bytes in
    List.fold_left apply (Ok []) (List.take (List.length lines-1) lines)
  with Yojson.Json_error detail -> Error ("Malformed Broadcast recovery journal: " ^ detail)
let event name scope credential selected id = Yojson.Safe.to_string (`Assoc [
  "event",`String name;"scope",`String scope;"credential",`String credential;
  "selection",selected;"request_id",`String id]) ^ "\n"
let transact ~path decide =
  try
    let outcome=Fs_compat.update_private_file_durable_locked_result path (fun bytes ->
      match decode bytes with Error detail -> None,Error detail | Ok pending -> decide pending) in
    match outcome with
    | Fs_compat.Private_file_succeeded result -> result
    | Fs_compat.Private_file_succeeded_with_cleanup_failure {value;cleanup_failure} ->
        let detail=Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure in
        Error (match value with Ok _ -> detail | Error primary -> primary ^ "; " ^ detail)
    | Fs_compat.Private_file_failed error -> Error (Fs_compat.durable_append_error_to_string error)
    | Fs_compat.Private_file_failed_with_cleanup_failure {error;cleanup_failure} ->
        Error (Fs_compat.durable_append_error_to_string error ^ "; " ^
          Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)
  with
  | Sys_error detail -> Error detail
  | Unix.Unix_error (error,call,arg) -> Error (call ^ " " ^ arg ^ ": " ^ Unix.error_message error)
let prepare ~path ~scope ~credential request =
  let* identity=request_identity request in
  match identity with
  | None -> Ok request
  | Some (selected,proposed) ->
      let* id=transact ~path (fun pending -> match List.assoc_opt (scope,selected) pending with
        | Some (id,Some held) when String.equal credential held -> None,Ok id
        | Some _ -> None,Error "Pending Broadcast belongs to another or unverified credential; reconcile the original send before retrying"
        | None -> Some (event "pending" scope credential selected proposed),Ok proposed) in
      (match request with
       | `Assoc fields -> Ok (`Assoc (("request_id",`String id)::List.remove_assoc "request_id" fields))
       | _ -> Error "Broadcast request must be an object")
let acknowledge ~path ~scope ~credential ~request receipt =
  let* identity=request_identity request in
  match identity,field "delivery" receipt with
  | Some (selected,id),Some delivery ->
      (match field "status" delivery,field "request_id" delivery with
       | Some (`String "committed"),Some (`String received) when String.equal received id ->
           (match Option.bind (field "receipt" delivery) (field "fanout_state") with
            | Some (`String ("not_started" | "active")) -> Ok ()
            | Some (`String ("finished" | "durable_admitted")) ->
                transact ~path (fun pending ->
                  if List.assoc_opt (scope,selected) pending=Some (id,Some credential)
                  then Some (event "acknowledged" scope credential selected id),Ok ()
                  else None,Ok ())
            | Some _ | None -> Error "Broadcast receipt has no valid fanout settlement")
       | Some (`String "committed"),_ -> Error "Broadcast receipt identity does not match the pending request"
       | _ -> Ok ())
  | _ -> Ok ()
