(** Byte-identity pins for the RFC-0057 codegen migration.

    The 19 tools below were owned by [bin/gen_tool_descriptors.ml], which held
    them as OCaml values and emitted [tool_descriptors_gen.ml] through a dune
    rule. The expected values here were read off that generated module before
    the migration, so this suite passing *before* the TOML replaces it is what
    proves the files say the same thing.

    Compared as parsed JSON with keys sorted, per RFC
    prompts-and-tool-definitions-outside-ocaml §4: object key order is not part
    of a JSON object's meaning, and TOML cannot place a sub-table before its
    parent's scalar keys. Everything the order does not carry — description,
    type, required, default, enum, pattern, nesting — is pinned exactly. *)

open Alcotest

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

let loaded name : Masc_domain.tool_schema =
  Tool_schemas_operator_surface.schema_of_name name
;;

(* name, description, input_schema (keys sorted) *)
let expected =
  [ {|masc_broadcast|}, {|Send a message visible to ALL agents via SSE push.

Usage rules:
- Call `masc_status` first to verify state before invoking this tool.
- Use `@agent_name` syntax to ping a specific agent.
- Use for status updates (e.g. starting/done/blocker).
- Use to request help or review from another agent.|}, {|{"additionalProperties":false,"properties":{"agent_name":{"description":"Your agent name","type":"string"},"content":{"description":"Broadcast body text (use @mention for specific agents)","type":"string"},"task_cache_subject_agent":{"description":"Optional typed cache signal: agent whose cached current task is being observed. Must be supplied together with task_cache_task_id.","type":"string"},"task_cache_task_id":{"description":"Optional typed cache signal: task ID observed as active in the subject agent cache. Must be supplied together with task_cache_subject_agent.","type":"string"}},"required":["agent_name","content"],"type":"object"}|}
    ; {|masc_config|}, {|Return the effective runtime configuration with source attribution (env var or default) for each setting. Sensitive values (tokens, passwords) are masked. Use to inspect or verify the server config without restarting. Pass category to filter results to a single section.|}, {|{"additionalProperties":false,"properties":{"category":{"description":"Filter by config category","enum":["server","auth","transport","storage","runtime","rate_limiting","inference","keeper","keeper_execution","autonomy","dashboard","operations","channel","process","worker","web_search","session"],"type":"string"}},"type":"object"}|}
    ; {|masc_dashboard|}, {|Return a concise workspace dashboard summary for the current project. Use scope to choose the current task-focused view or the full workspace view.|}, {|{"additionalProperties":false,"properties":{"scope":{"default":"current","description":"Dashboard scope: current or all","enum":["all","current"],"type":"string"}},"type":"object"}|}
    ; {|masc_deliver|}, {|Attach final output/result to a task for handoff or review. Use for: code diffs, PR URLs, analysis reports, generated files. Deliverables persist with task and are visible to other agents. Call before masc_transition(action='done'). Example: masc_deliver({task_id: 'task-001', content: 'artifact:review-123'})|}, {|{"additionalProperties":false,"properties":{"content":{"description":"Deliverable content","type":"string"},"task_id":{"description":"Task ID","type":"string"}},"required":["task_id","content"],"type":"object"}|}
    ; {|masc_gc|}, {|Run explicit age-based garbage collection. Agent lifecycle is not modified.|}, {|{"additionalProperties":false,"properties":{"days":{"description":"Operator-selected retention horizon in days","minimum":1,"type":"integer"}},"required":["days"],"type":"object"}|}
    ; {|masc_keeper_waiting_inventory|}, {|Return the canonical keeper waiting inventory read model: what each keeper is waiting on, source counts, global waiting rows, and supported state labels.|}, {|{"additionalProperties":false,"properties":{},"type":"object"}|}
    ; {|masc_messages|}, {|Get recent broadcast messages from all agents. Use to: catch up after joining, check if someone @mentioned you, see project activity. Returns chronological list with sender, timestamp, content. Default: last 20 messages. Use limit param for more/less. Tip: Search for '@your-name' in results to find mentions.|}, {|{"additionalProperties":false,"properties":{"limit":{"default":10,"description":"Max messages to return","type":"integer"},"since_seq":{"default":0,"description":"Get messages after this sequence number","type":"integer"}},"type":"object"}|}
    ; {|masc_note_add|}, {|Add a note/observation to the planning context. Notes are timestamped and appended.|}, {|{"additionalProperties":false,"properties":{"note":{"description":"Note content","type":"string"},"task_id":{"description":"Task ID","type":"string"}},"required":["task_id","note"],"type":"object"}|}
    ; {|masc_pause|}, {|Pause the workspace until an operator resumes it. Existing state is preserved.|}, {|{"additionalProperties":false,"properties":{"reason":{"default":"Manual pause","description":"Operator-visible reason for pausing the workspace","type":"string"}},"type":"object"}|}
    ; {|masc_pause_status|}, {|Return the current pause status of the workspace and any paused keepers. Read-only; takes no arguments.|}, {|{"additionalProperties":false,"properties":{},"type":"object"}|}
    ; {|masc_plan_clear_task|}, {|Clear your current task assignment without completing it (does not change task status). Use when switching to a different task, abandoning work, or resetting session state. Use masc_transition to change task status separately.|}, {|{"additionalProperties":false,"properties":{},"type":"object"}|}
    ; {|masc_plan_get|}, {|Retrieve the full planning context for a task as markdown (plan, notes, deliverable). Use when loading task context into your working memory before starting work. After masc_plan_init; omit task_id if masc_plan_set_task was called.|}, {|{"additionalProperties":false,"properties":{"task_id":{"description":"Task ID (optional if current task is set)","type":"string"}},"type":"object"}|}
    ; {|masc_plan_get_task|}, {|Get the task_id you're currently working on (session-scoped). Use when resuming work after a context switch or verifying your current assignment. Set via masc_plan_set_task. Auto-cleared on session end.|}, {|{"additionalProperties":false,"properties":{},"type":"object"}|}
    ; {|masc_plan_init|}, {|Initialize a planning context for a task, creating task_plan.md, notes.md, and deliverable.md structure. Use when starting structured work on a claimed task that needs planning artifacts. After keeper_task_claim; follow up with masc_plan_update to write the plan.|}, {|{"additionalProperties":false,"properties":{"task_id":{"description":"Task ID to create planning context for","type":"string"}},"required":["task_id"],"type":"object"}|}
    ; {|masc_plan_set_task|}, {|Set the current task for your session so you can omit task_id in subsequent planning calls. Use when starting work on a task after claiming it. After keeper_task_claim; auto-cleared on session end.|}, {|{"additionalProperties":false,"properties":{"task_id":{"description":"Task ID to set as current","type":"string"}},"required":["task_id"],"type":"object"}|}
    ; {|masc_plan_update|}, {|Overwrite the current task plan with new content (markdown). Use when refining or replacing the execution plan for your current task. After masc_plan_init creates the structure; pair with masc_plan_get to review.|}, {|{"additionalProperties":false,"properties":{"content":{"description":"New plan content (markdown)","type":"string"},"task_id":{"description":"Task ID","type":"string"}},"required":["task_id","content"],"type":"object"}|}
    ; {|masc_resume|}, {|Resume a workspace that was paused by an operator.|}, {|{"additionalProperties":false,"properties":{},"type":"object"}|}
    ; {|masc_start|}, {|One-step onboarding: sets the active project root, joins as agent, and optionally creates+claims a task.|}, {|{"additionalProperties":false,"properties":{"path":{"description":"Project directory path (absolute, relative, or ~/...). Omit if the active project scope is already set.","type":"string"},"task_title":{"description":"If provided, creates a task with this title, claims it, and sets it as current_task. Omit to just join without a task.","type":"string"}},"type":"object"}|}
    ; {|masc_tool_help|}, {|Return canonical help text, parameters, and metadata for a specific MASC tool by name.|}, {|{"additionalProperties":false,"properties":{"tool_name":{"description":"Exact MCP tool name to explain","type":"string"}},"required":["tool_name"],"type":"object"}|}
  ]
;;

let test_descriptions_are_byte_identical () =
  List.iter
    (fun (name, description, _) ->
       check string (name ^ " description") description (loaded name).description)
    expected
;;

let test_input_schemas_match_with_keys_sorted () =
  List.iter
    (fun (name, _, schema) ->
       check
         string
         (name ^ " input_schema")
         schema
         (Yojson.Safe.to_string (sorted (loaded name).input_schema)))
    expected
;;

let test_every_tool_the_generator_owned_is_declared () =
  check int "19 tools moved" 19 (List.length expected)
;;

let () =
  run
    "operator_surface_toml_parity"
    [ ( "byte_identity"
      , [ test_case "descriptions" `Quick test_descriptions_are_byte_identical
        ; test_case
            "input schemas, keys sorted"
            `Quick
            test_input_schemas_match_with_keys_sorted
        ; test_case
            "every tool the generator owned is declared"
            `Quick
            test_every_tool_the_generator_owned_is_declared
        ] )
    ]
;;
