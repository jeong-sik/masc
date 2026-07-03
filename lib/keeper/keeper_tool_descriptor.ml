(** Agent-facing tool descriptor spine. *)

type executor =
  | Shell_ir
  | Filesystem
  | In_process

type backend =
  | Ocaml_runtime
  | Host_process
  | Sandbox_process

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

type readonly_of_input = Yojson.Safe.t -> bool option

type runtime_handler =
  | Tool_execute
  | Tool_search_files
  | Tool_read_file
  | Tool_edit_file
  | Tool_write_file
  | Tool_time_now
  | Tool_tools_list
  | Tool_tool_search
  | Tool_context_status
  | Tool_memory_search
  | Tool_memory_write
  | Tool_library_search
  | Tool_library_read
  | Tool_surface_read
  | Tool_surface_post
  | Tool_person_note_set
  | Tool_ide_annotate
  | Tool_voice_dispatch
  | Tool_task_dispatch
  | Board_tool_dispatch
  | Tool_masc_board_dispatch
  | Tool_masc_task_dispatch
  | Tool_masc_plan_dispatch
  | Tool_masc_run_dispatch
  | Tool_masc_agent_dispatch
  | Tool_masc_workspace_dispatch
  | Tool_masc_misc_dispatch
  | Tool_masc_control_dispatch
  | Tool_masc_agent_timeline_dispatch
  | Tool_masc_schedule_dispatch
  | Tool_masc_keeper_dispatch
  | Tool_masc_surface_audit
  | Tool_masc_fusion_dispatch
  | Tool_masc_fusion_status
  | Tool_analyze_image

type policy =
  { visibility : Tool_catalog.visibility
  ; readonly_of_input : readonly_of_input
  ; readonly_hint : bool option
  ; effect_domain : Tool_catalog.effect_domain option
  ; approval : approval
  ; retryable : bool
  ; cwd_scope : string option
  ; inline_safe : bool
  ; maintenance_only : bool
  ; polling_read : bool
  }

type t =
  { id : string
  ; public_name : string
  ; public_aliases : string list
  ; internal_name : string
  ; description : string
  ; input_schema : Yojson.Safe.t
  ; policy : policy
  ; executor : executor
  ; backend : backend
  ; sandbox : sandbox
  ; runtime_handler : runtime_handler
  ; translate : Yojson.Safe.t -> Yojson.Safe.t
  ; validate_translated_input : bool
  ; receipt_labels : (string * string) list
  ; eval_tags : string list
  ; examples : Yojson.Safe.t list
  }

let executor_to_string = function
  | Shell_ir -> "shell_ir"
  | Filesystem -> "filesystem"
  | In_process -> "in_process"
;;

let backend_to_string = function
  | Ocaml_runtime -> "ocaml_runtime"
  | Host_process -> "host_process"
  | Sandbox_process -> "sandbox_process"
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
  | Tool_time_now -> "tool_time_now"
  | Tool_tools_list -> "tool_tools_list"
  | Tool_tool_search -> "tool_tool_search"
  | Tool_context_status -> "tool_context_status"
  | Tool_memory_search -> "tool_memory_search"
  | Tool_memory_write -> "tool_memory_write"
  | Tool_library_search -> "tool_library_search"
  | Tool_library_read -> "tool_library_read"
  | Tool_surface_read -> "tool_surface_read"
  | Tool_surface_post -> "tool_surface_post"
  | Tool_person_note_set -> "tool_person_note_set"
  | Tool_ide_annotate -> "tool_ide_annotate"
  | Tool_voice_dispatch -> "tool_voice_dispatch"
  | Tool_task_dispatch -> "tool_task_dispatch"
  | Board_tool_dispatch -> "board_tool_dispatch"
  | Tool_masc_board_dispatch -> "tool_masc_board_dispatch"
  | Tool_masc_task_dispatch -> "tool_masc_task_dispatch"
  | Tool_masc_plan_dispatch -> "tool_masc_plan_dispatch"
  | Tool_masc_run_dispatch -> "tool_masc_run_dispatch"
  | Tool_masc_agent_dispatch -> "tool_masc_agent_dispatch"
  | Tool_masc_workspace_dispatch -> "tool_masc_workspace_dispatch"
  | Tool_masc_misc_dispatch -> "tool_masc_misc_dispatch"
  | Tool_masc_control_dispatch -> "tool_masc_control_dispatch"
  | Tool_masc_agent_timeline_dispatch -> "tool_masc_agent_timeline_dispatch"
  | Tool_masc_schedule_dispatch -> "tool_masc_schedule_dispatch"
  | Tool_masc_keeper_dispatch -> "tool_masc_keeper_dispatch"
  | Tool_masc_surface_audit -> "tool_masc_surface_audit"
  | Tool_masc_fusion_dispatch -> "tool_masc_fusion_dispatch"
  | Tool_masc_fusion_status -> "tool_masc_fusion_status"
  | Tool_analyze_image -> "tool_analyze_image"
;;

let discovery_example ~label ?cwd ~executable ~argv () =
  let input =
    `Assoc
      ([ "executable", `String executable
       ; "argv", Json_util.json_string_list argv
       ]
       @
       match cwd with
       | Some cwd -> [ "cwd", `String cwd ]
       | None -> [])
  in
  `Assoc [ "label", `String label; "input", input ]
;;

let policy ?(visibility = Tool_catalog.Default) ?readonly ?readonly_of_input
      ?effect_domain ?(approval = Policy_selected) ?cwd_scope ?(retryable = false)
      ?(inline_safe = false) ?(maintenance_only = false) ?(polling_read = false) ()
  =
  let readonly_of_input =
    match readonly_of_input with
    | Some readonly_of_input -> readonly_of_input
    | None -> fun _input -> readonly
  in
  { visibility
  ; readonly_of_input
  ; readonly_hint = readonly
  ; effect_domain
  ; approval
  ; retryable
  ; cwd_scope
  ; inline_safe
  ; maintenance_only
  ; polling_read
  }
;;

let property name typ description =
  name, `Assoc [ "type", `String typ; "description", `String description ]
;;

let string_enum_property name values description =
  ( name
  , `Assoc
      [ "type", `String "string"
      ; "enum", `List (List.map (fun value -> `String value) values)
      ; "description", `String description
      ] )
;;

let object_schema ?(required = []) properties =
  `Assoc
    [ "type", `String "object"
    ; "properties", `Assoc properties
    ; "required", `List (List.map (fun n -> `String n) required)
    ]
;;

