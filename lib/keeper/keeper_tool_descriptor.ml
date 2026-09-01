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
  | Host_sandbox_roots
  | Turn_sandbox
  | Docker_profile
  | Backend_selected

type keeper_model_projection =
  | Preferred_public_name
  | Internal_name
  | Operator_only
  | Transport_alias of { projected_by : string }



type input_schema_source =
  | Descriptor_owned
  | Canonical_registry
  | Keeper_projection

type readonly_of_input = Yojson.Safe.t -> bool option

type ordinary_execution_mode =
  | Serial
  | Concurrent

type execution =
  | Ordinary of ordinary_execution_mode
  | Direct_terminal
  | Terminal

let execution_to_string = function
  | Ordinary Serial -> "serial"
  | Ordinary Concurrent -> "concurrent"
  | Direct_terminal -> "direct_terminal"
  | Terminal -> "terminal"
;;

type tool_kind =
  | Atomic_tool
  | Composition_tool
  | Async_composition_tool

let tool_kind_to_string = function
  | Atomic_tool -> "atomic"
  | Composition_tool -> "composition"
  | Async_composition_tool -> "async_composition"
;;

let tool_kind_of_string = function
  | "atomic" -> Ok Atomic_tool
  | "composition" -> Ok Composition_tool
  | "async_composition" -> Ok Async_composition_tool
  | unknown -> Error ("unknown tool kind: " ^ unknown)
;;

type composable_output =
  | Opaque_output
  | Json_output of { schema : Yojson.Safe.t }

let composable_output_kind = function
  | Opaque_output -> "opaque"
  | Json_output _ -> "json"
;;

let composable_output_to_json = function
  | Opaque_output -> `Assoc [ "kind", `String "opaque" ]
  | Json_output { schema } ->
    `Assoc [ "kind", `String "json"; "schema", schema ]
;;

type identity_validation =
  | Validate_once_before_translation
  | Validate_once_after_translation

type shape_changing_validation =
  | Validate_before_and_after_translation
  | Validate_before_then_runtime_handler

type input_translation =
  | Identity of identity_validation
  | Shape_changing of
      { translate : Yojson.Safe.t -> Yojson.Safe.t
      ; validation : shape_changing_validation
      }

type runtime_handler =
  | Tool_execute
  | Tool_search_files
  | Tool_read_file
  | Tool_edit_file
  | Tool_write_file
  | Tool_time_now
  | Tool_tools_list
  | Tool_capability_search
  | Tool_context_status
  | Tool_artifact_read
  | Tool_memory_search
  | Tool_memory_retract
  | Tool_memory_write
  | Tool_library_search
  | Tool_library_read
  | Tool_surface_read
  | Tool_surface_post
  | Tool_person_note_set
  | Tool_ide_annotate
  | Tool_voice_dispatch
  | Tool_task_dispatch
  | Tool_board_dispatch
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
  | Tool_keeper_spawn_dispatch
  | Tool_keeper_code_query_dispatch
  | Tool_keeper_webmcp_dispatch
  | Tool_masc_keeper_dispatch
  | Tool_masc_fusion_dispatch
  | Tool_masc_fusion_status
  | Tool_masc_library_dispatch
  | Tool_masc_local_runtime_dispatch
  | Tool_analyze_image

type policy =
  { readonly_of_input : readonly_of_input
  ; readonly_hint : bool option
  ; cwd_scope : string option
  ; polling_read : bool
  ; leaves_masc : bool
      (** Whether a call that is not a read reaches past masc's own stores —
          the sandbox filesystem, a process, a service. A write that only
          moves masc's durable rows (a memory entry, a board post, a surface
          row) is visible and undoable inside the workspace, so the approval
          policy runs it; anything that leaves is asked about. Declared per
          descriptor rather than derived from [cwd_scope], which answers a
          different question and would make this gate quietly wrong the day
          a sandbox-scoped read-only tool appears. *)
  }

type t =
  { id : string
  ; capability_id : string
  ; keeper_model_projection : keeper_model_projection
  ; input_schema_source : input_schema_source
  ; public_name : string
  ; internal_name : string
  ; description : string
  ; input_schema : Yojson.Safe.t
  ; model_output_projection : Tool_output.model_projection
  ; composable_output : composable_output
  ; execution : execution
  ; tool_kind : tool_kind
  ; policy : policy
  ; executor : executor
  ; backend : backend
  ; sandbox : sandbox
  ; runtime_handler : runtime_handler
  ; input_translation : input_translation
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
  | Host_sandbox_roots -> "host_sandbox_roots"
  | Turn_sandbox -> "turn_sandbox"
  | Docker_profile -> "docker_profile"
  | Backend_selected -> "backend_selected"
;;

let keeper_model_projection_to_string = function
  | Preferred_public_name -> "preferred_public_name"
  | Internal_name -> "internal_name"
  | Operator_only -> "operator_only"
  | Transport_alias _ -> "transport_alias"
;;

;;


let input_schema_source_to_string = function
  | Descriptor_owned -> "descriptor_owned"
  | Canonical_registry -> "canonical_registry"
  | Keeper_projection -> "keeper_projection"
;;

let runtime_handler_to_string = function
  | Tool_execute -> "tool_execute"
  | Tool_search_files -> "tool_search_files"
  | Tool_read_file -> "tool_read_file"
  | Tool_edit_file -> "tool_edit_file"
  | Tool_write_file -> "tool_write_file"
  | Tool_time_now -> "tool_time_now"
  | Tool_tools_list -> "tool_tools_list"
  | Tool_capability_search -> "tool_capability_search"
  | Tool_context_status -> "tool_context_status"
  | Tool_artifact_read -> "tool_artifact_read"
  | Tool_memory_search -> "tool_memory_search"
  | Tool_memory_retract -> "tool_memory_retract"
  | Tool_memory_write -> "tool_memory_write"
  | Tool_library_search -> "tool_library_search"
  | Tool_library_read -> "tool_library_read"
  | Tool_surface_read -> "tool_surface_read"
  | Tool_surface_post -> "tool_surface_post"
  | Tool_person_note_set -> "tool_person_note_set"
  | Tool_ide_annotate -> "tool_ide_annotate"
  | Tool_voice_dispatch -> "tool_voice_dispatch"
  | Tool_task_dispatch -> "tool_task_dispatch"
  | Tool_board_dispatch -> "tool_board_dispatch"
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
  | Tool_keeper_spawn_dispatch -> "tool_keeper_spawn_dispatch"
  | Tool_keeper_code_query_dispatch -> "tool_keeper_code_query_dispatch"
  | Tool_keeper_webmcp_dispatch -> "tool_keeper_webmcp_dispatch"
  | Tool_masc_keeper_dispatch -> "tool_masc_keeper_dispatch"
  | Tool_masc_fusion_dispatch -> "tool_masc_fusion_dispatch"
  | Tool_masc_fusion_status -> "tool_masc_fusion_status"
  | Tool_masc_library_dispatch -> "tool_masc_library_dispatch"
  | Tool_masc_local_runtime_dispatch -> "tool_masc_local_runtime_dispatch"
  | Tool_analyze_image -> "tool_analyze_image"
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

let policy ?readonly ?readonly_of_input ?cwd_scope ?(polling_read = false)
      ?(leaves_masc = false) ()
  =
  let readonly_of_input =
    match readonly_of_input with
    | Some readonly_of_input -> readonly_of_input
    | None -> fun _input -> readonly
  in
  { readonly_of_input
  ; readonly_hint = readonly
  ; cwd_scope
  ; polling_read
  ; leaves_masc
  }
;;

let execute_schema = Tool_shard_types.tool_execute_schema.input_schema


(* [offset]/[limit] pass through as LINE coordinates — the runtime owns the
   line-window contract (keeper_tool_filesystem_runtime.slice_read_window).
   [limit] used to be renamed to [max_bytes] here, which silently turned "200
   lines" into "512 bytes" (the min byte clamp) and starved every code read. *)
let translate_read_file input =
  match input with
  | `Assoc fields ->
    let out = ref [] in
    List.iter
      (fun (k, v) ->
         match k with
         | "file_path" -> out := ("path", v) :: !out
         | _ -> out := (k, v) :: !out)
      fields;
    `Assoc (List.rev !out)
  | _ -> input
;;

(* Edit is patch-only: mode is pinned here, never inferred from the input. The
   closed Edit schema rejects an undeclared 'content' key before translation;
   inferring overwrite from its presence turned a mistaken key into a silent
   whole-file overwrite (masc#31573). Translation is closed to match: only the
   declared patch fields reach the runtime, so even a validation-bypassing
   caller cannot smuggle extra members through this path. *)
let translate_edit_file input =
  match input with
  | `Assoc fields ->
    let out = ref [ "mode", `String "patch" ] in
    List.iter
      (fun (k, v) ->
         match k with
         | "file_path" -> out := ("path", v) :: !out
         | "old_string" | "new_string" | "replace_all" -> out := (k, v) :: !out
         | _ -> ())
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

let translate_input_for_descriptor descriptor input =
  match descriptor.input_translation with
  | Identity _ -> input
  | Shape_changing { translate; _ } -> translate input
;;

type capability_identity =
  | Internal_name_identity
  | Named_capability of string

let capability_id_of_identity ~internal_name = function
  | Internal_name_identity -> internal_name
  | Named_capability capability_id -> capability_id
;;

let descriptor
      ?(examples = [])
      ~capability_identity
      ~keeper_model_projection
      ~input_schema_source
      ~id
      ~public_name
      ~internal_name
      ~description
      ~input_schema
      ?(model_output_projection = Tool_output.default_model_projection)
      ?(composable_output = Opaque_output)
      ?(ordinary_execution_mode = Serial)
      ?(tool_kind = Atomic_tool)
      ~policy
      ~executor
      ~backend
      ~sandbox
      ~runtime_handler
      ~input_translation
      ()
  =
  let capability_id =
    capability_id_of_identity ~internal_name capability_identity
  in
  let execution =
    match runtime_handler with
    | Tool_surface_post -> Terminal
    | Tool_memory_write | Tool_memory_retract -> Direct_terminal
    | ( Tool_execute
      | Tool_keeper_code_query_dispatch
      | Tool_keeper_webmcp_dispatch
      | Tool_search_files
      | Tool_read_file
      | Tool_edit_file
      | Tool_write_file
      | Tool_time_now
      | Tool_tools_list
      | Tool_capability_search
      | Tool_context_status
      | Tool_artifact_read
      | Tool_memory_search
      | Tool_library_search
      | Tool_library_read
      | Tool_surface_read
      | Tool_person_note_set
      | Tool_ide_annotate
      | Tool_voice_dispatch
      | Tool_task_dispatch
      | Tool_board_dispatch
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
      | Tool_keeper_spawn_dispatch
      | Tool_masc_keeper_dispatch
      | Tool_masc_fusion_dispatch
      | Tool_masc_fusion_status
      | Tool_masc_library_dispatch
      | Tool_masc_local_runtime_dispatch
      | Tool_analyze_image ) -> Ordinary ordinary_execution_mode
  in
  (* Fail-closed admission rule for parallel tool use: a descriptor may opt
     into [Concurrent] batches only when its policy carries a static
     read-only hint. The batch planner (Agent_core Agent_tool_batch_plan)
     fans an ordinary [Concurrent] run out onto sibling Eio fibers, so an
     effectful tool admitted by mistake would execute its side effect
     concurrently with no ordering guarantee. The hint is the same typed
     declaration the composition catalog uses for its Async admission
     check (Async_tool_not_statically_read_only); no string heuristics. *)
  (match execution, policy.readonly_hint with
   | Ordinary Concurrent, Some true -> ()
   | Ordinary Concurrent, (Some false | None) ->
     invalid_arg
       (Printf.sprintf
          "descriptor %S declares Concurrent execution without a static \
           read-only policy hint"
          internal_name)
   | Ordinary Serial, _ | Direct_terminal, _ | Terminal, _ -> ());
  let receipt_labels =
    [ "descriptor_id", id
    ; "capability_id", capability_id
    ; ( "keeper_model_projection"
      , keeper_model_projection_to_string keeper_model_projection )
    ; "public_name", public_name
    ; "canonical_name", internal_name
    ; "executor", executor_to_string executor
    ; "backend", backend_to_string backend
    ; "sandbox", sandbox_to_string sandbox
    ; "runtime_handler", runtime_handler_to_string runtime_handler
    ; "execution", execution_to_string execution
    ; "composable_output", composable_output_kind composable_output
    ; "input_schema_source", input_schema_source_to_string input_schema_source
    ]
    @ (match keeper_model_projection with
       | Transport_alias { projected_by } ->
         [ "transport_alias_of", projected_by ]
       | Preferred_public_name | Internal_name | Operator_only -> [])
  in
  { id
  ; capability_id
  ; keeper_model_projection
  ; input_schema_source
  ; public_name
  ; internal_name
  ; description
  ; input_schema
  ; model_output_projection
  ; composable_output
  ; execution
  ; tool_kind
  ; policy
  ; executor
  ; backend
  ; sandbox
  ; runtime_handler
  ; input_translation
  ; receipt_labels
  ; eval_tags = []
  ; examples
  }
;;

let with_eval_tags eval_tags descriptor =
  { descriptor with eval_tags }
;;

let with_model_output_projection model_output_projection descriptor =
  { descriptor with model_output_projection }
;;

let with_composable_output composable_output descriptor =
  { descriptor with composable_output }
;;

let normalized_artifact_ref_schema =
  `Assoc
    [ "type", `String "object"
    ; ( "properties"
      , `Assoc
          [ ( "_blob"
            , `Assoc
                [ "type", `String "object"
                ; ( "properties"
                  , `Assoc
                      [ "sha256", `Assoc [ "type", `String "string" ]
                      ; "bytes", `Assoc [ "type", `String "integer" ]
                      ; "mime", `Assoc [ "type", `String "string" ]
                      ; "preview", `Assoc [ "type", `String "string" ]
                      ] )
                ; ( "required"
                  , `List
                      (List.map
                         (fun name -> `String name)
                         [ "sha256"; "bytes"; "mime"; "preview" ]) )
                ; "additionalProperties", `Bool false
                ] )
          ] )
    ; "required", `List [ `String "_blob" ]
    ; "additionalProperties", `Bool false
    ]
