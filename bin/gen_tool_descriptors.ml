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

let admin_section_enum_strings = [ "auth" ]
;;

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
  }
;;

let masc_code_read_spec : tool_spec =
  { name = "masc_code_read"
  ; description =
      "Read a file with offset/limit pagination for large files. Use when inspecting \
       source code during task execution without loading the entire file into context."
  ; parameters =
      [ { p_name = "path"
        ; p_type = T_string { enum = None; default = None }
        ; p_description = "Absolute file path"
        ; p_required = true
        }
      ; { p_name = "offset"
        ; p_type = T_int { min = Some 0; max = None; default = None }
        ; p_description = "Offset in bytes (default 0)"
        ; p_required = false
        }
      ; { p_name = "limit"
        ; p_type = T_int { min = Some 1; max = Some 1_000_000; default = None }
        ; p_description = "Maximum bytes to read (default 1_000_000)"
        ; p_required = false
        }
      ]
  ; additional_properties = false
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
  }
;;

let dashboard_scope_enum_strings = [ "all"; "current" ]

let masc_dashboard_spec : tool_spec =
  { name = "masc_dashboard"
  ; description =
      "Render the MASC dashboard summarizing rooms, agents, and tasks. Set \
       scope='current' for this room only."
  ; parameters =
      [ { p_name = "compact"
        ; p_type = T_bool { default = None }
        ; p_description =
            "If true, show compact single-line summary instead of full dashboard"
        ; p_required = false
        }
      ; { p_name = "scope"
        ; p_type =
            T_string { enum = Some dashboard_scope_enum_strings; default = Some "all" }
        ; p_description = "Dashboard scope (default: all)"
        ; p_required = false
        }
      ]
  ; additional_properties = false
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
  }
;;

let masc_web_search_spec : tool_spec =
  { name = "masc_web_search"
  ; description =
      "Search the public web and return top result titles, URLs, and snippets. Read-only \
       helper for current-information lookups before deeper file or repo work. Uses \
       configured web-search providers with structured fallback behavior and returns \
       structured JSON."
  ; parameters =
      [ { p_name = "query"
        ; p_type = T_string { enum = None; default = None }
        ; p_description = "Search query text"
        ; p_required = true
        }
      ; { p_name = "limit"
        ; p_type = T_int { min = Some 1; max = Some 10; default = Some 5 }
        ; p_description = "Maximum number of results to return (default 5, max 10)"
        ; p_required = false
        }
      ]
  ; additional_properties = false
  }
;;

let masc_web_fetch_spec : tool_spec =
  { name = "masc_web_fetch"
  ; description =
      "Fetch a web page by URL and return cleaned text content. Read-only helper for \
       reading selected sources after web search before citing them. Strips HTML tags, \
       decodes entities, normalizes whitespace, and optionally extracts <title> and \
       <meta name=\"description\">. Returns structured JSON with the cleaned text."
  ; parameters =
      [ { p_name = "url"
        ; p_type = T_string { enum = None; default = None }
        ; p_description = "URL to fetch (http or https only)"
        ; p_required = true
        }
      ; { p_name = "timeout"
        ; p_type = T_int { min = Some 1; max = Some 60; default = Some 15 }
        ; p_description = "Request timeout in seconds (default 15, max 60)"
        ; p_required = false
        }
      ]
  ; additional_properties = false
  }
;;

let masc_tool_admin_snapshot_spec : tool_spec =
  { name = "masc_tool_admin_snapshot"
  ; description =
      "Return a unified admin snapshot of tool inventory, auth/RBAC, and command-plane \
       surfaces."
  ; parameters =
      [ { p_name = "include_hidden"
        ; p_type = T_bool { default = Some true }
        ; p_description = "Include hidden tools in tool_inventory (default: true)"
        ; p_required = false
        }
      ; { p_name = "include_deprecated"
        ; p_type = T_bool { default = Some true }
        ; p_description = "Include deprecated tools in tool_inventory (default: true)"
        ; p_required = false
        }
      ]
  ; additional_properties = false
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
  }
;;

let masc_cleanup_zombies_spec : tool_spec =
  { name = "masc_cleanup_zombies"
  ; description =
      "Remove zombie agents (no heartbeat for 5+ min) and release their file locks."
  ; parameters = []
  ; additional_properties = false
  }
