(* Goal store -- current-schema shared planning state. Invalid persisted input
   never becomes an empty Goal set and no retired shape is recognized. *)

let ( let* ) = Result.bind

module Phase = struct
  type view =
    | Executing
    | Blocked
    | Paused
    | Completed
    | Dropped

  type nonterminal =
    | N_executing
    | N_blocked
    | N_paused
    | N_dropped

  type t = view

  let view phase = phase

  let view_to_string = function
    | Executing -> "executing"
    | Blocked -> "blocked"
    | Paused -> "paused"
    | Completed -> "completed"
    | Dropped -> "dropped"
  ;;

  let to_string = view_to_string

  let view_of_string = function
    | "executing" -> Some Executing
    | "blocked" -> Some Blocked
    | "paused" -> Some Paused
    | "completed" -> Some Completed
    | "dropped" -> Some Dropped
    | _ -> None
  ;;

  let parse_view value =
    String.trim value |> String.lowercase_ascii |> view_of_string
  ;;

  let view_to_yojson view = `String (view_to_string view)

  let view_of_yojson = function
    | `String raw ->
      (match parse_view raw with
       | Some view -> Ok view
       | None -> Error ("goal_phase_of_yojson: " ^ raw))
    | json ->
      Error ("goal_phase_of_yojson: " ^ Yojson.Safe.to_string json)
  ;;

  let all_views = [ Executing; Blocked; Paused; Completed; Dropped ]
  let executing = Executing
  let blocked = Blocked
  let paused = Paused
  let dropped = Dropped
  let completed = Completed

  let of_nonterminal = function
    | N_executing -> Executing
    | N_blocked -> Blocked
    | N_paused -> Paused
    | N_dropped -> Dropped
  ;;

  let nonterminal_to_view = function
    | N_executing -> Executing
    | N_blocked -> Blocked
    | N_paused -> Paused
    | N_dropped -> Dropped
  ;;

  let of_view = function
    | Executing -> Executing
    | Blocked -> Blocked
    | Paused -> Paused
    | Completed -> Completed
    | Dropped -> Dropped
  ;;

  let is_executing phase = view phase = Executing
  let is_blocked phase = view phase = Blocked
  let is_paused phase = view phase = Paused
  let is_completed phase = view phase = Completed
  let is_dropped phase = view phase = Dropped

  let admits_self_directed_progress phase =
    match view phase with
    | Executing -> true
    | Blocked | Paused | Completed | Dropped -> false
  ;;

  type action =
    | Request_complete
    | Pause
    | Resume
    | Block
    | Unblock
    | Drop
    | Reopen

  let action_to_string = function
    | Request_complete -> "request_complete"
    | Pause -> "pause"
    | Resume -> "resume"
    | Block -> "block"
    | Unblock -> "unblock"
    | Drop -> "drop"
    | Reopen -> "reopen"
  ;;

  let all_actions =
    [ Request_complete; Pause; Resume; Block; Unblock; Drop; Reopen ]
  ;;

  let action_of_string = function
    | "request_complete" -> Some Request_complete
    | "pause" -> Some Pause
    | "resume" -> Some Resume
    | "block" -> Some Block
    | "unblock" -> Some Unblock
    | "drop" -> Some Drop
    | "reopen" -> Some Reopen
    | _ -> None
  ;;

  let parse_action value =
    String.trim value |> String.lowercase_ascii |> action_of_string
  ;;

  type transition_outcome =
    | Move_to of nonterminal
    | Complete

  let decide_transition ~phase ~(action : action) =
    match view phase, action with
    | Executing, Request_complete -> Ok Complete
    | Executing, Pause -> Ok (Move_to N_paused)
    | Executing, Block -> Ok (Move_to N_blocked)
    | Executing, Drop -> Ok (Move_to N_dropped)
    | Paused, Resume -> Ok (Move_to N_executing)
    | Paused, Drop -> Ok (Move_to N_dropped)
    | Blocked, Unblock -> Ok (Move_to N_executing)
    | Blocked, Drop -> Ok (Move_to N_dropped)
    | Completed, Reopen -> Ok (Move_to N_executing)
    | Completed, Drop -> Ok (Move_to N_dropped)
    | Dropped, Reopen -> Ok (Move_to N_executing)
    | current, _ ->
      Error
        (Printf.sprintf
           "invalid goal transition: %s -> %s"
           (view_to_string current)
           (action_to_string action))
  ;;
end

(* RFC-0294: the workspace-goal [horizon] (short/mid/long) and its dead
   refresh/snapshot scheduler ([refresh_mode], [snapshot_mode], and their
   yojson codecs) were removed. The cadence had no live caller; the only
   surviving horizon consumer (dashboard stagnation threshold) was re-based
   onto a single policy constant. *)

let clamp_priority p =
  max 1 (min 5 p)

type completion_receipt =
  { workspace_identity : string
  ; expected_state_version : int
  ; operation_id : string
  ; completion_digest : string
  ; review_evidence_sha256 : string
  ; evaluator_runtime : string
  ; reviewed_at : string
  ; reviewed_goal_updated_at : string
  ; review_prompt_sha256 : string
  ; completion_claim : string
  ; requesting_agent : string
  ; linked_task_ids : string list
  }

type completion_review_failure =
  | Rejected
  | Evaluator_unavailable
  | Review_snapshot_changed
  | Current_evidence_unavailable
  | Completion_persistence_failed

