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

(* Each pair binds a name to the value the module exposes under it, so a value
   repointed at another declaration -- or two values swapped -- fails here. A
   lookup that went to the file, or to the name the loaded schema carries,
   would pass in both cases: the file still says the expected thing, and a swap
   leaves both names present. *)
let bindings : (string * Masc_domain.tool_schema) list =
  let open Tool_schemas_operator_surface in
  [ "masc_broadcast", broadcast
  ; "masc_config", config
  ; "masc_dashboard", dashboard
  ; "masc_gc", gc
  ; "masc_keeper_waiting_inventory", keeper_waiting_inventory
  ; "masc_messages", messages
  ; "masc_pause", pause
  ; "masc_pause_status", pause_status
  ; "masc_plan_clear_task", plan_clear_task
  ; "masc_plan_get_task", plan_get_task
  ; "masc_plan_set_task", plan_set_task
  ; "masc_resume", resume
  ; "masc_start", start
  ; "masc_tool_help", tool_help
  ]
;;

let loaded name : Masc_domain.tool_schema =
  match List.assoc_opt name bindings with
  | Some schema -> schema
  | None -> failwith (name ^ " is not bound in Tool_schemas_operator_surface")
;;

(* name, description, input_schema (keys sorted) *)
let expected =
  [ {|masc_broadcast|}, {|Send a message visible to ALL agents via SSE push.

Usage rules:
- Call `masc_status` first to verify state before invoking this tool.
- Use `@agent_name` syntax to ping a specific agent.
- Use for status updates (e.g. starting/done/blocker).
- Use to request help or review from another agent.|}, {|{"additionalProperties":false,"properties":{"agent_name":{"description":"Your agent name","type":"string"},"content":{"description":"Broadcast body text (use @mention for specific agents)","type":"string"},"task_cache_subject_agent":{"description":"Optional typed cache signal: agent whose cached current task is being observed. Must be supplied together with task_cache_task_id.","type":"string"},"task_cache_task_id":{"description":"Optional typed cache signal: task ID observed as active in the subject agent cache. Must be supplied together with task_cache_subject_agent.","type":"string"}},"required":["agent_name","content"],"type":"object"}|}
    ; {|masc_config|}, {|Return the effective runtime configuration.

Each setting carries its source attribution: env var or default. Sensitive values (tokens, passwords) are masked. Use to inspect or verify the server config without restarting. Pass category to filter results to a single section.|}, {|{"additionalProperties":false,"properties":{"category":{"description":"Filter by config category","enum":["server","auth","transport","storage","runtime","rate_limiting","inference","keeper","keeper_execution","autonomy","dashboard","operations","channel","process","worker","web_search","session"],"type":"string"}},"type":"object"}|}
    ; {|masc_dashboard|}, {|Return a concise workspace dashboard summary for the current project. Use scope to choose the current task-focused view or the full workspace view.|}, {|{"additionalProperties":false,"properties":{"scope":{"default":"current","description":"Dashboard scope: current or all","enum":["all","current"],"type":"string"}},"type":"object"}|}
    ; {|masc_gc|}, {|Run explicit age-based garbage collection. Agent lifecycle is not modified.|}, {|{"additionalProperties":false,"properties":{"days":{"description":"Operator-selected retention horizon in days","minimum":1,"type":"integer"}},"required":["days"],"type":"object"}|}
    ; {|masc_keeper_waiting_inventory|}, {|Return the canonical keeper waiting inventory read model: what each keeper is waiting on, source counts, global waiting rows, and supported state labels.|}, {|{"additionalProperties":false,"properties":{},"type":"object"}|}
    ; {|masc_messages|}, {|Get recent broadcast messages from all agents. Use to: catch up after joining, check if someone @mentioned you, see project activity. Returns chronological list with sender, timestamp, content. Default: last 20 messages. Use limit param for more/less. Tip: Search for '@your-name' in results to find mentions.|}, {|{"additionalProperties":false,"properties":{"limit":{"default":10,"description":"Max messages to return","type":"integer"},"since_seq":{"default":0,"description":"Get messages after this sequence number","type":"integer"}},"type":"object"}|}
    ; {|masc_pause|}, {|Pause the workspace until an operator resumes it. Existing state is preserved.|}, {|{"additionalProperties":false,"properties":{"reason":{"default":"Manual pause","description":"Operator-visible reason for pausing the workspace","type":"string"}},"type":"object"}|}
    ; {|masc_pause_status|}, {|Return the current pause status of the workspace and any paused keepers. Read-only; takes no arguments.|}, {|{"additionalProperties":false,"properties":{},"type":"object"}|}
    ; {|masc_plan_clear_task|}, {|Clear your current task assignment without completing it.

The task's own status does not change. Use when switching to a different task, abandoning work, or resetting session state. Use masc_transition to change task status separately.|}, {|{"additionalProperties":false,"properties":{},"type":"object"}|}
    ; {|masc_plan_get_task|}, {|Get the task_id you're currently working on (session-scoped). Use when resuming work after a context switch or verifying your current assignment. Set via masc_plan_set_task. Auto-cleared on session end.|}, {|{"additionalProperties":false,"properties":{},"type":"object"}|}
    ; {|masc_plan_set_task|}, {|Set the current task for your session so you can omit task_id in subsequent planning calls. Use when starting work on a task after claiming it. After keeper_task_claim; auto-cleared on session end.|}, {|{"additionalProperties":false,"properties":{"task_id":{"description":"Task ID to set as current","type":"string"}},"required":["task_id"],"type":"object"}|}
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
  check int "14 tools pinned here" 14 (List.length expected);
  check int "14 tools bound in the module" 14 (List.length bindings)
;;

(* Three checks that lived in test_tool_descriptors_gen and have nothing to do
   with code generation. Deleting the generator's regression suite would have
   taken them with it. *)

let has_schema name schemas =
  List.exists (fun (s : Masc_domain.tool_schema) -> String.equal s.name name) schemas
;;

(* The masc_config category enum is a literal in the TOML now, so nothing
   derives it from its owner. This is what fails when a category is added to
   one side only. *)
let test_config_category_enum_matches_its_owner () =
  check
    (list string)
    "the enum matches Env_config_snapshot.valid_config_category_strings"
    Env_config_snapshot.valid_config_category_strings
    Tool_schemas_specs_types.config_category_enum_strings
;;

let test_keeper_spawn_is_not_published () =
  check
    bool
    "keeper_spawn absent from the misc schema set"
    false
    (has_schema "keeper_spawn" Tool_schemas_misc.schemas)
;;

(* pause / resume / pause_status are Operator_only: reached through
   control_schema, never through the list a Keeper model reads. *)
let test_control_operations_stay_off_the_published_list () =
  check
    (list string)
    "the typed control projection is exhaustive"
    [ "masc_pause"; "masc_resume"; "masc_pause_status" ]
    (List.map
       (fun operation -> (Tool_schemas_misc.control_schema operation).name)
       Tool_schemas_misc.control_operations);
  List.iter
    (fun name ->
       check
         bool
         (name ^ " absent from the published misc schemas")
         false
         (has_schema name Tool_schemas_misc.schemas))
    [ "masc_pause"; "masc_resume"; "masc_pause_status" ]
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
    ; ( "invariants_the_codegen_suite_carried"
      , [ test_case
            "the config category enum matches its owner"
            `Quick
            test_config_category_enum_matches_its_owner
        ; test_case "keeper_spawn is not published" `Quick test_keeper_spawn_is_not_published
        ; test_case
            "control operations stay off the published list"
            `Quick
            test_control_operations_stay_off_the_published_list
        ] )
    ]
;;
