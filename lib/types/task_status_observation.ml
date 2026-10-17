open Masc_domain

let to_yojson status =
  match task_status_to_yojson status with
  | `Assoc fields ->
      `Assoc (List.filter (fun (key, _) -> key <> "notes" && key <> "reason") fields)
  | json -> json

let validate status =
  let nonblank value = String.trim value <> "" in
  let clock value = Option.is_some (parse_iso8601_opt value) in
  let valid = match status with
    | Todo -> true
    | Claimed { assignee; claimed_at } -> nonblank assignee && clock claimed_at
    | InProgress { assignee; started_at } -> nonblank assignee && clock started_at
    | AwaitingVerification { assignee; started_at; submitted_at; verification_id } ->
        nonblank assignee && clock started_at && clock submitted_at && nonblank verification_id
    | Done { assignee; completed_at; notes = _ } -> nonblank assignee && clock completed_at
    | Cancelled { cancelled_by; cancelled_at; reason = _ } -> nonblank cancelled_by && clock cancelled_at in
  if valid then Ok () else Error "Task observation has invalid owner, verification identity or lifecycle clock"

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
