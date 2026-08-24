(** Byte-identity pins for the task tool TOML migration.

    The expected values are the schema bytes the migration must not move. They
    were generated from the live schemas before the OCaml literals were
    removed, so this suite passing *before* the migration is what proves the
    TOML says the same thing; passing only after would prove nothing beyond
    "my copy matches my expectation".

    The comparison point is [Masc.Config.raw_all_tool_schemas] — the array MCP
    clients read. A drifted description, a reordered property, a lost required
    entry, or a dropped default is a byte difference here. *)

open Alcotest

let schema name =
  match
    List.find_opt
      (fun (s : Masc_domain.tool_schema) -> String.equal s.name name)
      Masc.Config.raw_all_tool_schemas
  with
  | Some s -> s
  | None -> failf "%s is absent from the canonical registry" name
;;

let serialized name = Yojson.Safe.to_string (schema name).input_schema

let expected_task_history =
  {|{"type":"object","properties":{"task_id":{"type":"string","description":"Task ID to filter (e.g., 'task-001')"},"limit":{"type":"integer","description":"Max events to return (default: 50)","default":50}},"required":["task_id"]}|}
;;

let expected_tasks =
  {|{"type":"object","properties":{"status":{"type":"string","description":"Optional status filter: todo|claimed|in_progress|awaiting_verification|done|cancelled"},"include_done":{"type":"boolean","description":"Include done tasks (default: false)","default":false},"include_cancelled":{"type":"boolean","description":"Include cancelled tasks (default: false)","default":false}}}|}
;;

let expected_update_priority =
  {|{"type":"object","properties":{"task_id":{"type":"string","description":"Task ID to update"},"priority":{"type":"integer","description":"New priority (1=highest, 5=lowest)","minimum":1,"maximum":5}},"required":["task_id","priority"]}|}
;;

let expected_task_set_goal =
  {|{"type":"object","properties":{"task_id":{"type":"string","description":"ID of the task to assign"},"goal_id":{"type":"string","description":"ID of the goal to assign the task to"}},"required":["task_id","goal_id"]}|}
;;

let test_input_schemas_are_byte_identical () =
  List.iter
    (fun (name, expected) -> check string (name ^ " input_schema") expected (serialized name))
    [ "masc_task_history", expected_task_history
    ; "masc_tasks", expected_tasks
    ; "masc_update_priority", expected_update_priority
    ; "masc_task_set_goal", expected_task_set_goal
    ]
;;

let test_descriptions_are_byte_identical () =
  List.iter
    (fun (name, expected) -> check string (name ^ " description") expected (schema name).description)
    [ "masc_task_history", {|Fetch recent task transition history from event logs. Useful for audits or debugging transitions.|}
    ; "masc_tasks", {|List tasks in backlog with their status and assignee. Defaults to active tasks (todo/claimed/in_progress/awaiting_verification). Use include_done/include_cancelled or status to filter. awaiting_verification tasks are pending a completion-authority verdict and are not claimable agent work. Output includes task ID, title, priority, assignee, timestamps. Tip: Look for status='todo' tasks to claim.|}
    ; "masc_update_priority", {|Change the priority of a task. Priority 1 is highest (most urgent), 5 is lowest. Use this to reprioritize work based on new information or urgency changes.|}
    ; "masc_task_set_goal", {|Assign an existing, currently goalless task to a goal. Both task_id and goal_id are required and validated against the backlog and the goal store; an unknown id is rejected (never silently ignored or auto-picked). A task that already has a goal is rejected — reassignment is out of scope.|} ]
;;

let member (json : Yojson.Safe.t) key =
  match json with
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let property_names name =
  match member (schema name).input_schema "properties" with
  | Some (`Assoc props) -> List.map fst props
  | _ -> failf "%s has no properties object" name
;;

let required_names name =
  match member (schema name).input_schema "required" with
  | Some (`List entries) ->
    List.map (function `String s -> s | _ -> failf "%s: non-string required" name) entries
  | None -> []
  | Some _ -> failf "%s: required is not an array" name
;;

(* Order is part of the byte comparison: the tools array is serialized as
   written, so a reordered TOML file moves bytes on the wire. *)
let test_properties_keep_their_order_and_requirement () =
  List.iter
    (fun (name, props, required) ->
       check (list string) (name ^ " properties, in order") props (property_names name);
       check (list string) (name ^ " required, in order") required (required_names name))
    [ "masc_task_history", [ "task_id"; "limit" ], [ "task_id" ]
    ; "masc_tasks", [ "status"; "include_done"; "include_cancelled" ], []
    ; "masc_update_priority", [ "task_id"; "priority" ], [ "task_id"; "priority" ]
    ; "masc_task_set_goal", [ "task_id"; "goal_id" ], [ "task_id"; "goal_id" ]
    ]
;;

(* A default that survives the move is the difference between a caller that
   may omit the field and one that must supply it. *)
let test_defaults_survive () =
  let default name prop =
    match member (schema name).input_schema "properties" with
    | Some (`Assoc props) ->
      (match List.assoc_opt prop props with
       | Some spec -> member spec "default"
       | None -> failf "%s has no %s property" name prop)
    | _ -> failf "%s has no properties object" name
  in
  check bool "masc_task_history.limit keeps 50" true (default "masc_task_history" "limit" = Some (`Int 50));
  check
    bool
    "masc_tasks.include_done keeps false"
    true
    (default "masc_tasks" "include_done" = Some (`Bool false));
  check
    bool
    "masc_tasks.include_cancelled keeps false"
    true
    (default "masc_tasks" "include_cancelled" = Some (`Bool false))
;;

let () =
  run
    "task_tool_toml_parity"
    [ ( "byte_identity"
      , [ test_case "input schemas" `Quick test_input_schemas_are_byte_identical
        ; test_case "descriptions" `Quick test_descriptions_are_byte_identical
        ; test_case
            "properties keep order and requirement"
            `Quick
            test_properties_keep_their_order_and_requirement
        ; test_case "defaults survive" `Quick test_defaults_survive
        ] )
    ]
;;
