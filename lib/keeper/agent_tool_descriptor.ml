(** Agent-facing tool descriptor spine. *)

type executor =
  | In_process
  | Shell_ir
  | Gh_cli
  | Filesystem
  | Remote_mcp
  | Oas_bridge

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
  ; translate : Yojson.Safe.t -> Yojson.Safe.t
  ; receipt_labels : (string * string) list
  }

let executor_to_string = function
  | In_process -> "in_process"
  | Shell_ir -> "shell_ir"
  | Gh_cli -> "gh_cli"
  | Filesystem -> "filesystem"
  | Remote_mcp -> "remote_mcp"
  | Oas_bridge -> "oas_bridge"
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

let policy ?readonly ?effect_domain ?(approval = Policy_selected) ?cwd_scope
      ?credential_profile ?(retryable = false) ()
  =
  { visibility = Tool_catalog.Default
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

let execute_schema = Tool_shard_types_schemas_bash.keeper_bash_schema.input_schema

let read_file_schema =
  object_schema
    ~required:[ "file_path" ]
    [ property "file_path" "string" "Absolute or sandbox-relative file path to read."
    ; property
        "limit"
        "integer"
        "Approximate maximum bytes to return. Line offsets are not supported."
    ; property
        "offset"
        "integer"
        "Accepted for compatibility and ignored; reads start at the beginning."
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
    ; property "-n" "boolean" "Accepted for compatibility; line numbers are always included."
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
         | "offset" -> ()
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
         | "op" | "-i" | "-n" -> ()
         | _ -> out := (k, v) :: !out)
      fields;
    `Assoc (List.rev !out)
  | _ -> input
;;

let descriptor ~id ~public_name ~internal_name ~description ~input_schema ~policy
      ~executor ~backend ~sandbox ~translate
  =
  let receipt_labels =
    [ "descriptor_id", id
    ; "public_name", public_name
    ; "canonical_name", internal_name
    ; "executor", executor_to_string executor
    ; "backend", backend_to_string backend
    ; "sandbox", sandbox_to_string sandbox
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
  ; translate
  ; receipt_labels
  }
;;

let public_descriptors =
  [ descriptor
      ~id:"agent.execute"
      ~public_name:"Execute"
      ~internal_name:"keeper_bash"
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
      ~translate:translate_identity
  ; descriptor
      ~id:"agent.search_files"
      ~public_name:"SearchFiles"
      ~internal_name:"keeper_shell"
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
      ~translate:translate_search_files
  ; descriptor
      ~id:"agent.read_file"
      ~public_name:"ReadFile"
      ~internal_name:"keeper_fs_read"
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
      ~translate:translate_read_file
  ; descriptor
      ~id:"agent.edit_file"
      ~public_name:"EditFile"
      ~internal_name:"keeper_fs_edit"
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
      ~translate:translate_edit_file
  ; descriptor
      ~id:"agent.write_file"
      ~public_name:"WriteFile"
      ~internal_name:"keeper_fs_edit"
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
      ~translate:translate_identity
  ]
;;

let public_names () = List.map (fun d -> d.public_name) public_descriptors

let find_public name =
  List.find_opt (fun d -> String.equal d.public_name name) public_descriptors
;;

let public_descriptors_for_internal internal_name =
  List.filter (fun d -> String.equal d.internal_name internal_name) public_descriptors
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
     ; "approval", `String (approval_to_string policy.approval)
     ; "retryable", `Bool policy.retryable
     ; "cwd_scope", string_opt_to_json policy.cwd_scope
     ; "credential_profile", string_opt_to_json policy.credential_profile
     ]
     @ policy_fields)
;;
