(** Keeper_tool_dispatch_runtime — keeper tool execution and tool-loop helpers.

    Split into multiple layers:
    - [Keeper_tool_registry]: declarative tool name lists (data)
    - [Keeper_tool_policy]: descriptor/registry surface + denylist resolution (logic)
    - [Keeper_tool_*_runtime]: dedicated runtime modules for tool categories
    - This module: execution dispatch + shared helpers (side-effects) *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_tool_shared_runtime
include Keeper_tool_registry
include Keeper_tool_policy

let has_mutating_side_effect_with_input ~(tool_name : string) ~(input : Yojson.Safe.t)
  : bool
  =
  not (Keeper_tool_registry.is_read_only_with_input ~tool_name ~input)
;;

type keeper_tool_call_recorder =
  tool_name:string -> success:bool -> duration_ms:int -> unit

let default_keeper_tool_call_recorder ~tool_name:_ ~success:_ ~duration_ms:_ = ()
let keeper_tool_call_recorder : keeper_tool_call_recorder Atomic.t =
  Atomic.make default_keeper_tool_call_recorder

let set_on_keeper_tool_call (f : keeper_tool_call_recorder) =
  Atomic.set keeper_tool_call_recorder f
;;

let record_keeper_tool_call ~tool_name ~success ~duration_ms =
  Atomic.get keeper_tool_call_recorder ~tool_name ~success ~duration_ms
;;

let search_char c =
  match c with
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' -> c
  | _ when Char.code c > 127 -> c
  | _ -> ' '
;;

let normalize_search_text text = String.lowercase_ascii (String.map search_char text)


let search_terms query =
  normalize_search_text query
  |> String.split_on_char ' '
  |> List.map String.trim
  |> List.filter (fun term -> term <> "")
  |> List.sort_uniq String.compare
;;

let dedupe_tool_search_schemas schemas =
  let seen = Hashtbl.create (List.length schemas) in
  List.filter
    (fun (schema : Masc_domain.tool_schema) ->
       if Hashtbl.mem seen schema.name
       then false
       else (
         Hashtbl.replace seen schema.name ();
         true))
    schemas
;;

let default_tool_search_schemas () =
  all_keeper_model_tool_schemas () |> dedupe_tool_search_schemas
;;

let score_tool_schema terms (schema : Masc_domain.tool_schema) =
  let help = Tool_help_registry.entry_of_schema schema in
  let name_text = normalize_search_text schema.name in
  let search_text =
    normalize_search_text
      (String.concat
         " "
         [ schema.name
         ; schema.description
         ; help.Tool_help_registry.when_to_use
         ; Yojson.Safe.to_string schema.input_schema
         ])
  in
  List.fold_left
    (fun score term ->
       if String_util.contains_substring name_text term
       then score +. 2.0
       else if String_util.contains_substring search_text term
       then score +. 1.0
       else score)
    0.0
    terms
;;

let default_tool_search_fn ~query ~max_results =
  let terms = search_terms query in
  let schemas = default_tool_search_schemas () in
  let hits =
    schemas
    |> List.filter_map (fun schema ->
      let score = score_tool_schema terms schema in
      if Float.compare score 0.0 <= 0 then None else Some (schema, score))
    |> List.sort (fun (left_schema, left_score) (right_schema, right_score) ->
      let by_score = compare right_score left_score in
      if by_score <> 0
      then by_score
      else String.compare left_schema.Masc_domain.name right_schema.name)
  in
  let rec take n xs =
    if n <= 0
    then []
    else (
      match xs with
      | [] -> []
      | x :: rest -> x :: take (n - 1) rest)
  in
  let selected = take max_results hits in
  let result_json (schema, score) =
    let help = Tool_help_registry.entry_of_schema schema in
    `Assoc
      [ "name", `String schema.Masc_domain.name
      ; "score", `Float score
      ; "description", `String help.short_description
      ; "when_to_use", `String help.when_to_use
      ; "input_schema", schema.input_schema
      ; "already_visible", `Bool false
      ]
  in
  let results = List.map result_json selected in
  let hint =
    if results = []
    then
      "No tools match this static fallback query. In normal keeper turns, the \
       session-scoped BM25 index provides richer policy-aware search."
    else
      "Static fallback results from keeper schemas. Normal keeper turns use the richer \
       session-scoped BM25 index."
  in
  `Assoc
    [ "ok", `Bool true
    ; "query", `String query
    ; "results", `List results
    ; "result_count", `Int (List.length results)
    ; ( "diagnostics"
      , `Assoc
          [ "source", `String "static_schema_fallback"
          ; "candidate_count", `Int (List.length schemas)
          ] )
    ; "hint", `String hint
    ]
;;

type tool_searcher = query:string -> max_results:int -> Yojson.Safe.t

let default_tool_searcher = default_tool_search_fn
let tool_searcher : tool_searcher Atomic.t = Atomic.make default_tool_searcher

let set_tool_search_fn (f : tool_searcher) = Atomic.set tool_searcher f

let search_tools ~query ~max_results = Atomic.get tool_searcher ~query ~max_results

type tool_result_payload =
  | Structured_success
  | Structured_error
  | Plain_text
  | Malformed_structured of string

type execution_outcome =
  [ `Success
  | `Failure
  ]

type executed_tool_result =
  { raw_output : string
  ; outcome : execution_outcome
  ; payload_shape : tool_result_payload
  }

let looks_like_structured_payload payload =
  let len = String.length payload in
  let rec find_first_nonspace i =
    if i >= len
    then None
    else (
      match payload.[i] with
      | ' ' | '\t' | '\n' | '\r' -> find_first_nonspace (i + 1)
      | c -> Some c)
  in
  match find_first_nonspace 0 with
  | Some ('{' | '[') -> true
  | Some _ | None -> false
;;

let classify_tool_result_payload payload =
  if not (looks_like_structured_payload payload)
  then Plain_text
  else (
    match
      Safe_ops.parse_json_safe
        ~context:"Keeper_tool_dispatch_runtime.classify_tool_result_payload"
        payload
    with
    | Error msg -> Malformed_structured msg
    | Ok (`Assoc fields) ->
      let is_error =
        match List.assoc_opt "ok" fields with
        | Some (`Bool false) -> true
        | _ -> List.mem_assoc "error" fields
      in
      if is_error then Structured_error else Structured_success
    | Ok _ -> Structured_success)
;;

let failure_class_of_tool_result_payload payload =
  match
    Safe_ops.parse_json_safe
      ~context:"Keeper_tool_dispatch_runtime.failure_class_of_tool_result_payload"
      payload
  with
  | Ok json ->
    if Safe_ops.json_bool ~default:false "ok" json
    then None
    else (
      match Safe_ops.json_string_opt "failure_class" json with
      | Some class_str ->
        (match Tool_result.tool_failure_class_of_string class_str with
         | Some _ as fc -> fc
         | None -> Some Tool_result.Runtime_failure)
      | None -> Some Tool_result.Runtime_failure)
  | Error _ -> Some Tool_result.Runtime_failure
;;

let should_apply_circuit_breaker_to_failure_payload failure_class_opt =
  match failure_class_opt with
  | Some Tool_result.Policy_rejection | Some Tool_result.Workflow_rejection -> false
  | Some Tool_result.Transient_error | Some Tool_result.Runtime_failure | None -> true
;;

let is_policy_gate_error raw_output =
  match
    Safe_ops.parse_json_safe ~context:"Keeper_tool_dispatch_runtime.is_policy_gate_error" raw_output
  with
  | Ok json ->
    (match Safe_ops.json_string_opt "error" json with
     | Some msg -> String.equal (String.trim msg) "tool_not_allowed"
     | None -> false)
  | Error _ -> false
;;

let inferred_outcome_of_result ~raw_output ~payload_shape =
  match payload_shape with
  | Structured_success | Plain_text -> `Success
  | Structured_error -> `Failure
  | Malformed_structured _ -> `Failure
;;

let make_executed_tool_result ?outcome raw_output =
  let payload_shape = classify_tool_result_payload raw_output in
  let outcome =
    match outcome with
    | Some explicit -> explicit
    | None -> inferred_outcome_of_result ~raw_output ~payload_shape
  in
  { raw_output; outcome; payload_shape }
;;

let args_has_any_field fields args =
  match args with
  | `Assoc args_fields ->
    List.exists
      (fun wanted -> List.exists (fun (key, _) -> String.equal key wanted) args_fields)
      fields
  | _ -> false
;;

let tool_tutor_json ~kind ~requested_tool ~message ~alternatives =
  `Assoc
    [ "kind", `String kind
    ; "requested_tool", `String requested_tool
    ; "message", `String message
    ; "alternatives", `List alternatives
    ]
;;

let grep_alternative =
  `Assoc
    [ "tool", `String "Grep"
    ; "when", `String "search file contents with a ripgrep regex"
    ; "required", `List [ `String "pattern" ]
    ; "optional", `List [ `String "path"; `String "glob"; `String "type" ]
    ]
;;

let execute_find_alternative =
  `Assoc
    [ "tool", `String "Execute"
    ; "when", `String "list files or expand globs"
    ; ( "example"
      , `Assoc
          [ "executable", `String "find"
          ; "argv", `List [ `String "."; `String "-name"; `String "*.ml" ]
          ] )
    ]
;;

let read_alternative =
  `Assoc
    [ "tool", `String "Read"
    ; "when", `String "read one whole file or a byte-limited prefix"
    ; "required", `List [ `String "file_path" ]
    ; "optional", `List [ `String "cwd"; `String "limit" ]
    ]
;;

(* Closed vocabulary of the hallucinated/typo'd tool names this tutor
   recognizes. These names intentionally have no [Tool_name]/[runtime_handler]
   variant: they are *not* tools, they are common model mistakes routed to the
   rejection path. Modelling them as their own closed sum keeps the guidance
   match exhaustive (no catch-all swallow) while not polluting the real tool
   enums. #21087 introduced these as lowercased string literals. *)
type tutor_alias =
  | Glob
  | Search_files_alias
  | Read_file_alias

let tutor_alias_of_requested_name requested_tool =
  match String.lowercase_ascii (String.trim requested_tool) with
  | "glob" -> Some Glob
  | "searchfiles" | "search_files" -> Some Search_files_alias
  | "readfile" | "read_file" -> Some Read_file_alias
  | _ -> None
;;

let tool_tutor_for_unknown_name requested_tool =
  match tutor_alias_of_requested_name requested_tool with
  | Some Glob ->
    Some
      (tool_tutor_json
         ~kind:"unknown_tool"
         ~requested_tool
         ~message:
           "Glob is not an active MASC keeper tool. Use Grep only for content \
            search; use Execute with find/ls for file listing."
         ~alternatives:[ grep_alternative; execute_find_alternative ])
  | Some Search_files_alias ->
    Some
      (tool_tutor_json
         ~kind:"tool_name_alias"
         ~requested_tool
         ~message:
           "Use Grep or search_files with the public search-files schema: \
            provide pattern, not query."
         ~alternatives:[ grep_alternative ])
  | Some Read_file_alias ->
    Some
      (tool_tutor_json
         ~kind:"tool_name_alias"
         ~requested_tool
         ~message:"Use Read with file_path; Read has no start_line or offset."
         ~alternatives:[ read_alternative ])
  | None -> None
;;

(* Tutor guidance is keyed on the descriptor's typed [runtime_handler] rather
   than its internal-name string. Resolving to the descriptor and matching the
   variant keeps the compiler exhaustive: a new handler forces a decision here
   instead of silently falling through a string default. #21087 introduced this
   as a [canonical_internal_name_for_tool_name] string match; the typed handler
   is the same canonical signal carried by the descriptor. *)
let tool_tutor_for_validation ~tool_name ~input =
  match Keeper_tool_descriptor_resolution.descriptor_for_tool_name tool_name with
  | None -> None
  | Some descriptor ->
    (match descriptor.Keeper_tool_descriptor.runtime_handler with
     | Keeper_tool_descriptor.Tool_read_file
       when args_has_any_field
              [ "offset"; "start_line"; "end_line"; "line"; "line_start"; "line_end" ]
              input ->
       Some
         (tool_tutor_json
            ~kind:"invalid_arguments"
            ~requested_tool:tool_name
            ~message:
              "Read does not support line offsets. Use file_path plus optional \
               cwd/limit; use Grep or Execute for locating a smaller target first."
            ~alternatives:[ read_alternative; grep_alternative; execute_find_alternative ])
     | Keeper_tool_descriptor.Tool_search_files when args_has_any_field [ "query" ] input
       ->
       Some
         (tool_tutor_json
            ~kind:"invalid_arguments"
            ~requested_tool:tool_name
            ~message:
              "Grep/search_files requires pattern. Rename query to pattern for \
               content search."
            ~alternatives:[ grep_alternative ])
     (* Handlers below carry no tutor; listed explicitly so a new runtime_handler
        variant forces a compile-time choice instead of a string catch-all. *)
     | Keeper_tool_descriptor.Tool_read_file
     | Keeper_tool_descriptor.Tool_search_files
     | Keeper_tool_descriptor.Tool_execute
     | Keeper_tool_descriptor.Tool_edit_file
     | Keeper_tool_descriptor.Tool_write_file
     | Keeper_tool_descriptor.Tool_time_now
     | Keeper_tool_descriptor.Tool_tools_list
     | Keeper_tool_descriptor.Tool_tool_search
     | Keeper_tool_descriptor.Tool_context_status
     | Keeper_tool_descriptor.Tool_memory_search
     | Keeper_tool_descriptor.Tool_memory_write
     | Keeper_tool_descriptor.Tool_library_search
     | Keeper_tool_descriptor.Tool_library_read
     | Keeper_tool_descriptor.Tool_surface_read
     | Keeper_tool_descriptor.Tool_surface_post
     | Keeper_tool_descriptor.Tool_person_note_set
     | Keeper_tool_descriptor.Tool_ide_annotate
     | Keeper_tool_descriptor.Tool_voice_dispatch
     | Keeper_tool_descriptor.Tool_task_dispatch
     | Keeper_tool_descriptor.Board_tool_dispatch
     | Keeper_tool_descriptor.Tool_masc_board_dispatch
     | Keeper_tool_descriptor.Tool_masc_task_dispatch
     | Keeper_tool_descriptor.Tool_masc_plan_dispatch
     | Keeper_tool_descriptor.Tool_masc_run_dispatch
     | Keeper_tool_descriptor.Tool_masc_agent_dispatch
     | Keeper_tool_descriptor.Tool_masc_workspace_dispatch
     | Keeper_tool_descriptor.Tool_masc_misc_dispatch
     | Keeper_tool_descriptor.Tool_masc_control_dispatch
     | Keeper_tool_descriptor.Tool_masc_agent_timeline_dispatch
     | Keeper_tool_descriptor.Tool_masc_schedule_dispatch
     | Keeper_tool_descriptor.Tool_masc_keeper_dispatch
     | Keeper_tool_descriptor.Tool_masc_surface_audit
     | Keeper_tool_descriptor.Tool_masc_fusion_dispatch
     | Keeper_tool_descriptor.Tool_masc_fusion_status
     | Keeper_tool_descriptor.Tool_masc_library_dispatch
     | Keeper_tool_descriptor.Tool_masc_recurring_dispatch
     | Keeper_tool_descriptor.Tool_masc_local_runtime_dispatch
     | Keeper_tool_descriptor.Tool_analyze_image -> None)
;;

let append_assoc_fields json extra_fields =
  match json with
  | `Assoc fields -> `Assoc (fields @ extra_fields)
  | other -> `Assoc (("payload", other) :: extra_fields)
;;

let add_tool_tutor_to_payload raw_payload tutor =
  let json =
    match
      Safe_ops.parse_json_safe
        ~context:"Keeper_tool_dispatch_runtime.add_tool_tutor_to_payload"
        raw_payload
    with
    | Ok json -> json
    | Error _ -> `String raw_payload
  in
  Yojson.Safe.to_string (append_assoc_fields json [ "tool_tutor", tutor ])
;;

(* Descriptor and registered-only routes are distinct dispatch sources.
   Outcome is inferred from raw JSON via [classify_tool_result_payload]. *)

type descriptor_dispatch =
  | Descriptor_route of Keeper_tool_descriptor.t * string option
  | Validation_rejected of string
  | Undescribed_route

type descriptor_dispatch_resolution =
  | Return_output of string
  | Return_descriptor_invariant of Keeper_tool_descriptor.t
  | Try_registered_only_route

let resolve_descriptor_dispatch = function
  | Descriptor_route (_, Some raw_output) | Validation_rejected raw_output ->
    Return_output raw_output
  | Descriptor_route (descriptor, None) -> Return_descriptor_invariant descriptor
  | Undescribed_route -> Try_registered_only_route
;;

let descriptor_route_invariant_payload ~tool_name descriptor =
  let descriptor_id = descriptor.Keeper_tool_descriptor.id in
  let executor =
    Keeper_tool_descriptor.executor_to_string descriptor.executor
  in
  let runtime_handler =
    Keeper_tool_descriptor.runtime_handler_to_string descriptor.runtime_handler
  in
  `Assoc
    [ "ok", `Bool false
    ; "error", `String "keeper_tool_descriptor_route_invariant"
    ; "failure_class", `String "runtime_failure"
    ; "tool", `String tool_name
    ; "descriptor_id", `String descriptor_id
    ; "executor", `String executor
    ; "runtime_handler", `String runtime_handler
    ]
;;

let descriptor_route_invariant_error ~keeper_name ~tool_name descriptor =
  let payload = descriptor_route_invariant_payload ~tool_name descriptor in
  let descriptor_id = descriptor.Keeper_tool_descriptor.id in
  let executor =
    Keeper_tool_descriptor.executor_to_string descriptor.executor
  in
  let runtime_handler =
    Keeper_tool_descriptor.runtime_handler_to_string descriptor.runtime_handler
  in
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string AgentToolDispatchRuntimeFailures)
    ~labels:
      [ "keeper", keeper_name
      ; "tool", tool_name
      ; "reason", "descriptor_route_unhandled"
      ; "descriptor_id", descriptor_id
      ; "executor", executor
      ; "runtime_handler", runtime_handler
      ]
    ();
  Log.Keeper.emit
    Log.Error
    ~keeper_name
    ~category:Log.Tool
    ~details:
      (`Assoc
         [ "error_kind", `String "keeper_tool_descriptor_route_invariant"
         ; "tool", `String tool_name
         ; "descriptor_id", `String descriptor_id
         ; "executor", `String executor
         ; "runtime_handler", `String runtime_handler
         ])
    "keeper descriptor route resolved but its typed runtime handler returned no result";
  Yojson.Safe.to_string payload