;;

let execute_output_schema =
  `Assoc
    [ "type", `String "object"
    ; ( "properties"
      , `Assoc
          [ "ok", `Assoc [ "type", `String "boolean" ]
          ; ( "status"
            , `Assoc
                [ "type", `String "object"
                ; ( "properties"
                  , `Assoc
                      [ "kind", `Assoc [ "type", `String "string" ]
                      ; "code", `Assoc [ "type", `String "integer" ]
                      ; "signal", `Assoc [ "type", `String "integer" ]
                      ] )
                ; "required", `List [ `String "kind" ]
                ; "additionalProperties", `Bool false
                ] )
          ; "output", `Assoc [ "type", `String "string" ]
          ; "output_artifact", normalized_artifact_ref_schema
          ; "stdout_artifact", normalized_artifact_ref_schema
          ; "stderr_artifact", normalized_artifact_ref_schema
          ; "typed", `Assoc [ "type", `String "boolean" ]
          ; "execution_time_ms", `Assoc [ "type", `String "integer" ]
          ] )
    ; ( "required"
      , `List
          (List.map
             (fun name -> `String name)
             [ "ok"; "status"; "typed"; "execution_time_ms" ]) )
    ; "additionalProperties", `Bool true
    ]
;;

let public_descriptors =
  [ (descriptor
      ~capability_identity:Internal_name_identity
      ~keeper_model_projection:Preferred_public_name
      ~input_schema_source:Descriptor_owned
      ~id:"agent.execute"
      ~public_name:"Execute"
      ~internal_name:"tool_execute"
      ~description:
        "Execute one opaque typed process invocation inside the Keeper sandbox. \
         Provide one non-empty argv process vector, an explicit typed \
         pipeline, or a script command line that is parsed rather than handed \
         to a shell. Use typed stdin/stdout/stderr fields for \
         I/O and typed env for environment variables. MASC validates the input \
         shape, path jail, sandbox target, and external-effect Gate but never \
         interprets program or subcommand meaning. The invoked program owns \
         its syntax and exit result. A successful result exposes typed status, \
         output and execution_time_ms fields to later composition nodes. Small \
         output stays inline; oversized output is represented by canonical \
         output/stdout/stderr artifact references."
      ~input_schema:execute_schema
      ~policy:
        (policy
           ~cwd_scope:"keeper_sandbox"
           ~leaves_masc:true
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
      ~input_translation:(Identity Validate_once_before_translation)
      ()
     |> with_composable_output (Json_output { schema = execute_output_schema }))
  ; descriptor
      ~capability_identity:Internal_name_identity
      ~keeper_model_projection:Preferred_public_name
      ~input_schema_source:Canonical_registry
      ~id:"agent.search_files"
      ~public_name:"Grep"
      ~internal_name:"tool_search_files"
      ~description:Tool_schemas_filesystem_files.search_files.description
      ~input_schema:Tool_schemas_filesystem_files.search_files.input_schema
      (* Concurrent: each call spawns its own rg process through the sandbox
         backend; the only shared write is the bash-history audit line, a
         single O_APPEND write with no fiber yield inside it. *)
      ~ordinary_execution_mode:Concurrent
      ~policy:
        (policy
           ~readonly:true
           ~readonly_of_input:search_files_readonly_of_input
           ~cwd_scope:"keeper_sandbox"
           ~leaves_masc:true
           ())
      ~executor:Shell_ir
      ~backend:Sandbox_process
      ~sandbox:Backend_selected
      ~runtime_handler:Tool_search_files
      ~input_translation:
        (Shape_changing
           { translate = translate_search_files
           ; validation = Validate_before_and_after_translation
           })
      ()
  ; descriptor
      ~capability_identity:Internal_name_identity
      ~keeper_model_projection:Preferred_public_name
      ~input_schema_source:Canonical_registry
      ~id:"agent.read_file"
      ~public_name:"Read"
      ~internal_name:"tool_read_file"
      ~description:Tool_schemas_filesystem_files.read_file.description
      ~input_schema:Tool_schemas_filesystem_files.read_file.input_schema
      (* Concurrent: a pure read — containment check plus either a host
         file read (Safe_ops.read_file_result) or a per-call backend read
         runner process; no shared mutable state on the path. *)
      ~ordinary_execution_mode:Concurrent
      ~policy:
        (policy
           ~readonly:true
           ~cwd_scope:"keeper_sandbox"
           ~leaves_masc:true
           ())
      ~executor:Filesystem
      ~backend:Sandbox_process
      ~sandbox:Backend_selected
      ~runtime_handler:Tool_read_file
      ~input_translation:
        (Shape_changing
           { translate = translate_read_file
           ; validation = Validate_before_then_runtime_handler
           })
      ()
  ; descriptor
      ~capability_identity:Internal_name_identity
      ~keeper_model_projection:Preferred_public_name
      ~input_schema_source:Canonical_registry
      ~id:"agent.edit_file"
      ~public_name:"Edit"
      ~internal_name:"tool_edit_file"
      ~description:Tool_schemas_filesystem_files.edit_file.description
      ~input_schema:Tool_schemas_filesystem_files.edit_file.input_schema
      ~policy:
        (policy
           ~readonly:false
           ~cwd_scope:"keeper_sandbox"
           ~leaves_masc:true
           ())
      ~executor:Filesystem
      ~backend:Sandbox_process
      ~sandbox:Backend_selected
      ~runtime_handler:Tool_edit_file
      ~input_translation:
        (Shape_changing
           { translate = translate_edit_file
           ; validation = Validate_before_then_runtime_handler
           })
      ()
  ; descriptor
      ~capability_identity:Internal_name_identity
      ~keeper_model_projection:Preferred_public_name
      ~input_schema_source:Canonical_registry
      ~id:"agent.write_file"
      ~public_name:"Write"
      ~internal_name:"tool_write_file"
      ~description:Tool_schemas_filesystem_files.write_file.description
      ~input_schema:Tool_schemas_filesystem_files.write_file.input_schema
      ~policy:
        (policy
           ~readonly:false
           ~cwd_scope:"keeper_sandbox"
           ~leaves_masc:true
           ())
      ~executor:Filesystem
      ~backend:Sandbox_process
      ~sandbox:Backend_selected
      ~runtime_handler:Tool_write_file
      ~input_translation:
        (Shape_changing
           { translate = translate_write_file
           ; validation = Validate_before_then_runtime_handler
           })
      ()
  ; descriptor
      ~capability_identity:Internal_name_identity
      ~keeper_model_projection:Preferred_public_name
      ~input_schema_source:Canonical_registry
      ~id:"agent.search_web"
      ~public_name:"WebSearch"
      ~internal_name:Tool_schemas_misc.web_search_schema.name
      ~description:Tool_schemas_misc.web_search_schema.description
      ~input_schema:Tool_schemas_misc.web_search_schema.input_schema
      (* Concurrent: every call runs its own curl subprocess via
         Tool_local_runtime_http; provider selection reads env only, so
         there is no shared mutable state between sibling calls. *)
      ~ordinary_execution_mode:Concurrent
      ~policy:
        (policy
           ~readonly:true
           ())
      ~executor:In_process
      ~backend:Ocaml_runtime
      ~sandbox:No_sandbox
      ~runtime_handler:Tool_web_search
      ~input_translation:(Identity Validate_once_before_translation)
      ()
  ; descriptor
      ~capability_identity:Internal_name_identity
      ~keeper_model_projection:Preferred_public_name
      ~input_schema_source:Canonical_registry
      ~id:"agent.fetch_web"
      ~public_name:"WebFetch"
      ~internal_name:Tool_schemas_misc.web_fetch_schema.name
      ~description:Tool_schemas_misc.web_fetch_schema.description
      ~input_schema:Tool_schemas_misc.web_fetch_schema.input_schema
      (* Concurrent: per-call curl subprocess; the full-text offload writes
         into the content-addressed Tool_blob_store (Atomic CAS cache, the
         same store keeper_artifact_read already reads concurrently) and
         appends the index row through Fs_compat.append_jsonl's per-path
         mutex. *)
      ~ordinary_execution_mode:Concurrent
      ~policy:
        (policy
           ~readonly:true
           ())
      ~executor:In_process
      ~backend:Ocaml_runtime
      ~sandbox:No_sandbox
      ~runtime_handler:Tool_web_fetch
      ~input_translation:(Identity Validate_once_before_translation)
      ()
  ]
;;

(** Descriptor-backed workspace tools that are not public model names. *)

let empty_object_schema =
  `Assoc
    [ "type", `String "object"
    ; "properties", `Assoc []
    ; "additionalProperties", `Bool false
    ]
;;

(* The whole registry record, not just its input schema: [cluster_descriptor]
   takes the description from this same lookup. *)
let find_schema_opt schemas name =
  List.find_opt (fun (s : Masc_domain.tool_schema) -> String.equal s.name name)
    schemas
;;

let find_taskboard_schema_opt name =
  find_schema_opt Tool_shard_types.taskboard_tools name
;;

let find_voice_schema_opt name =
  find_schema_opt Tool_shard_types.voice_tools name
;;

let find_misc_schema_opt name =
  find_schema_opt Tool_schemas_misc.schemas name
;;

let find_base_schema_opt name =
  match find_schema_opt Tool_shard_types.base_tools name with
  | Some _ as schema -> schema
  | None -> find_schema_opt Tool_shard_types.filesystem_tools name
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

let find_masc_schema_opt name =
  match Tools.find_tool name with
  | Some _ as schema -> schema
  | None ->
    (* [Tool_agent_timeline] is registered by the main composition root and is
       intentionally absent from [Tools.all_schemas_extended] to avoid pulling
       keeper/runtime dependencies into the neutral schema aggregate. *)
    (match find_schema_opt Tool_agent_timeline.schemas name with
     | Some _ as schema -> schema
     | None -> find_schema_opt Keeper_schema.schemas name)

let find_cluster_schema_opt name =
  (* Keeper taskboard tools are checked before voice, misc, and public
     aggregates. Board descriptors use their typed registry directly.
     The namespaces are disjoint because every registry reached here is also
     concatenated into [Config.raw_all_tool_schemas], whose module initialiser
     runs [Config.validate_schemas] and raises on a repeated name. This order
     is therefore not a conflict resolver. Control descriptors use their dedicated typed schema projection
     and do not enter this name-based lookup. *)
  match find_taskboard_schema_opt name with
  | Some _ as schema -> schema
  | None ->
    (match find_voice_schema_opt name with
     | Some _ as schema -> schema
     | None ->
       (match find_misc_schema_opt name with
        | Some _ as schema -> schema
        | None -> find_masc_schema_opt name))
;;

let base_schema_input name =
  match find_base_schema_opt name with
  | Some (schema : Masc_domain.tool_schema) ->
    Canonical_registry, schema.input_schema
  | None -> invalid_arg ("missing base tool schema for " ^ name)

(* [base_schema_input] keeps only the schema, so a descriptor whose
   description is the TOML's own cannot be built from it -- there is nothing
   left to read the description off. This keeps the whole record for that
   case. *)
let base_schema_declared name =
  match find_base_schema_opt name with
  | Some (schema : Masc_domain.tool_schema) -> Canonical_registry, schema
  | None -> invalid_arg ("missing base tool schema for " ^ name)

let keeper_tools_list_schema =
  match find_base_schema_opt "keeper_tools_list" with
  | Some schema -> schema
  | None -> invalid_arg "missing base tool schema for keeper_tools_list"
;;

let keeper_capability_search_schema =
  match find_base_schema_opt "keeper_capability_search" with
  | Some schema -> schema
  | None -> invalid_arg "missing base tool schema for keeper_capability_search"
;;

(* Declared twice until now: here and in the library shard, whose file is
   config/tools/keeper_library_*.toml. The parameters agreed to a full stop,
   but the tool descriptions did not -- this side said "Search the keeper
   library catalog." while the shard said what the tool returns (titles,
   relevance scores, snippets) and what to pair it with. The model received
   the thin one. The shard is now the one declaration. *)
let shard_library_schema name =
  match find_schema_opt Tool_shard_types.library_tools name with
  | Some schema -> schema
  | None -> failwith (Printf.sprintf "library shard is missing %s" name)
;;

let library_search = shard_library_schema "keeper_library_search"
let library_read = shard_library_schema "keeper_library_read"

let shard_surface_schema name =
  match find_schema_opt Tool_shard_types.surface_tools name with
  | Some schema -> schema.Masc_domain.input_schema
  | None -> failwith (Printf.sprintf "surface shard is missing %s" name)
;;

let surface_read_schema = shard_surface_schema "keeper_surface_read"
let surface_post_schema = shard_surface_schema "keeper_surface_post"
let person_note_set_schema = shard_surface_schema "keeper_person_note_set"

let memory_search_schema_source, memory_search_schema =
  base_schema_input "keeper_memory_search"
;;

let memory_retract_schema_source, memory_retract_schema =
  base_schema_declared "keeper_memory_retract"
;;

let memory_write_schema_source, memory_write_schema =
  base_schema_input "keeper_memory_write"
;;

let ide_annotate_schema_source, ide_annotate_schema =
  base_schema_input "keeper_ide_annotate"
;;

let read_only_in_process_policy ?(polling_read = false) () =
  policy ~readonly:true ~polling_read ()
;;

let write_in_process_policy () =
  policy ~readonly:false ()
;;

let in_process_descriptor_with_schema_source
      ~capability_identity
      ~keeper_model_projection
      ~input_schema_source ~id ~name ~description ~input_schema ~policy ~handler
      ?ordinary_execution_mode
      ()
  =
  descriptor
    ~capability_identity
    ~keeper_model_projection
    ~input_schema_source
    ~id
    ~public_name:name
    ~internal_name:name
    ~description
    ~input_schema
    ?ordinary_execution_mode
    ~policy
    ~executor:In_process
    ~backend:Ocaml_runtime
    ~sandbox:No_sandbox
    ~runtime_handler:handler
    ~input_translation:(Identity Validate_once_after_translation)
    ()
;;

let in_process_descriptor ~keeper_model_projection ~id ~name ~description
      ~input_schema ~policy ?ordinary_execution_mode ~handler
      ()
  =
  in_process_descriptor_with_schema_source
    ~capability_identity:Internal_name_identity
    ~keeper_model_projection
    ~input_schema_source:Descriptor_owned
    ~id
    ~name
    ~description
    ~input_schema
    ~policy
    ~handler
    ?ordinary_execution_mode
    ()
;;

(* Cluster-dispatched tools (board / voice / task) share a single
   [runtime_handler] variant but expose distinct [internal_name]s so each
   tool retains its own descriptor entry and receipt evidence. The
   [keeper_tool_in_process_runtime] handler routes by descriptor.internal_name. *)
let cluster_policy ?(polling_read = false) ~readonly () =
  if polling_read && not readonly then
    invalid_arg "polling_read descriptors must declare readonly=true";
  if readonly
  then read_only_in_process_policy ~polling_read ()
  else write_in_process_policy ()
;;

let cluster_descriptor_with_schema_source
      ?(polling_read = false)
      ?ordinary_execution_mode
      ~capability_identity
      ~keeper_model_projection
      ~input_schema_source
      ~input_schema
      ~id
      ~name
      ~description
      ~handler
      ~readonly
      ()
  =
  let policy = cluster_policy ~polling_read ~readonly () in
  in_process_descriptor_with_schema_source
    ~capability_identity
    ~keeper_model_projection
    ~input_schema_source
    ~id
    ~name
    ~description
    ~input_schema
    ?ordinary_execution_mode
    ~policy
    ~handler
    ()
;;

(* Schema and description both come from the one registry lookup. Callers used
   to pass a second description inline and nothing kept the two in agreement:
   measured 2026-08-06 over [model_visible_descriptors], 66 of 98 descriptors
   disagreed with their canonical schema and the model saw the shorter string
   in 57 — including every Goal tool and [masc_transition], whose canonical
   text is the only place [release] is named. Taking one field from the record
   and re-typing the other beside it is what allowed the drift. *)
let cluster_descriptor ?(polling_read = false) ?ordinary_execution_mode
      ~capability_identity
      ~keeper_model_projection ~id ~name
      ~handler ~readonly ()
  =
  let input_schema_source, (schema : Masc_domain.tool_schema) =
    match find_cluster_schema_opt name with
    | Some schema -> Canonical_registry, schema
    | None -> invalid_arg ("missing canonical registry schema for " ^ name)
  in
  cluster_descriptor_with_schema_source
    ~polling_read
    ?ordinary_execution_mode
    ~capability_identity
    ~keeper_model_projection
    ~input_schema_source
    ~input_schema:schema.input_schema
    ~id
    ~name
    ~description:schema.description
    ~handler
    ~readonly
    ()
;;

let object_output_schema ~properties ~required =
  `Assoc
    [ "type", `String "object"
    ; "properties", `Assoc properties
    ; "required", `List (List.map (fun name -> `String name) required)
    ; "additionalProperties", `Bool false
    ]
;;

let board_stats_output_schema =
  object_output_schema
    ~properties:
      [ "post_count", `Assoc [ "type", `String "integer" ]
      ; "comment_count", `Assoc [ "type", `String "integer" ]
      ; "expired_pending", `Assoc [ "type", `String "integer" ]
      ; "last_sweep", `Assoc [ "type", `String "number" ]
      ; "backend", `Assoc [ "type", `String "string" ]
      ]
    ~required:
      [ "post_count"; "comment_count"; "expired_pending"; "last_sweep"; "backend" ]