let completion_review_failure_to_string = function
  | Rejected -> "rejected"
  | Evaluator_unavailable -> "evaluator_unavailable"
  | Review_snapshot_changed -> "snapshot_changed"
  | Current_evidence_unavailable -> "evidence_unavailable"
  | Completion_persistence_failed -> "persistence_failed"
;;

let completion_review_failure_of_string = function
  | "rejected" -> Some Rejected
  | "evaluator_unavailable" -> Some Evaluator_unavailable
  | "snapshot_changed" -> Some Review_snapshot_changed
  | "evidence_unavailable" -> Some Current_evidence_unavailable
  | "persistence_failed" -> Some Completion_persistence_failed
  | _ -> None
;;

type goal = {
  id : string;
  title : string;
  metric : string option;
  target_value : string option;
  due_date : string option;
  priority : int;
  phase : Phase.t;
  parent_goal_id : string option;
  last_review_note : string option;
  last_review_at : string option;
  completion_review_failure : completion_review_failure option;
  completion_receipt : completion_receipt option;
  created_at : string;
  updated_at : string;
}

let validate_completion_invariant goal =
  match Phase.view goal.phase, goal.completion_receipt, goal.completion_review_failure with
  | Phase.Completed, None, _ ->
    Error
      "completed Goal requires a configured semantic-review completion receipt"
  | (Phase.Executing | Phase.Blocked | Phase.Paused | Phase.Dropped),
    Some _,
    _ ->
    Error "non-completed Goal cannot retain a completion receipt"
  | Phase.Completed, Some _, Some _ ->
    Error "completed Goal cannot retain a failed completion-review outcome"
  | _, _, Some _ when Option.is_none goal.last_review_note ->
    Error "failed completion-review outcome requires a durable review note"
  | Phase.Completed, Some _, None
  | (Phase.Executing | Phase.Blocked | Phase.Paused | Phase.Dropped),
    None,
    _ ->
    Ok ()
;;

let generic_completion_error =
  "generic Goal mutation cannot persist Completed; use the operation-bound \
   semantic-review completion authority"
;;

let validate_generic_goal_mutation ~before after =
  if Phase.is_completed before.phase || Phase.is_completed after.phase
  then Error generic_completion_error
  else validate_completion_invariant after
;;

type state = {
  version : int;
  updated_at : string;
  goals : goal list;
}

exception Current_state_invalid of string

let current_state_invalid_message =
  "Goal store current state is invalid; reset the pre-1.0 runtime state"
;;

let raise_current_state_invalid () =
  raise (Current_state_invalid current_state_invalid_message)
;;

let rec state_to_yojson (state : state) =
  `Assoc
    [
      ("version", `Int state.version);
      ("updated_at", `String state.updated_at);
      ("goals", `List (List.map (fun goal -> goal_to_yojson goal) state.goals));
    ]