;;

(* ── Tool execution dispatch ──────────────────────────────────── *)

let execute_keeper_tool_call_with_outcome
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(ctx_work : working_context)
      ?turn_sandbox_factory
      ~(exec_cache : Masc_exec.Exec_cache.t option)
      ?search_fn
      (* RFC-0182 Phase 5 PR-A.2: optional Eio resources threaded to
         Keeper_tool_runtime.context for Eio-bound descriptor handlers. *)
      ?sw
      ?clock
      ?proc_mgr
      ?net
      ?mcp_session_id
      ~(name : string)
      ~(input : Yojson.Safe.t)
      ()
  : executed_tool_result
  =
  let args = input in
  let meta =
    match Keeper_registry.get_with_health ~base_path:config.base_path meta.name with
    | Some (entry, Keeper_registry.Healthy) -> entry.meta
    | Some (_, health) ->
      let reason_label =
        match health with
        | Keeper_registry.Healthy -> "healthy"
        | Keeper_registry.Meta_validation_failed _ -> "meta_validation_failed"
        | Keeper_registry.Required_field_missing _ -> "required_field_missing"
        | Keeper_registry.Base_path_mismatch _ -> "base_path_mismatch"
        | Keeper_registry.Name_mismatch _ -> "name_mismatch"
      in
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string RegistryInvalidEntry)
        ~labels:
          [ "operation", "tool_dispatch_fallback"
          ; "name", meta.name
          ; "reason", reason_label
          ]
        ();
      meta
    | None -> meta
  in
  let apply_circuit_breaker (result : executed_tool_result) =
    match result.outcome, result.payload_shape with
    | `Success, _ ->
      Keeper_failure_circuit_breaker.record_success ~keeper_name:meta.name;
      result
    | `Failure, Malformed_structured parse_error ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string AgentToolDispatchRuntimeFailures)
        ~labels:[ "keeper", meta.name; "tool", name ]
        ();
      Log.Keeper.error ~keeper_name:meta.name
        "tool:%s produced malformed structured payload: %s"
        name
        parse_error;
      let breaker_msg = Printf.sprintf "malformed_tool_result: %s" parse_error in
      let raw_output =
        Keeper_failure_circuit_breaker.maybe_enrich_error
          ~keeper_name:meta.name
          ~error_msg:breaker_msg
      in
      { raw_output
      ; outcome = `Failure
      ; payload_shape = classify_tool_result_payload raw_output
      }
    | `Failure, Structured_error | `Failure, Structured_success | `Failure, Plain_text ->
      let raw_output =
        let failure_class = failure_class_of_tool_result_payload result.raw_output in
        if should_apply_circuit_breaker_to_failure_payload failure_class
        then
          Keeper_failure_circuit_breaker.maybe_enrich_error
            ~keeper_name:meta.name
            ~error_msg:result.raw_output
        else (
          Keeper_failure_circuit_breaker.record_observed_failure
            ~keeper_name:meta.name
            ~error_msg:result.raw_output;
          result.raw_output
        )
      in
      { raw_output
      ; outcome = `Failure
      ; payload_shape = classify_tool_result_payload raw_output
      }
  in
  let lookup = tool_access_lookup_of_meta meta in
  apply_circuit_breaker
    (if not (can_execute ~lookup name)
     then (
       let reason, hint =
         if not (StringSet.mem name lookup.candidate_set)
         then
           ( "not_in_candidate_set"
           , Printf.sprintf
               "'%s' is not a recognized tool. Check spelling or use keeper_tools_list \
                to see available tools."
               name )
         else if StringSet.mem name lookup.deny_set
         then
           ( "denied_by_policy"
           , Printf.sprintf
               "'%s' is blocked by your current policy. Ask operator to grant access."
               name )
         else
           ( "not_executable"
           , Printf.sprintf
               "'%s' exists but is not executable in this keeper runtime. Use \
                keeper_tool_search to find an active tool or ask the operator \
                to inspect the descriptor/denylist state."
               name )
       in
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string ToolNotAllowed)
         ~labels:
           [ "keeper", meta.name
           ; "tool", name
           ; "reason", reason
           ; "tool_type", Tool_telemetry.tool_type_of_name name
           ]
         ();
       make_executed_tool_result
         (Yojson.Safe.to_string
            (let fields =
               [ "ok", `Bool false
               ; "error", `String "tool_not_allowed"
               ; "failure_class", `String "policy_rejection"
               ; "tool", `String name
               ; "reason", `String reason
               ; "hint", `String hint
               ]
             in
             match tool_tutor_for_unknown_name name with
             | Some tutor -> `Assoc (fields @ [ "tool_tutor", tutor ])
             | None -> `Assoc fields)))
     else (
       let effective_search_fn =
         match search_fn with
         | Some f -> f
         | None -> search_tools
       in
       let keeper_tool_runtime_context =
         Keeper_tool_runtime.
                       { config
                       ; meta
                       ; ctx_work
                       ; turn_sandbox_factory
                       ; exec_cache
           ; search_fn = effective_search_fn
           ; (* RFC-0182 Phase 5 PR-A.2: Eio resources threaded from
                caller via labeled ? params.  Callers without Eio
                context (OAS handler, tests) leave them unset. *)
             sw
           ; clock
           ; proc_mgr
           ; net
           ; mcp_session_id
           }
       in
       let descriptor_dispatch =
         match
           Keeper_tool_descriptor_resolution.validated_descriptor_and_input_for_tool_call
             ~tool_name:name
             ~input:args
         with
         | Some (Ok (descriptor, translated_args)) ->
           Descriptor_route
             ( descriptor
             , Keeper_tool_runtime.handle
                 keeper_tool_runtime_context
                 ~descriptor
                 ~args:translated_args )
         | Some (Error validation_result) ->
           let raw_payload = Yojson.Safe.to_string (Tool_result.data validation_result) in
           let raw_payload =
             match tool_tutor_for_validation ~tool_name:name ~input:args with
             | Some tutor -> add_tool_tutor_to_payload raw_payload tutor
             | None -> raw_payload
           in
           Validation_rejected raw_payload
         | None -> Undescribed_route
       in
       match resolve_descriptor_dispatch descriptor_dispatch with
       | Return_output raw_output -> make_executed_tool_result raw_output
       | Return_descriptor_invariant descriptor ->
         make_executed_tool_result
           (descriptor_route_invariant_error
              ~keeper_name:meta.name
              ~tool_name:name
              descriptor)
       | Try_registered_only_route ->
         (* Registered-only tools are a separate dispatch source. A descriptor
            route that resolves but returns [None] is handled above as a typed
            invariant failure and can never fall through to this backend. *)
         let unknown_name = name in
         (match
            Keeper_tool_registered_runtime.handle_registered_tool
              ~config
              ~keeper_name:meta.name
              ~name:unknown_name
              ~args
          with
          | Some raw_output -> make_executed_tool_result raw_output
          | None ->
            let suggestion =
              let candidates = keeper_allowed_tool_names meta in
              let scored =
                candidates
                |> List.filter_map (fun c ->
                  if String.length c > 2 && String.length unknown_name > 2
                  then (
                    let unknown_name_lower = String.lowercase_ascii unknown_name in
                    let c_lower = String.lowercase_ascii c in
                    let contains haystack needle =
                      let nlen = String.length needle in
                      let hlen = String.length haystack in
                      if nlen = 0
                      then true
                      else if nlen > hlen
                      then false
                      else (
                        let found = ref false in
                        for i = 0 to hlen - nlen do
                          if (not !found) && String.sub haystack i nlen = needle
                          then found := true
                        done;
                        !found)
                    in
                    if
                      contains c_lower unknown_name_lower
                      || contains unknown_name_lower c_lower
                    then Some c
                    else None)
                  else None)
                |> List.filteri (fun i _ -> i < 3)
              in
              scored
            in
            let masc_schemas = Keeper_tool_registry.masc_schemas_snapshot () in
            let enrich_suggestion name =
              let schema_opt =
                List.find_opt
                  (fun (s : Masc_domain.tool_schema) -> s.name = name)
                  masc_schemas
              in
              match schema_opt with
              | Some s ->
                `Assoc
                  [ "name", `String name
                  ; "description", `String s.description
                  ; "input_schema", s.input_schema
                  ]
              | None -> `String name
            in
            let suggestion_fields =
              match suggestion with
              | [] ->
                [ "hint", `String "Use keeper_tool_search to find available tools." ]
              | names ->
                [ "did_you_mean", `List (List.map enrich_suggestion names)
                ; "hint", `String "Call one of these tools with the correct parameters."
                ]
            in
            let tutor_fields =
              match tool_tutor_for_unknown_name unknown_name with
              | Some tutor -> [ "tool_tutor", tutor ]
              | None -> []
            in
            let fields =
              [ "ok", `Bool false
              ; "error", `String "unknown_tool"
              ; "failure_class", `String "policy_rejection"
              ; "tool", `String unknown_name
              ]
              @ suggestion_fields
              @ tutor_fields
            in
            make_executed_tool_result (Yojson.Safe.to_string (`Assoc fields))))
      )
;;

let execute_keeper_tool_call
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(ctx_work : working_context)
      ?turn_sandbox_factory
      ~(exec_cache : Masc_exec.Exec_cache.t option)
      ?search_fn
      ~(name : string)
      ~(input : Yojson.Safe.t)
      ()
  : string
  =
  let result =
    execute_keeper_tool_call_with_outcome
      ~config
      ~meta
                  ~ctx_work
                  ?turn_sandbox_factory
                  ~exec_cache
      ?search_fn
      ~name
      ~input
      ()
  in
  result.raw_output
;;

module For_testing = struct
  type descriptor_route_kind =
    | Output
    | Invariant
    | Registered_only

  let set_on_keeper_tool_call = set_on_keeper_tool_call
  let record_keeper_tool_call = record_keeper_tool_call
  let set_tool_search_fn = set_tool_search_fn
  let search_tools = search_tools
  let descriptor_route_invariant_payload = descriptor_route_invariant_payload

  let descriptor_route_kind ~descriptor ~output =
    match resolve_descriptor_dispatch (Descriptor_route (descriptor, output)) with
    | Return_output _ -> Output
    | Return_descriptor_invariant _ -> Invariant
    | Try_registered_only_route -> Registered_only
  ;;
end
