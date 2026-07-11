(* RFC-0057 Phase 2 — tool descriptor codegen.

   Mirrors bin/gen_shell_ir_walkers.ml: spec-as-OCaml-value -> Buffer.emit
   -> stdout. The dune rule in lib/tool_schemas/ captures stdout into
   tool_descriptors_gen.ml inside the masc_tool_schemas library, so the
   generated schemas live alongside the hand-written ones in the same
   module namespace.

   Phase 2 lifted spec types into lib/tool_schemas_specs/ to share
   between the generator and any future tooling (schema lint, doc
   generation). The executable now depends on tool_schemas_specs (types
   only), avoiding the cycle because that library does not depend on
   masc_tool_schemas. *)

open Tool_schemas_specs_types

(* === Phase 0 spec data ==============================================

   masc_config — single optional `category` filter. The enum mirrors
   Tool_schemas_misc.config_category_enum_strings (Issue #8493). Phase
   0 keeps a third copy in this generator to stay self-contained; the
   regression test guarantees this copy stays aligned with the
   hand-written schema, and Phase 1 collapses all three into a typed
   SSOT. *)

let config_category_enum_strings =
  [ "server"
  ; "auth"
  ; "transport"
  ; "storage"
  ; "runtime"
  ; "rate_limiting"
  ; "inference"
  ; "keeper"
  ; "keeper_execution"
  ; "keeper_guardrails"
  ; "autonomy"
  ; "level2"
  ; "dashboard"
  ; "economy"
  ; "governance"
  ; "channel"
  ; "process"
  ; "worker"
  ; "web_search"
  ; "session"
  ]
;;

let masc_config_spec : tool_spec =
  { name = "masc_config"
  ; description =
      "Return the effective runtime configuration with source attribution (env var or \
       default) for each setting. Sensitive values (tokens, passwords) are masked. Use \
       to inspect or verify the server config without restarting. Pass category to \
       filter results to a single section."
  ; parameters =
      [ { p_name = "category"
        ; p_type = T_string { enum = Some config_category_enum_strings; default = None }
        ; p_description = "Filter by config category"
        ; p_required = false
        }
      ]
  ; additional_properties = false
  ; behavior_contract = []
  }
;;

let masc_tool_help_spec : tool_spec =
  { name = "masc_tool_help"
  ; description =
      "Return canonical help text, parameters, and metadata for a specific MASC tool by \
       name."
  ; parameters =
      [ { p_name = "tool_name"
        ; p_type = T_string { enum = None; default = None }
        ; p_description = "Exact MCP tool name to explain"
        ; p_required = true
        }
      ]
  ; additional_properties = false
  ; behavior_contract = []
  }
;;

let dashboard_scope_enum_strings = [ "all"; "current" ]

let masc_dashboard_spec : tool_spec =
  { name = "masc_dashboard"
  ; description =
      "Return a concise workspace dashboard summary for the current project. Use scope \
       to choose the current task-focused view or the full workspace view."
  ; parameters =
      [ { p_name = "scope"
        ; p_type =
            T_string { enum = Some dashboard_scope_enum_strings; default = Some "current" }
        ; p_description = "Dashboard scope: current or all"
        ; p_required = false
        }
      ]
  ; additional_properties = false
  ; behavior_contract = []
  }
;;

let masc_keeper_waiting_inventory_spec : tool_spec =
  { name = "masc_keeper_waiting_inventory"
  ; description =
      "Return the canonical keeper waiting inventory read model: what each keeper is \
       waiting on, source counts, global waiting rows, and supported state labels."
  ; parameters = []
  ; additional_properties = false
  ; behavior_contract = []
  }
;;

let masc_gc_spec : tool_spec =
  { name = "masc_gc"
  ; description =
      "Run garbage collection: remove zombie agents, archive stale tasks, delete old \
       messages (default: 7-day threshold)."
  ; parameters =
      [ { p_name = "days"
        ; p_type = T_int { min = None; max = None; default = Some 7 }
        ; p_description = "Age threshold in days (default: 7)"
        ; p_required = false
        }
      ]
  ; additional_properties = false
  ; behavior_contract = []
  }
;;

let masc_tool_stats_spec : tool_spec =
  { name = "masc_tool_stats"
  ; description =
      "In-memory tool usage stats: top calls, stale (30+ days), never-called. Resets on \
       server restart."
  ; parameters =
      [ { p_name = "top_n"
        ; p_type = T_int { min = Some 1; max = Some 100; default = Some 20 }
        ; p_description = "Number of top tools to return (default: 20)"
        ; p_required = false
        }
      ]
  ; additional_properties = false
  ; behavior_contract = []
  }
;;

let masc_cleanup_zombies_spec : tool_spec =
  { name = "masc_cleanup_zombies"
  ; description =
      "Remove zombie agents (no heartbeat for 5+ min) and release their file locks."
  ; parameters = []
  ; additional_properties = false
  ; behavior_contract = []
  }
;;

let masc_pause_spec : tool_spec =
  { name = "masc_pause"
  ; description =
      "Pause the workspace until an operator resumes it. Existing state is preserved."
  ; parameters =
      [ { p_name = "reason"
        ; p_type = T_string { enum = None; default = Some "Manual pause" }
        ; p_description = "Operator-visible reason for pausing the workspace"
        ; p_required = false
        }
      ]
  ; additional_properties = false
  ; behavior_contract = []
  }
;;

let masc_resume_spec : tool_spec =
  { name = "masc_resume"
  ; description = "Resume a workspace that was paused by an operator."
  ; parameters = []
  ; additional_properties = false
  ; behavior_contract = []
  }
;;

(* === PR-2: plan group (8 tools) === *)

let masc_plan_init_spec : tool_spec =
  { name = "masc_plan_init"
  ; description =
      "Initialize a planning context for a task, creating task_plan.md, notes.md, and \
       deliverable.md structure. Use when starting structured work on a claimed task \
       that needs planning artifacts. After keeper_task_claim; follow up \
       with masc_plan_update to write the plan."
  ; parameters =
      [ { p_name = "task_id"
        ; p_type = T_string { enum = None; default = None }
        ; p_description = "Task ID to create planning context for"
        ; p_required = true
        }
      ]
  ; additional_properties = false
  ; behavior_contract = []
  }
;;

let masc_plan_update_spec : tool_spec =
  { name = "masc_plan_update"
  ; description =
      "Overwrite the current task plan with new content (markdown). Use when refining \
       or replacing the execution plan for your current task. After masc_plan_init \
       creates the structure; pair with masc_plan_get to review."
  ; parameters =
      [ { p_name = "task_id"
        ; p_type = T_string { enum = None; default = None }
        ; p_description = "Task ID"
        ; p_required = true
        }
      ; { p_name = "content"
        ; p_type = T_string { enum = None; default = None }
        ; p_description = "New plan content (markdown)"
        ; p_required = true
        }
      ]
  ; additional_properties = false
  ; behavior_contract = []
  }
;;

let masc_plan_get_spec : tool_spec =
  { name = "masc_plan_get"
  ; description =
      "Retrieve the full planning context for a task as markdown (plan, notes, \
       deliverable). Use when loading task context into your working memory before \
       starting work. After masc_plan_init; omit task_id if masc_plan_set_task was \
       called."
  ; parameters =
      [ { p_name = "task_id"
        ; p_type = T_string { enum = None; default = None }
        ; p_description = "Task ID (optional if current task is set)"
        ; p_required = false
        }
      ]
  ; additional_properties = false
  ; behavior_contract = []
  }
;;

let masc_plan_set_task_spec : tool_spec =
  { name = "masc_plan_set_task"
  ; description =
      "Set the current task for your session so you can omit task_id in subsequent \
       planning calls. Use when starting work on a task after claiming it. After \
       keeper_task_claim; auto-cleared on session end."
  ; parameters =
      [ { p_name = "task_id"
        ; p_type = T_string { enum = None; default = None }
        ; p_description = "Task ID to set as current"
        ; p_required = true
        }
      ]
  ; additional_properties = false
  ; behavior_contract = []
  }
;;

let masc_plan_get_task_spec : tool_spec =
  { name = "masc_plan_get_task"
  ; description =
      "Get the task_id you're currently working on (session-scoped). Use when resuming \
       work after a context switch or verifying your current assignment. Set via \
       masc_plan_set_task. Auto-cleared on session end."
  ; parameters = []
  ; additional_properties = false
  ; behavior_contract = []
  }
;;

let masc_plan_clear_task_spec : tool_spec =
  { name = "masc_plan_clear_task"
  ; description =
      "Clear your current task assignment without completing it (does not change task \
       status). Use when switching to a different task, abandoning work, or resetting \
       session state. Use masc_transition to change task status separately."
  ; parameters = []
  ; additional_properties = false
  ; behavior_contract = []
  }
;;

let masc_note_add_spec : tool_spec =
  { name = "masc_note_add"
  ; description =
      "Add a note/observation to the planning context. Notes are timestamped and \
       appended."
  ; parameters =
      [ { p_name = "task_id"
        ; p_type = T_string { enum = None; default = None }
        ; p_description = "Task ID"
        ; p_required = true
        }
      ; { p_name = "note"
        ; p_type = T_string { enum = None; default = None }
        ; p_description = "Note content"
        ; p_required = true
        }
      ]
  ; additional_properties = false
  ; behavior_contract = []
  }
;;

let masc_deliver_spec : tool_spec =
  { name = "masc_deliver"
  ; description =
      "Attach final output/result to a task for handoff or review. Use for: code diffs, \
       PR URLs, analysis reports, generated files. Deliverables persist with task and \
       are visible to other agents. Call before masc_transition(action='done'). Example: \
       masc_deliver({task_id: 'task-001', content: 'PR: github.com/org/repo/pull/123'})"
  ; parameters =
      [ { p_name = "task_id"
        ; p_type = T_string { enum = None; default = None }
        ; p_description = "Task ID"
        ; p_required = true
        }
      ; { p_name = "content"
        ; p_type = T_string { enum = None; default = None }
        ; p_description = "Deliverable content"
        ; p_required = true
        }
      ]
  ; additional_properties = false
  ; behavior_contract = []
  }
;;

(* === PR-2d: inline_workspace group (6 tools) === *)

let masc_start_spec : tool_spec =
  { name = "masc_start"
  ; description =
      "One-step onboarding: sets the active project root, joins as agent, and \
       optionally creates+claims a task."
  ; parameters =
      [ { p_name = "path"
        ; p_type = T_string { enum = None; default = None }
        ; p_description =
            "Project directory path (absolute, relative, or ~/...). Omit if the active \
             project scope is already set."
        ; p_required = false
        }
      ; { p_name = "task_title"
        ; p_type = T_string { enum = None; default = None }
        ; p_description =
            "If provided, creates a task with this title, claims it, and sets it as \
             current_task. Omit to just join without a task."
        ; p_required = false
        }
      ]
  ; additional_properties = false
  ; behavior_contract = []
  }
;;

let masc_broadcast_spec : tool_spec =
  { name = "masc_broadcast"
  ; description =
      "Send a message visible to ALL agents via SSE push."
  ; parameters =
      [ { p_name = "agent_name"
        ; p_type = T_string { enum = None; default = None }
        ; p_description = "Your agent name"
        ; p_required = true
        }
      ; { p_name = "message"
        ; p_type = T_string { enum = None; default = None }
        ; p_description = "Message content (use @mention for specific agents)"
        ; p_required = true
        }
      ]
  ; additional_properties = false
  ; behavior_contract =
      [ Precede_with [ "masc_status" ]
      ; Hint Mention_specific_agent
      ; Hint Update_status
      ; Hint Help_request
      ]
  }
;;

let masc_messages_spec : tool_spec =
  { name = "masc_messages"
  ; description =
      "Get recent broadcast messages from all agents. Use to: catch up after joining, \
       check if someone @mentioned you, see project activity. Returns chronological \
       list with sender, timestamp, content. Default: last 20 messages. Use limit \
       param for more/less. Tip: Search for '@your-name' in results to find mentions."
  ; parameters =
      [ { p_name = "since_seq"
        ; p_type = T_int { min = None; max = None; default = Some 0 }
        ; p_description = "Get messages after this sequence number"
        ; p_required = false
        }
      ; { p_name = "limit"
        ; p_type = T_int { min = None; max = None; default = Some 10 }
        ; p_description = "Max messages to return"
        ; p_required = false
        }
      ]
  ; additional_properties = false
  ; behavior_contract = []
  }
;;

let phase6_specs : tool_spec list =
  [ masc_config_spec
  ; masc_tool_help_spec
  ; masc_dashboard_spec
  ; masc_keeper_waiting_inventory_spec
  ; masc_gc_spec
  ; masc_tool_stats_spec
  ; masc_cleanup_zombies_spec
    (* PR-2: plan group *)
  ; masc_plan_init_spec
  ; masc_plan_update_spec
  ; masc_plan_get_spec
  ; masc_plan_set_task_spec
  ; masc_plan_get_task_spec
  ; masc_plan_clear_task_spec
  ; masc_note_add_spec
  ; masc_deliver_spec
    (* PR-2d: inline_workspace group *)
  ; masc_start_spec
  ; masc_broadcast_spec
  ; masc_messages_spec
  ]
;;

(* === Emit helpers ==================================================== *)

let buf_addf buf fmt = Printf.ksprintf (Buffer.add_string buf) fmt

let emit_header buf =
  Buffer.add_string
    buf
    "(* GENERATED - DO NOT EDIT.\n\
    \   Source: bin/gen_tool_descriptors.ml (RFC-0057 Phase 1).\n\
    \   To regenerate: dune build *)\n\n\
     open Masc_domain\n\n"
;;

let rec emit_yojson_ocaml (v : Yojson.Safe.t) : string =
  match v with
  | `Null -> "`Null"
  | `Bool b -> Printf.sprintf "`Bool %b" b
  | `Int i -> Printf.sprintf "`Int %d" i
  | `Float f -> Printf.sprintf "`Float %f" f
  | `String s -> Printf.sprintf "`String %S" s
  | `Intlit s -> Printf.sprintf "`Intlit %S" s
  | `Assoc pairs ->
    let items =
      List.map (fun (k, v) -> Printf.sprintf "(%S, %s)" k (emit_yojson_ocaml v)) pairs
    in
    Printf.sprintf "`Assoc [%s]" (String.concat "; " items)
  | `List items ->
    Printf.sprintf "`List [%s]" (String.concat "; " (List.map emit_yojson_ocaml items))
;;

let emit_enum_list buf strings =
  Buffer.add_string buf "`List [";
  List.iteri
    (fun i s ->
       if i > 0 then Buffer.add_string buf "; ";
       buf_addf buf "`String %S" s)
    strings;
  Buffer.add_string buf "]"
;;

let emit_param_property buf p =
  let type_label =
    match p.p_type with
    | T_string _ -> "string"
    | T_int _ -> "integer"
    | T_bool _ -> "boolean"
    | T_string_array _ -> "array"
    | T_object _ -> "object"
  in
  buf_addf buf "        (%S, `Assoc [\n" p.p_name;
  buf_addf buf "          (\"type\", `String %S);\n" type_label;
  (match p.p_type with
   | T_string { enum = Some strings; _ } ->
     Buffer.add_string buf "          (\"enum\", ";
     emit_enum_list buf strings;
     Buffer.add_string buf ");\n"
   | T_string_array _ ->
     Buffer.add_string buf "          (\"items\", `Assoc [ (\"type\", `String \"string\") ]);\n"
   | _ -> ());
  buf_addf buf "          (\"description\", `String %S);\n" p.p_description;
  (match p.p_type with
   | T_string { default = Some d; _ } ->
     buf_addf buf "          (\"default\", `String %S);\n" d
   | T_int { default = Some d; _ } -> buf_addf buf "          (\"default\", `Int %d);\n" d
   | T_bool { default = Some d; _ } ->
     buf_addf buf "          (\"default\", `Bool %b);\n" d
   | T_string_array { default = Some d } ->
     buf_addf buf "          (\"default\", %s);\n" (emit_yojson_ocaml d)
   | T_object { default = Some d } ->
     buf_addf buf "          (\"default\", %s);\n" (emit_yojson_ocaml d)
   | _ -> ());
  (match p.p_type with
   | T_int { min = Some m; _ } -> buf_addf buf "          (\"minimum\", `Int %d);\n" m
   | _ -> ());
  (match p.p_type with
   | T_int { max = Some m; _ } -> buf_addf buf "          (\"maximum\", `Int %d);\n" m
   | _ -> ());
  Buffer.add_string buf "        ]);\n"
;;

let emit_required buf params =
  let req =
    List.filter_map (fun p -> if p.p_required then Some p.p_name else None) params
  in
  match req with
  | [] -> ()
  | _ ->
    Buffer.add_string buf "      (\"required\", `List [";
    List.iteri
      (fun i name ->
         if i > 0 then Buffer.add_string buf "; ";
         buf_addf buf "`String %S" name)
      req;
    Buffer.add_string buf "]);\n"
;;

(* Issue #15257 C축 — typed behavior rules를 description 본문 자연어로 inline.
   Claude Code BashTool/prompt.ts 패턴과 동일 (행동 규칙은 description에).
   exhaustive match라 새 variant 추가 시 컴파일러가 prose 표현도 강제. *)
let format_behavior_rule = function
  | Precede_with [ t ] ->
    Printf.sprintf "Call `%s` first to verify state before invoking this tool." t
  | Precede_with tools ->
    let names = String.concat ", " (List.map (Printf.sprintf "`%s`") tools) in
    Printf.sprintf "Call one of %s first to verify state." names
  | Hint Mention_specific_agent ->
    "Use `@agent_name` syntax to ping a specific agent."
  | Hint Update_status ->
    "Use for status updates (e.g. starting/done/blocker)."
  | Hint Help_request ->
    "Use to request help or review from another agent."
;;

let format_behavior_contract = function
  | [] -> ""
  | rules ->
    let bullets = List.map (Printf.sprintf "- %s") (List.map format_behavior_rule rules) in
    "\n\nUsage rules:\n" ^ String.concat "\n" bullets
;;

let emit_tool_schema_record buf spec =
  Buffer.add_string buf "  {\n";
  buf_addf buf "    name = %S;\n" spec.name;
  buf_addf
    buf
    "    description = %S;\n"
    (spec.description ^ format_behavior_contract spec.behavior_contract);
  Buffer.add_string buf "    input_schema = `Assoc [\n";
  Buffer.add_string buf "      (\"type\", `String \"object\");\n";
  (match spec.parameters with
   | [] -> Buffer.add_string buf "      (\"properties\", `Assoc []);\n"
   | params ->
     Buffer.add_string buf "      (\"properties\", `Assoc [\n";
     List.iter (emit_param_property buf) params;
     Buffer.add_string buf "      ]);\n");
  emit_required buf spec.parameters;
  buf_addf buf "      (\"additionalProperties\", `Bool %b);\n" spec.additional_properties;
  Buffer.add_string buf "    ];\n";
  Buffer.add_string buf "  }"
;;

let emit_tool_schema buf spec =
  emit_tool_schema_record buf spec;
  Buffer.add_string buf ";\n"
;;

let emit_named_tool_schema buf binding spec =
  buf_addf buf "let %s : tool_schema =\n" binding;
  emit_tool_schema_record buf spec;
  Buffer.add_string buf "\n;;\n\n"
;;

let emit_schemas_list buf specs =
  Buffer.add_string buf "let schemas : tool_schema list = [\n";
  List.iter (emit_tool_schema buf) specs;
  Buffer.add_string buf "]\n"
;;

(* === Entry point ===================================================== *)

let () =
  let buf = Buffer.create 4096 in
  emit_header buf;
  emit_named_tool_schema buf "masc_pause_schema" masc_pause_spec;
  emit_named_tool_schema buf "masc_resume_schema" masc_resume_spec;
  emit_schemas_list buf phase6_specs;
  print_string (Buffer.contents buf)
;;