let closed_object_schema ?(required = []) properties =
  match object_schema ~required properties with
  | `Assoc fields -> `Assoc (fields @ [ "additionalProperties", `Bool false ])
  | schema -> schema
;;

let unavailable_input_schema reason =
  `Assoc
    [ "type", `String "object"
    ; "description", `String reason
    ; "properties", `Assoc []
    ; "required", `List [ `String "__masc_unavailable_schema" ]
    ; "additionalProperties", `Bool false
    ]
;;

let execute_schema = Tool_shard_types.tool_execute_schema.input_schema

let read_file_schema =
  closed_object_schema
    ~required:[ "file_path" ]
    [ property
        "file_path"
        "string"
        "Existing file path to read. Relative paths resolve against cwd when cwd is \
         provided, otherwise against the keeper sandbox. Read does not inherit Execute \
         cwd implicitly; pass cwd explicitly or use a sandbox-relative repos/<repo>/... \
         path."
    ; property
        "cwd"
        "string"
        "Optional sandbox-relative directory to resolve file_path from, e.g. \
         repos/masc. This is explicit only; Read never inherits the previous \
         Execute cwd."
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
    [ property "pattern" "string" "Regular expression to search file contents for (ripgrep)."
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
    [ property "query" "string" "Plain-text search query. Example: \"OCaml 5.2 release date\"."
    ; property "limit" "integer" "Maximum number of results to return (1-10, default 5)."
    ; property
        "includeContent"
        "boolean"
        "When true, also fetch each result page and add raw page_content plus a human-readable content_text summary. Recommended for research."
    ; ( "contentMaxChars",
        `Assoc
          [ "type", `String "integer"
          ; "description",
            `String "Maximum raw page_content characters per result."
          ; "minimum", `Int 100
          ; "maximum", `Int 20000
          ; "default", `Int 4000
          ] )
    ; ( "contentTimeout",
        `Assoc
          [ "type", `String "integer"
          ; "description", `String "Per-result content fetch timeout in seconds."
          ; "minimum", `Int 1
          ; "maximum", `Int 60
          ; "default", `Int 15
          ] )
    ]
;;

let fetch_web_schema =
  `Assoc
    [ "type", `String "object"
    ; ( "properties",
        `Assoc
          [ property "url" "string" "Full URL to fetch. Example: \"https://ocaml.org/news\"."
          ; ( "timeout",
              `Assoc
                [ "type", `String "integer"
                ; "description", `String "Request timeout in seconds."
                ; "minimum", `Int 1
                ; "maximum", `Int 60
                ; "default", `Int 15
                ] )
          ; ( "extractMode",
              `Assoc
                [ "type", `String "string"
                ; "enum", `List [ `String "markdown"; `String "text" ]
                ; "description",
                  `String
                    "Output extraction mode. markdown (default) preserves headings/lists/links; \
                     text returns flattened plain text."
                ; "default", `String "markdown"
                ] )
          ; ( "maxChars",
              `Assoc
                [ "type", `String "integer"
                ; "description", `String "Maximum extracted content characters to return."
                ; "minimum", `Int 1
                ; "maximum", `Int 100000
                ; "default", `Int 50000
                ] )
          ] )
    ; "required", `List [ `String "url" ]
    ; "additionalProperties", `Bool false
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

(* search_files is rg (pattern search) only. Fold -i into the pattern as a
   (?i) prefix; pass pattern/path/glob/type through. *)
let translate_search_files input =
  match input with
  | `Assoc fields ->
    let is_case_insensitive =
      match List.assoc_opt "-i" fields with
      | Some (`Bool true) -> true
      | _ -> false
    in
    let out = ref [] in
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
         | "-i" -> ()
         | _ -> out := (k, v) :: !out)
      fields;
    `Assoc (List.rev !out)
  | _ -> input
;;

(* search_files is now rg (pattern search) only — always read-only. *)
let search_files_readonly_of_input _input = Some true

let descriptor_with_public_aliases
      ?(examples = [])
      ~validate_translated_input
      ~public_aliases
      ~id
      ~public_name
      ~internal_name
      ~description
      ~input_schema
      ~policy
      ~executor
      ~backend
      ~sandbox
      ~runtime_handler
      ~translate
      ()
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
  ; public_aliases
  ; internal_name
  ; description
  ; input_schema
  ; policy
  ; executor
  ; backend
  ; sandbox
  ; runtime_handler
  ; translate
  ; validate_translated_input
  ; receipt_labels
  ; eval_tags = []
  ; examples
  }
;;

let descriptor
      ?(examples = [])
      ~validate_translated_input
      ~id
      ~public_name
      ~internal_name
      ~description
      ~input_schema
      ~policy
      ~executor
      ~backend
      ~sandbox
      ~runtime_handler
      ~translate
      ()
  =
  descriptor_with_public_aliases
    ~examples
    ~validate_translated_input
    ~public_aliases:[]
    ~id
    ~public_name
    ~internal_name
    ~description
    ~input_schema
    ~policy
    ~executor
    ~backend
    ~sandbox
    ~runtime_handler
    ~translate
    ()
;;

let with_eval_tags eval_tags descriptor =
  { descriptor with eval_tags }
;;