and goal_to_yojson (goal : goal) =
  `Assoc
    [
      ("id", `String goal.id);
      ("title", `String goal.title);
      ("metric", Json_util.string_opt_to_json goal.metric);
      ("target_value", Json_util.string_opt_to_json goal.target_value);
      ("due_date", Json_util.string_opt_to_json goal.due_date);
      ("priority", `Int goal.priority);
      ("phase", Phase.view_to_yojson (Phase.view goal.phase));
      ("parent_goal_id", Json_util.string_opt_to_json goal.parent_goal_id);
      ("last_review_note", Json_util.string_opt_to_json goal.last_review_note);
      ("last_review_at", Json_util.string_opt_to_json goal.last_review_at);
      ( "completion_review_failure"
      , match goal.completion_review_failure with
        | None -> `Null
        | Some failure ->
          `String (completion_review_failure_to_string failure) );
      ( "completion_receipt"
      , match goal.completion_receipt with
        | None -> `Null
        | Some receipt -> completion_receipt_to_yojson receipt );
      ("created_at", `String goal.created_at);
      ("updated_at", `String goal.updated_at);
    ]

and completion_receipt_to_yojson receipt =
  `Assoc
    [ "workspace_identity", `String receipt.workspace_identity
    ; "expected_state_version", `Int receipt.expected_state_version
    ; "operation_id", `String receipt.operation_id
    ; "completion_digest", `String receipt.completion_digest
    ; "review_evidence_sha256", `String receipt.review_evidence_sha256
    ; "evaluator_runtime", `String receipt.evaluator_runtime
    ; "reviewed_at", `String receipt.reviewed_at
    ; "reviewed_goal_updated_at", `String receipt.reviewed_goal_updated_at
    ; "review_prompt_sha256", `String receipt.review_prompt_sha256
    ; "completion_claim", `String receipt.completion_claim
    ; "requesting_agent", `String receipt.requesting_agent
    ; ( "linked_task_ids"
      , `List (List.map (fun task_id -> `String task_id) receipt.linked_task_ids) )
    ]

and completion_receipt_of_yojson = function
  | `Assoc fields as json ->
    let accepted_fields =
      [ "workspace_identity"
      ; "expected_state_version"
      ; "operation_id"
      ; "completion_digest"
      ; "review_evidence_sha256"
      ; "evaluator_runtime"
      ; "reviewed_at"
      ; "reviewed_goal_updated_at"
      ; "review_prompt_sha256"
      ; "completion_claim"
      ; "requesting_agent"
      ; "linked_task_ids"
      ]
    in
    (match
       List.find_map
         (fun (field, _) ->
            if List.mem field accepted_fields then None else Some field)
         fields
     with
     | Some field ->
       Error
         (Printf.sprintf
            "completion_receipt_of_yojson: unknown field %S"
            field)
     | None ->
       (match
          ( Json_util.assoc_member_opt "workspace_identity" json
          , Json_util.assoc_member_opt "expected_state_version" json
          , Json_util.assoc_member_opt "operation_id" json
          , Json_util.assoc_member_opt "completion_digest" json
          , Json_util.assoc_member_opt "review_evidence_sha256" json
          , Json_util.assoc_member_opt "evaluator_runtime" json
          , Json_util.assoc_member_opt "reviewed_at" json
          , Json_util.assoc_member_opt "reviewed_goal_updated_at" json
          , Json_util.assoc_member_opt "review_prompt_sha256" json
          , Json_util.assoc_member_opt "completion_claim" json
          , Json_util.assoc_member_opt "requesting_agent" json
          , Json_util.assoc_member_opt "linked_task_ids" json )
        with
        | ( Some (`String workspace_identity)
          , Some (`Int expected_state_version)
          , Some (`String operation_id)
          , Some (`String completion_digest)
          , Some (`String review_evidence_sha256)
          , Some (`String evaluator_runtime)
          , Some (`String reviewed_at)
          , Some (`String reviewed_goal_updated_at)
          , Some (`String review_prompt_sha256)
          , Some (`String completion_claim)
          , Some (`String requesting_agent)
          , Some (`List linked_task_ids_json) ) ->
          let rec parse_task_ids acc = function
            | [] -> Ok (List.rev acc)
            | `String task_id :: rest -> parse_task_ids (task_id :: acc) rest
            | _ :: _ ->
              Error
                "completion_receipt_of_yojson: linked_task_ids must contain \
                 only strings"
          in
          Result.map
            (fun linked_task_ids ->
               { workspace_identity
               ; expected_state_version
               ; operation_id
               ; completion_digest
               ; review_evidence_sha256
               ; evaluator_runtime
               ; reviewed_at
               ; reviewed_goal_updated_at
               ; review_prompt_sha256
               ; completion_claim
               ; requesting_agent
               ; linked_task_ids
               })
            (parse_task_ids [] linked_task_ids_json)
        | _ -> Error "completion_receipt_of_yojson: invalid receipt"))
  | _ -> Error "completion_receipt_of_yojson: expected object"

and state_of_yojson = function
  | `Assoc fields as json ->
      let accepted_fields = [ "version"; "updated_at"; "goals" ] in
      let unknown_field =
        List.find_map
          (fun (field, _) ->
             if List.mem field accepted_fields then None else Some field)
          fields
      in
      begin
        match
          ( unknown_field
          , Json_util.assoc_member_opt "version" json
          , Json_util.assoc_member_opt "updated_at" json
          , Json_util.assoc_member_opt "goals" json )
        with
        | None, Some (`Int version), Some (`String updated_at), Some (`List goals_json) ->
            let rec collect acc = function
              | [] -> Ok (List.rev acc)
              | row :: rest -> (
                  match goal_of_yojson row with
                  | Ok goal -> collect (goal :: acc) rest
                  | Error msg -> Error msg)
            in
            Result.map
              (fun goals -> { version; updated_at; goals })
              (collect [] goals_json)
        | Some field, _, _, _ ->
          Error
            (Printf.sprintf
               "state_of_yojson: unknown current-state field %S"
               field)
        | _ -> Error "state_of_yojson: invalid current state"
      end
  | json ->
      Error ("state_of_yojson: " ^ Yojson.Safe.to_string json)

and goal_of_yojson = function
  | `Assoc fields as json ->
      let accepted_fields =
        [ "id"
        ; "title"
        ; "metric"
        ; "target_value"
        ; "due_date"
        ; "priority"
        ; "phase"
        ; "parent_goal_id"
        ; "last_review_note"
        ; "last_review_at"
        ; "completion_review_failure"
        ; "completion_receipt"
        ; "created_at"
        ; "updated_at"
        ]
      in
      let unknown_field =
        List.find_map
          (fun (field, _) ->
            if List.mem field accepted_fields then None else Some field)
          fields
      in
      let id_opt = Json_util.assoc_member_opt "id" json in
      let title_opt = Json_util.assoc_member_opt "title" json in
      (match unknown_field, id_opt, title_opt with
      | Some field, _, _ ->
          Error
            (Printf.sprintf
               "goal_of_yojson: unknown Goal field %S is not accepted"
               field)
      | None, Some (`String id), Some (`String title) ->
          let phase =
            match Json_util.assoc_member_opt "phase" json with
            | None | Some `Null ->
                Error
                  (Printf.sprintf
                     "goal_of_yojson: goal %S has no current phase field"
                     id)
            | Some phase_json -> Phase.view_of_yojson phase_json
          in
          let created_at =
            match Json_util.assoc_member_opt "created_at" json with
            | Some (`String value) -> Ok value
            | _ -> Error "goal_of_yojson: created_at missing"
          in
          let updated_at =
            match Json_util.assoc_member_opt "updated_at" json with
            | Some (`String value) -> Ok value
            | _ -> Error "goal_of_yojson: updated_at missing"
          in
          let completion_receipt =
            match Json_util.assoc_member_opt "completion_receipt" json with
            | None | Some `Null -> Ok None
            | Some receipt_json ->
              Result.map
                (fun receipt -> Some receipt)
                (completion_receipt_of_yojson receipt_json)
          in
          let completion_review_failure =
            match Json_util.assoc_member_opt "completion_review_failure" json with
            | None | Some `Null -> Ok None
            | Some (`String value) ->
              (match completion_review_failure_of_string value with
               | Some failure -> Ok (Some failure)
               | None ->
                 Error
                   "goal_of_yojson: completion_review_failure has an invalid \
                    current-schema value")
            | Some _ ->
              Error
                "goal_of_yojson: completion_review_failure must be a string or \
                 null"
          in
          (match
             ( phase
             , created_at
             , updated_at
             , completion_receipt
             , completion_review_failure )
           with
           | ( Ok phase
             , Ok created_at
             , Ok updated_at
             , Ok completion_receipt
             , Ok completion_review_failure ) ->
             let goal =
               {
                    id;
                    title;
                    metric = Json_util.get_string json "metric";
                    target_value = Json_util.get_string json "target_value";
                    due_date = Json_util.get_string json "due_date";
                    priority =
                      (match Json_util.assoc_member_opt "priority" json with
                      | Some (`Int value) -> clamp_priority value
                      | _ -> 3);
                    phase;
                    parent_goal_id = Json_util.get_string json "parent_goal_id";
                    last_review_note = Json_util.get_string json "last_review_note";
                    last_review_at = Json_util.get_string json "last_review_at";
                    completion_review_failure;
                    completion_receipt;
                    created_at;
                    updated_at;
                  }
             in
             Ok goal
           | Error msg, _, _, _, _ -> Error msg
           | _, Error msg, _, _, _ -> Error msg
           | _, _, Error msg, _, _ -> Error msg
           | _, _, _, Error msg, _ -> Error msg
           | _, _, _, _, Error msg -> Error msg)
      | None, _, _ -> Error "goal_of_yojson: invalid goal")
  | other_json ->
      Error ("goal_of_yojson: " ^ Yojson.Safe.to_string other_json)

type rollup = {
  active_count : int;
  paused_count : int;
  done_count : int;
  dropped_count : int;
}
[@@deriving yojson]

type upsert_kind = [ `created | `updated ]

let normalize_lower s =
  String.trim s |> String.lowercase_ascii

let parse_goal_phase = function
  | Some s -> Phase.parse_view s
  | None -> None

let goals_path config =
  Filename.concat (Workspace_utils.masc_dir config) "goals.json"

let ensure_dirs config =
  Workspace_utils.mkdir_p (Workspace_utils.masc_dir config)

let canonical_workspace_identity config =
  try
    ensure_dirs config;
    let canonical_path = Fs_compat.realpath (Workspace_utils.masc_dir config) in
    Ok
      Digestif.SHA256.(
        digest_string ("masc-workspace\000" ^ canonical_path) |> to_hex)
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | _ ->
    Error "Goal workspace identity is unavailable; reset is required"
;;

let exact_object_fields ~kind expected fields =
  let names = List.map fst fields in
  let rec first_duplicate seen = function
    | [] -> None
    | name :: rest ->
      if List.mem name seen then Some name else first_duplicate (name :: seen) rest
  in
  match first_duplicate [] names with
  | Some name -> Error (Printf.sprintf "%s has duplicate field %S" kind name)
  | None ->
    (match List.find_opt (fun name -> not (List.mem name expected)) names with
     | Some name -> Error (Printf.sprintf "%s has unknown field %S" kind name)
     | None ->
       (match List.find_opt (fun name -> not (List.mem name names)) expected with
        | Some name -> Error (Printf.sprintf "%s is missing field %S" kind name)
        | None -> Ok ()))
;;

let string_field kind name fields =
  match List.assoc name fields with
  | `String value -> Ok value
  | _ -> Error (Printf.sprintf "%s field %S must be a string" kind name)
;;

let string_or_null_field kind name fields =
  match List.assoc name fields with
  | `Null | `String _ -> Ok ()
  | _ -> Error (Printf.sprintf "%s field %S must be a string or null" kind name)
;;

let receipt_field_names =
  [ "workspace_identity"
  ; "expected_state_version"
  ; "operation_id"
  ; "completion_digest"
  ; "review_evidence_sha256"
  ; "evaluator_runtime"
  ; "reviewed_at"
  ; "reviewed_goal_updated_at"
  ; "review_prompt_sha256"
  ; "completion_claim"
  ; "requesting_agent"
  ; "linked_task_ids"
  ]
;;

let validate_receipt_json = function
  | `Assoc fields ->
    let* () = exact_object_fields ~kind:"completion receipt" receipt_field_names fields in
    let string_fields =
      [ "workspace_identity"
      ; "operation_id"
      ; "completion_digest"
      ; "review_evidence_sha256"
      ; "evaluator_runtime"
      ; "reviewed_at"
      ; "reviewed_goal_updated_at"
      ; "review_prompt_sha256"
      ; "completion_claim"
      ; "requesting_agent"
      ]
    in
    let rec validate_strings = function
      | [] -> Ok ()
      | name :: rest ->
        let* value = string_field "completion receipt" name fields in
        if String.equal value ""
        then Error (Printf.sprintf "completion receipt field %S must be non-empty" name)
        else validate_strings rest
    in
    let* () = validate_strings string_fields in
    let* () =
      match List.assoc "expected_state_version" fields with
      | `Int version when version >= 1 -> Ok ()
      | _ -> Error "completion receipt expected_state_version must be a positive integer"
    in
    (match List.assoc "linked_task_ids" fields with
     | `List values when List.for_all (function `String value -> value <> "" | _ -> false) values ->
       let ids = List.map (function `String value -> value | _ -> assert false) values in
       let rec unique seen = function
         | [] -> Ok ()
         | id :: rest ->
           if List.mem id seen
           then Error "completion receipt linked_task_ids must be unique"
           else unique (id :: seen) rest
       in
       unique [] ids
     | _ -> Error "completion receipt linked_task_ids must contain only non-empty strings")
  | _ -> Error "completion receipt must be an object"
;;

let goal_field_names =
  [ "id"
  ; "title"
  ; "metric"
  ; "target_value"
  ; "due_date"
  ; "priority"
  ; "phase"
  ; "parent_goal_id"
  ; "last_review_note"
  ; "last_review_at"
  ; "completion_review_failure"
  ; "completion_receipt"
  ; "created_at"
  ; "updated_at"
  ]
;;

let validate_goal_json = function
  | `Assoc fields ->
    let* () = exact_object_fields ~kind:"Goal" goal_field_names fields in
    let* id = string_field "Goal" "id" fields in
    let* _title = string_field "Goal" "title" fields in
    let* _created_at = string_field "Goal" "created_at" fields in
    let* _updated_at = string_field "Goal" "updated_at" fields in
    let* () =
      if String.equal id "" then Error "Goal id must be non-empty" else Ok ()
    in
    let rec validate_options = function
      | [] -> Ok ()
      | name :: rest ->
        let* () = string_or_null_field "Goal" name fields in
        validate_options rest
    in
    let* () =
      validate_options
        [ "metric"; "target_value"; "due_date"; "parent_goal_id"
        ; "last_review_note"; "last_review_at"
        ]
    in
    let* () =
      match List.assoc "priority" fields with
      | `Int value when value >= 1 && value <= 5 -> Ok ()
      | _ -> Error "Goal priority must be an integer in 1..5"
    in
    let* phase =
      match List.assoc "phase" fields with
      | `String ("executing" as phase)
      | `String ("blocked" as phase)
      | `String ("paused" as phase)
      | `String ("completed" as phase)
      | `String ("dropped" as phase) -> Ok phase
      | _ -> Error "Goal phase must be an exact current-schema token"
    in
    let* () =
      match List.assoc "completion_review_failure" fields with
      | `Null -> Ok ()
      | `String value
        when Option.is_some (completion_review_failure_of_string value) ->
        Ok ()
      | _ -> Error "Goal completion_review_failure has an invalid value"
    in
    let receipt = List.assoc "completion_receipt" fields in
    let* () =
      match phase, receipt, List.assoc "completion_review_failure" fields with
      | "completed", (`Assoc _ as receipt), `Null -> validate_receipt_json receipt
      | "completed", _, _ -> Error "Completed Goal requires one receipt and no review failure"
      | _, `Null, _ -> Ok ()
      | _, _, _ -> Error "Nonterminal Goal must not carry a completion receipt"
    in
    Ok id
  | _ -> Error "Goal must be an object"
;;

let validate_current_state_json = function
  | `Assoc fields ->
    let* () = exact_object_fields ~kind:"Goal state" [ "version"; "updated_at"; "goals" ] fields in
    let* () =
      match List.assoc "version" fields with
      | `Int version when version >= 1 -> Ok ()
      | _ -> Error "Goal state version must be a positive integer"
    in
    let* _updated_at = string_field "Goal state" "updated_at" fields in
    (match List.assoc "goals" fields with
     | `List rows ->
       let rec validate seen = function
         | [] -> Ok ()
         | row :: rest ->
           let* id = validate_goal_json row in
           if List.mem id seen
           then Error (Printf.sprintf "Goal state has duplicate id %S" id)
           else validate (id :: seen) rest
       in
       validate [] rows
     | _ -> Error "Goal state goals must be an array")
  | _ -> Error "Goal state must be an object"
;;

let validate_loaded_state config state =
  let* workspace_identity = canonical_workspace_identity config in
  let rec validate = function
    | [] -> Ok ()
    | goal :: rest ->
      let* () = validate_completion_invariant goal in
      let* () =
        match Phase.is_completed goal.phase, goal.completion_receipt with
        | false, None -> Ok ()
        | true, Some receipt ->
          if not (String.equal receipt.workspace_identity workspace_identity)
          then Error "Completed Goal receipt belongs to a different workspace"
          else
            let target_goal_json =
              goal_to_yojson { goal with completion_receipt = None }
            in
            let expected_digest =
              Goal_completion_contract.completion_digest
                ~workspace_identity:receipt.workspace_identity
                ~goal_json:target_goal_json
                ~reviewed_goal_updated_at:receipt.reviewed_goal_updated_at
                ~goal_id:goal.id
                ~expected_version:receipt.expected_state_version
                ~operation_id:receipt.operation_id
                ~evaluator_runtime:receipt.evaluator_runtime
                ~reviewed_at:receipt.reviewed_at
                ~review_prompt_sha256:receipt.review_prompt_sha256
                ~review_evidence_sha256:receipt.review_evidence_sha256
                ~completion_claim:receipt.completion_claim
                ~requesting_agent:receipt.requesting_agent
                ~linked_task_ids:receipt.linked_task_ids
            in
            if String.equal expected_digest receipt.completion_digest
            then Ok ()
            else Error "Completed Goal receipt target digest does not match persisted Goal"
        | _ -> Error generic_completion_error
      in
      validate rest
  in
  validate state.goals
;;

let default_state () =
  { version = 1; updated_at = Masc_domain.now_iso (); goals = [] }

let read_state config =
  ensure_dirs config;
  let path = goals_path config in
  if not (Workspace_utils.path_exists config path) then default_state ()
  else
    match Workspace_utils.read_json_result config path with
    | Error message ->
      Log.Misc.warn "goal_store: current goals.json is unreadable: %s" message;
      raise_current_state_invalid ()
    | Ok json ->
      (match validate_current_state_json json with
       | Error message ->
         Log.Misc.warn "goal_store: current goals.json shape is invalid: %s" message;
         raise_current_state_invalid ()
       | Ok () ->
         (match state_of_yojson json with
          | Error message ->
            Log.Misc.warn "goal_store: current goals.json decode failed: %s" message;
            raise_current_state_invalid ()
          | Ok state ->
            (match validate_loaded_state config state with
             | Ok () -> state
             | Error message ->
               Log.Misc.warn "goal_store: current goals.json invariant failed: %s" message;
               raise_current_state_invalid ())))

let write_state_unchecked config state =
  ensure_dirs config;
  Workspace_utils.write_json_result config (goals_path config) (state_to_yojson state)

let write_state_result config state =
  if List.exists
       (fun goal -> goal.phase = Phase.Completed)
       state.goals
  then Error generic_completion_error
  else
    let rec validate = function
      | [] -> Ok ()
      | goal :: rest ->
        let* () = validate_completion_invariant goal in
        validate rest
    in
    let* () = validate state.goals in
    write_state_unchecked config state
;;

let write_state config state =
  match write_state_result config state with
  | Ok () -> ()
  | Error msg ->
    Log.Misc.warn "goal_store.write_state failed for %s: %s"
      (goals_path config)
      msg

let now_ms () =
  int_of_float (Time_compat.now () *. 1000.0)

let gen_goal_id () =
  Printf.sprintf "goal-%d-%04x" (now_ms ())
    (Hashtbl.hash (Unix.gettimeofday ()) land 0xFFFF)

let find_goal goals id =
  List.find_opt (fun goal -> String.equal goal.id id) goals

let validate_state_mutation before after =
  let rec validate = function
    | [] -> Ok ()
    | goal :: rest ->
      let* () = validate_completion_invariant goal in
      (match goal.phase, find_goal before.goals goal.id with
       | Phase.Completed, Some previous when previous = goal ->
         validate rest
       | Phase.Completed, _ -> Error generic_completion_error
       | _ -> validate rest)
  in
  validate after.goals
;;

let replace_goal goals updated =
  List.map (fun goal -> if String.equal goal.id updated.id then updated else goal) goals

let update_state config f =
  let lock_path = goals_path config in
  Workspace_utils.with_file_lock config lock_path (fun () ->
      let state = read_state config in
      let next_state = f state in
      let* () = validate_state_mutation state next_state in
      let* () = write_state_unchecked config next_state in
      Ok next_state)

let get_goal config ~goal_id =
  read_state config |> fun state -> find_goal state.goals goal_id

let get_goal_with_version config ~goal_id =
  let state = read_state config in
  Option.map (fun goal -> goal, state.version) (find_goal state.goals goal_id)
;;

let update_goal config ~goal_id f =
  let lock_path = goals_path config in
  Workspace_utils.with_file_lock config lock_path (fun () ->
      let state = read_state config in
      match find_goal state.goals goal_id with
      | None -> Error "goal not found"
      | Some goal ->
          let now = Masc_domain.now_iso () in
          let updated_goal = f { goal with updated_at = now } in
          let* () =
            validate_generic_goal_mutation ~before:goal updated_goal
          in
          let next_state =
            {
              version = state.version + 1;
              updated_at = now;
              goals = replace_goal state.goals updated_goal;
            }
          in
          let* () = write_state_unchecked config next_state in
          Ok updated_goal)

type conditional_update_error =
  | Goal_not_found
  | Goal_snapshot_changed
  | Goal_persistence_failed of string

let conditional_update_error_to_string = function
  | Goal_not_found -> "goal not found"
  | Goal_snapshot_changed ->
    "Goal changed while completion was being reviewed; obtain a new verdict \
     for the current Goal snapshot"
  | Goal_persistence_failed msg -> msg
;;

let update_goal_if_unchanged config ~(expected : goal) f =
  let lock_path = goals_path config in
  Workspace_utils.with_file_lock config lock_path (fun () ->
    let state = read_state config in
    match find_goal state.goals expected.id with
    | None -> Error Goal_not_found
    | Some current when current <> expected -> Error Goal_snapshot_changed
    | Some current ->
      let now = Masc_domain.now_iso () in
      let updated_goal = f { current with updated_at = now } in
      (match validate_generic_goal_mutation ~before:current updated_goal with
       | Error msg -> Error (Goal_persistence_failed msg)
       | Ok () ->
         let next_state =
           { version = state.version + 1
           ; updated_at = now
           ; goals = replace_goal state.goals updated_goal
           }
         in
         (match write_state_unchecked config next_state with
          | Ok () -> Ok updated_goal
          | Error msg -> Error (Goal_persistence_failed msg))))

let set_nonterminal_phase_if_unchanged
      config
      ~expected
      ~phase
      ~review_note
  =
  update_goal_if_unchanged config ~expected (fun goal ->
    let last_review_note, last_review_at =
      match review_note, Phase.nonterminal_to_view phase with
      | Some note, _ -> Some note, Some goal.updated_at
      | None, Phase.Executing -> None, None
      | None, (Phase.Blocked | Phase.Paused | Phase.Dropped) ->
        goal.last_review_note, goal.last_review_at
      | None, Phase.Completed -> assert false
    in
    { goal with
      phase = Phase.of_nonterminal phase
    ; last_review_note
    ; last_review_at
    ; completion_review_failure = None
    ; completion_receipt = None
    })
;;

let record_completion_review_failure_if_unchanged
      config
      ~expected
      ~failure
      ~review_note
      ~reviewed_at
  =
  update_goal_if_unchanged config ~expected (fun goal ->
    { goal with
      last_review_note = Some review_note
    ; last_review_at = Some reviewed_at
    ; completion_review_failure = Some failure
    ; completion_receipt = None
    })
;;

let record_completion_review_failure_current
      config
      ~goal_id
      ~failure
      ~review_note
      ~reviewed_at
  =
  Workspace_utils.with_file_lock config (goals_path config) (fun () ->
    let state = read_state config in
    match find_goal state.goals goal_id with
    | None -> Error Goal_not_found
    | Some current when Phase.is_completed current.phase ->
      Error Goal_snapshot_changed
    | Some current ->
      let updated_goal =
        { current with
          updated_at = reviewed_at
        ; last_review_note = Some review_note
        ; last_review_at = Some reviewed_at
        ; completion_review_failure = Some failure
        ; completion_receipt = None
        }
      in
      (match validate_generic_goal_mutation ~before:current updated_goal with
       | Error msg -> Error (Goal_persistence_failed msg)
       | Ok () ->
         let next_state =
           { version = state.version + 1
           ; updated_at = reviewed_at
           ; goals = replace_goal state.goals updated_goal
           }
         in
         (match write_state_unchecked config next_state with
          | Ok () -> Ok updated_goal
          | Error msg -> Error (Goal_persistence_failed msg))))
;;

type delete_goal_outcome =
  | Deleted
  | Deleted_with_orphaned_links of string

type delete_goal_error =
  | Unknown_goal of string
  | Persistence_failed of string

let delete_goal_error_to_string = function
  | Unknown_goal msg -> msg
  | Persistence_failed msg -> "goal persistence failed: " ^ msg

let delete_goal config ~goal_id =
  let deleted =
    Workspace_utils.with_file_lock config (goals_path config) (fun () ->
      let state = read_state config in
      if not (List.exists (fun goal -> String.equal goal.id goal_id) state.goals) then
        Error (Unknown_goal "Goal not found")
      else (
        match
          write_state_unchecked
            config
            { version = state.version + 1
            ; goals =
                List.filter
                  (fun goal -> not (String.equal goal.id goal_id))
                  state.goals
            ; updated_at = Masc_domain.now_iso ()
            }
        with
        | Ok () -> Ok ()
        | Error msg -> Error (Persistence_failed msg)))
  in
  match deleted with
  | Error _ as error -> error
  | Ok () ->
    (* This is best-effort cascade cleanup across two file stores, not a
       cross-file transaction. A structural fix would either co-locate
       goal-task links with goals or add a higher-level transaction lock that
       covers every goal/link mutation path. *)
    (match Workspace_goal_index.prune_links_for_goal_result config ~goal_id with
     | Ok () -> Ok Deleted
     | Error detail ->
       Log.Misc.warn
         "goal_store.delete_goal: goal %s removed but goal_task_links prune failed: %s"
         goal_id
         detail;
       let warning =
         Printf.sprintf
           "goal deleted but failed to prune goal_task_links for %s: %s"
           goal_id
           detail
       in
       Ok (Deleted_with_orphaned_links warning))

let sort_goals goals =
  (* RFC-0294: sort key was [(horizon, priority, updated_at desc)]; with horizon
     removed it collapses to [(priority asc, updated_at desc)]. *)
  List.sort
    (fun left right ->
      let by_priority = compare left.priority right.priority in
      if by_priority <> 0 then
        by_priority
      else
        String.compare right.updated_at left.updated_at)
    goals

let list_goals config ?phase () =
  read_state config
  |> fun state -> state.goals
  |> List.filter (fun goal ->
         match phase with
         | None -> true
         | Some phase -> Phase.view goal.phase = phase)
  |> sort_goals

let validate_parent_goal_id goals ~goal_id ~parent_goal_id =
  (* Cannot be own parent *)
  if String.equal goal_id parent_goal_id then
    Error "goal cannot be its own parent"
  else
    (* Parent must exist *)
    match find_goal goals parent_goal_id with
    | None -> Error (Printf.sprintf "parent goal %s not found" parent_goal_id)
    | Some _ ->
      (* Walk ancestor chain to detect cycles *)
      let rec walk visited current_id =
        if String.equal current_id goal_id then
          true (* cycle detected *)
        else
          match find_goal goals current_id with
          | None -> false (* orphan parent, already checked above *)
          | Some g ->
            match g.parent_goal_id with
            | None -> false
            | Some pid ->
              if List.mem pid visited then
                false (* existing cycle in ancestors, don't add to it *)
              else
                walk (pid :: visited) pid
      in
      if walk [parent_goal_id] parent_goal_id then
        Error "parent_goal_id would create a cycle"
      else
        Ok ()

let upsert_goal config ?id ?title ?metric ?target_value ?due_date
    ?priority ?parent_goal_id () =
  let is_new_goal = id = None in
  if is_new_goal && (title = None || title = Some "") then
    Error "title required for new goal"
  else
    let now = Masc_domain.now_iso () in
        let resolved_id = Option.value id ~default:(gen_goal_id ()) in
        (* Validate parent_goal_id before acquiring the write lock *)
        let parent_validation =
          let current_goals = (read_state config).goals in
          match find_goal current_goals resolved_id with
          | Some existing ->
              (* Existing goal: validate only if parent is being changed *)
              (match parent_goal_id with
               | Some new_pid ->
                   (match existing.parent_goal_id with
                    | Some old_pid when String.equal old_pid new_pid ->
                        Ok () (* no change, skip validation *)
                    | _ ->
                        validate_parent_goal_id current_goals
                          ~goal_id:resolved_id
                          ~parent_goal_id:new_pid)
               | None -> Ok ())
          | None ->
              (* New goal: validate any provided parent_goal_id *)
              (match parent_goal_id with
               | Some pid ->
                   validate_parent_goal_id current_goals
                     ~goal_id:resolved_id
                     ~parent_goal_id:pid
               | None -> Ok ())
        in
        (match parent_validation with
         | Error msg -> Error msg
         | Ok () ->
        let was_created = ref false in
        let mutation_rejection = ref None in
        let state_result =
          update_state config (fun state ->
              match find_goal state.goals resolved_id with
              | Some existing ->
                  let candidate_goal =
                      {
                        existing with
                        title = Option.value title ~default:existing.title;
                        metric = (match metric with Some _ -> metric | None -> existing.metric);
                        target_value =
                          (match target_value with
                          | Some _ -> target_value
                          | None -> existing.target_value);
                        due_date =
                          (match due_date with
                          | Some _ -> due_date
                          | None -> existing.due_date);
                        priority =
                          clamp_priority
                            (Option.value priority ~default:existing.priority);
                        parent_goal_id =
                          (match parent_goal_id with
                          | Some _ -> parent_goal_id
                          | None -> existing.parent_goal_id);
                      }
                  in
                  if candidate_goal = existing
                  then state
                  else if existing.phase = Phase.Completed
                  then (
                    mutation_rejection :=
                      Some
                        "completed Goal metadata is immutable; reopen the Goal \
                         before changing its completion contract";
                    state)
                  else
                    let next_goal = { candidate_goal with updated_at = now } in
                    {
                      version = state.version + 1;
                      updated_at = now;
                      goals = replace_goal state.goals next_goal;
                    }
              | None ->
                  let new_goal =
                      {
                        id = resolved_id;
                        title = Option.value title ~default:"Untitled goal";
                        metric;
                        target_value;
                        due_date;
                        priority = clamp_priority (Option.value priority ~default:3);
                        phase = Phase.Executing;
                        parent_goal_id;
                        last_review_note = None;
                        last_review_at = None;
                        completion_review_failure = None;
                        completion_receipt = None;
                        created_at = now;
                        updated_at = now;
                      }
                  in
                  was_created := true;
                  {
                    version = state.version + 1;
                    updated_at = now;
                    goals = state.goals @ [ new_goal ];
                  })
        in
        match !mutation_rejection, state_result with
        | Some msg, _ -> Error msg
        | None, Error msg -> Error msg
        | None, Ok state ->
          match find_goal state.goals resolved_id with
          | Some goal ->
              Ok (goal, if !was_created then `created else `updated)
          | None ->
              Error "failed to save goal")

let compute_rollup goals =
  let count predicate =
    List_util.count_if predicate goals
  in
  {
    active_count = count (fun goal -> goal.phase = Phase.Executing);
    paused_count =
      count (fun goal ->
          match goal.phase with
          | Phase.Paused | Phase.Blocked -> true
          | _ -> false);
    done_count = count (fun goal -> goal.phase = Phase.Completed);
    dropped_count = count (fun goal -> goal.phase = Phase.Dropped);
  }

(* RFC-0294: the horizon-driven refresh/snapshot scheduler ([snapshot],
   [parse_yyyy_mm_dd], [days_until], [should_refresh_goal], [reprioritize],
   [refresh], [has_scheduler_state]) was removed. It had no live caller and its
   cohort selector keyed on the now-deleted [horizon]. *)

let active_goals config =
  list_goals config ~phase:Phase.Executing ()

module For_testing = struct
  let write_state = write_state
  let write_state_result = write_state_result
end