;;

let time_now_output_schema =
  object_output_schema
    ~properties:
      [ "now_iso", `Assoc [ "type", `String "string" ]
      ; "now_unix", `Assoc [ "type", `String "number" ]
      ]
    ~required:[ "now_iso"; "now_unix" ]
;;

(* Producer: Snapshot_protocol.to_yojson via dispatch_board_list
   (keeper_tool_board_runtime.ml). [snapshot] carries the formatted post
   listing as one string and is absent on the [unchanged] variant. *)
let board_list_output_schema =
  object_output_schema
    ~properties:
      [ "kind", `Assoc [ "type", `String "string" ]
      ; "revision", `Assoc [ "type", `String "string" ]
      ; "snapshot", `Assoc [ "type", `String "string" ]
      ]
    ~required:[ "kind"; "revision" ]
;;

(* Producer: Masc_domain.task_compact_to_yojson by default and
   Masc_domain.task_to_yojson under projection "full" (lib/types/types_core.ml).
   Required are the fields both shapes emit unconditionally; [description] and
   [files] are declared because the full shape always carries them; the
   status-variant and presence-conditional fields pass through
   [additionalProperties]. *)
let exact_skill_identity_schema =
  `Assoc
    [ "type", `String "object"
    ; ( "properties"
      , `Assoc
          [ "source_id", `Assoc [ "type", `String "string" ]
          ; "package_id", `Assoc [ "type", `String "string" ]
          ; "name", `Assoc [ "type", `String "string" ]
          ] )
    ; ( "required"
      , `List
          [ `String "source_id"; `String "package_id"; `String "name" ] )
    ; "additionalProperties", `Bool false
    ]
;;

let exact_skill_reference_schema =
  `Assoc
    [ "type", `String "object"
    ; ( "properties"
      , `Assoc
          [ "identity", exact_skill_identity_schema
          ; ( "content_revision"
            , `Assoc [ "type", `String "string" ] )
          ] )
    ; ( "required"
      , `List [ `String "identity"; `String "content_revision" ] )
    ; "additionalProperties", `Bool false
    ]
;;

let tasks_list_task_item_schema =
  `Assoc
    [ "type", `String "object"
    ; ( "properties"
      , `Assoc
          [ "id", `Assoc [ "type", `String "string" ]
          ; "title", `Assoc [ "type", `String "string" ]
          ; "description", `Assoc [ "type", `String "string" ]
          ; "priority", `Assoc [ "type", `String "integer" ]
          ; ( "files"
            , `Assoc
                [ "type", `String "array"
                ; "items", `Assoc [ "type", `String "string" ]
                ] )
          ; ( "skills"
            , `Assoc
                [ "type", `String "array"
                ; "items", exact_skill_reference_schema
                ] )
          ; "created_at", `Assoc [ "type", `String "string" ]
          ; "status", `Assoc [ "type", `String "string" ]
          ] )
    ; ( "required"
      , `List
          (List.map
             (fun name -> `String name)
             [ "id"; "title"; "priority"; "created_at"; "status" ]) )
    ; "additionalProperties", `Bool true
    ]
;;

(* Producer: Tasks_list Ok branch (keeper_tool_task_runtime.ml) — the
   Snapshot_protocol envelope prefixed with backlog provenance and the row
   shape that was served. [snapshot] is absent on the [unchanged] variant. *)
let tasks_list_output_schema =
  object_output_schema
    ~properties:
      [ "backlog_authority", `Assoc [ "type", `String "string" ]
      ; "degraded", `Assoc [ "type", `String "boolean" ]
      ; "projection", `Assoc [ "type", `String "string" ]
      ; "kind", `Assoc [ "type", `String "string" ]
      ; "revision", `Assoc [ "type", `String "string" ]
      ; ( "snapshot"
        , `Assoc
            [ "type", `String "array"; "items", tasks_list_task_item_schema ] )
      ; "matching_count", `Assoc [ "type", `String "integer" ]
      ; "returned_count", `Assoc [ "type", `String "integer" ]
      ; "truncated", `Assoc [ "type", `String "boolean" ]
      ]
    ~required:
      [ "backlog_authority"
      ; "degraded"
      ; "projection"
      ; "kind"
      ; "revision"
      ; "matching_count"
      ; "returned_count"
      ; "truncated"
      ]
;;

(* Producer: Keeper_artifact_read.page_to_json — the single success path. *)
let artifact_read_output_schema =
  object_output_schema
    ~properties:
      [ "ok", `Assoc [ "type", `String "boolean" ]
      ; "sha256", `Assoc [ "type", `String "string" ]
      ; "offset", `Assoc [ "type", `String "integer" ]
      ; "next_offset", `Assoc [ "type", `String "integer" ]
      ; "total_bytes", `Assoc [ "type", `String "integer" ]
      ; "eof", `Assoc [ "type", `String "boolean" ]
      ; "encoding", `Assoc [ "type", `String "string" ]
      ; "content", `Assoc [ "type", `String "string" ]
      ]
    ~required:
      [ "ok"
      ; "sha256"
      ; "offset"
      ; "next_offset"
      ; "total_bytes"
      ; "eof"
      ; "encoding"
      ; "content"
      ]
;;

(* Producer: Workspace_goals.handle_goal_list over Goal_store.goal_to_yojson
   and rollup_to_yojson, with the RFC-0387 verification ledger
   (Goal_verification.record_to_yojson) joined per goal as [verification].
   Option-carrying goal fields serialize as string-or-null and stay
   undeclared; [verification] rides the items' additionalProperties:true. *)
let goal_list_output_schema =
  object_output_schema
    ~properties:
      [ "status", `Assoc [ "type", `String "string" ]
      ; "generated_at", `Assoc [ "type", `String "string" ]
      ; "count", `Assoc [ "type", `String "integer" ]
      ; ( "goals"
        , `Assoc
            [ "type", `String "array"
            ; ( "items"
              , `Assoc
                  [ "type", `String "object"
                  ; ( "properties"
                    , `Assoc
                        [ "id", `Assoc [ "type", `String "string" ]
                        ; "title", `Assoc [ "type", `String "string" ]
                        ; "priority", `Assoc [ "type", `String "integer" ]
                        ; "phase", `Assoc [ "type", `String "string" ]
                        ; "created_at", `Assoc [ "type", `String "string" ]
                        ; "updated_at", `Assoc [ "type", `String "string" ]
                        ] )
                  ; ( "required"
                    , `List
                        (List.map
                           (fun name -> `String name)
                           [ "id"
                           ; "title"
                           ; "priority"
                           ; "phase"
                           ; "created_at"
                           ; "updated_at"
                           ]) )
                  ; "additionalProperties", `Bool true
                  ] )
            ] )
      ; ( "rollup"
        , object_output_schema
            ~properties:
              [ "active_count", `Assoc [ "type", `String "integer" ]
              ; "verifying_count", `Assoc [ "type", `String "integer" ]
              ; "done_count", `Assoc [ "type", `String "integer" ]
              ; "dropped_count", `Assoc [ "type", `String "integer" ]
              ]
            ~required:
              [ "active_count"; "verifying_count"; "done_count"
              ; "dropped_count" ] )
      ]
    ~required:[ "status"; "generated_at"; "count"; "goals"; "rollup" ]
;;

(* Producer: Run_eio.list over run_record_to_json. [agent_name] serializes
   as string-or-null and stays undeclared. *)
let run_list_output_schema =
  object_output_schema
    ~properties:
      [ "count", `Assoc [ "type", `String "integer" ]
      ; ( "runs"
        , `Assoc
            [ "type", `String "array"
            ; ( "items"
              , `Assoc
                  [ "type", `String "object"
                  ; ( "properties"
                    , `Assoc
                        [ "task_id", `Assoc [ "type", `String "string" ]
                        ; "plan", `Assoc [ "type", `String "string" ]
                        ; "created_at", `Assoc [ "type", `String "string" ]
                        ; "updated_at", `Assoc [ "type", `String "string" ]
                        ] )
                  ; ( "required"
                    , `List
                        (List.map
                           (fun name -> `String name)
                           [ "task_id"; "plan"; "created_at"; "updated_at" ]) )
                  ; "additionalProperties", `Bool true
                  ] )
            ] )
      ]
    ~required:[ "count"; "runs" ]
;;

(* Producer: Metrics_store_eio.agent_metrics_to_yojson (ppx-derived over the
   11-field record in metrics_store_eio.mli). *)
let agent_metrics_output_properties =
  [ "agent_id", `Assoc [ "type", `String "string" ]
  ; "period_start", `Assoc [ "type", `String "number" ]
  ; "period_end", `Assoc [ "type", `String "number" ]
  ; "total_tasks", `Assoc [ "type", `String "integer" ]
  ; "completed_tasks", `Assoc [ "type", `String "integer" ]
  ; "failed_tasks", `Assoc [ "type", `String "integer" ]
  ; "avg_completion_time_s", `Assoc [ "type", `String "number" ]
  ; "task_completion_rate", `Assoc [ "type", `String "number" ]
  ; "error_rate", `Assoc [ "type", `String "number" ]
  ; "handoff_success_rate", `Assoc [ "type", `String "number" ]
  ; ( "unique_collaborators"
    , `Assoc
        [ "type", `String "array"; "items", `Assoc [ "type", `String "string" ] ]
    )
  ]
;;

let agent_metrics_output_required =
  [ "agent_id"
  ; "period_start"
  ; "period_end"
  ; "total_tasks"
  ; "completed_tasks"
  ; "failed_tasks"
  ; "avg_completion_time_s"
  ; "task_completion_rate"
  ; "error_rate"
  ; "handoff_success_rate"
  ; "unique_collaborators"
  ]
;;

(* Producer: Tool_agent.handle_get_metrics. The two resolution fields are
   appended by metrics_json_with_resolution only when the requested name
   resolved to a different metric id. *)
let get_metrics_output_schema =
  object_output_schema
    ~properties:
      (agent_metrics_output_properties
       @ [ "requested_agent_name", `Assoc [ "type", `String "string" ]
         ; "resolved_agent_name", `Assoc [ "type", `String "string" ]
         ])
    ~required:agent_metrics_output_required
;;

(* Producer: Tool_agent.handle_agent_fitness — both the empty-pool and the
   populated envelope. *)
let agent_fitness_output_schema =
  object_output_schema
    ~properties:
      [ "count", `Assoc [ "type", `String "integer" ]
      ; ( "agents"
        , `Assoc
            [ "type", `String "array"
            ; ( "items"
              , object_output_schema
                  ~properties:
                    [ "agent_id", `Assoc [ "type", `String "string" ]
                    ; ( "components"
                      , object_output_schema
                          ~properties:
                            [ "completion", `Assoc [ "type", `String "number" ]
                            ; "reliability", `Assoc [ "type", `String "number" ]
                            ; "speed", `Assoc [ "type", `String "number" ]
                            ; "handoff", `Assoc [ "type", `String "number" ]
                            ]
                          ~required:
                            [ "completion"; "reliability"; "speed"; "handoff" ]
                      )
                    ; ( "metrics"
                      , object_output_schema
                          ~properties:agent_metrics_output_properties
                          ~required:agent_metrics_output_required )
                    ]
                  ~required:[ "agent_id"; "components"; "metrics" ] )
            ] )
      ]
    ~required:[ "count"; "agents" ]
;;

let masc_board_descriptor board_name =
  let canonical_schema = Board_tool_registry.schema_for_board_name board_name in
  let name = Tool_name.Board_name.to_string board_name in
  let operation_policy = Board_tool_registry.operation_policy board_name in
  let readonly = operation_policy.readonly in
  (* Concurrent rows are the store-read operations: each resolves through
     [Board_dispatch] into [Board_core] reads that snapshot under
     [store.mutex] (an [Eio.Mutex]; board_core.mli "Locking + cache
     invalidation"), or into the [Atomic]-held curation snapshot
     ([Board_curation.latest_snapshot]). The [maybe_sweep] hook on reads
     reserves timestamps under the same mutex and hands the work to the
     flusher fiber. Write operations stay [Serial]. *)
  let ordinary_execution_mode =
    match board_name with
    | Tool_name.Board_name.Board_stats
    | Board_curation_read
    | Board_hearths
    | Board_list
    | Board_post_get
    | Board_profile
    | Board_search
    | Board_sub_board_get
    | Board_sub_board_list -> Concurrent
    | ( Board_cleanup
      | Board_comment
      | Board_comment_vote
      | Board_curation_submit
      | Board_delete
      | Board_post
      | Board_post_update
      | Board_reaction
      | Board_sub_board_create
      | Board_sub_board_delete
      | Board_sub_board_update
      | Board_vote ) -> Serial
  in
  let policy = policy ~readonly () in
  let canonical_keeper_input_schema =
    remove_schema_fields
      (Board_tool_registry.identity_fields_for_board_name board_name)
      canonical_schema.input_schema
  in
  let input_schema_source, description, input_schema =
    match Tool_shard_types.keeper_board_schema board_name with
    | Some projection ->
      Keeper_projection, projection.description, projection.input_schema
    | None ->
      Canonical_registry, canonical_schema.description, canonical_keeper_input_schema
  in
  let descriptor =
    in_process_descriptor_with_schema_source
       ~capability_identity:Internal_name_identity
       (* The sub-board CRUD tools stay registered for operator entrypoints
          but leave the keeper model surface: no keeper called them in the
          August .masc/tool_calls log, and every turn carried their schemas.
          The board's own core and dashboard paths do not go through this
          projection. *)
       ~keeper_model_projection:
         (match board_name with
          | Tool_name.Board_name.Board_sub_board_create
          | Tool_name.Board_name.Board_sub_board_update
          | Tool_name.Board_name.Board_sub_board_delete
          | Tool_name.Board_name.Board_sub_board_get
          | Tool_name.Board_name.Board_sub_board_list -> Operator_only
          | _ -> Internal_name)
       ~input_schema_source
       ~id:("masc.board." ^ Tool_name.Board_name.operation_name board_name)
       ~name
       ~description
       ~input_schema
       ~ordinary_execution_mode
       ~policy
       ~handler:Tool_board_dispatch
       ()
  in
  match board_name with
  | Tool_name.Board_name.Board_stats ->
    descriptor
    |> with_composable_output (Json_output { schema = board_stats_output_schema })
  | Tool_name.Board_name.Board_list ->
    descriptor
    |> with_composable_output (Json_output { schema = board_list_output_schema })
  | ( Board_cleanup
    | Board_comment
    | Board_comment_vote
    | Board_curation_read
    | Board_curation_submit
    | Board_delete
    | Board_hearths
    | Board_post
    | Board_post_get
    | Board_post_update
    | Board_profile
    | Board_reaction
    | Board_search
    | Board_sub_board_create
    | Board_sub_board_delete
    | Board_sub_board_get
    | Board_sub_board_list
    | Board_sub_board_update
    | Board_vote ) -> descriptor
;;

let masc_board_descriptors =
  List.map masc_board_descriptor Tool_name.Board_name.all
;;

let voice_descriptor name ~readonly =
  cluster_descriptor
    ~capability_identity:Internal_name_identity
    ~keeper_model_projection:Internal_name
    ~id:("keeper.voice." ^ String.sub name (String.length "keeper_voice_")
         (String.length name - String.length "keeper_voice_"))
    ~name
    ~handler:Tool_voice_dispatch
    ~readonly
    ()
;;

let task_descriptor ?ordinary_execution_mode ~capability_identity id name ~readonly =
  cluster_descriptor
    ?ordinary_execution_mode
    ~capability_identity
    ~keeper_model_projection:Internal_name
    ~id:("keeper.task." ^ id)
    ~name
    ~handler:Tool_task_dispatch
    ~readonly
    ()
;;

(* RFC-0182 §3.1 — additional masc_* cluster descriptor helpers (task /
   plan / run / agent / workspace). The masc_board_descriptor lives above
   (registry-driven); these helpers follow the same projection pattern
   but use hardcoded id+description because their dispatchers
   (Task.Tool / Tool_plan / Tool_run / Tool_agent / Tool_workspace) are not
   schema-registry-backed. The handler routes by descriptor.internal_name
   through the existing typed dispatcher. *)
let masc_task_descriptor
    ?(keeper_model_projection = Internal_name)
    ?ordinary_execution_mode
    id
    name
    ~readonly
  =
  cluster_descriptor
    ?ordinary_execution_mode
    ~capability_identity:Internal_name_identity
    ~keeper_model_projection
    ~id:("masc.task." ^ id)
    ~name
    ~handler:Tool_masc_task_dispatch
    ~readonly
    ()
;;

let masc_task_transport_descriptor ?ordinary_execution_mode id name ~readonly =
  cluster_descriptor
    ?ordinary_execution_mode
    ~capability_identity:Internal_name_identity
    ~keeper_model_projection:
      (Transport_alias { projected_by = "keeper_tasks_list" })
    ~id:("masc.task." ^ id)
    ~name
    ~handler:Tool_masc_task_dispatch
    ~readonly
    ()
;;

let masc_plan_descriptor
    ?(keeper_model_projection = Internal_name)
    ?ordinary_execution_mode
    id
    name
    ~readonly
  =
  cluster_descriptor
    ?ordinary_execution_mode
    ~capability_identity:Internal_name_identity
    ~keeper_model_projection
    ~id:("masc.plan." ^ id)
    ~name
    ~handler:Tool_masc_plan_dispatch
    ~readonly
    ()
;;

let masc_run_descriptor ?ordinary_execution_mode name ~readonly =
  cluster_descriptor
    ?ordinary_execution_mode
    ~capability_identity:Internal_name_identity
    ~keeper_model_projection:Internal_name
    ~id:("masc.run." ^ String.sub name (String.length "masc_run_")
         (String.length name - String.length "masc_run_"))
    ~name
    ~handler:Tool_masc_run_dispatch
    ~readonly
    ()
;;

let masc_agent_descriptor
    ?(keeper_model_projection = Internal_name)
    ?ordinary_execution_mode
    id
    name
    ~readonly
  =
  cluster_descriptor
    ?ordinary_execution_mode
    ~capability_identity:Internal_name_identity
    ~keeper_model_projection
    ~id:("masc.agent." ^ id)
    ~name
    ~handler:Tool_masc_agent_dispatch
    ~readonly
    ()
;;

let masc_workspace_descriptor
    ?(keeper_model_projection = Internal_name)
    ?ordinary_execution_mode
    id
    name
    ~readonly
  =
  cluster_descriptor
    ?ordinary_execution_mode
    ~capability_identity:Internal_name_identity
    ~keeper_model_projection
    ~id:("masc.workspace." ^ id)
    ~name
    ~handler:Tool_masc_workspace_dispatch
    ~readonly
    ()
;;

(* RFC-0182 §3.1 — additional cluster descriptor helpers (Phase 3:
   misc / control / agent_timeline / local_runtime). *)
let masc_misc_descriptor
    ?(keeper_model_projection = Internal_name)
    ?ordinary_execution_mode
    id
    name
    ~readonly
  =
  cluster_descriptor
    ?ordinary_execution_mode
    ~capability_identity:Internal_name_identity
    ~keeper_model_projection
    ~id:("masc.misc." ^ id)
    ~name
    ~handler:Tool_masc_misc_dispatch
    ~readonly
    ()
;;

let masc_control_descriptor operation =
  let schema = Tool_schemas_misc.control_schema operation in
  cluster_descriptor_with_schema_source
    ~capability_identity:Internal_name_identity
    ~keeper_model_projection:Operator_only
    ~input_schema_source:Canonical_registry
    ~input_schema:schema.input_schema
    ~id:("masc.control." ^ Tool_schemas_misc.control_operation_id operation)
    ~name:schema.name
    ~description:schema.description
    ~handler:Tool_masc_control_dispatch
    ~readonly:false
    ()
;;

let masc_agent_timeline_descriptor
    ?(keeper_model_projection = Internal_name)
    ?ordinary_execution_mode
    name
    description
    ~readonly
  =
  cluster_descriptor
    ?ordinary_execution_mode
    ~capability_identity:Internal_name_identity
    ~keeper_model_projection
    ~id:"masc.agent_timeline"
    ~name
    ~handler:Tool_masc_agent_timeline_dispatch
    ~readonly
    ()
;;

let masc_schedule_descriptor (definition : Tool_schemas_schedule.definition) =
  let schema : Masc_domain.tool_schema = definition.schema in
  cluster_descriptor_with_schema_source
    ~capability_identity:Internal_name_identity
    ~keeper_model_projection:Internal_name
    ~input_schema_source:Canonical_registry
    ~input_schema:schema.input_schema
    ~id:("masc.schedule." ^ definition.id)
    ~name:schema.name
    ~description:schema.description
    ~handler:Tool_masc_schedule_dispatch
    ~readonly:definition.read_only
    ()
;;

let keeper_spawn_descriptor (definition : Tool_schemas_spawn.definition) =
  let schema : Masc_domain.tool_schema = definition.schema in
  cluster_descriptor_with_schema_source
    ~capability_identity:Internal_name_identity
    ~keeper_model_projection:Internal_name
    ~input_schema_source:Canonical_registry
    ~input_schema:schema.input_schema
    ~id:("masc.spawn." ^ definition.id)
    ~name:schema.name
    ~description:schema.description
    ~handler:Tool_keeper_spawn_dispatch
    ~readonly:definition.read_only
    ()
;;

let keeper_code_query_descriptor () =
  let schema : Masc_domain.tool_schema = Tool_schemas_code_query.schema in
  cluster_descriptor_with_schema_source
    ~capability_identity:Internal_name_identity
    ~keeper_model_projection:Internal_name
    ~input_schema_source:Canonical_registry
    ~input_schema:schema.input_schema
    ~id:"masc.code_query"
    ~name:schema.name
    ~description:schema.description
    ~handler:Tool_keeper_code_query_dispatch
    (* Reads code and writes nothing. It does start a language server, but the
       turn's pool owns that and ends it; the caller is left holding an answer
       or a refusal. The wait is the pool's own bound, not one a caller states,
       so the reason keeper_spawn_wait is not read-only does not apply. *)
    ~readonly:true
    ()
;;

(* RFC-webmcp-keeper-consumption Lane B: relay to WebMCP tools a browser page
   registered, through the embedded node bridge and an operator-run Chrome. *)
let keeper_webmcp_list_descriptor () =
  let schema : Masc_domain.tool_schema = Tool_schemas_webmcp.list_schema in
  cluster_descriptor_with_schema_source
    ~capability_identity:Internal_name_identity
    ~keeper_model_projection:Internal_name
    ~input_schema_source:Canonical_registry
    ~input_schema:schema.input_schema
    ~id:"masc.webmcp_list"
    ~name:schema.name
    ~description:schema.description
    ~handler:Tool_keeper_webmcp_dispatch
    (* Discovery only: reads the page's registered tool catalog. *)
    ~readonly:true
    ()
;;

let keeper_webmcp_call_descriptor () =
  let schema : Masc_domain.tool_schema = Tool_schemas_webmcp.call_schema in
  cluster_descriptor_with_schema_source
    ~capability_identity:Internal_name_identity
    ~keeper_model_projection:Internal_name
    ~input_schema_source:Canonical_registry
    ~input_schema:schema.input_schema
    ~id:"masc.webmcp_call"
    ~name:schema.name
    ~description:schema.description
    ~handler:Tool_keeper_webmcp_dispatch
    (* Executes whatever the page tool does — a page may register mutating
       tools, and the bridge cannot know which kind it called. *)
    ~readonly:false
    ()
;;

let masc_keeper_descriptor
    ?(polling_read = false)
    ~keeper_model_projection
    id
    name
    ~readonly =
  let schema =
    match
      List.find_opt
        (fun (schema : Masc_domain.tool_schema) -> String.equal schema.name name)
        (Keeper_schema.schemas @ Tool_schemas_misc.schemas)
    with
    | Some schema -> schema
    | None -> invalid_arg ("missing Keeper surface schema for " ^ name)
  in
  cluster_descriptor_with_schema_source
    ~polling_read
    ~capability_identity:Internal_name_identity
    ~keeper_model_projection
    ~input_schema_source:Canonical_registry
    ~input_schema:schema.input_schema
    ~id:("masc.keeper." ^ id)
    ~name
    ~description:schema.description
    ~handler:Tool_masc_keeper_dispatch
    ~readonly
    ()
;;

let masc_library_descriptor (definition : Tool_schemas_library.definition) =
  let schema = definition.schema in
  let keeper_model_projection, description =
    match definition.operation with
    | Tool_schemas_library.List_documents ->
      ( Internal_name
      , "List all documents in the agent knowledge library with title, source, \
         author, created date, and tags. Use keeper_library_read to fetch a \
         document or keeper_library_search to query by content." )
    | Tool_schemas_library.Read_document ->
      Transport_alias { projected_by = "keeper_library_read" }, schema.description
    | Tool_schemas_library.Search_documents ->
      Transport_alias { projected_by = "keeper_library_search" }, schema.description
    | Tool_schemas_library.Add_document -> Internal_name, schema.description
  in
  cluster_descriptor_with_schema_source
    ~capability_identity:Internal_name_identity
    ~keeper_model_projection
    ~input_schema_source:Canonical_registry
    ~input_schema:schema.input_schema
    ~id:("masc.library." ^ Tool_schemas_library.operation_id definition.operation)
    ~name:schema.name
    ~description
    ~handler:Tool_masc_library_dispatch
    ~readonly:definition.read_only
    ()
;;

let masc_library_descriptors =
  List.map masc_library_descriptor Tool_schemas_library.definitions
;;

let masc_local_runtime_descriptor
      (definition : Tool_schemas_local_runtime.definition) =
  let schema = definition.schema in
  let keeper_model_projection =
    match Tool_schemas_local_runtime.keeper_model_exposure definition.operation with
    | Tool_schemas_local_runtime.Keeper_callable -> Internal_name
    | Tool_schemas_local_runtime.Operator_diagnostic -> Operator_only
  in
  let execution_policy =
    Tool_schemas_local_runtime.execution_policy definition.operation
  in
  let policy =
    policy ~readonly:execution_policy.read_only ()
  in
  in_process_descriptor_with_schema_source
    ~capability_identity:Internal_name_identity
    ~keeper_model_projection
    ~input_schema_source:Canonical_registry
    ~input_schema:schema.input_schema
    ~id:
      ("masc.local_runtime."
       ^ Tool_schemas_local_runtime.operation_id definition.operation)
    ~name:schema.name
    ~description:schema.description
    ~handler:Tool_masc_local_runtime_dispatch
    ~policy
    ()
;;

let masc_local_runtime_descriptors =
  List.map
    masc_local_runtime_descriptor
    Tool_schemas_local_runtime.definitions
;;

let internal_descriptors : t list =
  [ (* ── time / catalog (RFC-0179 PR-2 + PR-3) ────────── *)
    (in_process_descriptor
      ~keeper_model_projection:Internal_name
      ~id:"keeper.time.now"
      ~name:"keeper_time_now"
      ~description:
        "Return the current wall-clock time as ISO 8601 and Unix epoch \
         seconds. No arguments."
      ~input_schema:empty_object_schema
      ~ordinary_execution_mode:Concurrent
      ~policy:(read_only_in_process_policy ())
      ~handler:Tool_time_now
      ()
     |> with_composable_output (Json_output { schema = time_now_output_schema }))
  ; (in_process_descriptor_with_schema_source
       ~capability_identity:Internal_name_identity
       ~keeper_model_projection:Internal_name
       ~input_schema_source:Canonical_registry
       ~id:"keeper.tools_list"
       ~name:"keeper_tools_list"
       ~description:keeper_tools_list_schema.description
       ~input_schema:keeper_tools_list_schema.input_schema
       (* Concurrent: pure projection over the boot-time descriptor
          registry and registered schemas; no shared mutable state. *)
       ~ordinary_execution_mode:Concurrent
       ~policy:(read_only_in_process_policy ())
       ~handler:Tool_tools_list
       ()
     |> with_eval_tags [ "capability_introspection" ])
  ; (in_process_descriptor_with_schema_source
       ~capability_identity:Internal_name_identity
       ~keeper_model_projection:Internal_name
       ~input_schema_source:Canonical_registry
       ~id:"keeper.capability_search"
       ~name:"keeper_capability_search"
       ~description:keeper_capability_search_schema.description
       ~input_schema:keeper_capability_search_schema.input_schema
       ~ordinary_execution_mode:Concurrent
       ~policy:(read_only_in_process_policy ())
       ~handler:Tool_capability_search
       ()
     |> with_eval_tags [ "capability_introspection" ])
    (* ── memory / context (RFC-0179 PR-3) ─────────────────────── *)
  ; in_process_descriptor
      ~keeper_model_projection:Internal_name
      ~id:"keeper.context.status"
      ~name:"keeper_context_status"
      ~description:
        "Return persisted checkpoint, recent-message, memory, and sandbox \
         state for this keeper turn. Context-window occupancy is not \
         currently observed."
      ~input_schema:empty_object_schema
      ~policy:(read_only_in_process_policy ())
      ~handler:Tool_context_status
      ()
  ; (in_process_descriptor_with_schema_source
      ~capability_identity:Internal_name_identity
      ~keeper_model_projection:Internal_name
      ~input_schema_source:Canonical_registry
      ~id:"keeper.artifact.read"
      ~name:Keeper_tool_runtime_schemas.artifact_read.name
      ~description:Keeper_tool_runtime_schemas.artifact_read.description
      ~input_schema:Keeper_tool_runtime_schemas.artifact_read.input_schema
      (* Concurrent: content-addressed blob reads; the validated-file
         cache in Tool_blob_store is an Atomic CAS over an immutable map. *)
      ~ordinary_execution_mode:Concurrent
      ~policy:(read_only_in_process_policy ())
      ~handler:Tool_artifact_read
      ()
    |> with_model_output_projection Tool_output.bounded_inline_model_projection
    |> with_composable_output (Json_output { schema = artifact_read_output_schema }))
  ; in_process_descriptor_with_schema_source
      ~capability_identity:Internal_name_identity
      ~keeper_model_projection:Internal_name
      ~input_schema_source:memory_search_schema_source
      ~id:"keeper.memory.search"
      ~name:"keeper_memory_search"
      ~description:
        "Search keeper memory or history; current facts use explicit substring filtering and snapshot order."
      ~input_schema:memory_search_schema
      ~policy:(read_only_in_process_policy ())
      ~handler:Tool_memory_search
      ()
  ; in_process_descriptor_with_schema_source
      ~capability_identity:Internal_name_identity
      ~keeper_model_projection:Internal_name
      ~input_schema_source:memory_retract_schema_source
      ~id:"keeper.memory.retract"
      ~name:"keeper_memory_retract"
      ~description:memory_retract_schema.description
      ~input_schema:memory_retract_schema.input_schema
      ~policy:(write_in_process_policy ())
      ~handler:Tool_memory_retract
      ()
  ; in_process_descriptor_with_schema_source
      ~capability_identity:Internal_name_identity
      ~keeper_model_projection:Internal_name
      ~input_schema_source:memory_write_schema_source
      ~id:"keeper.memory.write"
      ~name:"keeper_memory_write"
      ~description:"Persist a memory entry for this keeper."
      ~input_schema:memory_write_schema
      ~policy:(write_in_process_policy ())
      ~handler:Tool_memory_write
      ()
    (* ── library (RFC-0179 PR-3) ──────────────────────────────── *)
  ; in_process_descriptor
      ~keeper_model_projection:Internal_name
      ~id:"keeper.library.search"
      ~name:"keeper_library_search"
      ~description:library_search.Masc_domain.description
      ~input_schema:library_search.Masc_domain.input_schema
      (* Concurrent: directory listing + whole-file reads in
         Tool_library; no shared mutable state on the search path. *)
      ~ordinary_execution_mode:Concurrent
      ~policy:(read_only_in_process_policy ())
      ~handler:Tool_library_search
      ()
  ; in_process_descriptor
      ~keeper_model_projection:Internal_name
      ~id:"keeper.library.read"
      ~name:"keeper_library_read"
      ~description:library_read.Masc_domain.description
      ~input_schema:library_read.Masc_domain.input_schema
      ~ordinary_execution_mode:Concurrent
      ~policy:(read_only_in_process_policy ())
      ~handler:Tool_library_read
      ()
    (* ── connector surfaces (RFC-0223 P3) ─────────────────────── *)
  ; (in_process_descriptor
       ~keeper_model_projection:Internal_name
       ~id:"keeper.surface.read"
       ~name:"keeper_surface_read"
       ~description:
         "Read recent messages from one conversation endpoint (dashboard, \
          discord, slack, or another connector label) with speaker identity \
          and a derived participant roster. With mode='channel', 'messages', \
          'members', or 'member', the Discord lane can also query its live \
          channel and server read surface within the keeper's bound channels."
       ~input_schema:surface_read_schema
       ~policy:(read_only_in_process_policy ())
       ~handler:Tool_surface_read
       ()
     |> with_eval_tags [ "surface_context_read" ])
  ; in_process_descriptor
      ~keeper_model_projection:Internal_name
      ~id:"keeper.surface.post"
      ~name:"keeper_surface_post"
      ~description:Tool_shard_types.keeper_surface_post_description
      ~input_schema:surface_post_schema
      ~policy:(write_in_process_policy ())
      ~handler:Tool_surface_post
      ()
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
      ()
    (* ── IDE (RFC-0179 PR-3) ──────────────────────────────────── *)
  ; in_process_descriptor_with_schema_source
      ~capability_identity:Internal_name_identity
      ~keeper_model_projection:Internal_name
      ~input_schema_source:ide_annotate_schema_source
      ~id:"keeper.ide.annotate"
      ~name:"keeper_ide_annotate"
      ~description:"Emit an IDE annotation event for the current keeper."
      ~input_schema:ide_annotate_schema
      ~policy:(write_in_process_policy ())
      ~handler:Tool_ide_annotate
      ()
    (* ── fusion deliberation (RFC-0252) ───────────────────────── *)
  ; in_process_descriptor_with_schema_source
      ~capability_identity:Internal_name_identity
      ~keeper_model_projection:Internal_name
      ~input_schema_source:Canonical_registry
      ~id:"masc.fusion.deliberate"
      ~name:Keeper_tool_runtime_schemas.fusion.name
      ~description:Keeper_tool_runtime_schemas.fusion.description
      ~input_schema:Keeper_tool_runtime_schemas.fusion.input_schema
      (* The explicit [Internal_name] projection makes Fusion available. *)
      ~policy:(write_in_process_policy ())
      ~handler:Tool_masc_fusion_dispatch
      ()
    (* ── fusion status (RFC-0266 §7 Phase 3) ──────────────────── *)
  ; in_process_descriptor_with_schema_source
      ~capability_identity:Internal_name_identity
      ~keeper_model_projection:Internal_name
      ~input_schema_source:Canonical_registry
      ~id:"masc.fusion.status"
      ~name:Keeper_tool_runtime_schemas.fusion_status.name
      ~description:Keeper_tool_runtime_schemas.fusion_status.description
      ~input_schema:Keeper_tool_runtime_schemas.fusion_status.input_schema
      (* [Internal_name] is the model exposure authority. *)
      (* Concurrent: projects an [Atomic.get] snapshot of the fusion run
         registry (Run_registry_core); mutation goes through its own
         cross-context mutex on the write side. *)
      ~ordinary_execution_mode:Concurrent
      ~policy:(read_only_in_process_policy ())
      ~handler:Tool_masc_fusion_status
      ()
    (* ── vision delegation (RFC-keeper-vision-delegation-tool §2.6) ─ *)
  ; in_process_descriptor_with_schema_source
      ~capability_identity:Internal_name_identity
      (* [Operator_only]: the model has its own analyze_image builtin and the
         .masc/tool_calls log shows this keeper-facing name was never called;
         hiding it takes its schema off every keeper turn. The handler and the
         read-only sub-call stay available to operator entrypoints. *)
      ~keeper_model_projection:Operator_only
      ~input_schema_source:Canonical_registry
      ~id:"keeper.vision.analyze_image"
      ~name:Keeper_tool_runtime_schemas.keeper_analyze_image.name
      ~description:Keeper_tool_runtime_schemas.keeper_analyze_image.description
      ~input_schema:Keeper_tool_runtime_schemas.keeper_analyze_image.input_schema
      ~policy:(read_only_in_process_policy ())
      ~handler:Tool_analyze_image
      ()
    (* ── voice cluster (RFC-0179 PR-3, 6 tools) ───────────────── *)
  ; voice_descriptor
      "keeper_voice_speak"
      ~readonly:false
  ; voice_descriptor
      "keeper_voice_listen"
      ~readonly:false
  ; voice_descriptor
      "keeper_voice_agent"
      ~readonly:true
  ; voice_descriptor
      "keeper_voice_sessions"
      ~readonly:true
  ; voice_descriptor
      "keeper_voice_session_start"
      ~readonly:false
  ; voice_descriptor
      "keeper_voice_session_end"
      ~readonly:false
    (* ── task / broadcast cluster (RFC-0179 PR-3, 6 tools) ────── *)
  ; (task_descriptor
       (* Concurrent: backlog reads go through the mtime/size-keyed cache in
          Workspace_backlog, whose lookups and refreshes run under a
          Stdlib.Mutex with no suspension inside the critical section. *)
       ~ordinary_execution_mode:Concurrent
       ~capability_identity:(Named_capability "masc_tasks")
       "list"
       "keeper_tasks_list"
       ~readonly:true
     |> with_composable_output (Json_output { schema = tasks_list_output_schema }))
  ; task_descriptor
      ~ordinary_execution_mode:Concurrent
      ~capability_identity:Internal_name_identity
      "audit"
      "keeper_tasks_audit"
      ~readonly:true
  ; task_descriptor
      ~capability_identity:(Named_capability "masc_broadcast")
      "broadcast"
      "keeper_broadcast"
      ~readonly:false
  ; task_descriptor
      ~capability_identity:Internal_name_identity
      "claim"
      "keeper_task_claim"
      ~readonly:false
  ; task_descriptor
      ~capability_identity:Internal_name_identity
      "create"
      "keeper_task_create"
      ~readonly:false
  ; task_descriptor
      ~capability_identity:Internal_name_identity
      "done"
      "keeper_task_done"
      (* The name says done; the handler issues submit_for_verification
         (keeper_tool_task_runtime.ml:910). The description that says so now
         lives once, on the canonical schema this descriptor reads. *)
      ~readonly:false
  ; task_descriptor
      ~capability_identity:Internal_name_identity
      "release"
      "keeper_task_release"
      (* The other half of the claim refusal: a keeper holding work it cannot
         finish is also barred from claiming anything else, and until this
         existed the only way back was shutting the keeper down. *)
      ~readonly:false
  (* ── RFC-0182 §3.1 — masc_task_* cluster (7 entries) ─────────── *)
  (* Zero keeper dispatches in the live window (tool_usage 2026-07..08):
     keepers create and move tasks through the keeper_task_* surface, so the
     masc_* twins stay on the transport surface only. Transport_alias names
     the keeper tool that already covers the capability. *)
  ; masc_task_descriptor
       ~keeper_model_projection:(Transport_alias { projected_by = "keeper_task_create" })
       "add" "masc_add_task"
       ~readonly:false
  ; masc_task_descriptor
       ~keeper_model_projection:(Transport_alias { projected_by = "keeper_task_create" })
       "batch_add" "masc_batch_add_tasks"
       ~readonly:false
  ; masc_task_descriptor ~ordinary_execution_mode:Concurrent
       "task_history" "masc_task_history"
       ~readonly:true
  ; masc_task_transport_descriptor ~ordinary_execution_mode:Concurrent
       "tasks" "masc_tasks"
       ~readonly:true
  ; masc_task_descriptor
       ~keeper_model_projection:(Transport_alias { projected_by = "keeper_task_claim" })
       "transition" "masc_transition"
       ~readonly:false
  ; masc_task_descriptor
       ~keeper_model_projection:(Transport_alias { projected_by = "keeper_task_claim" })
       "update_priority" "masc_update_priority"
       ~readonly:false
  ; masc_task_descriptor "set_goal" "masc_task_set_goal"
       ~readonly:false
  (* ── RFC-0182 §3.1 — masc_plan_* current-task trio (3 entries).
     The five plan-document tools (init/update/get + note_add/deliver)
     were retired with their planning/<task_id> store; only the
     current-task session pointer remains. ── *)
  ; masc_plan_descriptor ~keeper_model_projection:Operator_only
       "set_task" "masc_plan_set_task"
       ~readonly:false
  ; masc_plan_descriptor ~ordinary_execution_mode:Concurrent
       "get_task" "masc_plan_get_task"
       ~readonly:true
  ; masc_plan_descriptor "clear_task" "masc_plan_clear_task"
       ~readonly:false
  (* ── RFC-0182 §3.1 — masc_run_* cluster (4 entries) ──────────── *)
  ; masc_run_descriptor "masc_run_init"
       ~readonly:false
  ; (masc_run_descriptor ~ordinary_execution_mode:Concurrent
       "masc_run_list"
       ~readonly:true
     |> with_composable_output (Json_output { schema = run_list_output_schema }))
  ; masc_run_descriptor "masc_run_get"
      ~readonly:false
  ; masc_run_descriptor "masc_run_plan"
       ~readonly:true
  (* ── RFC-0182 §3.1 — masc_agent_* cluster (3 entries) ────────── *)
  ; (masc_agent_descriptor ~keeper_model_projection:Operator_only
        ~ordinary_execution_mode:Concurrent
        "card" "masc_agent_card"
        ~readonly:true
     (* No composable output: #29681 took this off the model surface, and a
        composable schema only means "a Keeper plan may reference this node's
        output" -- every reader of the field is in keeper_tool_plan*. A tool
        the model cannot name is never a plan node, so the schema described a
        reference nobody can write. *)
     |> with_eval_tags [ "agent_profile_lookup" ])
  ; (masc_agent_descriptor ~ordinary_execution_mode:Concurrent
       "fitness" "masc_agent_fitness"
       ~readonly:true
     |> with_composable_output
          (Json_output { schema = agent_fitness_output_schema }))
  ; (masc_agent_descriptor ~ordinary_execution_mode:Concurrent
       "get_metrics" "masc_get_metrics"
       ~readonly:true
     |> with_composable_output (Json_output { schema = get_metrics_output_schema }))
  (* ── RFC-0182 §3.1 — masc_workspace_* cluster (8 entries) ────────── *)
  (* Operator-only: [masc_status] answers with the operator's status *screen*.
     Workspace_status renders it for a terminal — emoji, a box-drawing rule, a
     [Players:] roster that includes non-Keeper MCP clients, a [Task binding:]
     line of seven fields, and an [Attention:] list whose entry for a Keeper is
     "Your agent session is not bound", a CLI concept a Keeper has no session to
     bind. Its own header calls it a display and caps the roster at
     [max_agents_display].

     A Keeper is handed the same facts as typed per-turn context: the world
     state frame already carries the backlog counts, the running fiber count,
     and the Keeper's own recent Board posts. Exposing the screen on top of that
     offered a second, untyped copy whose only Keeper-specific line was a false
     warning.

     The tool itself stays registered: the dashboard Settings "Server check"
     calls it through MCP, [GET /api/v1/status] maps to it, and it remains in
     the public MCP surface for CLI clients. Only the Keeper model projection
     goes. *)
  ; masc_workspace_descriptor
      ~keeper_model_projection:Operator_only
      "status"
      "masc_status"
       ~readonly:true
  ; masc_workspace_descriptor ~keeper_model_projection:Operator_only
      "heartbeat"
      "masc_heartbeat"
       ~readonly:false
  ; masc_workspace_descriptor ~keeper_model_projection:Operator_only
      "check" "masc_check"
       ~readonly:true
  ; (masc_workspace_descriptor ~ordinary_execution_mode:Concurrent
       "goal_list" "masc_goal_list"
       ~readonly:true
     |> with_composable_output (Json_output { schema = goal_list_output_schema }))
  ; masc_workspace_descriptor "goal_upsert" "masc_goal_upsert"
       ~readonly:false
  ; masc_workspace_descriptor "goal_transition" "masc_goal_transition"
       ~readonly:false
  (* ── RFC-0182 §3.1 — masc_misc_* cluster (9 entries) ─────────── *)
  ; masc_misc_descriptor ~ordinary_execution_mode:Concurrent
       "config" "masc_config"
       ~readonly:true
  ; masc_misc_descriptor "dashboard" "masc_dashboard"
       ~readonly:true
  ; cluster_descriptor
      ~capability_identity:Internal_name_identity
      ~keeper_model_projection:Operator_only
      ~id:"masc.misc.keeper_waiting_inventory"
      ~name:"masc_keeper_waiting_inventory"
      ~handler:Tool_masc_misc_dispatch
      ~readonly:true
      ()
  ; masc_misc_descriptor ~keeper_model_projection:Operator_only
       ~ordinary_execution_mode:Concurrent
       "tool_help" "masc_tool_help"
       ~readonly:true
  ; masc_misc_descriptor "gc" "masc_gc"
      ~readonly:false
  (* [masc_web_search] / [masc_web_fetch] are already owned by the
     MASC-owned web descriptors above. Do not add
     duplicate internal descriptors here; that would make runtime receipt
     projection depend on list order. *)
  (* ── RFC-0182 §3.1 — masc_control_* cluster (2 entries) ──────── *)
  ; masc_control_descriptor Tool_schemas_misc.Pause
  ; masc_control_descriptor Tool_schemas_misc.Resume
  (* ── RFC-0182 §3.1 — masc_agent_timeline singleton (1 entry) ── *)
  ; (masc_agent_timeline_descriptor ~keeper_model_projection:Operator_only
       ~ordinary_execution_mode:Concurrent
       "masc_agent_timeline"
       (* No composable output, for the same reason as masc_agent_card above:
          off the model surface since #29681, so no plan can name it. *)
       "Read agent timeline events." ~readonly:true)
  (* ── RFC-0234 — scheduled internal automation (6 entries) ─────── *)
  ]
  @ List.map masc_schedule_descriptor Tool_schemas_schedule.definitions
  @ List.map keeper_spawn_descriptor Tool_schemas_spawn.definitions
  (* ── RFC a-language-server-the-keeper-can-ask (1 entry) ───────── *)
  @ [ keeper_code_query_descriptor () ]
  (* ── RFC-webmcp-keeper-consumption Lane B (2 entries) ─────────── *)
  @ [ keeper_webmcp_list_descriptor (); keeper_webmcp_call_descriptor () ]
  @ [
  (* ── RFC-0182 §3.1 — masc_keeper cluster ──── *)
    masc_keeper_descriptor ~keeper_model_projection:Operator_only "list" "masc_keeper_list"
      ~readonly:true
  ; masc_keeper_descriptor ~keeper_model_projection:Internal_name "delegate_status" "masc_keeper_delegate_status"
      ~readonly:true
      ~polling_read:true
  ; masc_keeper_descriptor ~keeper_model_projection:Internal_name "delegate_cancel" "masc_keeper_delegate_cancel"
      ~readonly:false
  ; masc_keeper_descriptor ~keeper_model_projection:Operator_only "delegate_list" "masc_keeper_delegate_list"
      ~readonly:true
  ; masc_keeper_descriptor ~keeper_model_projection:Operator_only "clear" "masc_keeper_clear"
      ~readonly:false
  ; masc_keeper_descriptor ~keeper_model_projection:Operator_only "sandbox_start" "masc_keeper_sandbox_start"
      ~readonly:false
  ; masc_keeper_descriptor ~keeper_model_projection:Operator_only "sandbox_stop" "masc_keeper_sandbox_stop"
      ~readonly:false
  ; masc_keeper_descriptor ~keeper_model_projection:Operator_only "reset" "masc_keeper_reset"
      ~readonly:false
  ; masc_keeper_descriptor ~keeper_model_projection:Operator_only "audit" "masc_keeper_audit"
      ~readonly:true
  ; masc_keeper_descriptor ~keeper_model_projection:Operator_only "status" "masc_keeper_status"
      ~readonly:true
  ; masc_keeper_descriptor ~keeper_model_projection:Operator_only "down" "masc_keeper_down"
      ~readonly:false
  ; masc_keeper_descriptor ~keeper_model_projection:Internal_name "delegate" "masc_keeper_delegate"
      ~readonly:false
  ; masc_keeper_descriptor ~keeper_model_projection:Operator_only "up" "masc_keeper_up"
      ~readonly:false
  ; masc_keeper_descriptor ~keeper_model_projection:Operator_only "msg" "masc_keeper_msg"
      ~readonly:false
  ]
  @ masc_board_descriptors
  @ masc_library_descriptors
  @ masc_local_runtime_descriptors
;;

let all_descriptors () = public_descriptors @ internal_descriptors

let find_id id =
  List.find_opt (fun descriptor -> String.equal descriptor.id id) (all_descriptors ())
;;

let model_input_schema_errors ~tool_name = function
  | `Assoc _ as schema -> (Tool_input_validation.schema_shape schema).errors
  | other ->
    [ Printf.sprintf
        "input schema for %s must be an object, got %s"
        tool_name
        (Json_util.kind_name other)
    ]
;;

let model_schema_errors descriptor =
  match descriptor.input_schema_source with
  | Descriptor_owned | Canonical_registry | Keeper_projection ->
    model_input_schema_errors
      ~tool_name:descriptor.internal_name
      descriptor.input_schema
;;

let keeper_model_names descriptor =
  match model_schema_errors descriptor, descriptor.keeper_model_projection with
  | _ :: _, _ -> []
  | [], Preferred_public_name ->
    [ descriptor.public_name ]
  | [], Internal_name ->
    [ descriptor.internal_name ]
  | [], (Operator_only | Transport_alias _) -> []
;;

let registered_names descriptor =
  [ descriptor.internal_name; descriptor.public_name ]
  |> List.sort_uniq String.compare
;;

let model_visible_descriptors () =
  all_descriptors ()
  |> List.filter (fun descriptor ->
    match model_schema_errors descriptor, keeper_model_names descriptor with
    | _ :: _, _ | [], [] -> false
    | [], _ :: _ -> true)
;;



let model_visible_schemas () =
  model_visible_descriptors ()
  |> List.concat_map (fun descriptor ->
    keeper_model_names descriptor
    |> List.map (fun name ->
      { Masc_domain.name
      ; description = descriptor.description
      ; input_schema = descriptor.input_schema
      }))
;;

let public_names_of_descriptor d = [ d.public_name ]

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
  | Some descriptor -> translate_input_for_descriptor descriptor input
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
  ; "cwd_scope", Json_util.string_opt_to_json policy.cwd_scope
  ; "polling_read", `Bool policy.polling_read
  ]
;;

(* Route evidence consumers must read fields by key; object field order is not a
   compatibility contract. *)
let route_evidence_json d =
  let policy = d.policy in
  `Assoc
    ([ "descriptor_id", `String d.id
     ; "capability_id", `String d.capability_id
     ; ( "keeper_model_projection"
       , `String (keeper_model_projection_to_string d.keeper_model_projection) )
     ; "public_name", `String d.public_name
     ; "canonical_name", `String d.internal_name
     ; "description", `String d.description
     ; "executor", `String (executor_to_string d.executor)
     ; "backend", `String (backend_to_string d.backend)
     ; "sandbox", `String (sandbox_to_string d.sandbox)
     ; "runtime_handler", `String (runtime_handler_to_string d.runtime_handler)
     ; "execution", `String (execution_to_string d.execution)
     ; "tool_kind", `String (tool_kind_to_string d.tool_kind)
     ; "composable_output", composable_output_to_json d.composable_output
     ; "receipt_labels", receipt_labels_json d
     ; "eval_tags", eval_tags_json d
     ]
     @
     (match d.keeper_model_projection with
      | Transport_alias { projected_by } ->
        [ "transport_alias_of", `String projected_by ]
      | Preferred_public_name | Internal_name | Operator_only -> [])
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
   ; "capability_id", `String d.capability_id
   ; ( "keeper_model_projection"
     , `String (keeper_model_projection_to_string d.keeper_model_projection) )
   ; "input_schema_source", `String (input_schema_source_to_string d.input_schema_source)
   ; "public_name", `String d.public_name
   ; "internal_name", `String d.internal_name
   ; "description", `String d.description
   ; "executor", `String (executor_to_string d.executor)
   ; "backend", `String (backend_to_string d.backend)
   ; "sandbox", `String (sandbox_to_string d.sandbox)
   ; "runtime_handler", `String (runtime_handler_to_string d.runtime_handler)
   ; "execution", `String (execution_to_string d.execution)
   ; "tool_kind", `String (tool_kind_to_string d.tool_kind)
   ; "composable_output", composable_output_to_json d.composable_output
   ; "policy", discovery_policy_json d.policy
   ; "schema_shape", Tool_input_validation.schema_shape_json d.input_schema
   ]
   @
   match d.keeper_model_projection with
   | Transport_alias { projected_by } ->
     [ "transport_alias_of", `String projected_by ]
   | Preferred_public_name | Internal_name | Operator_only -> [])
  @ examples_field
;;