let public_descriptors =
  [ descriptor
      ~id:"agent.execute"
      ~public_name:"Execute"
      ~internal_name:"tool_execute"
      ~description:
        "Execute one typed command through deterministic execution gates with \
         sandbox/policy-scoped filesystem access for allowed read, write, and \
         execute operations. Git and GitHub CLI commands are supported through \
         typed argv when Execute is visible and the call is scoped to an allowed \
         repo cwd; repo-hosting mutations remain subject to Shell IR/policy and \
         keeper-scoped credentials. Provide executable plus argv arguments after \
         the executable, or pipeline. Do not repeat executable as argv[0]. \
         Examples: executable='git' argv=['status', '--short']; executable='gh' \
         argv=['pr', 'list', '--repo', 'owner/name']. Use cwd for repo-scoped \
         operations."
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
      ~examples:
        [ discovery_example
            ~label:"Inspect pull request metadata"
            ~cwd:"<repository-root>"
            ~executable:"gh"
            ~argv:
              [ "pr"
              ; "view"
              ; "<pull-request-number>"
              ; "--json"
              ; "number,state,headRefOid"
              ]
            ()
        ; discovery_example
            ~label:"Read repository status"
            ~cwd:"<repository-root>"
            ~executable:"git"
            ~argv:[ "status"; "--short" ]
            ()
        ; discovery_example
            ~label:"Search source text"
            ~cwd:"<repository-root>"
            ~executable:"rg"
            ~argv:[ "--line-number"; "<pattern>"; "<path>" ]
            ()
        ]
      ~validate_translated_input:true
      ~translate:translate_identity
      ()
  ; descriptor_with_public_aliases
      ~id:"agent.search_files"
      ~public_name:"Grep"
      ~public_aliases:[ "Search"; "search_files" ]
      ~internal_name:"tool_search_files"
      ~description:
        "Search file contents with ripgrep: provide a regex `pattern` (and \
         optionally path/glob/type). To list a directory, read a file, or run \
         git status/log/diff, use the Execute tool (e.g. executable='ls' \
         argv=['-la','<path>'])."
      ~input_schema:search_files_schema
      ~policy:
        (policy
           ~readonly:true
           ~readonly_of_input:search_files_readonly_of_input
           ~effect_domain:Tool_catalog.Read_only
           ~cwd_scope:"keeper_sandbox_or_allowed_path"
           ~retryable:true
           ())
      ~executor:Shell_ir
      ~backend:Sandbox_process
      ~sandbox:Backend_selected
      ~runtime_handler:Tool_search_files
      ~validate_translated_input:true
      ~translate:translate_search_files
      ()
  ; descriptor
      ~id:"agent.read_file"
      ~public_name:"Read"
      ~internal_name:"tool_read_file"
      ~description:
        "Read one existing file from the keeper sandbox or an allowed path with no \
         implicit cwd. Read targets a single FILE; to list a directory use the \
         Execute tool with ls. Pass cwd explicitly for repo-relative reads. Read \
         never inherits Execute cwd."
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
      ~validate_translated_input:false
      ~translate:translate_read_file
      ()
  ; descriptor
      ~id:"agent.edit_file"
      ~public_name:"Edit"
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
      ~validate_translated_input:false
      ~translate:translate_edit_file
      ()
  ; descriptor
      ~id:"agent.write_file"
      ~public_name:"Write"
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
      ~validate_translated_input:false
      ~translate:translate_write_file
      ()
  ; descriptor
      ~id:"agent.search_web"
      ~public_name:"WebSearch"
      ~internal_name:"masc_web_search"
      ~description:
        "Search the public web. Use exact tool name WebSearch. Example input: \
         {\"query\":\"OCaml 5.2 release date\",\"limit\":5,\"includeContent\":true}. \
         Returns result.results with title, url, snippet. With includeContent:true \
         each result also has page_content and the response has a human-readable \
         content_text summary. Do not use snake_case names like web_search."
      ~input_schema:search_web_schema
      ~policy:
        (policy
           ~readonly:true
           ~effect_domain:Tool_catalog.Read_only
           ~approval:Policy_selected
           ~retryable:true
           ())
      ~executor:In_process
      ~backend:Ocaml_runtime
      ~sandbox:No_sandbox
      ~runtime_handler:Tool_masc_misc_dispatch
      ~validate_translated_input:true
      ~translate:translate_identity
      ()
  ; descriptor
      ~id:"agent.fetch_web"
      ~public_name:"WebFetch"
      ~internal_name:"masc_web_fetch"
      ~description:
        "Fetch one web page for deeper reading. Use exact tool name WebFetch. \
         Example input: {\"url\":\"https://ocaml.org/news\",\"extractMode\":\"markdown\",\"maxChars\":5000}. \
         Returns text, title, final_url, http_status, truncated. Use after WebSearch \
         when you need a citation or full article text. Do not use snake_case names \
         like web_fetch."
      ~input_schema:fetch_web_schema
      ~policy:
        (policy
           ~readonly:true
           ~effect_domain:Tool_catalog.Read_only
           ~approval:Policy_selected
           ~retryable:true
           ())
      ~executor:In_process
      ~backend:Ocaml_runtime
      ~sandbox:No_sandbox
      ~runtime_handler:Tool_masc_misc_dispatch
      ~validate_translated_input:true
      ~translate:translate_identity
      ()
  ]
;;

(* RFC-0179 list bifurcation. [internal_descriptors] hosts descriptor-backed
   workspace tools (keeper_* / masc_* clusters). Each cluster migration PR
   adds entries here. The LLM-native [public_descriptors] contract (RFC-0064
   hard-cut) is preserved as preferred public descriptors; secondary aliases
   reuse an existing descriptor instead of duplicating runtime ownership.

   RFC-0179 PR-3 (full keeper_* coverage). Every legacy match arm in
   [Keeper_tool_dispatch_runtime.execute_keeper_tool_call_with_outcome] is now backed by
   a descriptor entry below. After this PR the legacy chain is empty modulo
   the trailing remote-MCP fallback. *)

let empty_object_schema =
  `Assoc
    [ "type", `String "object"
    ; "properties", `Assoc []
    ; "additionalProperties", `Bool false
    ]
;;

(* Workspace tools historically dispatched by name in [Keeper_tool_dispatch_runtime]
   without input-schema validation — the underlying handlers (Board_tool,
   Tool_library, Keeper_tool_task_runtime, Keeper_tool_voice_runtime, etc.) parse
   their own input. The descriptor input_schema is informational only
   (these tools are Hidden visibility; no LLM sees the schema). A
   passthrough object schema preserves behavior. *)
