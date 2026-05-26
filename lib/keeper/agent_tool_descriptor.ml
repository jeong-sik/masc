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
  | Tool_search_files
  | Tool_read_file
  | Tool_edit_file
  | Tool_write_file
  | Tool_remote_mcp
  | Tool_time_now
  | Tool_stay_silent
  | Tool_tools_list
  | Tool_memory_write
  | Tool_ide_annotate
  | Tool_voice
  | Tool_task

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
  | Tool_search_files -> "tool_search_files"
  | Tool_read_file -> "tool_read_file"
  | Tool_edit_file -> "tool_edit_file"
  | Tool_write_file -> "tool_write_file"
  | Tool_remote_mcp -> "tool_remote_mcp"
  | Tool_time_now -> "tool_time_now"
  | Tool_stay_silent -> "tool_stay_silent"
  | Tool_tools_list -> "tool_tools_list"
  | Tool_memory_write -> "tool_memory_write"
  | Tool_ide_annotate -> "tool_ide_annotate"
  | Tool_voice -> "tool_voice"
  | Tool_task -> "tool_task"
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
      ~id:"agent.search_files"
      ~public_name:"SearchFiles"
      ~internal_name:"tool_search_files"
      ~description:"Search file contents with ripgrep through the structured file-search tool."
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
      ~runtime_handler:Tool_search_files
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
   hard-cut, 7 entries) is preserved unchanged. *)
let empty_object_schema =
  `Assoc
    [ "type", `String "object"
    ; "properties", `Assoc []
    ; "additionalProperties", `Bool false
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

let coordination_write_in_process_policy () =
  policy
    ~visibility:Tool_catalog.Hidden
    ~readonly:false
    ~effect_domain:Tool_catalog.Masc_coordination
    ~approval:Policy_selected
    ~retryable:false
    ()
;;

let voice_external_in_process_policy () =
  policy
    ~visibility:Tool_catalog.Hidden
    ~readonly:false
    ~approval:Policy_selected
    ~retryable:false
    ()
;;

let task_read_in_process_policy () =
  policy
    ~visibility:Tool_catalog.Hidden
    ~readonly:true
    ~effect_domain:Tool_catalog.Read_only
    ~approval:No_approval
    ~retryable:true
    ()
;;