;;

let masc_webrtc_offer_spec : tool_spec =
  { name = "masc_webrtc_offer"
  ; description =
      "Create a WebRTC signaling offer in the server registry and return an offer_id. \
       Use from the initiating side before calling masc_webrtc_answer from the \
       answering side."
  ; parameters =
      [ { p_name = "agent_name"
        ; p_type = T_string { enum = None; default = None }
        ; p_description = "Name of the agent creating the offer"
        ; p_required = true
        }
      ; { p_name = "ice_candidates"
        ; p_type = T_string_array { default = Some (`List []) }
        ; p_description = "ICE candidates gathered by the offering peer"
        ; p_required = false
        }
      ; { p_name = "dtls_fingerprint"
        ; p_type = T_string { enum = None; default = None }
        ; p_description = "Optional DTLS fingerprint for the offering peer"
        ; p_required = false
        }
      ]
  ; additional_properties = false
  }
;;

let masc_webrtc_answer_spec : tool_spec =
  { name = "masc_webrtc_answer"
  ; description =
      "Accept a pending WebRTC signaling offer by offer_id and return the peer_id plus \
       server-side ICE credentials. Use from the answering side after a prior \
       masc_webrtc_offer call."
  ; parameters =
      [ { p_name = "offer_id"
        ; p_type = T_string { enum = None; default = None }
        ; p_description = "Offer identifier returned by masc_webrtc_offer"
        ; p_required = true
        }
      ; { p_name = "agent_name"
        ; p_type = T_string { enum = None; default = None }
        ; p_description = "Name of the agent accepting the offer"
        ; p_required = true
        }
      ; { p_name = "ice_candidates"
        ; p_type = T_string_array { default = Some (`List []) }
        ; p_description = "Optional ICE candidates gathered by the answering peer"
        ; p_required = false
        }
      ]
  ; additional_properties = false
  }
;;

let masc_tool_admin_update_spec : tool_spec =
  { name = "masc_tool_admin_update"
  ; description =
      "Apply auth updates through a single admin entrypoint. Use after \
       masc_tool_admin_snapshot to review current state before making changes. \
       Additional sections (unit_policy, keeper_policy) are not yet implemented and \
       will be added here when their handlers land."
  ; parameters =
      [ { p_name = "section"
        ; p_type = T_string { enum = Some admin_section_enum_strings; default = None }
        ; p_description = "Config section to update (currently only auth is implemented)"
        ; p_required = true
        }
      ; { p_name = "enabled"
        ; p_type = T_bool { default = None }
        ; p_description = "Enable or disable auth for section=auth"
        ; p_required = false
        }
      ; { p_name = "require_token"
        ; p_type = T_bool { default = None }
        ; p_description = "Require tokens for section=auth"
        ; p_required = false
        }
      ; { p_name = "token_expiry_hours"
        ; p_type = T_int { min = None; max = None; default = None }
        ; p_description = "Token expiry in hours for section=auth"
        ; p_required = false
        }
      ; { p_name = "unit_id"
        ; p_type = T_string { enum = None; default = None }
        ; p_description = "Managed unit id for section=unit_policy"
        ; p_required = false
        }
      ; { p_name = "policy"
        ; p_type = T_object { default = None }
        ; p_description = "Unit policy envelope for section=unit_policy"
        ; p_required = false
        }
      ; { p_name = "budget"
        ; p_type = T_object { default = None }
        ; p_description = "Unit budget envelope for section=unit_policy"
        ; p_required = false
        }
      ]
  ; additional_properties = false
  }
;;

let masc_pause_spec : tool_spec =
  { name = "masc_pause"
  ; description =
      "Pause the server. Stops orchestrator from spawning new agents. Broadcasts \
       notification to all agents. Use when you need to stop automated work temporarily."
  ; parameters =
      [ { p_name = "reason"
        ; p_type = T_string { enum = None; default = Some "Manual pause" }
        ; p_description =
            "Reason for pausing (e.g., 'Need to review', 'Taking a break')"
        ; p_required = false
        }
      ]
  ; additional_properties = false
  }
;;

let masc_resume_spec : tool_spec =
  { name = "masc_resume"
  ; description =
      "Resume the server after pause. Allows orchestrator to spawn agents again. \
       Broadcasts notification to all agents."
  ; parameters = []
  ; additional_properties = false
  }
