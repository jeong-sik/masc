(** Agent-facing tool descriptor spine. *)

type executor =
  | Shell_ir
  | Filesystem
  | Remote_mcp
  | In_process

type backend =
  | Ocaml_runtime
  | Host_process
  | Sandbox_process
  | Remote_service

type sandbox =
  | No_sandbox
  | Host_allowed_paths
  | Turn_sandbox
  | Docker_profile
  | Backend_selected

type approval =
  | No_approval
  | Policy_selected
  | Human_required

type runtime_handler =
  | Tool_execute
  | Tool_workspace_inspect
  | Tool_read_file
  | Tool_edit_file
  | Tool_write_file
  | Tool_remote_mcp
  | Tool_time_now
  | Tool_stay_silent
  | Tool_tools_list
  | Tool_tool_search
  | Tool_context_status
  | Tool_memory_search
  | Tool_memory_write
  | Tool_library_search
  | Tool_library_read
  | Tool_ide_annotate
  | Tool_voice_dispatch
  | Tool_task_dispatch
  | Tool_board_dispatch
  | Tool_masc_board_dispatch
  | Tool_masc_task_dispatch
  | Tool_masc_plan_dispatch
  | Tool_masc_run_dispatch
  | Tool_masc_agent_dispatch
  | Tool_masc_coord_dispatch
  | Tool_masc_misc_dispatch
  | Tool_masc_control_dispatch
  | Tool_masc_agent_timeline_dispatch
  | Tool_masc_local_runtime_dispatch

type policy =
  { visibility : Tool_catalog.visibility
  ; readonly : bool option
  ; effect_domain : Tool_catalog.effect_domain option
  ; approval : approval
  ; retryable : bool
  ; cwd_scope : string option
  ; credential_profile : string option
  }

type t =
  { id : string
  ; public_name : string
  ; internal_name : string
  ; description : string
  ; input_schema : Yojson.Safe.t
  ; policy : policy
  ; executor : executor
  ; backend : backend
  ; sandbox : sandbox
  ; runtime_handler : runtime_handler
  ; translate : Yojson.Safe.t -> Yojson.Safe.t
  ; receipt_labels : (string * string) list
  }

let executor_to_string = function
  | Shell_ir -> "shell_ir"
  | Filesystem -> "filesystem"
  | Remote_mcp -> "remote_mcp"
  | In_process -> "in_process"
;;

let backend_to_string = function
  | Ocaml_runtime -> "ocaml_runtime"
  | Host_process -> "host_process"
  | Sandbox_process -> "sandbox_process"
  | Remote_service -> "remote_service"
;;

let sandbox_to_string = function
  | No_sandbox -> "none"
  | Host_allowed_paths -> "host_allowed_paths"
  | Turn_sandbox -> "turn_sandbox"
  | Docker_profile -> "docker_profile"
  | Backend_selected -> "backend_selected"
;;

let approval_to_string = function
  | No_approval -> "none"
  | Policy_selected -> "policy_selected"
  | Human_required -> "human_required"
;;

let runtime_handler_to_string = function
  | Tool_execute -> "tool_execute"
  | Tool_workspace_inspect -> "tool_workspace_inspect"
  | Tool_read_file -> "tool_read_file"
  | Tool_edit_file -> "tool_edit_file"
  | Tool_write_file -> "tool_write_file"
  | Tool_remote_mcp -> "tool_remote_mcp"
  | Tool_time_now -> "tool_time_now"
  | Tool_stay_silent -> "tool_stay_silent"
  | Tool_tools_list -> "tool_tools_list"
  | Tool_tool_search -> "tool_tool_search"
  | Tool_context_status -> "tool_context_status"
  | Tool_memory_search -> "tool_memory_search"
  | Tool_memory_write -> "tool_memory_write"
  | Tool_library_search -> "tool_library_search"
  | Tool_library_read -> "tool_library_read"
  | Tool_ide_annotate -> "tool_ide_annotate"
  | Tool_voice_dispatch -> "tool_voice_dispatch"
  | Tool_task_dispatch -> "tool_task_dispatch"
  | Tool_board_dispatch -> "tool_board_dispatch"
  | Tool_masc_board_dispatch -> "tool_masc_board_dispatch"
  | Tool_masc_task_dispatch -> "tool_masc_task_dispatch"
  | Tool_masc_plan_dispatch -> "tool_masc_plan_dispatch"
  | Tool_masc_run_dispatch -> "tool_masc_run_dispatch"
  | Tool_masc_agent_dispatch -> "tool_masc_agent_dispatch"
  | Tool_masc_coord_dispatch -> "tool_masc_coord_dispatch"
  | Tool_masc_misc_dispatch -> "tool_masc_misc_dispatch"
  | Tool_masc_control_dispatch -> "tool_masc_control_dispatch"
  | Tool_masc_agent_timeline_dispatch -> "tool_masc_agent_timeline_dispatch"
  | Tool_masc_local_runtime_dispatch -> "tool_masc_local_runtime_dispatch"
;;