let internal_descriptors : t list =
  [ descriptor
      ~id:"keeper.time.now"
      ~public_name:"keeper_time_now"
      ~internal_name:"keeper_time_now"
      ~description:
        "Return the current wall-clock time as ISO 8601 and Unix epoch \
         seconds. No arguments."
      ~input_schema:empty_object_schema
      ~policy:(read_only_in_process_policy ())
      ~executor:In_process
      ~backend:Ocaml_runtime
      ~sandbox:No_sandbox
      ~runtime_handler:Tool_time_now
      ~translate:translate_identity
  ; descriptor
      ~id:"keeper.stay.silent"
      ~public_name:"keeper_stay_silent"
      ~internal_name:"keeper_stay_silent"
      ~description:
        "Yield the turn without taking action. Returns {\"status\":\"silent\"}. \
         No arguments."
      ~input_schema:empty_object_schema
      ~policy:(read_only_in_process_policy ())
      ~executor:In_process
      ~backend:Ocaml_runtime
      ~sandbox:No_sandbox
      ~runtime_handler:Tool_stay_silent
      ~translate:translate_identity
  ; descriptor
      ~id:"keeper.tools.list"
      ~public_name:"keeper_tools_list"
      ~internal_name:"keeper_tools_list"
      ~description:
        "List the tools available to the current keeper, with descriptions \
         and policy notes. No arguments."
      ~input_schema:empty_object_schema
      ~policy:(read_only_in_process_policy ())
      ~executor:In_process
      ~backend:Ocaml_runtime
      ~sandbox:No_sandbox
      ~runtime_handler:Tool_tools_list
      ~translate:translate_identity
  ; descriptor
      ~id:"keeper.memory.write"
      ~public_name:"keeper_memory_write"
      ~internal_name:"keeper_memory_write"
      ~description:
        "Append an entry to the keeper memory store. Body fields define \
         the entry payload."
      ~input_schema:empty_object_schema
      ~policy:(coordination_write_in_process_policy ())
      ~executor:In_process
      ~backend:Ocaml_runtime
      ~sandbox:No_sandbox
      ~runtime_handler:Tool_memory_write
      ~translate:translate_identity
  ; descriptor
      ~id:"keeper.ide.annotate"
      ~public_name:"keeper_ide_annotate"
      ~internal_name:"keeper_ide_annotate"
      ~description:
        "Create a line-bound annotation in the .masc-ide store. \
         Returns the created record's id and coordinates."
      ~input_schema:empty_object_schema
      ~policy:(coordination_write_in_process_policy ())
      ~executor:In_process
      ~backend:Ocaml_runtime
      ~sandbox:No_sandbox
      ~runtime_handler:Tool_ide_annotate
      ~translate:translate_identity
  ; descriptor
      ~id:"keeper.voice.speak"
      ~public_name:"keeper_voice_speak"
      ~internal_name:"keeper_voice_speak"
      ~description:"Speak the given text via the configured voice service."
      ~input_schema:empty_object_schema
      ~policy:(voice_external_in_process_policy ())
      ~executor:In_process
      ~backend:Remote_service
      ~sandbox:No_sandbox
      ~runtime_handler:Tool_voice
      ~translate:translate_identity
  ; descriptor
      ~id:"keeper.voice.listen"
      ~public_name:"keeper_voice_listen"
      ~internal_name:"keeper_voice_listen"
      ~description:"Listen for voice input via the configured voice service."
      ~input_schema:empty_object_schema
      ~policy:(voice_external_in_process_policy ())
      ~executor:In_process
      ~backend:Remote_service
      ~sandbox:No_sandbox
      ~runtime_handler:Tool_voice
      ~translate:translate_identity
  ; descriptor
      ~id:"keeper.voice.agent"
      ~public_name:"keeper_voice_agent"
      ~internal_name:"keeper_voice_agent"
      ~description:"Run a voice agent turn via the configured voice service."
      ~input_schema:empty_object_schema
      ~policy:(voice_external_in_process_policy ())
      ~executor:In_process
      ~backend:Remote_service
      ~sandbox:No_sandbox
      ~runtime_handler:Tool_voice
      ~translate:translate_identity
  ; descriptor
      ~id:"keeper.voice.sessions"
      ~public_name:"keeper_voice_sessions"
      ~internal_name:"keeper_voice_sessions"
      ~description:"List ongoing voice sessions for this keeper."
      ~input_schema:empty_object_schema
      ~policy:(read_only_in_process_policy ())
      ~executor:In_process
      ~backend:Remote_service
      ~sandbox:No_sandbox
      ~runtime_handler:Tool_voice
      ~translate:translate_identity
  ; descriptor
      ~id:"keeper.voice.session.start"
      ~public_name:"keeper_voice_session_start"
      ~internal_name:"keeper_voice_session_start"
      ~description:"Start a new voice session for this keeper."
      ~input_schema:empty_object_schema
      ~policy:(voice_external_in_process_policy ())
      ~executor:In_process
      ~backend:Remote_service
      ~sandbox:No_sandbox
      ~runtime_handler:Tool_voice
      ~translate:translate_identity
  ; descriptor
      ~id:"keeper.voice.session.end"
      ~public_name:"keeper_voice_session_end"
      ~internal_name:"keeper_voice_session_end"
      ~description:"End an ongoing voice session for this keeper."
      ~input_schema:empty_object_schema
      ~policy:(voice_external_in_process_policy ())
      ~executor:In_process
      ~backend:Remote_service
      ~sandbox:No_sandbox
      ~runtime_handler:Tool_voice
      ~translate:translate_identity
  (* Task cluster (RFC-0179 PR-5). All 9 descriptors share the
     Tool_task runtime_handler variant. Agent_tool_in_process_runtime
     forwards descriptor.internal_name into
     Keeper_exec_task.handle_keeper_task_tool, which name-dispatches
     across the cluster. Policy: tasks_list / tasks_audit are
     read-only; the rest mutate coordination state. *)
  ; descriptor
      ~id:"keeper.tasks.list"
      ~public_name:"keeper_tasks_list"
      ~internal_name:"keeper_tasks_list"
      ~description:"List tasks visible to this keeper."
      ~input_schema:empty_object_schema
      ~policy:(task_read_in_process_policy ())
      ~executor:In_process
      ~backend:Ocaml_runtime
      ~sandbox:No_sandbox
      ~runtime_handler:Tool_task
      ~translate:translate_identity
  ; descriptor
      ~id:"keeper.tasks.audit"
      ~public_name:"keeper_tasks_audit"
      ~internal_name:"keeper_tasks_audit"
      ~description:"Audit task state for this keeper's namespace."
      ~input_schema:empty_object_schema
      ~policy:(task_read_in_process_policy ())
      ~executor:In_process
      ~backend:Ocaml_runtime
      ~sandbox:No_sandbox
      ~runtime_handler:Tool_task
      ~translate:translate_identity
  ; descriptor
      ~id:"keeper.task.force.release"
      ~public_name:"keeper_task_force_release"
      ~internal_name:"keeper_task_force_release"
      ~description:"Force-release a task back to the backlog."
      ~input_schema:empty_object_schema
      ~policy:(coordination_write_in_process_policy ())
      ~executor:In_process
      ~backend:Ocaml_runtime
      ~sandbox:No_sandbox
      ~runtime_handler:Tool_task
      ~translate:translate_identity
  ; descriptor
      ~id:"keeper.task.force.done"
      ~public_name:"keeper_task_force_done"
      ~internal_name:"keeper_task_force_done"
      ~description:"Force-mark a task as done."
      ~input_schema:empty_object_schema
      ~policy:(coordination_write_in_process_policy ())
      ~executor:In_process
      ~backend:Ocaml_runtime
      ~sandbox:No_sandbox
      ~runtime_handler:Tool_task
      ~translate:translate_identity
  ; descriptor
      ~id:"keeper.broadcast"
      ~public_name:"keeper_broadcast"
      ~internal_name:"keeper_broadcast"
      ~description:
        "Broadcast a message visible to other keepers in this namespace."
      ~input_schema:empty_object_schema
      ~policy:(coordination_write_in_process_policy ())
      ~executor:In_process
      ~backend:Ocaml_runtime
      ~sandbox:No_sandbox
      ~runtime_handler:Tool_task
      ~translate:translate_identity
  ; descriptor
      ~id:"keeper.task.claim"
      ~public_name:"keeper_task_claim"
      ~internal_name:"keeper_task_claim"
      ~description:"Claim the next eligible task into the active turn."
      ~input_schema:empty_object_schema
      ~policy:(coordination_write_in_process_policy ())
      ~executor:In_process
      ~backend:Ocaml_runtime
      ~sandbox:No_sandbox
      ~runtime_handler:Tool_task
      ~translate:translate_identity
  ; descriptor
      ~id:"keeper.task.create"
      ~public_name:"keeper_task_create"
      ~internal_name:"keeper_task_create"
      ~description:"Create a new backlog task with keeper-native evidence."
      ~input_schema:empty_object_schema
      ~policy:(coordination_write_in_process_policy ())
      ~executor:In_process
      ~backend:Ocaml_runtime
      ~sandbox:No_sandbox
      ~runtime_handler:Tool_task
      ~translate:translate_identity
  ; descriptor
      ~id:"keeper.task.done"
      ~public_name:"keeper_task_done"
      ~internal_name:"keeper_task_done"
      ~description:"Mark the current task as done."
      ~input_schema:empty_object_schema
      ~policy:(coordination_write_in_process_policy ())
      ~executor:In_process
      ~backend:Ocaml_runtime
      ~sandbox:No_sandbox
      ~runtime_handler:Tool_task
      ~translate:translate_identity
  ; descriptor
      ~id:"keeper.task.submit.for.verification"
      ~public_name:"keeper_task_submit_for_verification"
      ~internal_name:"keeper_task_submit_for_verification"
      ~description:"Submit the current task for verification."
      ~input_schema:empty_object_schema
      ~policy:(coordination_write_in_process_policy ())
      ~executor:In_process
      ~backend:Ocaml_runtime
      ~sandbox:No_sandbox
      ~runtime_handler:Tool_task
      ~translate:translate_identity
  ]
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
     ; "approval", `String (approval_to_string policy.approval)
     ; "retryable", `Bool policy.retryable
     ; "cwd_scope", string_opt_to_json policy.cwd_scope
     ; "credential_profile", string_opt_to_json policy.credential_profile
     ]
     @ policy_fields)
;;
