let ( let* ) = Result.bind

type verdict =
  | Approve
  | Reject of string

let verdict_constructor_name = function
  | Approve -> "APPROVE"
  | Reject _ -> "REJECT"
;;

let duplicate_key fields =
  let rec loop seen = function
    | [] -> None
    | (name, _) :: rest ->
      if List.mem name seen then Some name else loop (name :: seen) rest
  in
  loop [] fields
;;

let rec canonical_json = function
  | `Assoc fields ->
    (match duplicate_key fields with
     | Some name -> Error (Printf.sprintf "duplicate JSON object key %S" name)
     | None ->
       let rec collect acc = function
         | [] -> Ok (`Assoc (List.sort (fun (a, _) (b, _) -> String.compare a b) acc))
         | (name, value) :: rest ->
           let* value = canonical_json value in
           collect ((name, value) :: acc) rest
       in
       collect [] fields)
  | `List values ->
    let rec collect acc = function
      | [] -> Ok (`List (List.rev acc))
      | value :: rest ->
        let* value = canonical_json value in
        collect (value :: acc) rest
    in
    collect [] values
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _) as scalar ->
    Ok scalar
;;

let canonical_string json =
  let* canonical = canonical_json json in
  Ok (Yojson.Safe.to_string canonical)
;;

let canonical_sha256 json =
  let* canonical = canonical_string json in
  Ok (Digestif.SHA256.digest_string canonical |> Digestif.SHA256.to_hex)
;;

let sha256_exn json =
  match canonical_sha256 json with
  | Ok digest -> digest
  | Error message -> invalid_arg ("Goal completion canonical JSON: " ^ message)
;;

let string_list_json values =
  `List (List.map (fun value -> `String value) values)
;;

let review_evidence_sha256
      ~workspace_identity
      ~goal_json
      ~completion_claim
      ~requesting_agent
      ~linked_tasks_json
      ~linked_task_ids
      ~child_goals_json
  =
  sha256_exn
    (`Assoc
       [ "workspace_identity", `String workspace_identity
       ; "goal", goal_json
       ; "completion_claim", `String completion_claim
       ; "requesting_agent", `String requesting_agent
       ; "linked_tasks", linked_tasks_json
       ; "linked_task_ids", string_list_json linked_task_ids
       ; "child_goals", child_goals_json
       ])
;;

let completion_digest
      ~workspace_identity
      ~goal_json
      ~reviewed_goal_updated_at
      ~goal_id
      ~expected_version
      ~operation_id
      ~evaluator_runtime
      ~reviewed_at
      ~review_prompt_sha256
      ~review_evidence_sha256
      ~completion_claim
      ~requesting_agent
      ~linked_task_ids
  =
  sha256_exn
    (`Assoc
       [ "workspace_identity", `String workspace_identity
       ; "goal", goal_json
       ; "reviewed_goal_updated_at", `String reviewed_goal_updated_at
       ; "goal_id", `String goal_id
       ; "expected_state_version", `Int expected_version
       ; "committed_state_version", `Int (expected_version + 1)
       ; "operation_id", `String operation_id
       ; "evaluator_runtime", `String evaluator_runtime
       ; "reviewed_at", `String reviewed_at
       ; "review_prompt_sha256", `String review_prompt_sha256
       ; "review_evidence_sha256", `String review_evidence_sha256
       ; "completion_claim", `String completion_claim
       ; "requesting_agent", `String requesting_agent
       ; "linked_task_ids", string_list_json linked_task_ids
       ])
;;

let parse_verdict_from_json = function
  | `Assoc fields ->
    (match duplicate_key fields with
     | Some name -> Error (Printf.sprintf "duplicate verdict field %S" name)
     | None ->
       let unexpected =
         List.find_opt
           (fun (name, _) -> not (String.equal name "verdict" || String.equal name "reason"))
           fields
       in
       (match unexpected with
        | Some (name, _) ->
          Error (Printf.sprintf "unexpected Goal completion verdict field: %s" name)
        | None ->
          let verdicts = List.filter_map (fun (name, value) -> if String.equal name "verdict" then Some value else None) fields in
          let reasons = List.filter_map (fun (name, value) -> if String.equal name "reason" then Some value else None) fields in
          (match verdicts, reasons with
           | [ `String "APPROVE" ], [] -> Ok Approve
           | [ `String "APPROVE" ], _ -> Error "reason must be omitted for APPROVE"
           | [ `String "REJECT" ], [ `String reason ] when String.trim reason <> "" ->
             Ok (Reject reason)
           | [ `String "REJECT" ], _ ->
             Error "reason is required exactly once and must be non-empty for REJECT"
           | [ `String value ], _ ->
             Error (Printf.sprintf "unexpected Goal completion verdict value: %s" value)
           | [ _ ], _ -> Error "verdict must be a string"
           | [], _ -> Error "verdict is required exactly once"
           | _ -> Error "verdict is required exactly once")))
  | _ -> Error "Goal completion verdict arguments must be an object"
;;

module For_testing = struct
  let completion_digest = completion_digest
  let review_evidence_sha256 = review_evidence_sha256
end