let policy ?(visibility = Tool_catalog.Default) ?readonly ?effect_domain
      ?(approval = Policy_selected) ?cwd_scope ?credential_profile
      ?(retryable = false) ()
  =
  { visibility
  ; readonly
  ; effect_domain
  ; approval
  ; retryable
  ; cwd_scope
  ; credential_profile
  }
;;

let property name typ description =
  name, `Assoc [ "type", `String typ; "description", `String description ]
;;

let object_schema ?(required = []) properties =
  `Assoc
    [ "type", `String "object"
    ; "properties", `Assoc properties
    ; "required", `List (List.map (fun n -> `String n) required)
    ]
;;

let execute_schema = Tool_shard_types_schemas_bash.tool_execute_schema.input_schema

let read_file_schema =
  object_schema
    ~required:[ "file_path" ]
    [ property "file_path" "string" "Absolute or sandbox-relative file path to read."
    ; property
        "limit"
        "integer"
        "Approximate maximum bytes to return. Line offsets are not supported."
    ]
;;

let edit_file_schema =
  object_schema
    ~required:[ "file_path"; "old_string"; "new_string" ]
    [ property
        "file_path"
        "string"
        "Absolute or sandbox-relative file path to edit. The file must exist."
    ; property
        "old_string"
        "string"
        "Exact substring to replace. Must occur exactly once unless replace_all=true."
    ; property
        "new_string"
        "string"
        "Replacement substring. Pass an empty string to delete old_string."
    ; property
        "replace_all"
        "boolean"
        "Default false. When true, replaces every occurrence of old_string."
    ]
;;

let write_file_schema =
  object_schema
    ~required:[ "file_path"; "content" ]
    [ property
        "file_path"
        "string"
        "Absolute or sandbox-relative file path. Parent directories are created as needed."
    ; property "content" "string" "Full file content. Overwrites the existing file."
    ]
;;

let search_files_schema =
  object_schema
    ~required:[ "pattern" ]
    [ property "pattern" "string" "Regular expression to search for."
    ; property
        "path"
        "string"
        "Directory or file to search in. Defaults to the keeper sandbox when omitted."
    ; property "glob" "string" "Glob filter, e.g. '*.ml' or 'lib/**/*.ml'."
    ; property "type" "string" "Ripgrep file-type filter, e.g. 'ml', 'py'."
    ; property "-i" "boolean" "Case-insensitive search."
    ]
;;

let search_web_schema =
  object_schema
    ~required:[ "query" ]
    [ property "query" "string" "Search query text for current public web information."
    ; property "limit" "integer" "Maximum number of results to return."
    ]
;;

let fetch_web_schema =
  object_schema
    ~required:[ "url" ]
    [ property "url" "string" "URL to fetch."
    ; property "timeout" "integer" "Request timeout in seconds."
    ]
;;

let translate_identity input = input

let translate_read_file input =
  match input with
  | `Assoc fields ->
    let out = ref [] in
    List.iter
      (fun (k, v) ->
         match k with
         | "file_path" -> out := ("path", v) :: !out
         | "limit" -> out := ("max_bytes", v) :: !out
         | _ -> out := (k, v) :: !out)
      fields;
    `Assoc (List.rev !out)
  | _ -> input
;;

