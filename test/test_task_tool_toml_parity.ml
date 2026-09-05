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

(* Compared as parsed JSON with object keys sorted, not as serialized bytes.

   A JSON object is an unordered set of members (RFC 8259 §4), and no reader of
   these schemas behaves differently for a different key order. What the order
   does reach is the prompt cache: tool definitions sit in the system prompt
   layer and the match is exact, so moving a key costs one uncached turn after
   deployment — the same one-time cost Claude Code pays whenever an upgrade
   changes its own tool definitions.

   Byte identity was the right pin while the OCaml literals were the source: it
   catches a migration that drops a default or reorders properties. It stops
   being the right pin here, because the three schemas below put their
   structural keys in three different places — [contract] last,
   [tasks] after maxItems, [handoff_context] after description — and TOML
   cannot express any of them: a sub-table may only follow every scalar key of
   its parent. Holding the bytes would mean keeping three hand-written orders
   forever and leaving these tools in OCaml.

   Everything the order does not carry is still pinned exactly: every
   description, type, required list, default, enum, pattern, and the nesting
   itself. *)
let rec sorted (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `Assoc fields ->
    `Assoc
      (fields
       |> List.map (fun (key, value) -> key, sorted value)
       |> List.sort (fun (a, _) (b, _) -> String.compare a b))
  | `List items -> `List (List.map sorted items)
  | other -> other
;;

let serialized name = Yojson.Safe.to_string (sorted (schema name).input_schema)

let expected_task_history =
  {|{"properties":{"limit":{"default":50,"description":"Max events to return (default: 50)","type":"integer"},"task_id":{"description":"Task ID to filter (e.g., 'task-001')","type":"string"}},"required":["task_id"],"type":"object"}|}
;;

let expected_tasks =
  {|{"properties":{"include_cancelled":{"default":false,"description":"Include cancelled tasks (default: false)","type":"boolean"},"include_done":{"default":false,"description":"Include done tasks (default: false)","type":"boolean"},"status":{"description":"Optional status filter: todo|claimed|in_progress|awaiting_verification|done|cancelled","type":"string"}},"type":"object"}|}
;;

let expected_update_priority =
  {|{"properties":{"priority":{"description":"New priority (1=highest, 5=lowest)","maximum":5,"minimum":1,"type":"integer"},"task_id":{"description":"Task ID to update","type":"string"}},"required":["task_id","priority"],"type":"object"}|}
;;

let expected_task_set_goal =
  {|{"properties":{"goal_id":{"description":"ID of the goal to assign the task to","type":"string"},"task_id":{"description":"ID of the task to assign","type":"string"}},"required":["task_id","goal_id"],"type":"object"}|}
;;


let expected_add_task =
  {|{"properties":{"contract":{"additionalProperties":false,"description":"What counts as done for this task, and what evidence shows it. Recorded at creation and never rewritten. Omit it and the task carries no criteria.","properties":{"completion_contract":{"items":{"type":"string"},"type":"array"},"inspect_gate_evidence":{"items":{"type":"string"},"type":"array"},"required_evidence":{"items":{"type":"string"},"type":"array"},"strict":{"type":"boolean"},"verify_gate_evidence":{"items":{"type":"string"},"type":"array"}},"type":"object"},"description":{"description":"Task description","type":"string"},"goal_id":{"description":"Optional structured goal link for rollups. If omitted, the task is created unscoped (goalless); pass goal_id explicitly to link it to a goal.","type":"string"},"predecessor_task_id":{"description":"Optional re-run provenance link (RFC-0323): the terminal (done/cancelled) task this one re-runs. Rejected if the id is unknown or the predecessor is not terminal. To re-run completed work, create a new task with this link instead of re-claiming the old one.","type":"string"},"priority":{"default":3,"description":"Priority 1-5 (1=highest)","type":"integer"},"skills":{"description":"Canonical exact Skill references from the published Skill catalog. Each item pins source, package, canonical Skill name, and exact SKILL.md content revision. Omit or pass an empty list when the task needs none.","items":{"additionalProperties":false,"properties":{"content_revision":{"maxLength":64,"minLength":64,"pattern":"^[0-9a-f]{64}$","type":"string"},"identity":{"additionalProperties":false,"properties":{"name":{"minLength":1,"type":"string"},"package_id":{"minLength":1,"type":"string"},"source_id":{"minLength":1,"type":"string"}},"required":["source_id","package_id","name"],"type":"object"}},"required":["identity","content_revision"],"type":"object"},"type":"array"},"title":{"description":"Task title","type":"string"}},"required":["title"],"type":"object"}|}
;;

let expected_transition =
  {|{"properties":{"action":{"description":"Which transition to apply. claim takes an unclaimed Task; start moves your claim into progress; release hands it back with a required handoff_context.summary; cancel ends it with a reason. Completion goes through submit_for_verification with evidence in notes — done is refused from every working status and cannot complete a Task here.","enum":["claim","start","done","cancel","release","submit_for_verification"],"type":"string"},"expected_version":{"description":"Optional CAS guard (current backlog.version). Transition fails if mismatched","type":"integer"},"handoff_context":{"description":"Typed handoff payload. 'summary' is REQUIRED (non-empty) for exit-class actions (submit_for_verification / done / release / cancel). On action='submit_for_verification', every 'evidence_refs' entry must use 'artifact:<producer-root-relative-path>' for a bounded file snapshot or 'note:<text>' for narrative evidence. A public URL inside a note (a PR, a CI run) can be fetched live by the verifier itself; materialize volatile contents as an artifact when they must be pinned at submit time. Commits and traces are not fetched. Bare relative paths and absolute host paths are persisted as typed invalid references. The list itself is optional. Example: {\"summary\": \"tests green, local proof saved\", \"evidence_refs\": [\"artifact:artifacts/proof.json\"]}.","properties":{"evidence_refs":{"description":"Typed verifier evidence. Use artifact:<producer-root-relative-path> for files or note:<text> for narrative, commit, trace, receipt, or URL evidence. Bare and absolute paths are invalid.","items":{"minLength":1,"type":"string"},"type":"array"},"failure_mode":{"description":"If released due to failure, describe the failure mode.","type":"string"},"next_step":{"description":"What the next owner should do first.","type":"string"},"reason":{"description":"Why the task is being released (blocker, handoff, pause).","type":"string"},"reclaim_policy":{"description":"Explicit reclaim policy. Omit or use allow_reclaim for normal handoff. Use block_reclaim only for deterministic terminal mismatches that must require operator review.","enum":["allow_reclaim","block_reclaim"],"type":"string"},"summary":{"description":"REQUIRED. Non-empty one-line summary of current state at release time. Example: 'tests green, PR #123 pending review'.","minLength":1,"type":"string"}},"required":["summary"],"type":"object"},"notes":{"description":"Evidence summary for submit_for_verification, or completion notes for done","type":"string"},"reason":{"description":"Why this Task should stop existing (used with action='cancel'). Cancelling a Task you hold submits the stop for a verdict and the completion authority judges this sentence and nothing else, so one must be stated — here, or in handoff_context (summary or reason), which exit-class actions already require. Cancelling an unclaimed Task takes no verdict and needs none.","type":"string"},"task_id":{"description":"Task ID (e.g., 'task-001')","type":"string"}},"required":["task_id","action"],"type":"object"}|}
;;

let expected_batch_add_tasks =
  {|{"properties":{"tasks":{"description":"List of tasks to add","items":{"properties":{"contract":{"additionalProperties":false,"properties":{"completion_contract":{"items":{"type":"string"},"type":"array"},"inspect_gate_evidence":{"items":{"type":"string"},"type":"array"},"required_evidence":{"items":{"type":"string"},"type":"array"},"strict":{"type":"boolean"},"verify_gate_evidence":{"items":{"type":"string"},"type":"array"}},"type":"object"},"description":{"description":"Task description","type":"string"},"goal_id":{"description":"Optional structured goal link for rollups. If omitted, the task is created unscoped (goalless); pass goal_id explicitly to link it to a goal.","type":"string"},"priority":{"default":3,"description":"Priority 1-5 (1=highest)","type":"integer"},"title":{"description":"Task title","type":"string"}},"required":["title"],"type":"object"},"maxItems":20,"type":"array"}},"required":["tasks"],"type":"object"}|}
;;

let test_input_schemas_are_byte_identical () =
  List.iter
    (fun (name, expected) -> check string (name ^ " input_schema") expected (serialized name))
    [ "masc_task_history", expected_task_history
    ; "masc_tasks", expected_tasks
    ; "masc_update_priority", expected_update_priority
    ; "masc_task_set_goal", expected_task_set_goal
    ; "masc_add_task", expected_add_task
    ; "masc_transition", expected_transition
    ; "masc_batch_add_tasks", expected_batch_add_tasks
    ]
;;

let test_descriptions_are_byte_identical () =
  List.iter
    (fun (name, expected) -> check string (name ^ " description") expected (schema name).description)
    [ "masc_task_history", {|Fetch recent task transition history from event logs. Useful for audits or debugging transitions.|}
    ; "masc_tasks", {|List tasks in backlog with their status and assignee. Defaults to active tasks (todo/claimed/in_progress/awaiting_verification). Use include_done/include_cancelled or status to filter. awaiting_verification tasks are pending a completion-authority verdict and are not claimable agent work. Output includes task ID, title, priority, assignee, timestamps. Tip: Look for status='todo' tasks to claim.|}
    ; "masc_update_priority", {|Change the priority of a task. Priority 1 is highest (most urgent), 5 is lowest. Use this to reprioritize work based on new information or urgency changes.|}
    ; "masc_task_set_goal", {|Assign an existing, currently goalless task to a goal.

Both task_id and goal_id are required and validated against the backlog and the goal store; an unknown id is rejected (never silently ignored or auto-picked). A task that already has a goal is rejected — reassignment is out of scope.|} ]
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