let passthrough_object_schema =
  `Assoc
    [ "type", `String "object"; "additionalProperties", `Bool true ]
;;

let find_schema_input_opt schemas name =
  List.find_opt (fun (s : Masc_domain.tool_schema) -> String.equal s.name name)
    schemas
  |> Option.map (fun (s : Masc_domain.tool_schema) -> s.input_schema)
;;

let find_taskboard_schema_opt name =
  find_schema_input_opt Tool_shard_types.taskboard_tools name
;;

let find_voice_schema_opt name =
  find_schema_input_opt Tool_shard_types.voice_tools name
;;

let find_base_schema_opt name =
  match find_schema_input_opt Tool_shard_types.base_tools name with
  | Some _ as schema -> schema
  | None -> find_schema_input_opt Tool_shard_types.filesystem_tools name
;;

let remove_schema_fields removed schema =
  match schema with
  | `Assoc fields ->
      let fields =
        List.filter_map
          (function
            | ("properties", `Assoc properties) ->
              Some
                ( "properties",
                  `Assoc
                    (List.filter
                       (fun (name, _) -> not (List.mem name removed))
                       properties) )
            | ("required", `List required) ->
              Some
                ( "required",
                  `List
                    (List.filter
                       (function
                         | `String name -> not (List.mem name removed)
                         | _ -> true)
                       required) )
            | field -> Some field)
          fields
      in
      `Assoc fields
  | _ -> schema

let find_board_schema_opt name =
  match Keeper_tool_name.masc_board_name_of_keeper_name name with
  | None -> None
  | Some board_name ->
    Board_tool_registry.schema_for_board_name board_name
    |> Option.map (fun (s : Masc_domain.tool_schema) ->
         remove_schema_fields
           (Board_tool_registry.identity_fields_for_board_name board_name)
           s.input_schema)

let find_masc_schema_opt name =
  match Tools.find_tool name with
  | Some schema -> Some schema.input_schema
  | None ->
    (* [Tool_agent_timeline] is registered by the main composition root and is
       intentionally absent from [Tools.all_schemas_extended] to avoid pulling
       keeper/runtime dependencies into the neutral schema aggregate. *)
    (match find_schema_input_opt Tool_agent_timeline.schemas name with
     | Some _ as schema -> schema
     | None -> find_schema_input_opt Keeper_schema.schemas name)

let find_cluster_schema_opt name =
  (* Priority preserves the historical hidden keeper namespace ownership:
     keeper taskboard wrappers first, then typed board wrappers, voice,
     then public masc_* aggregates. The namespaces are expected to be
     disjoint; this order is not a conflict resolver. *)
  match find_taskboard_schema_opt name with
  | Some _ as schema -> schema
  | None ->
    (match find_board_schema_opt name with
     | Some _ as schema -> schema
     | None ->
       (match find_voice_schema_opt name with
        | Some _ as schema -> schema
        | None -> find_masc_schema_opt name))
;;

let required_base_schema_input name =
  match find_base_schema_opt name with
  | Some schema -> schema
  | None -> unavailable_input_schema ("missing base tool schema for " ^ name)


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

let library_search_schema =
  object_schema
    [ property
        "query"
        "string"
        "Search query string; empty or missing returns a workflow error."
    ]
;;

let library_read_schema =
  object_schema
    ~required:[ "topic" ]
    [ property
        "topic"
        "string"
        "Exact document topic name from search results or known context."
    ]
;;

let surface_read_schema =
  object_schema
    ~required:[ "surface" ]
    [ property
        "surface"
        "string"
        "Lane label exactly as shown in Connected Surfaces or chat history \
         source: 'dashboard', 'discord', 'slack', or another connector's \
         channel label. Rows written before source labelling carry no label \
         and are not returned."
    ; property
        "limit"
        "integer"
        "Maximum lane messages to return (default 20, max 100). The \
         participant roster always covers the whole loaded lane."
    ]
;;

let surface_post_schema =
  object_schema
    ~required:[ "surface"; "content" ]
    [ property
        "surface"
        "string"
        "Lane to post to: 'dashboard' or 'discord'. Posting to a surface \
         this keeper is not bound to is an error, not a no-op."
    ; property "content" "string" "Message text to deliver on the lane."
    ; property
        "channel_id"
        "string"
        "Discord channel snowflake. Required only when more than one \
         channel is bound to this keeper; must be one of the bound \
         channels."
    ]
;;

let person_note_set_schema =
  object_schema
    ~required:[ "speaker_id"; "note" ]
    [ property
        "speaker_id"
        "string"
        "Stable speaker id from the roster (Discord snowflake). Notes \
         attach to ids, never to display names."
    ; property
        "note"
        "string"
        "What to remember about this person. Blank clears the note \
         (tombstone)."
    ]
;;

let memory_search_schema =
  required_base_schema_input "keeper_memory_search"
;;

let memory_write_schema =
  required_base_schema_input "keeper_memory_write"
;;

let ide_annotate_schema =
  required_base_schema_input "keeper_ide_annotate"
;;

let masc_fusion_schema =
  object_schema
    ~required:[ "prompt" ]
    [ property
        "prompt"
        "string"
        "Question or task to deliberate. A panel of models answers \
         independently, then a judge synthesises consensus, contradictions, \
         partial coverage, unique insights, and blind spots. Out-of-band: the \
         synthesis arrives asynchronously on this keeper's chat lane, not \
         inline in this turn."
    ; property
        "preset"
        "string"
        "Panel preset name from runtime.toml [fusion.presets]. Omitted uses \
         the configured default_preset."
    ; property
        "web_tools"
        "boolean"
        "When true, the panel and judge agents are given web_search / \
         web_fetch tools to ground their answers. Defaults to false; the \
         selected preset may also enable web tools on its own (the effective \
         setting is this flag OR the preset's)."
    ; property
        "topology"
        "string"
        "How to reduce the panel answers. \"simple\" (default): panel -> one \
         judge -> result. \"refine\": panel -> judge -> a second judge that \
         critically reviews and improves the first synthesis against the panel \
         evidence -> result (deeper, two judge passes). \"conditional\": like \
         simple, but escalates to a second (refine) judge only when the first \
         judge could not decide (verdict insufficient); otherwise returns the \
         first synthesis. \"judge_of_judges\": several distinct judges each \
         synthesise the panel independently and a meta-judge reconciles them \
         (requires the preset to configure >= 2 judges). \
         \"staged_judge_of_judges\": first judges are grouped by \
         [fusion].staged_judge_group_size, each group is reconciled by a \
         stage meta-judge, then a final meta-judge reconciles the stage \
         results (requires at least two exact groups; ragged counts are \
         rejected). Unknown values are rejected."
    ]
;;

let masc_fusion_status_schema =
  object_schema
    [ property
        "run_id"
        "string"
        "Optional fusion run id (the run_id returned by masc_fusion). When \
         given, returns that single run's status; when omitted, lists every \
         tracked run (in-progress and recently completed)."
    ]
;;

let analyze_image_schema =
  object_schema
    ~required:[ "artifact"; "query" ]
    [ property
        "artifact"
        "string"
        "Handle of a stored image artifact (the content-addressed id returned \
         when the image was stored). The raw image is read in a vision sub-call \
         and never enters this conversation."
    ; property
        "query"
        "string"
        "What to ask about the image, e.g. \"describe the chart\" or \
         \"transcribe the text\"."
    ; string_enum_property
        "media_type"
        Keeper_vision_tool.supported_image_media_types
        "Optional image MIME type override (e.g. image/png, image/jpeg). \
         Sniffed from the bytes when omitted."
    ]
;;

let read_only_in_process_policy ?(inline_safe = false) ?(maintenance_only = false)
      ?(polling_read = false) ?(visibility = Tool_catalog.Hidden) ()
  =
  policy
    ~visibility
    ~readonly:true
    ~effect_domain:Tool_catalog.Read_only
    ~approval:No_approval
    ~retryable:true
    ~inline_safe
    ~maintenance_only
    ~polling_read
    ()
;;

let write_in_process_policy ?(retryable = false) ?(inline_safe = false)
      ?(maintenance_only = false) ?(visibility = Tool_catalog.Hidden) ()
  =
  policy
    ~visibility
    ~readonly:false
    ~effect_domain:Tool_catalog.Playground_write
    ~approval:No_approval
    ~retryable
    ~inline_safe
    ~maintenance_only
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
    ~validate_translated_input:true
    ~translate:translate_identity
    ()
;;

(* Cluster-dispatched tools (board / voice / task) share a single
   [runtime_handler] variant but expose distinct [internal_name]s so each
   tool retains its own descriptor entry and receipt evidence. The
   [keeper_tool_in_process_runtime] handler routes by descriptor.internal_name. *)
let cluster_descriptor ?(polling_read = false) ~id ~name ~description ~handler ~readonly
      ~inline_safe ~maintenance_only
      ()
  =
  if polling_read && not readonly then
    invalid_arg "polling_read descriptors must declare readonly=true";
  if inline_safe && not readonly then
    invalid_arg "inline_safe descriptors must declare readonly=true";
  let policy =
    if readonly
    then read_only_in_process_policy ~inline_safe ~maintenance_only ~polling_read ()
    else write_in_process_policy ~inline_safe ~maintenance_only ()
  in
  let input_schema =
    match find_cluster_schema_opt name with
    | Some schema -> schema
    | None
      when Option.is_some
             (Keeper_tool_name.masc_board_name_of_keeper_name name) ->
      unavailable_input_schema ("missing board registry schema for " ^ name)
    | None -> passthrough_object_schema
  in
  in_process_descriptor
    ~id
    ~name
    ~description
    ~input_schema
    ~policy
    ~handler
;;

let board_descriptor name description ~readonly =
  cluster_descriptor
    ~id:("keeper.board." ^ String.sub name (String.length "keeper_board_")
         (String.length name - String.length "keeper_board_"))
    ~name
    ~description
    ~handler:Board_tool_dispatch
    ~readonly
    ~inline_safe:false
    ~maintenance_only:false
    ()
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
    | None -> List.mem name Board_tool_dispatch.tool_spec_read_only
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
  List.map masc_board_descriptor Board_tool_registry.tools
;;

let voice_descriptor name description ~readonly =
  cluster_descriptor
    ~id:("keeper.voice." ^ String.sub name (String.length "keeper_voice_")
         (String.length name - String.length "keeper_voice_"))
    ~name
    ~description
    ~handler:Tool_voice_dispatch
    ~readonly
    ~inline_safe:false
    ~maintenance_only:false
    ()
;;

let task_descriptor id name description ~readonly =
  cluster_descriptor
    ~id:("keeper.task." ^ id)
    ~name
    ~description
    ~handler:Tool_task_dispatch
    ~readonly
    ~inline_safe:false
    ~maintenance_only:false
    ()
;;

(* RFC-0182 §3.1 — additional masc_* cluster descriptor helpers (task /
   plan / run / agent / workspace). The masc_board_descriptor lives above
   (registry-driven); these helpers follow the same projection pattern
   but use hardcoded id+description because their dispatchers
   (Task.Tool / Tool_plan / Tool_run / Tool_agent / Tool_workspace) are not
   schema-registry-backed. The handler routes by descriptor.internal_name
   through the existing typed dispatcher. *)
let masc_task_descriptor id name description ~readonly =
  cluster_descriptor
    ~id:("masc.task." ^ id)
    ~name
    ~description
    ~handler:Tool_masc_task_dispatch
    ~readonly
    ~inline_safe:false
    ~maintenance_only:false
    ()
;;

let masc_plan_descriptor id name description ~readonly =
  cluster_descriptor
    ~id:("masc.plan." ^ id)
    ~name
    ~description
    ~handler:Tool_masc_plan_dispatch
    ~readonly
    ~inline_safe:false
    ~maintenance_only:false
    ()
;;

let masc_run_descriptor name description ~readonly =
  cluster_descriptor
    ~id:("masc.run." ^ String.sub name (String.length "masc_run_")
         (String.length name - String.length "masc_run_"))
    ~name
    ~description
    ~handler:Tool_masc_run_dispatch
    ~readonly
    ~inline_safe:false
    ~maintenance_only:false
    ()
;;

let masc_agent_descriptor id name description ~readonly =
  cluster_descriptor
    ~id:("masc.agent." ^ id)
    ~name
    ~description
    ~handler:Tool_masc_agent_dispatch
    ~readonly
    ~inline_safe:false
    ~maintenance_only:false
    ()
;;

let masc_workspace_descriptor ?(maintenance_only = false) id
      name description ~readonly
  =
  cluster_descriptor
    ~id:("masc.workspace." ^ id)
    ~name
    ~description
    ~handler:Tool_masc_workspace_dispatch
    ~readonly
    ~inline_safe:false
    ~maintenance_only
    ()
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
    ~inline_safe:false
    ~maintenance_only:false
    ()
;;

let masc_control_descriptor id name description ~readonly =
  cluster_descriptor
    ~id:("masc.control." ^ id)
    ~name
    ~description
    ~handler:Tool_masc_control_dispatch
    ~readonly
    ~inline_safe:false
    ~maintenance_only:false
    ()
;;

let masc_agent_timeline_descriptor name description ~readonly =
  cluster_descriptor
    ~id:"masc.agent_timeline"
    ~name
    ~description
    ~handler:Tool_masc_agent_timeline_dispatch
    ~readonly
    ~inline_safe:false
    ~maintenance_only:false
    ()
;;

let masc_schedule_descriptor (definition : Tool_schemas_schedule.definition) =
  let schema : Masc_domain.tool_schema = definition.schema in
  { (cluster_descriptor
       ~id:("masc.schedule." ^ definition.id)
       ~name:schema.name
       ~description:schema.description
       ~handler:Tool_masc_schedule_dispatch
       ~readonly:definition.read_only
       ~inline_safe:false
       ~maintenance_only:false
       ())
    with
    input_schema = schema.input_schema
  }
;;

let masc_keeper_descriptor ?(polling_read = false) id name description ~readonly =
  cluster_descriptor
    ~polling_read
    ~id:("masc.keeper." ^ id)
    ~name
    ~description
    ~handler:Tool_masc_keeper_dispatch
    ~readonly
    ~inline_safe:false
    ~maintenance_only:false
    ()
;;

let internal_descriptors : t list =
  [ (* ── time / catalog (RFC-0179 PR-2 + PR-3) ────────── *)
    in_process_descriptor
      ~id:"keeper.time.now"
      ~name:"keeper_time_now"
      ~description:
        "Return the current wall-clock time as ISO 8601 and Unix epoch \
         seconds. No arguments."
      ~input_schema:empty_object_schema
      ~policy:(read_only_in_process_policy ())
      ~handler:Tool_time_now
  ; (in_process_descriptor
       ~id:"keeper.tools_list"
       ~name:"keeper_tools_list"
       ~description:
         "List the active keeper tool surface from descriptors and registered schemas. \
          This is capability introspection, not connector content lookup. Use \
          keeper_surface_read only for current connected-surface lane context. \
          No arguments."
       ~input_schema:empty_object_schema
       ~policy:(read_only_in_process_policy ())
       ~handler:Tool_tools_list
     |> with_eval_tags [ "capability_introspection" ])
  ; (in_process_descriptor
       ~id:"keeper.tool_search"
       ~name:"keeper_tool_search"
       ~description:
         "Search keeper tool schemas by free-text query. Returns ranked tool \
          descriptions and input schemas."
       ~input_schema:tool_search_schema
       ~policy:(read_only_in_process_policy ())
       ~handler:Tool_tool_search
     |> with_eval_tags [ "capability_introspection" ])
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
      ~input_schema:memory_search_schema
      ~policy:(read_only_in_process_policy ())
      ~handler:Tool_memory_search
  ; in_process_descriptor
      ~id:"keeper.memory.write"
      ~name:"keeper_memory_write"
      ~description:"Persist a memory entry for this keeper."
      ~input_schema:memory_write_schema
      ~policy:(write_in_process_policy ())
      ~handler:Tool_memory_write
    (* ── library (RFC-0179 PR-3) ──────────────────────────────── *)
  ; in_process_descriptor
      ~id:"keeper.library.search"
      ~name:"keeper_library_search"
      ~description:"Search the keeper library catalog."
      ~input_schema:library_search_schema
      ~policy:(read_only_in_process_policy ())
      ~handler:Tool_library_search
  ; in_process_descriptor
      ~id:"keeper.library.read"
      ~name:"keeper_library_read"
      ~description:"Read a library entry by id."
      ~input_schema:library_read_schema
      ~policy:(read_only_in_process_policy ())
      ~handler:Tool_library_read
    (* ── connector surfaces (RFC-0223 P3) ─────────────────────── *)
  ; (in_process_descriptor
       ~id:"keeper.surface.read"
       ~name:"keeper_surface_read"
       ~description:
         "Read recent conversation from one connected surface lane (dashboard, \
          discord, slack, or another connector label) with speaker identity \
          and a derived participant roster. Use when the user asks about a \
          current connector lane, recent lane messages, or participants. This \
          does not enumerate connector-wide channel registries; if asked for \
          channels outside Connected Surfaces, read only visible lane evidence \
          and state that the wider registry is unavailable."
       ~input_schema:surface_read_schema
       ~policy:(read_only_in_process_policy ())
       ~handler:Tool_surface_read
     |> with_eval_tags [ "surface_context_read" ])
  ; in_process_descriptor
      ~id:"keeper.surface.post"
      ~name:"keeper_surface_post"
      ~description:
        "Post a message to one connected surface lane: 'dashboard' (appears \
         in the operator's chat transcript) or 'discord' (sends to the bound \
         channel). Posting to an unbound surface is an error."
      ~input_schema:surface_post_schema
      ~policy:(write_in_process_policy ())
      ~handler:Tool_surface_post
  ; in_process_descriptor
      ~id:"keeper.person.note_set"
      ~name:"keeper_person_note_set"
      ~description:
        "Remember (or clear) a note about a person met on a connected \
         surface, keyed by their roster speaker_id. Deliberate memory: \
         the note survives after their chat rows age out of the log \
         window and shows up on the keeper_surface_read roster."
      ~input_schema:person_note_set_schema
      ~policy:(write_in_process_policy ())
      ~handler:Tool_person_note_set
    (* ── IDE (RFC-0179 PR-3) ──────────────────────────────────── *)
  ; in_process_descriptor
      ~id:"keeper.ide.annotate"
      ~name:"keeper_ide_annotate"
      ~description:"Emit an IDE annotation event for the current keeper."
      ~input_schema:ide_annotate_schema
      ~policy:(write_in_process_policy ())
      ~handler:Tool_ide_annotate
    (* ── fusion deliberation (RFC-0252) ───────────────────────── *)
  ; in_process_descriptor
      ~id:"masc.fusion.deliberate"
      ~name:"masc_fusion"
      ~description:
        "Run an out-of-band panel+judge deliberation. A panel of models from \
         the configured preset answers the prompt independently; a judge model \
         synthesises consensus, contradictions, partial coverage, unique \
         insights, and blind spots. Advisory only: this keeper turn continues \
         immediately; when the deliberation completes you are WOKEN with the \
         result, and the conclusion (or the failure reason) is appended to \
         your chat lane (also visible in the dashboard) — do not poll \
         masc_fusion_status while waiting. Returns a status with a run_id. \
         Panels answer from their own knowledge only: they cannot see your \
         files, tasks, or conversation, so phrase the prompt \
         self-contained. Set web_tools=true to let the panel and judge ground \
         their answers with web_search / web_fetch. Gated by runtime.toml \
         [fusion] (disabled by default)."
      ~input_schema:masc_fusion_schema
      (* RFC-0252 §159/§177: 심의 가치는 키퍼(이미 LLM)가 스스로 판단해
         masc_fusion 을 직접 호출하는 것으로 표현된다. 따라서 키퍼가 LLM 도구
         목록에서 이 도구를 볼 수 있어야 한다 → visibility=Default. 다른
         in-process write 도구의 기본값(Hidden, playground_write 공통)을 그대로
         쓰면 키퍼가 도구를 못 봐 자율 호출이 불가능해 RFC 의도와 모순된다. *)
      ~policy:(write_in_process_policy ~visibility:Tool_catalog.Default ())
      ~handler:Tool_masc_fusion_dispatch
    (* ── fusion status (RFC-0266 §7 Phase 3) ──────────────────── *)
  ; in_process_descriptor
      ~id:"masc.fusion.status"
      ~name:"masc_fusion_status"
      ~description:
        "Read the status of out-of-band fusion deliberations started by \
         masc_fusion. With no argument, lists tracked runs (in-progress and \
         recently completed); with a run_id, returns that single run. Each run \
         reports keeper, preset, started_at (unix seconds), and status \
         (running | completed | failed); failed runs also carry error and \
         failure_code. Prefer waiting for the completion wake over polling \
         this tool — the result reaches you without it. Read-only — does not \
         start a deliberation. In-memory and server-lifetime: runs do not \
         survive a restart."
      ~input_schema:masc_fusion_status_schema
      (* read-only, but visibility=Default so the keeper LLM can poll its own
         fusion runs (sibling to masc_fusion, which is also Default). Without
         the override read_only_in_process_policy defaults to Hidden and the
         keeper could not see the tool. *)
      ~policy:(read_only_in_process_policy ~visibility:Tool_catalog.Default ())
      ~handler:Tool_masc_fusion_status
    (* ── vision delegation (RFC-keeper-vision-delegation-tool §2.6) ─ *)
  ; in_process_descriptor
      ~id:"keeper.vision.analyze_image"
      ~name:"analyze_image"
      ~description:
         "Read a stored image artifact and return a text description or answer. \
         Delegates to a vision model in a sub-call; the image is never added to \
         this conversation. Returns the extracted text, or a typed error \
         (invalid_args | eio_context_unavailable | artifact_load_failed | \
         invalid_timeout | image_too_large | invalid_media_type | \
         invalid_request | no_capable_runtime | empty_extraction | \
         truncated_extraction | timeout | provider_error)."
      ~input_schema:analyze_image_schema
      (* read-only (a sub-call, no side effects) but visibility=Default so the
         keeper LLM can see and call it — read_only_in_process_policy defaults to
         Hidden (same gotcha as masc_fusion_status above). *)
      ~policy:(read_only_in_process_policy ~visibility:Tool_catalog.Default ())
      ~handler:Tool_analyze_image
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
      "Read the keeper voice capability, assigned voice, and active turn-based \
       session state. This does not start a realtime audio stream."
      ~readonly:true
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
      "broadcast"
      "keeper_broadcast"
      "Broadcast a workspace message to the MASC workspace."
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
    (* ── board cluster (RFC-0179 PR-3, 14 tools) ──────────────── *)
  ; board_descriptor
      "keeper_board_comment"
      "Comment on one board post. Requires an exact post_id from board activity, keeper_board_list, keeper_board_search, or keeper_board_post_get."
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
      "keeper_board_post_get"
      "Read one board post by exact post_id. Use keeper_board_list or keeper_board_search first when no post_id is visible; do not call with empty arguments."
      ~readonly:true
  ; board_descriptor
      "keeper_board_list"
      "List recent board posts and return post_id values for follow-up board get/comment/vote calls."
      ~readonly:true
  ; board_descriptor
      "keeper_board_post"
      "Post a new board entry. Quantitative claims require code-anchor evidence."
      ~readonly:false
  ; board_descriptor
      "keeper_board_search"
      "Search board posts by keyword and return post_id values for follow-up board get/comment/vote calls."
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
      "Vote on one board post. Requires an exact post_id from board activity, keeper_board_list, keeper_board_search, or keeper_board_post_get."
      ~readonly:false
  (* ── RFC-0182 §3.1 — masc_task_* cluster (7 entries) ─────────── *)
  ; masc_task_descriptor "add" "masc_add_task"
      "Add a task to the workspace plan." ~readonly:false
  ; masc_task_descriptor "batch_add" "masc_batch_add_tasks"
      "Add multiple tasks in a single call." ~readonly:false
  ; masc_task_descriptor "task_history" "masc_task_history"
      "Read history events for a task." ~readonly:true
  ; masc_task_descriptor "tasks" "masc_tasks"
      "List tasks visible to the caller." ~readonly:true
  ; masc_task_descriptor "transition" "masc_transition"
      "Transition a task to a new status." ~readonly:false
  ; masc_task_descriptor "update_priority" "masc_update_priority"
      "Update the priority of a task." ~readonly:false
  ; masc_task_descriptor "set_goal" "masc_task_set_goal"
      "Assign an existing, currently goalless task to a goal." ~readonly:false
  (* ── RFC-0182 §3.1 — masc_plan_* + note + deliver (8 entries) ── *)
  ; masc_plan_descriptor "init" "masc_plan_init"
      "Initialise a workspace plan." ~readonly:false
  ; masc_plan_descriptor "update" "masc_plan_update"
      "Update a workspace plan." ~readonly:false
  ; masc_plan_descriptor "get" "masc_plan_get"
      "Read the current plan, creating an empty planning context when missing."
      ~readonly:false
  ; masc_plan_descriptor "set_task" "masc_plan_set_task"
      "Bind a task to a plan slot." ~readonly:false
  ; masc_plan_descriptor "get_task" "masc_plan_get_task"
      "Read the task bound to a plan slot." ~readonly:true
  ; masc_plan_descriptor "clear_task" "masc_plan_clear_task"
      "Unbind a task from a plan slot." ~readonly:false
  ; masc_plan_descriptor "note_add" "masc_note_add"
      "Append a workspace note." ~readonly:false
  ; masc_plan_descriptor "deliver" "masc_deliver"
      "Record a deliverable against the plan." ~readonly:false
  (* ── RFC-0182 §3.1 — masc_run_* cluster (4 entries) ──────────── *)
  ; masc_run_descriptor "masc_run_init"
      "Initialise a workspace run." ~readonly:false
  ; masc_run_descriptor "masc_run_list"
      "List recent runs." ~readonly:true
  ; masc_run_descriptor "masc_run_get"
      "Read a single run by id, creating an empty run record when missing."
      ~readonly:false
  ; masc_run_descriptor "masc_run_plan"
      "Read the run plan." ~readonly:true
  (* ── RFC-0182 §3.1 — masc_agent_* cluster (3 entries; masc_agents +
       masc_agent_update removed 2026-06-09 with the dead agent-status
       surface) ────────── *)
  ; (masc_agent_descriptor "card" "masc_agent_card"
       "Read an agent card." ~readonly:true
     |> with_eval_tags [ "agent_profile_lookup" ])
  ; masc_agent_descriptor "fitness" "masc_agent_fitness"
      "Read agent fitness metrics." ~readonly:true
  ; masc_agent_descriptor "get_metrics" "masc_get_metrics"
      "Read aggregated agent metrics." ~readonly:true
  (* ── RFC-0182 §3.1 — masc_workspace_* cluster (8 entries) ────────── *)
  ; masc_workspace_descriptor "status" "masc_status"
      "Read overall workspace status." ~readonly:true
  ; masc_workspace_descriptor ~maintenance_only:true "heartbeat" "masc_heartbeat"
      "Emit an agent heartbeat." ~readonly:false
  ; masc_workspace_descriptor "check" "masc_check"
      "Read a workspace assertion check." ~readonly:true
  ; masc_workspace_descriptor "reset" "masc_reset"
      "Reset workspace state." ~readonly:false
  ; masc_workspace_descriptor "goal_list" "masc_goal_list"
      "List workspace goals." ~readonly:true
  ; masc_workspace_descriptor "goal_upsert" "masc_goal_upsert"
      "Create or update a workspace goal." ~readonly:false
  ; masc_workspace_descriptor "goal_transition" "masc_goal_transition"
      "Transition a goal status." ~readonly:false
  ; masc_workspace_descriptor "goal_verify" "masc_goal_verify"
      "Verify goal completion criteria." ~readonly:false
  (* ── RFC-0182 §3.1 — masc_misc_* cluster (9 entries) ─────────── *)
  ; masc_misc_descriptor "config" "masc_config"
      "Read workspace configuration." ~readonly:true
  ; masc_misc_descriptor "dashboard" "masc_dashboard"
      "Read workspace dashboard summary." ~readonly:true
  ; masc_misc_descriptor "cleanup_zombies" "masc_cleanup_zombies"
      "Reap orphan / zombie workspace state." ~readonly:false
  ; masc_misc_descriptor "tool_stats" "masc_tool_stats"
      "Read tool-usage statistics." ~readonly:true
  ; masc_misc_descriptor "tool_help" "masc_tool_help"
      "Read help text for a tool name." ~readonly:true
  (* [masc_web_search] / [masc_web_fetch] are already owned by the
     MASC-owned web descriptors above. Do not add
     duplicate internal descriptors here; that would make runtime receipt
     projection depend on list order. *)
  (* ── RFC-0182 §3.1 — masc_control_* cluster (2 entries) ──────── *)
  ; masc_control_descriptor "pause" "masc_pause"
      "Pause a paused/runnable agent." ~readonly:false
  ; masc_control_descriptor "resume" "masc_resume"
      "Resume a paused agent." ~readonly:false
  (* ── RFC-0182 §3.1 — masc_agent_timeline singleton (1 entry) ── *)
  ; masc_agent_timeline_descriptor "masc_agent_timeline"
      "Read agent timeline events." ~readonly:true
  (* ── RFC-0234 — scheduled internal automation (6 entries) ─────── *)
  ]
  @ List.map masc_schedule_descriptor Tool_schemas_schedule.definitions
  @ [
  (* ── RFC-0182 §3.1 — masc_keeper cluster (1 entry today) ──── *)
  (* Other masc_keeper_ tools (status, msg, clear, compact, repair,
     sandbox lifecycle) use the keeper Eio context and are gated on
     Phase 5 Eio plumbing scope. *)
    masc_keeper_descriptor "list" "masc_keeper_list"
      "List configured keepers with optional detailed metadata." ~readonly:true
  ; masc_keeper_descriptor "msg_result" "masc_keeper_msg_result"
      "Poll an async keeper_msg dispatch by request_id." ~readonly:true
      ~polling_read:true
  ; masc_keeper_descriptor "msg_cancel" "masc_keeper_msg_cancel"
      "Cancel a running async keeper_msg turn by request_id." ~readonly:false
  ; masc_keeper_descriptor "msg_queue" "masc_keeper_msg_queue"
      "List all pending/running async keeper_msg requests, optionally filtered by keeper_name." ~readonly:true
  ; masc_keeper_descriptor "compact" "masc_keeper_compact"
      "Run operator-requested context compaction on a keeper." ~readonly:false
  ; masc_keeper_descriptor "clear" "masc_keeper_clear"
      "Last-resort context clear (drops conversation, requires reason)." ~readonly:false
  ; masc_keeper_descriptor "sandbox_start" "masc_keeper_sandbox_start"
      "Start the managed sandbox container for a keeper." ~readonly:false
  ; masc_keeper_descriptor "sandbox_stop" "masc_keeper_sandbox_stop"
      "Stop the managed sandbox container(s) for a keeper or fleet." ~readonly:false
  ; masc_keeper_descriptor "reset" "masc_keeper_reset"
      "Reset a keeper's runtime state (usage counters, last_model_used)." ~readonly:false
  ; masc_keeper_descriptor "persona_audit" "masc_keeper_persona_audit"
      "Audit configured keepers vs personas." ~readonly:true
  ; masc_keeper_descriptor "status" "masc_keeper_status"
      "Detailed single-keeper status (defaults to self when name is empty)." ~readonly:true
  ; masc_keeper_descriptor "repair" "masc_keeper_repair"
      "Validate keeper repair inputs (execution path currently unsupported)." ~readonly:false
  ; masc_keeper_descriptor "adversarial_review" "masc_keeper_adversarial_review"
      "Run fresh-context structural adversarial review on a diff or changed file." ~readonly:true
  ; masc_keeper_descriptor "down" "masc_keeper_down"
      "Stop keeper keepalive, optionally remove meta and session directory." ~readonly:false
  (* RFC-0182 Phase 5 PR-B: Eio-bound keeper tools (require sw + clock). *)
  ; masc_keeper_descriptor "msg" "masc_keeper_msg"
      "Submit an async keeper turn (returns request_id for keeper_msg_result polling)." ~readonly:false
  ; masc_keeper_descriptor "up" "masc_keeper_up"
      "Bring a keeper online (create new or update existing)." ~readonly:false
  (* ── RFC-0182 §3.1 — masc_surface_audit singleton ────────────── *)
  ; cluster_descriptor
      ~id:"masc.surface.audit"
      ~name:"masc_surface_audit"
      ~description:"Read dashboard surface readiness snapshot (optionally for a single surface)."
      ~handler:Tool_masc_surface_audit
      ~readonly:true
      ~inline_safe:false
      ~maintenance_only:false
      ()
  ]
  @ masc_board_descriptors
;;

let all_descriptors () = public_descriptors @ internal_descriptors

let model_visible_descriptors () =
  let visible_internal_descriptors =
    internal_descriptors
    |> List.filter (fun descriptor ->
      match descriptor.policy.visibility with
      | Tool_catalog.Default -> true
      | Tool_catalog.Hidden -> false)
  in
  public_descriptors @ visible_internal_descriptors
;;

let public_names_of_descriptor d = d.public_name :: d.public_aliases

let public_names () = List.concat_map public_names_of_descriptor public_descriptors

let internal_names d =
  [ d.internal_name ]
;;

let find_public name =
  List.find_opt
    (fun d -> List.exists (String.equal name) (public_names_of_descriptor d))
    public_descriptors
;;

let public_descriptors_for_internal internal_name =
  List.filter
    (fun d -> List.exists (String.equal internal_name) (internal_names d))
    public_descriptors
;;

(* Walks [all_descriptors ()]. Used by the runtime dispatcher to resolve any
   descriptor-backed tool by its internal name, including workspace tools
   that live in [internal_descriptors]. While [internal_descriptors = []], this
   returns the same result as [public_descriptors_for_internal]. *)
let descriptors_for_internal internal_name =
  List.filter
    (fun d -> List.exists (String.equal internal_name) (internal_names d))
    (all_descriptors ())
;;

let readonly_static_hint d = d.policy.readonly_hint
let readonly_for_input d ~input = d.policy.readonly_of_input input

let readonly_internal_names () =
  all_descriptors ()
  |> List.concat_map (fun d ->
    match readonly_static_hint d with
    | Some true -> internal_names d
    | Some false | None -> [])
  |> List.sort_uniq String.compare
;;

let keeper_safe_inline_names () =
  all_descriptors ()
  |> List.concat_map (fun d -> if d.policy.inline_safe then internal_names d else [])
  |> List.sort_uniq String.compare
;;

let keeper_maintenance_only_names () =
  all_descriptors ()
  |> List.concat_map (fun d ->
       if d.policy.maintenance_only then internal_names d else [])
  |> List.sort_uniq String.compare
;;

let polling_read_internal_names () =
  all_descriptors ()
  |> List.concat_map (fun d ->
       if d.policy.polling_read then internal_names d else [])
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


let receipt_labels_json d =
  `Assoc (List.map (fun (key, value) -> key, `String value) d.receipt_labels)
;;

let eval_tags_json d =
  `List (List.map (fun tag -> `String tag) d.eval_tags)