let translate_edit_file input =
  match input with
  | `Assoc fields ->
    let has_content = List.exists (fun (k, _) -> k = "content") fields in
    let mode = if has_content then "overwrite" else "patch" in
    let out = ref [ "mode", `String mode ] in
    List.iter
      (fun (k, v) ->
         match k with
         | "file_path" -> out := ("path", v) :: !out
         | "old_string" | "new_string" | "replace_all" | "content" ->
           out := (k, v) :: !out
         | "mode" -> ()
         | _ -> out := (k, v) :: !out)
      fields;
    `Assoc (List.rev !out)
  | _ -> input
;;

let translate_write_file input =
  match input with
  | `Assoc fields ->
    let out = ref [ "mode", `String "overwrite" ] in
    List.iter
      (fun (k, v) ->
         match k with
         | "file_path" -> out := ("path", v) :: !out
         | "content" -> out := ("content", v) :: !out
         | "mode" -> ()
         | _ -> out := (k, v) :: !out)
      fields;
    `Assoc (List.rev !out)
  | _ -> input
;;

let translate_search_files input =
  match input with
  | `Assoc fields ->
    let out = ref [ "op", `String "rg" ] in
    let is_case_insensitive =
      match List.assoc_opt "-i" fields with
      | Some (`Bool true) -> true
      | _ -> false
    in
    List.iter
      (fun (k, v) ->
         match k with
         | "pattern" ->
           let v' =
             if is_case_insensitive
             then (
               match v with
               | `String s -> `String ("(?i)" ^ s)
               | _ -> v)
             else v
           in
           out := (k, v') :: !out
         | "path" | "glob" | "type" -> out := (k, v) :: !out
         | "op" | "-i" -> ()
         | _ -> out := (k, v) :: !out)
      fields;
    `Assoc (List.rev !out)
  | _ -> input
;;

let descriptor ~id ~public_name ~internal_name ~description ~input_schema ~policy
      ~executor ~backend ~sandbox ~runtime_handler ~translate
  =
  let receipt_labels =
    [ "descriptor_id", id
    ; "public_name", public_name
    ; "canonical_name", internal_name
    ; "executor", executor_to_string executor
    ; "backend", backend_to_string backend
    ; "sandbox", sandbox_to_string sandbox
    ; "runtime_handler", runtime_handler_to_string runtime_handler
    ]
  in
  { id
  ; public_name
  ; internal_name
  ; description
  ; input_schema
  ; policy
  ; executor
  ; backend
  ; sandbox
  ; runtime_handler
  ; translate
  ; receipt_labels
  }
;;

let public_descriptors =
  [ descriptor
      ~id:"agent.execute"
      ~public_name:"Execute"
      ~internal_name:"tool_execute"
      ~description:
        "Execute one typed command through deterministic execution gates. Provide \
         executable/argv or pipeline; use cwd for repo-scoped git/gh commands."
      ~input_schema:execute_schema
      ~policy:
        (policy
           ~effect_domain:Tool_catalog.Playground_write
           ~cwd_scope:"keeper_sandbox_or_allowed_path"
           ~retryable:false
           ())
      ~executor:Shell_ir
      ~backend:Sandbox_process
      ~sandbox:Backend_selected
      ~runtime_handler:Tool_execute
      ~translate:translate_identity
  ; descriptor
      ~id:"agent.workspace_inspect"
      ~public_name:"SearchFiles"
      ~internal_name:"tool_workspace_inspect"
      ~description:"Inspect the project workspace through a structured op (ls, cat, find, rg, head, tail, wc, tree, git_status, git_log, git_diff, pwd)."
      ~input_schema:search_files_schema
      ~policy:
        (policy
           ~readonly:true
           ~effect_domain:Tool_catalog.Read_only
           ~cwd_scope:"keeper_sandbox_or_allowed_path"
           ~retryable:true
           ())
      ~executor:Shell_ir
      ~backend:Sandbox_process
      ~sandbox:Backend_selected
      ~runtime_handler:Tool_workspace_inspect
      ~translate:translate_search_files
  ; descriptor
      ~id:"agent.read_file"
      ~public_name:"ReadFile"
      ~internal_name:"tool_read_file"
      ~description:"Read one file from the keeper sandbox or an allowed path."
      ~input_schema:read_file_schema
      ~policy:
        (policy
           ~readonly:true
           ~effect_domain:Tool_catalog.Read_only
           ~cwd_scope:"keeper_sandbox_or_allowed_path"
           ~retryable:true
           ())
      ~executor:Filesystem
      ~backend:Sandbox_process
      ~sandbox:Backend_selected
      ~runtime_handler:Tool_read_file
      ~translate:translate_read_file
  ; descriptor
      ~id:"agent.edit_file"
      ~public_name:"EditFile"
      ~internal_name:"tool_edit_file"
      ~description:"Patch an existing file by replacing an exact string."
      ~input_schema:edit_file_schema
      ~policy:
        (policy
           ~readonly:false
           ~effect_domain:Tool_catalog.Playground_write
           ~cwd_scope:"keeper_sandbox_or_allowed_path"
           ())
      ~executor:Filesystem
      ~backend:Sandbox_process
      ~sandbox:Backend_selected
      ~runtime_handler:Tool_edit_file
      ~translate:translate_edit_file
  ; descriptor
      ~id:"agent.write_file"
      ~public_name:"WriteFile"
      ~internal_name:"tool_write_file"
      ~description:"Write full file content into the keeper sandbox or an allowed path."
      ~input_schema:write_file_schema
      ~policy:
        (policy
           ~readonly:false
           ~effect_domain:Tool_catalog.Playground_write
           ~cwd_scope:"keeper_sandbox_or_allowed_path"
           ())
      ~executor:Filesystem
      ~backend:Sandbox_process
      ~sandbox:Backend_selected
      ~runtime_handler:Tool_write_file
      ~translate:translate_write_file
  ; descriptor
      ~id:"agent.search_web"
      ~public_name:"SearchWeb"
      ~internal_name:"masc_web_search"
      ~description:"Search the public web for current information."
      ~input_schema:search_web_schema
      ~policy:
        (policy
           ~readonly:true
           ~effect_domain:Tool_catalog.Read_only
           ~approval:Policy_selected
           ~retryable:true
           ())
      ~executor:Remote_mcp
      ~backend:Remote_service
      ~sandbox:No_sandbox
      ~runtime_handler:Tool_remote_mcp
      ~translate:translate_identity
  ; descriptor
      ~id:"agent.fetch_web"
      ~public_name:"FetchWeb"
      ~internal_name:"masc_web_fetch"
      ~description:"Fetch a selected web page for source-backed reading."
      ~input_schema:fetch_web_schema
      ~policy:
        (policy
           ~readonly:true
           ~effect_domain:Tool_catalog.Read_only
           ~approval:Policy_selected
           ~retryable:true
           ())
      ~executor:Remote_mcp
      ~backend:Remote_service
      ~sandbox:No_sandbox
      ~runtime_handler:Tool_remote_mcp
      ~translate:translate_identity
  ]
;;

(* RFC-0179 list bifurcation. [internal_descriptors] hosts descriptor-backed
   coordination tools (keeper_* / masc_* clusters). Each cluster migration PR
   adds entries here. The LLM-native [public_descriptors] contract (RFC-0064
   hard-cut, 7 entries) is preserved unchanged.

   RFC-0179 PR-3 (full keeper_* coverage). Every legacy match arm in
   [Keeper_exec_tools.execute_keeper_tool_call_with_outcome] is now backed by
   a descriptor entry below. After this PR the legacy chain is empty modulo
   the trailing remote-MCP fallback. *)

let empty_object_schema =
  `Assoc
    [ "type", `String "object"
    ; "properties", `Assoc []
    ; "additionalProperties", `Bool false
    ]