;;

(* === PR-2: plan group (8 tools) === *)

let masc_plan_init_spec : tool_spec =
  { name = "masc_plan_init"
  ; description =
      "Initialize a planning context for a task, creating task_plan.md, notes.md, and \
       deliverable.md structure. Use when starting structured work on a claimed task \
       that needs planning artifacts. After masc_claim_next or masc_add_task; follow up \
       with masc_plan_update to write the plan."
  ; parameters =
      [ { p_name = "task_id"
        ; p_type = T_string { enum = None; default = None }
        ; p_description = "Task ID to create planning context for"
        ; p_required = true
        }
      ]
  ; additional_properties = false
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
  }
;;

let masc_plan_set_task_spec : tool_spec =
  { name = "masc_plan_set_task"
  ; description =
      "Set the current task for your session so you can omit task_id in subsequent \
       planning calls. Use when starting work on a task after claiming it. After \
       masc_claim_next; auto-cleared on masc_leave."
  ; parameters =
      [ { p_name = "task_id"
        ; p_type = T_string { enum = None; default = None }
        ; p_description = "Task ID to set as current"
        ; p_required = true
        }
      ]
  ; additional_properties = false
  }
;;

let masc_plan_get_task_spec : tool_spec =
  { name = "masc_plan_get_task"
  ; description =
      "Get the task_id you're currently working on (session-scoped). Use when resuming \
       work after a context switch or verifying your current assignment. Set via \
       masc_plan_set_task. Auto-cleared on masc_leave."
  ; parameters = []
  ; additional_properties = false
  }
;;

let masc_plan_clear_task_spec : tool_spec =
  { name = "masc_plan_clear_task"
  ; description =
      "Clear your current task assignment without completing it (does not change task \
       status). Use when switching to a different task, abandoning work, or resetting \
       session state. Use masc_transition to change task status separately. Auto-called \
       on masc_leave."
  ; parameters = []
  ; additional_properties = false
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
  }
;;

(* === PR-2c: inline_infra group (3 of 4 tools — masc_mcp_session
   deferred because enum SSOT is locked to Tool_schemas_inline_infra
   by test_types.ml :: mcp_session_action_ssot. Codegen needs a
   shared enum source RFC before that can swap.) === *)

let masc_approval_pending_spec : tool_spec =
  { name = "masc_approval_pending"
  ; description =
      "Keeper-safe read-only view of the pending HITL approval queue. Use this to \
       detect whether any approvals are waiting before asking an operator or using an \
       admin-only detail/resolve path."
  ; parameters = []
  ; additional_properties = false
  }
;;

let masc_approval_get_spec : tool_spec =
  { name = "masc_approval_get"
  ; description =
      "Operator/admin-only detail view. Fetch one pending HITL approval by id, \
       including the full input JSON. Use after finding an approval id in the \
       dashboard or pending approval queue when the preview is insufficient for an \
       operator decision. Requires the same privileged approval surface as resolving \
       an approval."
  ; parameters =
      [ { p_name = "id"
        ; p_type = T_string { enum = None; default = None }
        ; p_description = "Pending approval id, for example appr_abc123def456"
        ; p_required = true
        }
      ]
  ; additional_properties = false
  }
;;

let masc_spawn_spec : tool_spec =
  { name = "masc_spawn"
  ; description =
      "Spawn an agent process (claude, gemini, codex, or llama) to execute a task. \
       Use when you need another agent to work in parallel on a subtask. For llama, \
       provide model explicitly. Pair with masc_add_task to create the task first."
  ; parameters =
      [ { p_name = "agent_name"
        ; p_type = T_string { enum = None; default = None }
        ; p_description = "Agent to spawn: 'claude', 'gemini', 'codex', or custom command"
        ; p_required = true
        }
      ; { p_name = "model"
        ; p_type = T_string { enum = None; default = None }
        ; p_description = "Explicit model id. Required when agent_name='llama'."
        ; p_required = false
        }
      ; { p_name = "prompt"
        ; p_type = T_string { enum = None; default = None }
        ; p_description = "The task/prompt to send to the agent"
        ; p_required = true
        }
      ; { p_name = "timeout_seconds"
        ; p_type = T_int { min = None; max = None; default = Some 300 }
        ; p_description = "Max execution time in seconds (default: 300)"
        ; p_required = false
        }
      ; { p_name = "working_dir"
        ; p_type = T_string { enum = None; default = None }
        ; p_description = "Working directory for the agent (optional)"
        ; p_required = false
        }
      ]
  ; additional_properties = false
  }
