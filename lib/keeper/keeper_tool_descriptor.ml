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

type keeper_model_projection =
  | Preferred_public_name
  | Internal_name
  | Transport_alias of { projected_by : string }

type model_description_projection =
  | Static_description
  | Current_task_state

type keeper_tool_group =
  | Execute_group
  | Search_files_group
  | Filesystem_group
  | Board_group
  | Voice_group
  | Workspace_group
  | Surface_group
  | Memory_group
  | Meta_group
  | Core_group

type input_schema_source =
  | Descriptor_owned
  | Canonical_registry
  | Missing_canonical_registry

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
  | Tool_web_search
  | Tool_web_fetch
  | Tool_masc_control_dispatch
  | Tool_masc_agent_timeline_dispatch
  | Tool_masc_schedule_dispatch
  | Tool_masc_keeper_dispatch
  | Tool_masc_fusion_dispatch
  | Tool_masc_fusion_status
  | Tool_masc_library_dispatch
  | Tool_masc_recurring_dispatch
  | Tool_masc_local_runtime_dispatch
  | Tool_analyze_image

type policy =
  { readonly_of_input : readonly_of_input
  ; readonly_hint : bool option
  ; retryable : bool
  ; cwd_scope : string option
  ; inline_safe : bool
  ; polling_read : bool
  }

type t =
  { id : string
  ; keeper_model_projection : keeper_model_projection
  ; model_description_projection : model_description_projection
  ; keeper_tool_group : keeper_tool_group
  ; input_schema_source : input_schema_source
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

let keeper_model_projection_to_string = function
  | Preferred_public_name -> "preferred_public_name"
  | Internal_name -> "internal_name"
  | Transport_alias _ -> "transport_alias"
;;

let model_description_projection_to_string = function
  | Static_description -> "static_description"
  | Current_task_state -> "current_task_state"
;;

let keeper_tool_group_to_string = function
  | Execute_group -> "execute"
  | Search_files_group -> "search_files"
  | Filesystem_group -> "fs"
  | Board_group -> "board"
  | Voice_group -> "voice"
  | Workspace_group -> "workspace"
  | Surface_group -> "surface"
  | Memory_group -> "memory"
  | Meta_group -> "meta"
  | Core_group -> "core"
;;

let input_schema_source_to_string = function
  | Descriptor_owned -> "descriptor_owned"
  | Canonical_registry -> "canonical_registry"
  | Missing_canonical_registry -> "missing_canonical_registry"
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
  | Tool_web_search -> "tool_web_search"
  | Tool_web_fetch -> "tool_web_fetch"
  | Tool_masc_control_dispatch -> "tool_masc_control_dispatch"
  | Tool_masc_agent_timeline_dispatch -> "tool_masc_agent_timeline_dispatch"
  | Tool_masc_schedule_dispatch -> "tool_masc_schedule_dispatch"
  | Tool_masc_keeper_dispatch -> "tool_masc_keeper_dispatch"
  | Tool_masc_fusion_dispatch -> "tool_masc_fusion_dispatch"
  | Tool_masc_fusion_status -> "tool_masc_fusion_status"
  | Tool_masc_library_dispatch -> "tool_masc_library_dispatch"
  | Tool_masc_recurring_dispatch -> "tool_masc_recurring_dispatch"
  | Tool_masc_local_runtime_dispatch -> "tool_masc_local_runtime_dispatch"
  | Tool_analyze_image -> "tool_analyze_image"
;;

let keeper_tool_group_of_runtime_handler = function
  | Tool_execute -> Execute_group
  | Tool_search_files -> Search_files_group
  | Tool_read_file | Tool_edit_file | Tool_write_file -> Filesystem_group
  | Board_tool_dispatch | Tool_masc_board_dispatch -> Board_group
  | Tool_voice_dispatch -> Voice_group
  | Tool_task_dispatch | Tool_masc_task_dispatch | Tool_masc_plan_dispatch ->
    Workspace_group
  | Tool_masc_run_dispatch
  | Tool_masc_agent_dispatch
  | Tool_masc_workspace_dispatch
  | Tool_masc_control_dispatch
  | Tool_masc_agent_timeline_dispatch
  | Tool_masc_schedule_dispatch
  | Tool_masc_keeper_dispatch
  | Tool_masc_fusion_dispatch
  | Tool_masc_fusion_status
  | Tool_masc_misc_dispatch
  | Tool_web_search
  | Tool_web_fetch
  | Tool_masc_local_runtime_dispatch
  | Tool_analyze_image -> Core_group
  | Tool_surface_read | Tool_surface_post | Tool_person_note_set -> Surface_group
  | Tool_memory_search
  | Tool_memory_write
  | Tool_library_search
  | Tool_library_read
  | Tool_masc_library_dispatch -> Memory_group
  | Tool_masc_recurring_dispatch -> Workspace_group
  | Tool_time_now
  | Tool_tools_list
  | Tool_tool_search
  | Tool_context_status
  | Tool_ide_annotate -> Meta_group
;;

let discovery_example ~label ?cwd ~argv () =
  let input =
    `Assoc
      ([ "argv", Json_util.json_string_list argv ]
       @
       match cwd with
       | Some cwd -> [ "cwd", `String cwd ]
       | None -> [])
  in
  `Assoc [ "label", `String label; "input", input ]