;;

(* Coordination tools historically dispatched by name in [Keeper_exec_tools]
   without input-schema validation — the underlying handlers (Tool_board,
   Tool_library, Keeper_exec_task, Agent_tool_voice_runtime, etc.) parse
   their own input. The descriptor input_schema is informational only
   (these tools are Hidden visibility; no LLM sees the schema). A
   passthrough object schema preserves behavior. *)
let passthrough_object_schema =
  `Assoc
    [ "type", `String "object"; "additionalProperties", `Bool true ]
;;

let tool_search_schema =
  object_schema
    ~required:[ "query" ]
    [ property "query" "string" "Search query for available keeper tools."
    ; property
        "max_results"
        "integer"
        "Maximum tool schemas to return. Default 5, capped at 10."
    ]
;;

let read_only_in_process_policy () =
  policy
    ~visibility:Tool_catalog.Hidden
    ~readonly:true
    ~effect_domain:Tool_catalog.Read_only
    ~approval:No_approval
    ~retryable:true
    ()
;;

let write_in_process_policy ?(retryable = false) () =
  policy
    ~visibility:Tool_catalog.Hidden
    ~readonly:false
    ~effect_domain:Tool_catalog.Playground_write
    ~approval:No_approval
    ~retryable
    ()
;;

let in_process_descriptor ~id ~name ~description ~input_schema ~policy ~handler =
  descriptor
    ~id
    ~public_name:name
    ~internal_name:name
    ~description
    ~input_schema
    ~policy
    ~executor:In_process
    ~backend:Ocaml_runtime
    ~sandbox:No_sandbox
    ~runtime_handler:handler
    ~translate:translate_identity
;;

(* Cluster-dispatched tools (board / voice / task) share a single
   [runtime_handler] variant but expose distinct [internal_name]s so each
   tool retains its own descriptor entry and receipt evidence. The
   [agent_tool_in_process_runtime] handler routes by descriptor.internal_name. *)
let cluster_descriptor ~id ~name ~description ~handler ~readonly =
  let policy =
    if readonly then read_only_in_process_policy () else write_in_process_policy ()
  in
  in_process_descriptor
    ~id
    ~name
    ~description
    ~input_schema:passthrough_object_schema
    ~policy
    ~handler
;;

let board_descriptor name description ~readonly =
  cluster_descriptor
    ~id:("keeper.board." ^ String.sub name (String.length "keeper_board_")
         (String.length name - String.length "keeper_board_"))
    ~name
    ~description
    ~handler:Tool_board_dispatch
    ~readonly
;;

let masc_board_descriptor (schema : Masc_domain.tool_schema) =
  let name = schema.name in
  let suffix =
    String.sub
      name
      (String.length "masc_board_")
      (String.length name - String.length "masc_board_")
  in
  let metadata = Tool_catalog.metadata name in
  let readonly =
    match metadata.readonly with
    | Some readonly -> readonly
    | None -> List.mem name Tool_board_dispatch.tool_spec_read_only
  in
  let policy =
    policy
      ~visibility:metadata.visibility
      ~readonly
      ?effect_domain:metadata.effect_domain
      ~approval:No_approval
      ~retryable:readonly
      ()
  in
  in_process_descriptor
    ~id:("masc.board." ^ suffix)
    ~name
    ~description:schema.description
    ~input_schema:schema.input_schema
    ~policy
    ~handler:Tool_masc_board_dispatch
;;

let masc_board_descriptors =
  List.map masc_board_descriptor Tool_board_registry.tools
;;

let voice_descriptor name description ~readonly =
  cluster_descriptor
    ~id:("keeper.voice." ^ String.sub name (String.length "keeper_voice_")
         (String.length name - String.length "keeper_voice_"))
    ~name
    ~description
    ~handler:Tool_voice_dispatch
    ~readonly
;;

let task_descriptor id name description ~readonly =
  cluster_descriptor
    ~id:("keeper.task." ^ id)
    ~name
    ~description
    ~handler:Tool_task_dispatch
    ~readonly
;;

(* RFC-0182 §3.1 — additional masc_* cluster descriptor helpers (task /
   plan / run / agent / coord). The masc_board_descriptor lives above
   (registry-driven); these helpers follow the same projection pattern
   but use hardcoded id+description because their dispatchers
   (Tool_task / Tool_plan / Tool_run / Tool_agent / Tool_coord) are not
   schema-registry-backed. The handler routes by descriptor.internal_name
   through the existing typed dispatcher. *)
let masc_task_descriptor id name description ~readonly =
  cluster_descriptor
    ~id:("masc.task." ^ id)
    ~name
    ~description
    ~handler:Tool_masc_task_dispatch
    ~readonly
;;

let masc_plan_descriptor id name description ~readonly =
  cluster_descriptor
    ~id:("masc.plan." ^ id)
    ~name
    ~description
    ~handler:Tool_masc_plan_dispatch
    ~readonly
;;

let masc_run_descriptor name description ~readonly =
  cluster_descriptor
    ~id:("masc.run." ^ String.sub name (String.length "masc_run_")
         (String.length name - String.length "masc_run_"))
    ~name
    ~description
    ~handler:Tool_masc_run_dispatch
    ~readonly
;;

let masc_agent_descriptor id name description ~readonly =
  cluster_descriptor
    ~id:("masc.agent." ^ id)
    ~name
    ~description
    ~handler:Tool_masc_agent_dispatch
    ~readonly
;;

let masc_coord_descriptor id name description ~readonly =
  cluster_descriptor
    ~id:("masc.coord." ^ id)
    ~name
    ~description
    ~handler:Tool_masc_coord_dispatch
    ~readonly
;;

(* RFC-0182 §3.1 — additional cluster descriptor helpers (Phase 3:
   misc / control / agent_timeline / local_runtime). *)
let masc_misc_descriptor id name description ~readonly =
  cluster_descriptor
    ~id:("masc.misc." ^ id)
    ~name
    ~description
    ~handler:Tool_masc_misc_dispatch
    ~readonly
;;

let masc_control_descriptor id name description ~readonly =
  cluster_descriptor
    ~id:("masc.control." ^ id)
    ~name
    ~description
    ~handler:Tool_masc_control_dispatch
    ~readonly
;;

let masc_agent_timeline_descriptor name description ~readonly =
  cluster_descriptor
    ~id:"masc.agent_timeline"
    ~name
    ~description
    ~handler:Tool_masc_agent_timeline_dispatch
    ~readonly
;;

let masc_local_runtime_descriptor id name description ~readonly =
  cluster_descriptor
    ~id:("masc.local_runtime." ^ id)
    ~name
    ~description
    ~handler:Tool_masc_local_runtime_dispatch
    ~readonly
;;

let internal_descriptors : t list =
  [ (* ── time / silence / catalog (RFC-0179 PR-2 + PR-3) ────────── *)
    in_process_descriptor
      ~id:"keeper.time.now"
      ~name:"keeper_time_now"
      ~description:
        "Return the current wall-clock time as ISO 8601 and Unix epoch \
         seconds. No arguments."
      ~input_schema:empty_object_schema
      ~policy:(read_only_in_process_policy ())
      ~handler:Tool_time_now
  ; in_process_descriptor
      ~id:"keeper.stay_silent"
      ~name:"keeper_stay_silent"
      ~description:
        "Signal that the keeper will not emit further output this turn. \
         Returns {status:\"silent\"}. No arguments."
      ~input_schema:empty_object_schema
      ~policy:(read_only_in_process_policy ())
      ~handler:Tool_stay_silent
  ; in_process_descriptor
      ~id:"keeper.tools_list"
      ~name:"keeper_tools_list"
      ~description:
        "List the keeper-allowed tools for the current preset. No arguments."
      ~input_schema:empty_object_schema
      ~policy:(read_only_in_process_policy ())
      ~handler:Tool_tools_list
  ; in_process_descriptor
      ~id:"keeper.tool_search"
      ~name:"keeper_tool_search"
      ~description:
        "Search keeper tool schemas by free-text query. Returns ranked tool \
         descriptions and input schemas."
      ~input_schema:tool_search_schema
      ~policy:(read_only_in_process_policy ())
      ~handler:Tool_tool_search
    (* ── memory / context (RFC-0179 PR-3) ─────────────────────── *)
  ; in_process_descriptor
      ~id:"keeper.context.status"
      ~name:"keeper_context_status"
      ~description:
        "Return current context window usage and recent-message stats for \
         this keeper turn."
      ~input_schema:empty_object_schema
      ~policy:(read_only_in_process_policy ())
      ~handler:Tool_context_status
  ; in_process_descriptor
      ~id:"keeper.memory.search"
      ~name:"keeper_memory_search"
      ~description:
        "Search keeper memory (semantic + recency) for relevant prior context."
      ~input_schema:passthrough_object_schema
      ~policy:(read_only_in_process_policy ())
      ~handler:Tool_memory_search
  ; in_process_descriptor
      ~id:"keeper.memory.write"
      ~name:"keeper_memory_write"
      ~description:"Persist a memory entry for this keeper."
      ~input_schema:passthrough_object_schema
      ~policy:(write_in_process_policy ())
      ~handler:Tool_memory_write
    (* ── library (RFC-0179 PR-3) ──────────────────────────────── *)
  ; in_process_descriptor
      ~id:"keeper.library.search"
      ~name:"keeper_library_search"
      ~description:"Search the keeper library catalog."
      ~input_schema:passthrough_object_schema
      ~policy:(read_only_in_process_policy ())
      ~handler:Tool_library_search
  ; in_process_descriptor
      ~id:"keeper.library.read"
      ~name:"keeper_library_read"
      ~description:"Read a library entry by id."
      ~input_schema:passthrough_object_schema
      ~policy:(read_only_in_process_policy ())
      ~handler:Tool_library_read
    (* ── IDE (RFC-0179 PR-3) ──────────────────────────────────── *)
  ; in_process_descriptor
      ~id:"keeper.ide.annotate"
      ~name:"keeper_ide_annotate"
      ~description:"Emit an IDE annotation event for the current keeper."
      ~input_schema:passthrough_object_schema
      ~policy:(write_in_process_policy ())
      ~handler:Tool_ide_annotate
    (* ── voice cluster (RFC-0179 PR-3, 6 tools) ───────────────── *)
  ; voice_descriptor
      "keeper_voice_speak"
      "Synthesize speech for the keeper to deliver."
      ~readonly:false
  ; voice_descriptor
      "keeper_voice_listen"
      "Listen for spoken input on the keeper voice channel."
      ~readonly:true
  ; voice_descriptor
      "keeper_voice_agent"
      "Invoke the realtime voice agent for the current keeper."
      ~readonly:false
  ; voice_descriptor
      "keeper_voice_sessions"
      "List active voice sessions for this keeper."
      ~readonly:true
  ; voice_descriptor
      "keeper_voice_session_start"
      "Start a new voice session for the keeper."
      ~readonly:false
  ; voice_descriptor
      "keeper_voice_session_end"
      "End the current voice session."
      ~readonly:false
    (* ── task / broadcast cluster (RFC-0179 PR-3, 9 tools) ────── *)
  ; task_descriptor
      "list"
      "keeper_tasks_list"
      "List MASC tasks visible to this keeper."
      ~readonly:true
  ; task_descriptor
      "audit"
      "keeper_tasks_audit"
      "Audit MASC task state for stale claims and verification gaps."
      ~readonly:true
  ; task_descriptor
      "force_release"
      "keeper_task_force_release"
      "Operator-only: release a stuck task claim."
      ~readonly:false
  ; task_descriptor
      "force_done"
      "keeper_task_force_done"
      "Operator-only: mark a task done out-of-band."
      ~readonly:false
  ; task_descriptor
      "broadcast"
      "keeper_broadcast"
      "Broadcast a coordination message to the MASC room."
      ~readonly:false
  ; task_descriptor
      "claim"
      "keeper_task_claim"
      "Claim ownership of a MASC task."
      ~readonly:false
  ; task_descriptor
      "create"
      "keeper_task_create"
      "Create a new MASC task on the board."
      ~readonly:false
  ; task_descriptor
      "done"
      "keeper_task_done"
      "Mark the claimed MASC task as done."
      ~readonly:false
  ; task_descriptor
      "submit_for_verification"
      "keeper_task_submit_for_verification"
      "Submit task work for verification by another keeper."
      ~readonly:false
    (* ── board cluster (RFC-0179 PR-3, 14 tools) ──────────────── *)
  ; board_descriptor
      "keeper_board_comment"
      "Post a comment on a board entry."
      ~readonly:false
  ; board_descriptor
      "keeper_board_comment_vote"
      "Vote on a board comment."
      ~readonly:false
  ; board_descriptor
      "keeper_board_curation_read"
      "Read curated board entries."
      ~readonly:true
  ; board_descriptor
      "keeper_board_curation_submit"
      "Submit a board entry for curation."
      ~readonly:false
  ; board_descriptor
      "keeper_board_get"
      "Fetch a single board entry."
      ~readonly:true
  ; board_descriptor
      "keeper_board_list"
      "List board entries."
      ~readonly:true
  ; board_descriptor
      "keeper_board_post"
      "Post a new board entry. Quantitative claims require code-anchor evidence."
      ~readonly:false
  ; board_descriptor
      "keeper_board_search"
      "Search board entries."
      ~readonly:true
  ; board_descriptor
      "keeper_board_stats"
      "Board statistics."
      ~readonly:true
  ; board_descriptor
      "keeper_board_sub_board_create"
      "Create a sub-board."
      ~readonly:false
  ; board_descriptor
      "keeper_board_sub_board_delete"
      "Delete a sub-board."
      ~readonly:false
  ; board_descriptor
      "keeper_board_sub_board_get"
      "Fetch a sub-board."
      ~readonly:true
  ; board_descriptor
      "keeper_board_sub_board_list"
      "List sub-boards."
      ~readonly:true
  ; board_descriptor
      "keeper_board_sub_board_update"
      "Update a sub-board."
      ~readonly:false
  ; board_descriptor
      "keeper_board_vote"
      "Vote on a board entry."
      ~readonly:false
  (* ── RFC-0182 §3.1 — masc_task_* cluster (7 entries) ─────────── *)
  ; masc_task_descriptor "add" "masc_add_task"
      "Add a task to the coordination plan." ~readonly:false
  ; masc_task_descriptor "batch_add" "masc_batch_add_tasks"
      "Add multiple tasks in a single call." ~readonly:false
  ; masc_task_descriptor "claim_next" "masc_claim_next"
      "Claim the next available task." ~readonly:false
  ; masc_task_descriptor "task_history" "masc_task_history"
      "Read history events for a task." ~readonly:true
  ; masc_task_descriptor "tasks" "masc_tasks"
      "List tasks visible to the caller." ~readonly:true
  ; masc_task_descriptor "transition" "masc_transition"
      "Transition a task to a new status." ~readonly:false
  ; masc_task_descriptor "update_priority" "masc_update_priority"
      "Update the priority of a task." ~readonly:false
  (* ── RFC-0182 §3.1 — masc_plan_* + note + deliver (8 entries) ── *)
  ; masc_plan_descriptor "init" "masc_plan_init"
      "Initialise a coordination plan." ~readonly:false
  ; masc_plan_descriptor "update" "masc_plan_update"
      "Update a coordination plan." ~readonly:false
  ; masc_plan_descriptor "get" "masc_plan_get"
      "Read the current plan." ~readonly:true
  ; masc_plan_descriptor "set_task" "masc_plan_set_task"
      "Bind a task to a plan slot." ~readonly:false
  ; masc_plan_descriptor "get_task" "masc_plan_get_task"
      "Read the task bound to a plan slot." ~readonly:true
  ; masc_plan_descriptor "clear_task" "masc_plan_clear_task"
      "Unbind a task from a plan slot." ~readonly:false
  ; masc_plan_descriptor "note_add" "masc_note_add"
      "Append a coordination note." ~readonly:false
  ; masc_plan_descriptor "deliver" "masc_deliver"
      "Record a deliverable against the plan." ~readonly:false
  (* ── RFC-0182 §3.1 — masc_run_* cluster (6 entries) ──────────── *)
  ; masc_run_descriptor "masc_run_init"
      "Initialise a coordination run." ~readonly:false
  ; masc_run_descriptor "masc_run_list"
      "List recent runs." ~readonly:true
  ; masc_run_descriptor "masc_run_get"
      "Read a single run by id." ~readonly:true
  ; masc_run_descriptor "masc_run_log"
      "Read or append run log events." ~readonly:false
  ; masc_run_descriptor "masc_run_plan"
      "Read the run plan." ~readonly:true
  ; masc_run_descriptor "masc_run_deliverable"
      "Read or attach a run deliverable." ~readonly:false
  (* ── RFC-0182 §3.1 — masc_agent_* cluster (5 entries) ────────── *)
  ; masc_agent_descriptor "agents" "masc_agents"
      "List registered agents." ~readonly:true
  ; masc_agent_descriptor "card" "masc_agent_card"
      "Read an agent card." ~readonly:true
  ; masc_agent_descriptor "fitness" "masc_agent_fitness"
      "Read agent fitness metrics." ~readonly:true
  ; masc_agent_descriptor "update" "masc_agent_update"
      "Update agent registration metadata." ~readonly:false
  ; masc_agent_descriptor "get_metrics" "masc_get_metrics"
      "Read aggregated agent metrics." ~readonly:true
  (* ── RFC-0182 §3.1 — masc_coord_* cluster (8 entries) ────────── *)
  ; masc_coord_descriptor "status" "masc_status"
      "Read overall coordination status." ~readonly:true
  ; masc_coord_descriptor "heartbeat" "masc_heartbeat"
      "Emit an agent heartbeat." ~readonly:false
  ; masc_coord_descriptor "check" "masc_check"
      "Read a coordination assertion check." ~readonly:true
  ; masc_coord_descriptor "reset" "masc_reset"
      "Reset coordination state." ~readonly:false
  ; masc_coord_descriptor "goal_list" "masc_goal_list"
      "List coordination goals." ~readonly:true
  ; masc_coord_descriptor "goal_upsert" "masc_goal_upsert"
      "Create or update a coordination goal." ~readonly:false
  ; masc_coord_descriptor "goal_transition" "masc_goal_transition"
      "Transition a goal status." ~readonly:false
  ; masc_coord_descriptor "goal_verify" "masc_goal_verify"
      "Verify goal completion criteria." ~readonly:false
  (* ── RFC-0182 §3.1 — masc_misc_* cluster (9 entries) ─────────── *)
  ; masc_misc_descriptor "config" "masc_config"
      "Read coordination configuration." ~readonly:true
  ; masc_misc_descriptor "dashboard" "masc_dashboard"
      "Read coordination dashboard summary." ~readonly:true
  ; masc_misc_descriptor "cleanup_zombies" "masc_cleanup_zombies"
      "Reap orphan / zombie coordination state." ~readonly:false
  ; masc_misc_descriptor "tool_stats" "masc_tool_stats"
      "Read tool-usage statistics." ~readonly:true
  ; masc_misc_descriptor "tool_help" "masc_tool_help"
      "Read help text for a tool name." ~readonly:true
  (* [masc_web_search] / [masc_web_fetch] are already owned by the
     LLM-native SearchWeb / FetchWeb descriptors above. Do not add
     duplicate internal descriptors here; that would make runtime receipt
     projection depend on list order. *)
  ; masc_misc_descriptor "tool_admin_snapshot" "masc_tool_admin_snapshot"
      "Read tool-admin inventory snapshot." ~readonly:true
  ; masc_misc_descriptor "tool_admin_update" "masc_tool_admin_update"
      "Update tool-admin metadata." ~readonly:false
  (* ── RFC-0182 §3.1 — masc_control_* cluster (2 entries) ──────── *)
  ; masc_control_descriptor "pause" "masc_pause"
      "Pause a paused/runnable agent." ~readonly:false
  ; masc_control_descriptor "resume" "masc_resume"
      "Resume a paused agent." ~readonly:false
  (* ── RFC-0182 §3.1 — masc_agent_timeline singleton (1 entry) ── *)
  ; masc_agent_timeline_descriptor "masc_agent_timeline"
      "Read agent timeline events." ~readonly:true
  (* ── RFC-0182 §3.1 — masc_local_runtime_* cluster (2 entries) ─ *)
  ; masc_local_runtime_descriptor "verify" "masc_runtime_verify"
      "Verify provider/runtime contract for swarm / benchmark." ~readonly:true
  ; masc_local_runtime_descriptor "ollama_probe" "masc_runtime_ollama_probe"
      "Probe Ollama runtime endpoint for diagnostics." ~readonly:true
  ]
  @ masc_board_descriptors
;;

let all_descriptors () = public_descriptors @ internal_descriptors

let public_names () = List.map (fun d -> d.public_name) public_descriptors

let find_public name =
  List.find_opt (fun d -> String.equal d.public_name name) public_descriptors
;;

let public_descriptors_for_internal internal_name =
  List.filter (fun d -> String.equal d.internal_name internal_name) public_descriptors
;;

(* Walks [all_descriptors ()]. Used by the runtime dispatcher to resolve any
   descriptor-backed tool by its internal name, including coordination tools
   that live in [internal_descriptors]. While [internal_descriptors = []], this
   returns the same result as [public_descriptors_for_internal]. *)
let descriptors_for_internal internal_name =
  List.filter (fun d -> String.equal d.internal_name internal_name) (all_descriptors ())
;;

let readonly_internal_names () =
  all_descriptors ()
  |> List.filter_map (fun d ->
    match d.policy.readonly with
    | Some true -> Some d.internal_name
    | Some false | None -> None)
  |> List.sort_uniq String.compare
;;

let public_name_for_internal internal_name =
  match public_descriptors_for_internal internal_name with
  | [] -> None
  | first :: _ -> Some first.public_name
;;

let public_input_schema public =
  Option.map (fun d -> d.input_schema) (find_public public)
;;

let translate_input ~public input =
  match find_public public with
  | Some d -> d.translate input
  | None -> input
;;

let string_opt_to_json = function
  | Some value -> `String value
  | None -> `Null
;;

let bool_opt_to_json = function
  | Some value -> `Bool value
  | None -> `Null
;;

let receipt_labels_json d =
  `Assoc (List.map (fun (key, value) -> key, `String value) d.receipt_labels)
;;

let route_evidence_json d =
  let policy = d.policy in
  let policy_fields =
    match policy.effect_domain with
    | Some domain ->
      [ "effect_domain", `String (Tool_catalog.effect_domain_to_string domain) ]
    | None -> []
  in
  `Assoc
    ([ "descriptor_id", `String d.id
     ; "public_name", `String d.public_name
     ; "canonical_name", `String d.internal_name
     ; "description", `String d.description
     ; "visibility", `String (Tool_catalog.visibility_to_string policy.visibility)
     ; "readonly", bool_opt_to_json policy.readonly
     ; "executor", `String (executor_to_string d.executor)
     ; "backend", `String (backend_to_string d.backend)
     ; "sandbox", `String (sandbox_to_string d.sandbox)
     ; "runtime_handler", `String (runtime_handler_to_string d.runtime_handler)
     ; "receipt_labels", receipt_labels_json d
     ; "approval", `String (approval_to_string policy.approval)
     ; "retryable", `Bool policy.retryable
     ; "cwd_scope", string_opt_to_json policy.cwd_scope
     ; "credential_profile", string_opt_to_json policy.credential_profile
     ]
     @ policy_fields)
;;
