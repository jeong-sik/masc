open Masc_domain

let to_yojson status =
  match task_status_to_yojson status with
  | `Assoc fields ->
      `Assoc (List.filter (fun (key, _) -> key <> "notes" && key <> "reason") fields)
  | json -> json

(* Lifecycle clocks are already RFC 3339 here: [task_status_of_yojson] rejects
   any other value for every status. *)
let validate status =
  let nonblank value = String.trim value <> "" in
  let valid = match status with
    | Todo -> true
    | Claimed { assignee; claimed_at = _ } -> nonblank assignee
    | InProgress { assignee; started_at = _ } -> nonblank assignee
    | AwaitingVerification { assignee; started_at = _; submitted_at = _; verification_id } ->
        nonblank assignee && nonblank verification_id
    | Done { assignee; completed_at = _; notes = _ } -> nonblank assignee
    | Cancelled { cancelled_by; cancelled_at = _; reason = _ } -> nonblank cancelled_by in
  if valid then Ok () else Error "Task observation has invalid owner or verification identity"

let of_yojson json =
  let ( let* ) = Result.bind in
  let* status = task_status_of_yojson json in
  let metadata = to_yojson status in
  let* () = match json, metadata with
    | `Assoc fields, `Assoc expected ->
        List.fold_left (fun checked (key, value) ->
          let* () = checked in
          match List.filter (fun (name, _) -> name = key) fields with
          | [_, actual] when actual = value -> Ok ()
          | _ -> Error ("Task observation field is missing, invalid or duplicated: " ^ key))
          (Ok ()) expected
    | _ -> Error "Task observation must be an object" in
  let* () = validate status in
  (* Decode only metadata, so free text supplied by a peer is never retained. *)
  task_status_of_yojson metadata