;;

let policy ?readonly ?readonly_of_input ?cwd_scope ?(retryable = false)
      ?(inline_safe = false) ?(polling_read = false) ()
  =
  let readonly_of_input =
    match readonly_of_input with
    | Some readonly_of_input -> readonly_of_input
    | None -> fun _input -> readonly
  in
  { readonly_of_input
  ; readonly_hint = readonly
  ; retryable
  ; cwd_scope
  ; inline_safe
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
      ~keeper_model_projection
      ~input_schema_source
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
    ; ( "keeper_model_projection"
      , keeper_model_projection_to_string keeper_model_projection )
    ; "public_name", public_name
    ; "canonical_name", internal_name
    ; "executor", executor_to_string executor
    ; "backend", backend_to_string backend
    ; "sandbox", sandbox_to_string sandbox
    ; "runtime_handler", runtime_handler_to_string runtime_handler
    ; ( "keeper_tool_group"
      , keeper_tool_group_to_string
          (keeper_tool_group_of_runtime_handler runtime_handler) )
    ; "input_schema_source", input_schema_source_to_string input_schema_source
    ]
    @ (match keeper_model_projection with
       | Transport_alias { projected_by } ->
         [ "transport_alias_of", projected_by ]
       | Preferred_public_name | Internal_name -> [])
  in
  { id
  ; keeper_model_projection
  ; model_description_projection = Static_description
  ; keeper_tool_group = keeper_tool_group_of_runtime_handler runtime_handler
  ; input_schema_source
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
      ~keeper_model_projection
      ~input_schema_source
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
    ~keeper_model_projection
    ~input_schema_source
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
      ~keeper_model_projection:Preferred_public_name
      ~input_schema_source:Descriptor_owned
      ~id:"agent.execute"
      ~public_name:"Execute"
      ~internal_name:"tool_execute"
      ~description:
        "Execute one opaque typed process invocation inside the Keeper sandbox. \
         Provide one non-empty argv process vector, or an explicit typed \
         pipeline. Use typed stdin/stdout/stderr fields for \
         I/O and typed env for environment variables. MASC validates the input \
         shape, path jail, sandbox target, and external-effect Gate but never \
         interprets program or subcommand meaning. The invoked program owns \
         its syntax and exit result."
      ~input_schema:execute_schema
      ~policy:
        (policy
           ~cwd_scope:"keeper_sandbox_or_allowed_path"
           ~retryable:false
           ())
      ~executor:Shell_ir
      ~backend:Sandbox_process
      ~sandbox:Backend_selected
      ~runtime_handler:Tool_execute
      ~examples:
        [ discovery_example
            ~label:"Run an opaque typed program"
            ~cwd:"<allowed-directory>"
            ~argv:[ "program"; "--version" ]
            ()
        ]
      ~validate_translated_input:true
      ~translate:translate_identity
      ()
  ; descriptor_with_public_aliases
      ~keeper_model_projection:Preferred_public_name
      ~input_schema_source:Descriptor_owned
      ~id:"agent.search_files"
      ~public_name:"Grep"
      ~public_aliases:[ "Search"; "search_files" ]
      ~internal_name:"tool_search_files"
      ~description:
        "Search file contents with ripgrep: provide a regex `pattern` (and \
         optionally path/glob/type). To list a directory, read a file, or run \
         git status/log/diff, use the Execute tool (e.g. \
         argv=['ls','-la','<path>']). Patterns match within a single line; a \
         literal newline in `pattern` is rejected. To match across lines, run \
         `rg -U` through the Execute tool."
      ~input_schema:search_files_schema
      ~policy:
        (policy
           ~readonly:true
           ~readonly_of_input:search_files_readonly_of_input
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
      ~keeper_model_projection:Preferred_public_name
      ~input_schema_source:Descriptor_owned
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
      ~keeper_model_projection:Preferred_public_name
      ~input_schema_source:Descriptor_owned
      ~id:"agent.edit_file"
      ~public_name:"Edit"
      ~internal_name:"tool_edit_file"
      ~description:
        "Patch an existing file by replacing an exact string. Read the file \
         first and copy old_string verbatim from its current bytes, including \
         leading whitespace, indentation, and newlines; the match is exact and \
         byte-sensitive. On 'old_string not found', re-Read the file to get the \
         current text instead of retrying the same string."
      ~input_schema:edit_file_schema
      ~policy:
        (policy
           ~readonly:false
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
      ~keeper_model_projection:Preferred_public_name
      ~input_schema_source:Descriptor_owned
      ~id:"agent.write_file"
      ~public_name:"Write"
      ~internal_name:"tool_write_file"
      ~description:"Write full file content into the keeper sandbox or an allowed path."
      ~input_schema:write_file_schema
      ~policy:
        (policy
           ~readonly:false
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
      ~keeper_model_projection:Preferred_public_name
      ~input_schema_source:Descriptor_owned
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
           ~retryable:true
           ())
      ~executor:In_process
      ~backend:Ocaml_runtime
      ~sandbox:No_sandbox
      ~runtime_handler:Tool_web_search
      ~validate_translated_input:true
      ~translate:translate_identity
      ()
  ; descriptor
      ~keeper_model_projection:Preferred_public_name
      ~input_schema_source:Descriptor_owned
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
           ~retryable:true
           ())
      ~executor:In_process
      ~backend:Ocaml_runtime
      ~sandbox:No_sandbox
      ~runtime_handler:Tool_web_fetch
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

let find_misc_schema_opt name =
  find_schema_input_opt Tool_schemas_misc.schemas name
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
    let schema = Board_tool_registry.schema_for_board_name board_name in
    Some
      (remove_schema_fields
         (Board_tool_registry.identity_fields_for_board_name board_name)
         schema.input_schema)

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
     the generated misc registry, then public masc_* aggregates.
     The namespaces are expected to be disjoint; this order is not a conflict
     resolver. Control descriptors use their dedicated typed schema projection
     and do not enter this name-based lookup. *)
  match find_taskboard_schema_opt name with
  | Some _ as schema -> schema
  | None ->
    (match find_board_schema_opt name with
     | Some _ as schema -> schema
     | None ->
       (match find_voice_schema_opt name with
        | Some _ as schema -> schema
        | None ->
          (match find_misc_schema_opt name with
           | Some _ as schema -> schema
           | None -> find_masc_schema_opt name)))
;;

let base_schema_input name =
  match find_base_schema_opt name with
  | Some schema -> Canonical_registry, schema
  | None ->
    ( Missing_canonical_registry
    , unavailable_input_schema ("missing base tool schema for " ^ name) )

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

let memory_search_schema_source, memory_search_schema =
  base_schema_input "keeper_memory_search"
;;

let memory_write_schema_source, memory_write_schema =
  base_schema_input "keeper_memory_write"
;;

let ide_annotate_schema_source, ide_annotate_schema =
  base_schema_input "keeper_ide_annotate"
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
         in their configured order. Unknown values are rejected."
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

let read_only_in_process_policy ?(inline_safe = false) ?(polling_read = false) ()
  =
  policy
    ~readonly:true
    ~retryable:true
    ~inline_safe
    ~polling_read
    ()
;;

let write_in_process_policy ?(retryable = false) ?(inline_safe = false) ()
  =
  policy
    ~readonly:false
    ~retryable
    ~inline_safe
    ()
;;

let in_process_descriptor_with_schema_source ~keeper_model_projection
      ~input_schema_source ~id ~name ~description ~input_schema ~policy ~handler
  =
  descriptor
    ~keeper_model_projection
    ~input_schema_source
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

let in_process_descriptor ~keeper_model_projection ~id ~name ~description
      ~input_schema ~policy ~handler
  =
  in_process_descriptor_with_schema_source
    ~keeper_model_projection
    ~input_schema_source:Descriptor_owned
    ~id
    ~name
    ~description
    ~input_schema
    ~policy
    ~handler
;;

(* Cluster-dispatched tools (board / voice / task) share a single
   [runtime_handler] variant but expose distinct [internal_name]s so each
   tool retains its own descriptor entry and receipt evidence. The
   [keeper_tool_in_process_runtime] handler routes by descriptor.internal_name. *)
let cluster_policy ?(polling_read = false) ~readonly ~inline_safe () =
  if polling_read && not readonly then
    invalid_arg "polling_read descriptors must declare readonly=true";
  if inline_safe && not readonly then
    invalid_arg "inline_safe descriptors must declare readonly=true";
  if readonly
  then read_only_in_process_policy ~inline_safe ~polling_read ()
  else write_in_process_policy ~inline_safe ()
;;

let cluster_descriptor_with_schema_source ?(polling_read = false)
      ~keeper_model_projection ~input_schema_source ~input_schema ~id ~name
      ~description ~handler ~readonly ~inline_safe () =
  let policy = cluster_policy ~polling_read ~readonly ~inline_safe () in
  in_process_descriptor_with_schema_source
    ~keeper_model_projection
    ~input_schema_source
    ~id
    ~name
    ~description
    ~input_schema
    ~policy
    ~handler
;;

let cluster_descriptor ?(polling_read = false) ~keeper_model_projection ~id ~name
      ~description ~handler ~readonly ~inline_safe ()
  =
  let input_schema_source, input_schema =
    match find_cluster_schema_opt name with
    | Some schema -> Canonical_registry, schema
    | None ->
      ( Missing_canonical_registry
      , unavailable_input_schema ("missing canonical registry schema for " ^ name) )
  in
  cluster_descriptor_with_schema_source
    ~polling_read
    ~keeper_model_projection
    ~input_schema_source
    ~input_schema
    ~id
    ~name
    ~description
    ~handler
    ~readonly
    ~inline_safe
    ()
;;

let with_current_task_state_description descriptor =
  { descriptor with model_description_projection = Current_task_state }
;;

let board_descriptor name description ~readonly =
  cluster_descriptor
    ~keeper_model_projection:Internal_name
    ~id:("keeper.board." ^ String.sub name (String.length "keeper_board_")
         (String.length name - String.length "keeper_board_"))
    ~name
    ~description
    ~handler:Board_tool_dispatch
    ~readonly
    ~inline_safe:false
    ()
;;

let masc_board_descriptor board_name =
  let schema = Board_tool_registry.schema_for_board_name board_name in
  let name = Tool_name.Board_name.to_string board_name in
  let operation_policy = Board_tool_registry.operation_policy board_name in
  let readonly = operation_policy.readonly in
  let keeper_model_projection =
    match Keeper_tool_name.board_projection_of_masc_board_name board_name with
    | Keeper_tool_name.Keeper_wrapper keeper_tool ->
      Transport_alias { projected_by = Keeper_tool_name.to_string keeper_tool }
    | Keeper_tool_name.Direct_masc -> Internal_name
  in
  let policy = policy ~readonly ~retryable:readonly () in
  let input_schema =
    remove_schema_fields
      (Board_tool_registry.identity_fields_for_board_name board_name)
      schema.input_schema
  in
  in_process_descriptor_with_schema_source
       ~keeper_model_projection
       ~input_schema_source:Canonical_registry
       ~id:("masc.board." ^ Tool_name.Board_name.operation_name board_name)
       ~name
       ~description:schema.description
       ~input_schema
       ~policy
       ~handler:Tool_masc_board_dispatch
;;

let masc_board_descriptors =
  List.map masc_board_descriptor Tool_name.Board_name.all
;;

let voice_descriptor name description ~readonly =
  cluster_descriptor
    ~keeper_model_projection:Internal_name
    ~id:("keeper.voice." ^ String.sub name (String.length "keeper_voice_")
         (String.length name - String.length "keeper_voice_"))
    ~name
    ~description
    ~handler:Tool_voice_dispatch
    ~readonly
    ~inline_safe:false
    ()
;;

let task_descriptor id name description ~readonly =
  cluster_descriptor
    ~keeper_model_projection:Internal_name
    ~id:("keeper.task." ^ id)
    ~name
    ~description
    ~handler:Tool_task_dispatch
    ~readonly
    ~inline_safe:false
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
    ~keeper_model_projection:Internal_name
    ~id:("masc.task." ^ id)
    ~name
    ~description
    ~handler:Tool_masc_task_dispatch
    ~readonly
    ~inline_safe:false
    ()
;;

let masc_task_transport_descriptor id name description ~readonly =
  cluster_descriptor
    ~keeper_model_projection:
      (Transport_alias { projected_by = "keeper_tasks_list" })
    ~id:("masc.task." ^ id)
    ~name
    ~description
    ~handler:Tool_masc_task_dispatch
    ~readonly
    ~inline_safe:false
    ()
;;

let masc_plan_descriptor id name description ~readonly =
  cluster_descriptor
    ~keeper_model_projection:Internal_name
    ~id:("masc.plan." ^ id)
    ~name
    ~description
    ~handler:Tool_masc_plan_dispatch
    ~readonly
    ~inline_safe:false
    ()
;;

let masc_run_descriptor name description ~readonly =
  cluster_descriptor
    ~keeper_model_projection:Internal_name
    ~id:("masc.run." ^ String.sub name (String.length "masc_run_")
         (String.length name - String.length "masc_run_"))
    ~name
    ~description
    ~handler:Tool_masc_run_dispatch
    ~readonly
    ~inline_safe:false
    ()
;;

let masc_agent_descriptor id name description ~readonly =
  cluster_descriptor
    ~keeper_model_projection:Internal_name
    ~id:("masc.agent." ^ id)
    ~name
    ~description
    ~handler:Tool_masc_agent_dispatch
    ~readonly
    ~inline_safe:false
    ()
;;

let masc_workspace_descriptor id name description ~readonly
  =
  cluster_descriptor
    ~keeper_model_projection:Internal_name
    ~id:("masc.workspace." ^ id)
    ~name
    ~description
    ~handler:Tool_masc_workspace_dispatch
    ~readonly
    ~inline_safe:false
    ()
;;

(* RFC-0182 §3.1 — additional cluster descriptor helpers (Phase 3:
   misc / control / agent_timeline / local_runtime). *)
let masc_misc_descriptor id name description ~readonly =
  cluster_descriptor
    ~keeper_model_projection:Internal_name
    ~id:("masc.misc." ^ id)
    ~name
    ~description
    ~handler:Tool_masc_misc_dispatch
    ~readonly
    ~inline_safe:false
    ()
;;

let masc_control_descriptor operation =
  let schema = Tool_schemas_misc.control_schema operation in
  cluster_descriptor_with_schema_source
    ~keeper_model_projection:Internal_name
    ~input_schema_source:Canonical_registry
    ~input_schema:schema.input_schema
    ~id:("masc.control." ^ Tool_schemas_misc.control_operation_id operation)
    ~name:schema.name
    ~description:schema.description
    ~handler:Tool_masc_control_dispatch
    ~readonly:false
    ~inline_safe:false
    ()
;;

let masc_agent_timeline_descriptor name description ~readonly =
  cluster_descriptor
    ~keeper_model_projection:Internal_name
    ~id:"masc.agent_timeline"
    ~name
    ~description
    ~handler:Tool_masc_agent_timeline_dispatch
    ~readonly
    ~inline_safe:false
    ()
;;

let masc_schedule_descriptor (definition : Tool_schemas_schedule.definition) =
  let schema : Masc_domain.tool_schema = definition.schema in
  cluster_descriptor_with_schema_source
    ~keeper_model_projection:Internal_name
    ~input_schema_source:Canonical_registry
    ~input_schema:schema.input_schema
    ~id:("masc.schedule." ^ definition.id)
    ~name:schema.name
    ~description:schema.description
    ~handler:Tool_masc_schedule_dispatch
    ~readonly:definition.read_only
    ~inline_safe:false
    ()
;;

let masc_keeper_descriptor ?(polling_read = false) id name description ~readonly =
  cluster_descriptor
    ~polling_read
    ~keeper_model_projection:Internal_name
    ~id:("masc.keeper." ^ id)
    ~name
    ~description
    ~handler:Tool_masc_keeper_dispatch
    ~readonly
    ~inline_safe:false
    ()
;;

let masc_library_descriptor (definition : Tool_schemas_library.definition) =
  let schema = definition.schema in
  let keeper_model_projection, description =
    match definition.operation with
    | Tool_schemas_library.List_documents ->
      ( Internal_name
      , "List all documents in the agent knowledge library with title, confidence, \
         source, and tags. Use keeper_library_read to fetch a document or \
         keeper_library_search to query by content." )
    | Tool_schemas_library.Read_document ->
      Transport_alias { projected_by = "keeper_library_read" }, schema.description
    | Tool_schemas_library.Search_documents ->
      Transport_alias { projected_by = "keeper_library_search" }, schema.description
    | Tool_schemas_library.Add_document
    | Tool_schemas_library.Promote_document -> Internal_name, schema.description
  in
  cluster_descriptor_with_schema_source
    ~keeper_model_projection
    ~input_schema_source:Canonical_registry
    ~input_schema:schema.input_schema
    ~id:("masc.library." ^ Tool_schemas_library.operation_id definition.operation)
    ~name:schema.name
    ~description
    ~handler:Tool_masc_library_dispatch
    ~readonly:definition.read_only
    ~inline_safe:false
    ()
;;

let masc_library_descriptors =
  List.map masc_library_descriptor Tool_schemas_library.definitions
;;

let masc_recurring_descriptor (definition : Tool_schemas_recurring.definition) =
  let schema = definition.schema in
  cluster_descriptor_with_schema_source
    ~keeper_model_projection:Internal_name
    ~input_schema_source:Canonical_registry
    ~input_schema:schema.input_schema
    ~id:("masc.recurring." ^ Tool_schemas_recurring.operation_id definition.operation)
    ~name:schema.name
    ~description:schema.description
    ~handler:Tool_masc_recurring_dispatch
    ~readonly:definition.read_only
    ~inline_safe:false
    ()
;;

let masc_recurring_descriptors =
  List.map masc_recurring_descriptor Tool_schemas_recurring.definitions
;;

let masc_local_runtime_descriptor
      (definition : Tool_schemas_local_runtime.definition) =
  let schema = definition.schema in
  cluster_descriptor_with_schema_source
    ~keeper_model_projection:Internal_name
    ~input_schema_source:Canonical_registry
    ~input_schema:schema.input_schema
    ~id:
      ("masc.local_runtime."
       ^ Tool_schemas_local_runtime.operation_id definition.operation)
    ~name:schema.name
    ~description:schema.description
    ~handler:Tool_masc_local_runtime_dispatch
    ~readonly:true
    ~inline_safe:false
    ()
;;

let masc_local_runtime_descriptors =
  List.map
    masc_local_runtime_descriptor
    Tool_schemas_local_runtime.definitions
;;

let internal_descriptors : t list =
  [ (* ── time / catalog (RFC-0179 PR-2 + PR-3) ────────── *)
    in_process_descriptor
      ~keeper_model_projection:Internal_name
      ~id:"keeper.time.now"
      ~name:"keeper_time_now"
      ~description:
        "Return the current wall-clock time as ISO 8601 and Unix epoch \
         seconds. No arguments."
      ~input_schema:empty_object_schema
      ~policy:(read_only_in_process_policy ())
      ~handler:Tool_time_now
  ; (in_process_descriptor
       ~keeper_model_projection:Internal_name
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
       ~keeper_model_projection:Internal_name
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
      ~keeper_model_projection:Internal_name
      ~id:"keeper.context.status"
      ~name:"keeper_context_status"
      ~description:
        "Return current context window usage and recent-message stats for \
         this keeper turn."
      ~input_schema:empty_object_schema
      ~policy:(read_only_in_process_policy ())
      ~handler:Tool_context_status
  ; in_process_descriptor_with_schema_source
      ~keeper_model_projection:Internal_name
      ~input_schema_source:memory_search_schema_source
      ~id:"keeper.memory.search"
      ~name:"keeper_memory_search"
      ~description:
        "Search keeper memory (semantic + recency) for relevant prior context."
      ~input_schema:memory_search_schema
      ~policy:(read_only_in_process_policy ())
      ~handler:Tool_memory_search
  ; in_process_descriptor_with_schema_source
      ~keeper_model_projection:Internal_name
      ~input_schema_source:memory_write_schema_source
      ~id:"keeper.memory.write"
      ~name:"keeper_memory_write"
      ~description:"Persist a memory entry for this keeper."
      ~input_schema:memory_write_schema
      ~policy:(write_in_process_policy ())
      ~handler:Tool_memory_write
    (* ── library (RFC-0179 PR-3) ──────────────────────────────── *)
  ; in_process_descriptor
      ~keeper_model_projection:Internal_name
      ~id:"keeper.library.search"
      ~name:"keeper_library_search"
      ~description:"Search the keeper library catalog."
      ~input_schema:library_search_schema
      ~policy:(read_only_in_process_policy ())
      ~handler:Tool_library_search
  ; in_process_descriptor
      ~keeper_model_projection:Internal_name
      ~id:"keeper.library.read"
      ~name:"keeper_library_read"
      ~description:"Read a library entry by id."
      ~input_schema:library_read_schema
      ~policy:(read_only_in_process_policy ())
      ~handler:Tool_library_read
    (* ── connector surfaces (RFC-0223 P3) ─────────────────────── *)
  ; (in_process_descriptor
       ~keeper_model_projection:Internal_name
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
      ~keeper_model_projection:Internal_name
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
      ~keeper_model_projection:Internal_name
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
  ; in_process_descriptor_with_schema_source
      ~keeper_model_projection:Internal_name
      ~input_schema_source:ide_annotate_schema_source
      ~id:"keeper.ide.annotate"
      ~name:"keeper_ide_annotate"
      ~description:"Emit an IDE annotation event for the current keeper."
      ~input_schema:ide_annotate_schema
      ~policy:(write_in_process_policy ())
      ~handler:Tool_ide_annotate
    (* ── fusion deliberation (RFC-0252) ───────────────────────── *)
  ; in_process_descriptor
      ~keeper_model_projection:Internal_name
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
      (* The explicit [Internal_name] projection makes Fusion available. *)
      ~policy:(write_in_process_policy ())
      ~handler:Tool_masc_fusion_dispatch
    (* ── fusion status (RFC-0266 §7 Phase 3) ──────────────────── *)
  ; in_process_descriptor
      ~keeper_model_projection:Internal_name
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
      (* [Internal_name] is the model exposure authority. *)
      ~policy:(read_only_in_process_policy ())
      ~handler:Tool_masc_fusion_status
    (* ── vision delegation (RFC-keeper-vision-delegation-tool §2.6) ─ *)
  ; in_process_descriptor
      ~keeper_model_projection:Internal_name
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
      (* [Internal_name] keeps the read-only vision sub-call model-visible. *)
      ~policy:(read_only_in_process_policy ())
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
    (* ── task / broadcast cluster (RFC-0179 PR-3, 6 tools) ────── *)
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
    (* ── board cluster (RFC-0179 PR-3, 15 tools) ──────────────── *)
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
      "Post a new board entry with the content and metadata supplied by the keeper."
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
  ; masc_task_transport_descriptor "tasks" "masc_tasks"
      "List tasks visible to the caller." ~readonly:true
  ; (masc_task_descriptor "transition" "masc_transition"
       "Transition a task to a new status." ~readonly:false
     |> with_current_task_state_description)
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
  ; masc_workspace_descriptor
      "heartbeat"
      "masc_heartbeat"
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
  (* ── RFC-0182 §3.1 — masc_misc_* cluster (9 entries) ─────────── *)
  ; masc_misc_descriptor "config" "masc_config"
      "Read workspace configuration." ~readonly:true
  ; masc_misc_descriptor "dashboard" "masc_dashboard"
      "Read workspace dashboard summary." ~readonly:true
  ; masc_misc_descriptor "keeper_waiting_inventory" "masc_keeper_waiting_inventory"
      "Read keeper waiting inventory." ~readonly:true
  ; masc_misc_descriptor "cleanup_zombies" "masc_cleanup_zombies"
      "Reap orphan / zombie workspace state." ~readonly:false
  ; masc_misc_descriptor "tool_stats" "masc_tool_stats"
      "Read tool-usage statistics." ~readonly:true
  ; masc_misc_descriptor "tool_help" "masc_tool_help"
      "Read help text for a tool name." ~readonly:true
  ; masc_misc_descriptor "gc" "masc_gc"
      "Run workspace garbage collection and return the collection result."
      ~readonly:false
  (* [masc_web_search] / [masc_web_fetch] are already owned by the
     MASC-owned web descriptors above. Do not add
     duplicate internal descriptors here; that would make runtime receipt
     projection depend on list order. *)
  (* ── RFC-0182 §3.1 — masc_control_* cluster (2 entries) ──────── *)
  ; masc_control_descriptor Tool_schemas_misc.Pause
  ; masc_control_descriptor Tool_schemas_misc.Resume
  (* ── RFC-0182 §3.1 — masc_agent_timeline singleton (1 entry) ── *)
  ; masc_agent_timeline_descriptor "masc_agent_timeline"
      "Read agent timeline events." ~readonly:true
  (* ── RFC-0234 — scheduled internal automation (6 entries) ─────── *)
  ]
  @ List.map masc_schedule_descriptor Tool_schemas_schedule.definitions
  @ [
  (* ── RFC-0182 §3.1 — masc_keeper cluster ──── *)
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
  ; masc_keeper_descriptor "down" "masc_keeper_down"
      "Stop keeper keepalive, optionally remove meta and session directory." ~readonly:false
  (* RFC-0182 Phase 5 PR-B: Eio-bound keeper tools (require sw + clock). *)
  ; masc_keeper_descriptor "msg" "masc_keeper_msg"
      "Submit an async keeper turn (returns request_id for keeper_msg_result polling)." ~readonly:false
  ; masc_keeper_descriptor "up" "masc_keeper_up"
      "Bring a keeper online (create new or update existing)." ~readonly:false
  ]
  @ masc_board_descriptors
  @ masc_library_descriptors
  @ masc_recurring_descriptors
  @ masc_local_runtime_descriptors
;;

let all_descriptors () = public_descriptors @ internal_descriptors

let model_schema_errors descriptor =
  match descriptor.input_schema_source, descriptor.input_schema with
  | Missing_canonical_registry, _ ->
    [ "missing canonical input schema for " ^ descriptor.internal_name ]
  | (Descriptor_owned | Canonical_registry), `Assoc _ ->
    (Tool_input_validation.schema_shape descriptor.input_schema).errors
  | (Descriptor_owned | Canonical_registry), other ->
    [ Printf.sprintf
        "input schema for %s must be an object, got %s"
        descriptor.internal_name
        (Json_util.kind_name other)
    ]
;;

let keeper_model_names descriptor =
  match model_schema_errors descriptor, descriptor.keeper_model_projection with
  | _ :: _, _ -> []
  | [], Preferred_public_name ->
    [ descriptor.public_name ]
  | [], Internal_name ->
    [ descriptor.internal_name ]
  | [], Transport_alias _ -> []
;;

let keeper_candidate_names descriptor =
  match model_schema_errors descriptor, descriptor.keeper_model_projection with
  | _ :: _, _ -> []
  | [], Preferred_public_name ->
    descriptor.public_name :: descriptor.internal_name :: descriptor.public_aliases
    |> List.sort_uniq String.compare
  | [], Internal_name ->
    [ descriptor.internal_name ]
  | [], Transport_alias _ -> []
;;

let registered_names descriptor =
  descriptor.internal_name :: descriptor.public_name :: descriptor.public_aliases
  |> List.sort_uniq String.compare
;;

let model_visible_descriptors () =
  all_descriptors ()
  |> List.filter (fun descriptor ->
    match model_schema_errors descriptor, keeper_model_names descriptor with
    | _ :: _, _ | [], [] -> false
    | [], _ :: _ -> true)
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

let common_policy_json_fields ~readonly_key policy =
  [ readonly_key, Json_util.bool_opt_to_json policy.readonly_hint
  ; "retryable", `Bool policy.retryable
  ; "cwd_scope", Json_util.string_opt_to_json policy.cwd_scope
  ; "inline_safe", `Bool policy.inline_safe
  ; "polling_read", `Bool policy.polling_read
  ]
;;

(* Route evidence consumers must read fields by key; object field order is not a
   compatibility contract. *)
let route_evidence_json d =
  let policy = d.policy in
  `Assoc
    ([ "descriptor_id", `String d.id
     ; ( "keeper_model_projection"
       , `String (keeper_model_projection_to_string d.keeper_model_projection) )
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
     @
     (match d.keeper_model_projection with
      | Transport_alias { projected_by } ->
        [ "transport_alias_of", `String projected_by ]
      | Preferred_public_name | Internal_name -> [])
     @ common_policy_json_fields ~readonly_key:"readonly" policy)
;;

let discovery_policy_json policy =
  `Assoc (common_policy_json_fields ~readonly_key:"readonly_hint" policy)
;;

let discovery_fields d =
  let examples_field =
    match d.examples with
    | [] -> []
    | examples -> [ "examples", `List examples ]
  in
  ([ "id", `String d.id
   ; ( "keeper_model_projection"
     , `String (keeper_model_projection_to_string d.keeper_model_projection) )
   ; ( "model_description_projection"
     , `String
         (model_description_projection_to_string d.model_description_projection) )
   ; "keeper_tool_group", `String (keeper_tool_group_to_string d.keeper_tool_group)
   ; "input_schema_source", `String (input_schema_source_to_string d.input_schema_source)
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
   @
   match d.keeper_model_projection with
   | Transport_alias { projected_by } ->
     [ "transport_alias_of", `String projected_by ]
   | Preferred_public_name | Internal_name -> [])
  @ examples_field
;;

let discovery_json d =
  `Assoc (discovery_fields d)
;;