;;

(* === PR-2d: inline_coord group (6 tools) === *)

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
  }
;;

let masc_join_spec : tool_spec =
  { name = "masc_join"
  ; description =
      "Join the active MASC project as agent_name to collaborate with other AI agents. \
       Call at session start or to re-register presence. Other agents can @mention \
       you. Check masc_status after joining to see active agents and available tasks."
  ; parameters =
      [ { p_name = "agent_name"
        ; p_type = T_string { enum = None; default = None }
        ; p_description = "Your identity: 'claude', 'gemini', or 'codex'"
        ; p_required = true
        }
      ; { p_name = "capabilities"
        ; p_type = T_string_array { default = None }
        ; p_description =
            "Your strengths (e.g., ['typescript', 'code-review', 'testing'])"
        ; p_required = false
        }
      ]
  ; additional_properties = false
  }
;;

let masc_leave_spec : tool_spec =
  { name = "masc_leave"
  ; description =
      "Leave the active MASC project and mark yourself as offline. Call when: (1) \
       session ends, (2) switching projects, (3) work complete. Side effects: releases \
       all your locks, sets presence to offline. Other agents will see you've left via \
       SSE. Example: masc_leave({agent_name: 'claude-xyz'})"
  ; parameters =
      [ { p_name = "agent_name"
        ; p_type = T_string { enum = None; default = None }
        ; p_description = "Your agent name"
        ; p_required = true
        }
      ]
  ; additional_properties = false
  }
;;

let masc_broadcast_spec : tool_spec =
  { name = "masc_broadcast"
  ; description =
      "Send a message visible to ALL agents via SSE push. Use for: status updates \
       ('Starting task X'), help requests ('@gemini can you review this?'), \
       completions. Use @agent_name to ping specific agent."
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
  }
;;

let masc_who_spec : tool_spec =
  { name = "masc_who"
  ; description =
      "List all agents currently in the active project with their capabilities. \
       Shows: agent name, join time, capabilities (e.g., ['typescript', 'testing']). \
       Use to: find who can help, check if specific agent is online, see team \
       composition. Agents appear after masc_join, disappear after masc_leave. Tip: \
       Use capabilities to find the right agent for @mentions."
  ; parameters = []
  ; additional_properties = false
  }
;;

let phase6_specs : tool_spec list =
  [ masc_config_spec
  ; masc_code_read_spec
  ; masc_tool_help_spec
  ; masc_dashboard_spec
  ; masc_gc_spec
  ; masc_web_search_spec
  ; masc_web_fetch_spec
  ; masc_tool_admin_snapshot_spec
  ; masc_tool_stats_spec
  ; masc_cleanup_zombies_spec
  ; masc_webrtc_offer_spec
  ; masc_webrtc_answer_spec
  ; masc_tool_admin_update_spec
    (* PR-1 (paving stone): control group *)
  ; masc_pause_spec
  ; masc_resume_spec
    (* PR-2: plan group *)
  ; masc_plan_init_spec
  ; masc_plan_update_spec
  ; masc_plan_get_spec
  ; masc_plan_set_task_spec
  ; masc_plan_get_task_spec
  ; masc_plan_clear_task_spec
  ; masc_note_add_spec
  ; masc_deliver_spec
    (* PR-2c: inline_infra (3 of 4 — masc_mcp_session deferred) *)
  ; masc_approval_pending_spec
  ; masc_approval_get_spec
  ; masc_spawn_spec
    (* PR-2d: inline_coord group *)
  ; masc_start_spec
  ; masc_join_spec
  ; masc_leave_spec
  ; masc_broadcast_spec
  ; masc_messages_spec
  ; masc_who_spec
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

let emit_tool_schema buf spec =
  Buffer.add_string buf "  {\n";
  buf_addf buf "    name = %S;\n" spec.name;
  buf_addf buf "    description = %S;\n" spec.description;
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
  Buffer.add_string buf "  };\n"
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
  emit_schemas_list buf phase6_specs;
  print_string (Buffer.contents buf)
;;