;;

let effect_domain_json = function
  | Some effect_domain -> `String (Tool_catalog.effect_domain_to_string effect_domain)
  | None -> `Null
;;

let effect_domain_fields = function
  | Some domain ->
    [ "effect_domain", `String (Tool_catalog.effect_domain_to_string domain) ]
  | None -> []
;;

let common_policy_json_fields ~readonly_key policy =
  [ "visibility", `String (Tool_catalog.visibility_to_string policy.visibility)
  ; readonly_key, Json_util.bool_opt_to_json policy.readonly_hint
  ; "approval", `String (approval_to_string policy.approval)
  ; "retryable", `Bool policy.retryable
  ; "cwd_scope", Json_util.string_opt_to_json policy.cwd_scope
  ; "inline_safe", `Bool policy.inline_safe
  ; "maintenance_only", `Bool policy.maintenance_only
  ; "polling_read", `Bool policy.polling_read
  ]
;;

(* Route evidence consumers must read fields by key; object field order is not a
   compatibility contract. *)
let route_evidence_json d =
  let policy = d.policy in
  `Assoc
    ([ "descriptor_id", `String d.id
     ; "public_name", `String d.public_name
     ; "canonical_name", `String d.internal_name
     ; "description", `String d.description
     ; "executor", `String (executor_to_string d.executor)
     ; "backend", `String (backend_to_string d.backend)
     ; "sandbox", `String (sandbox_to_string d.sandbox)
     ; "runtime_handler", `String (runtime_handler_to_string d.runtime_handler)
     ; "receipt_labels", receipt_labels_json d
     ; "eval_tags", eval_tags_json d
     ]
     @ common_policy_json_fields ~readonly_key:"readonly" policy
     @ effect_domain_fields policy.effect_domain)
;;

let discovery_policy_json policy =
  `Assoc
    (common_policy_json_fields ~readonly_key:"readonly_hint" policy
     @ [ "effect_domain", effect_domain_json policy.effect_domain ])
;;

let discovery_fields d =
  let examples_field =
    match d.examples with
    | [] -> []
    | examples -> [ "examples", `List examples ]
  in
  [ "id", `String d.id
  ; "public_name", `String d.public_name
  ; "public_aliases", Json_util.json_string_list d.public_aliases
  ; "internal_name", `String d.internal_name
  ; "description", `String d.description
  ; "executor", `String (executor_to_string d.executor)
  ; "backend", `String (backend_to_string d.backend)
  ; "sandbox", `String (sandbox_to_string d.sandbox)
  ; "runtime_handler", `String (runtime_handler_to_string d.runtime_handler)
  ; "policy", discovery_policy_json d.policy
  ; "schema_shape", Tool_input_validation.schema_shape_json d.input_schema
  ]
  @ examples_field
;;

let discovery_json d =
  `Assoc (discovery_fields d)
;;
