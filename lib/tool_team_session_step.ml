(** Extracted handle_step logic for team session step operations.

    Contains the canonical write entrypoint for team sessions.
    Moved from tool_team_session.ml to reduce file size.

    Depends on parent module via [step_deps] record to avoid circular deps. *)

open Tool_args
module Oas = Agent_sdk

(** Spawn specification parsed from MCP tool arguments. *)
type spawn_spec = {
  spawn_agent : string;
  spawn_prompt : string;
  spawn_model : string option;
  spawn_model_explicit : bool;
  spawn_role : string option;
  execution_scope : Team_session_types.execution_scope option;
  thinking_enabled : bool option;
  max_turns : int option;
  worker_class : Team_session_types.worker_class option;
  worker_size : Team_session_types.worker_size option;
  parent_actor : string option;
  capsule_mode : Team_session_types.capsule_mode option;
  runtime_pool : string option;
  lane_id : string option;
  control_domain : Team_session_types.control_domain option;
  supervisor_actor : string option;
  model_tier : Team_session_types.model_tier option;
  model_tier_explicit : bool;
  task_profile : Team_session_types.task_profile option;
  risk_level : Team_session_types.risk_level option;
  routing_confidence : float option;
  routing_reason : string option;
  spawn_selection_note : string option;
  spawn_timeout_seconds : int;
}

(** Prepared spawn with resolved runtime assignment. *)
type prepared_spawn = {
  worker_run_id : string;
  spec : spawn_spec;
  runtime_actor_name : string option;
  runtime_model : Llm_client.model_spec;
  runtime_lease : Local_runtime_pool.lease option;
  assigned_runtime : string option;
}

(** OAS worker evidence payload for trace integration. *)
type oas_worker_evidence = {
  trace_ref : Oas.Raw_trace.run_ref option;
  trace_summary_json : Yojson.Safe.t option;
  trace_validation_json : Yojson.Safe.t option;
  worker_json : Yojson.Safe.t option;
  conformance_json : Yojson.Safe.t option;
  worker : Oas.Sessions.worker_run option;
}

type 'a context = {
  config : Room.config;
  agent_name : string;
  sw : Eio.Switch.t;
  clock : 'a Eio.Time.clock;
  proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option;
}

type result = bool * string

(** Dependency record — all functions from the parent module that handle_step needs.
    Avoids circular dependency between tool_team_session and this module. *)
type step_deps = {
  json_error : string -> string;
  json_ok : (string * Yojson.Safe.t) list -> string;
  get_valid_session_id : Yojson.Safe.t -> (string, string) Result.t;
  ensure_session_access : 'a. 'a context -> string -> (unit, string) Result.t;
  parse_step_spawn_specs : Yojson.Safe.t -> (spawn_spec list, string) Result.t;
  annotate_control_hierarchy_for_session :
    Team_session_types.session -> spawn_spec list -> spawn_spec list;
  parse_turn_kind :
    Yojson.Safe.t -> (Team_session_types.turn_kind, string) Result.t;
  parse_turn_kind_opt :
    Yojson.Safe.t -> (Team_session_types.turn_kind option, string) Result.t;
  parse_wait_mode : Yojson.Safe.t -> Team_session_types.wait_mode;
  int_opt_to_json : int option -> Yojson.Safe.t;
  float_opt_to_json : float option -> Yojson.Safe.t;
  truncate_for_event : ?max_len:int -> string -> string;
  make_worker_run_id : unit -> string;
  derived_llama_runtime_actor : session_id:string -> prompt:string -> string;
  is_local_spawn_agent : string -> bool;
  effective_execution_scope_of_spec :
    spawn_spec -> Team_session_types.execution_scope option;
  worker_size_of_spec : spawn_spec -> Team_session_types.worker_size option;
  inferred_controller_level_of_spec :
    spawn_spec -> Team_session_types.controller_level option;
  planned_worker_of_spec :
    ?runtime_actor:string ->
    spawn_spec ->
    Team_session_types.planned_worker;
  register_planned_workers :
    Room.config ->
    string ->
    Team_session_types.planned_worker list ->
    (unit, string) Result.t;
  ensure_session_actor :
    Room.config -> string -> string -> (unit, string) Result.t;
  record_session_turn_json :
    config:Room.config ->
    session_id:string ->
    actor:string ->
    turn_kind:Team_session_types.turn_kind ->
    message:string option ->
    target_agent:string option ->
    task_title:string option ->
    task_description:string option ->
    task_priority:int ->
    (Yojson.Safe.t, string) Result.t;
  resolve_target_worker_name :
    Room.config -> Team_session_types.session -> string -> string option;
  session_has_turn_for_actor :
    Room.config -> string -> string -> bool;
  auto_note_message_of_spawn_output : string -> string option;
  reconcile_failed_spawn_actor :
    Room.config ->
    string ->
    string ->
    ([ `Retained | `Detached ], string) Result.t;
  extract_vote_id : string -> string option;
  oas_worker_evidence_payload :
    config:Room.config ->
    evidence_session_id:string ->
    oas_worker_evidence option;
  oas_trace_capability_to_string :
    Oas.Sessions.trace_capability -> string;
  oas_worker_status_to_json :
    Oas.Sessions.worker_status -> Yojson.Safe.t;
  worker_run_status_to_json :
    [ `Accepted | `Ready | `Running | `Completed | `Failed ] -> Yojson.Safe.t;
  raw_trace_run_ref_to_json : Oas.Raw_trace.run_ref -> Yojson.Safe.t;
  raw_trace_session_payloads :
    config:Room.config ->
    fallback_session_id:string ->
    Oas.Raw_trace.run_ref ->
    (Yojson.Safe.t * Yojson.Safe.t) option;
}

let handle_step (deps : step_deps) (ctx : _ context) args : result =
  match deps.get_valid_session_id args with
  | Error e -> (false, deps.json_error e)
  | Ok session_id -> (
      match deps.ensure_session_access ctx session_id with
      | Error e -> (false, deps.json_error e)
      | Ok () ->
          let session_opt = Team_session_store.load_session ctx.config session_id in
          let spawn_specs_result = deps.parse_step_spawn_specs args in
          match spawn_specs_result with
          | Error e -> (false, deps.json_error e)
          | Ok raw_spawn_specs ->
              let spawn_specs =
                match session_opt with
                | Some session ->
                    deps.annotate_control_hierarchy_for_session session raw_spawn_specs
                | None -> raw_spawn_specs
              in
              let delegate_prompt_opt = get_string_opt args "delegate_prompt" in
              let turn_kind_result =
                if spawn_specs <> [] || Option.is_some delegate_prompt_opt then
                  deps.parse_turn_kind_opt args
                else
                  match deps.parse_turn_kind args with
                  | Ok kind -> Ok (Some kind)
                  | Error e -> Error e
              in
              match turn_kind_result with
              | Error e -> (false, deps.json_error e)
              | Ok turn_kind_opt ->
              let actor_result =
                match get_string_opt args "actor" with
                | None -> Ok ctx.agent_name
                | Some actor_name
                  when String.equal (String.trim actor_name) ctx.agent_name ->
                    Ok ctx.agent_name
                | Some _ ->
                    Error
                      "actor must match the authenticated caller; omit actor to use the current agent"
              in
              match actor_result with
              | Error e -> (false, deps.json_error e)
              | Ok actor ->
              let wait_mode = deps.parse_wait_mode args in
              let base_message = get_string_opt args "message" in
              let target_agent = get_string_opt args "target_agent" in
              let delegate_prompt = delegate_prompt_opt in
              let task_title = get_string_opt args "task_title" in
              let task_description = get_string_opt args "task_description" in
              let task_priority = get_int args "task_priority" 3 in
              let append_spawn_event ?worker_run_id ?spawn_agent ?runtime_actor ?spawn_role
                  ?spawn_model ?execution_scope ?worker_class ?worker_size
                  ?worker_backend ?wait_mode ?trace_capability
                  ?parent_actor ?capsule_mode
                  ?runtime_pool ?lane_id ?controller_level ?control_domain
                  ?supervisor_actor ?model_tier ?task_profile ?risk_level
                  ?routing_confidence ?routing_reason ?assigned_runtime
                  ?spawn_selection_note ?tool_names ?tool_call_count ~success
                  ?exit_code
                  ?elapsed_ms ?output_preview ?error () =
                let _ = spawn_agent and _ = spawn_model and _ = model_tier in
                let detail =
                  `Assoc
                    [
                      ("actor", `String actor);
                      ("worker_run_id", Option.fold ~none:`Null ~some:(fun s -> `String s) worker_run_id);
                      ( "runtime_actor",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          runtime_actor );
                      ( "spawn_role",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          spawn_role );
                      ( "execution_scope",
                        Option.fold ~none:`Null
                          ~some:(fun scope ->
                            `String
                              (Team_session_types.execution_scope_to_string
                                 scope))
                          execution_scope );
                      ( "worker_class",
                        Option.fold ~none:`Null
                          ~some:(fun kind ->
                            `String
                              (Team_session_types.worker_class_to_string kind))
                          worker_class );
                      ( "worker_size",
                        Option.fold ~none:`Null
                          ~some:(fun size ->
                            `String
                              (Team_session_types.worker_size_to_string size))
                          worker_size );
                      ( "worker_backend",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          worker_backend );
                      ( "wait_mode",
                        Option.fold ~none:`Null ~some:(fun mode -> `String mode)
                          wait_mode );
                      ( "trace_capability",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          trace_capability );
                      ( "parent_actor",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          parent_actor );
                      ( "capsule_mode",
                        Option.fold ~none:`Null
                          ~some:(fun mode ->
                            `String
                              (Team_session_types.capsule_mode_to_string mode))
                          capsule_mode );
                      ( "runtime_pool",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          runtime_pool );
                      ( "lane_id",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          lane_id );
                      ( "controller_level",
                        Option.fold ~none:`Null
                          ~some:(fun level ->
                            `String
                              (Team_session_types.controller_level_to_string
                                 level))
                          controller_level );
                      ( "control_domain",
                        Option.fold ~none:`Null
                          ~some:(fun domain ->
                            `String
                              (Team_session_types.control_domain_to_string
                                 domain))
                          control_domain );
                      ( "supervisor_actor",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          supervisor_actor );
                      ( "task_profile",
                        Option.fold ~none:`Null
                          ~some:(fun profile ->
                            `String
                              (Team_session_types.task_profile_to_string
                                 profile))
                          task_profile );
                      ( "risk_level",
                        Option.fold ~none:`Null
                          ~some:(fun level ->
                            `String
                              (Team_session_types.risk_level_to_string level))
                          risk_level );
                      ("routing_confidence", deps.float_opt_to_json routing_confidence);
                      ( "routing_reason",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          routing_reason );
                      ( "assigned_runtime",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          assigned_runtime );
                      ( "spawn_selection_note",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          spawn_selection_note );
                      ( "tool_names",
                        Option.fold ~none:(`List [])
                          ~some:(fun names ->
                            `List (List.map (fun name -> `String name) names))
                          tool_names );
                      ( "tool_call_count",
                        Option.fold ~none:`Null ~some:(fun n -> `Int n)
                          tool_call_count );
                      ("success", `Bool success);
                      ("exit_code", deps.int_opt_to_json exit_code);
                      ("elapsed_ms", deps.int_opt_to_json elapsed_ms);
                      ( "output_preview",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          output_preview );
                      ("error", Option.fold ~none:`Null ~some:(fun s -> `String s) error);
                      ("ts_iso", `String (Types.now_iso ()));
                    ]
                in
                Team_session_store.append_event ctx.config session_id
                  ~event_type:"team_step_spawn" ~detail
              in
              let append_delegate_event ~worker_run_id ~worker_name ~delegate_prompt ~success
                  ?execution_scope ?wait_mode ?trace_capability
                  ?resolved_runtime ?resolved_model ?routing_reason
                  ?tool_names ?tool_call_count ?output_preview ?error () =
                Team_session_store.append_event ctx.config session_id
                  ~event_type:"team_step_delegate"
                  ~detail:
                    (`Assoc
                      [
                        ("actor", `String actor);
                        ("worker_run_id", `String worker_run_id);
                        ("target_agent", `String worker_name);
                        ("delegate_prompt", `String delegate_prompt);
                        ("worker_backend", `String "local");
                        ("execution_scope", Option.fold ~none:`Null ~some:(fun scope -> `String (Team_session_types.execution_scope_to_string scope)) execution_scope);
                        ("wait_mode", Option.fold ~none:`Null ~some:(fun mode -> `String mode) wait_mode);
                        ("trace_capability", Option.fold ~none:`Null ~some:(fun s -> `String s) trace_capability);
                        ("resolved_runtime", Option.fold ~none:`Null ~some:(fun s -> `String s) resolved_runtime);
                        ("resolved_model", Option.fold ~none:`Null ~some:(fun s -> `String s) resolved_model);
                        ("routing_reason", Option.fold ~none:`Null ~some:(fun s -> `String s) routing_reason);
                        ("success", `Bool success);
                        ( "tool_names",
                          Option.fold ~none:(`List [])
                            ~some:(fun names ->
                              `List (List.map (fun name -> `String name) names))
                            tool_names );
                        ( "tool_call_count",
                          Option.fold ~none:`Null ~some:(fun n -> `Int n)
                            tool_call_count );
                        ( "output_preview",
                          Option.fold ~none:`Null ~some:(fun s -> `String s)
                            output_preview );
                        ( "error",
                          Option.fold ~none:`Null ~some:(fun s -> `String s)
                            error );
                        ("ts_iso", `String (Types.now_iso ()));
                      ])
              in
              let append_spawn_requested_event ~worker_run_id prepared =
                Team_session_store.append_event ctx.config session_id
                  ~event_type:"team_step_spawn_requested"
                  ~detail:
                    (`Assoc
                      [
                        ("actor", `String actor);
                        ("worker_run_id", `String worker_run_id);
                        ( "runtime_actor",
                          Option.fold ~none:`Null
                            ~some:(fun s -> `String s)
                            prepared.runtime_actor_name );
                        ("spawn_role", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.spec.spawn_role);
                        ("worker_backend", if deps.is_local_spawn_agent prepared.spec.spawn_agent then `String "local" else `Null);
                        ("wait_mode", `String (Team_session_types.wait_mode_to_string wait_mode));
                        ("resolved_runtime", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.assigned_runtime);
                        ("resolved_model", `String prepared.runtime_model.model_id);
                        ("routing_reason", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.spec.routing_reason);
                        ("ts_iso", `String (Types.now_iso ()));
                      ])
              in
              let append_delegate_requested_event ~worker_run_id ~worker_name ~delegate_prompt =
                Team_session_store.append_event ctx.config session_id
                  ~event_type:"team_step_delegate_requested"
                  ~detail:
                    (`Assoc
                      [
                        ("actor", `String actor);
                        ("worker_run_id", `String worker_run_id);
                        ("target_agent", `String worker_name);
                        ("delegate_prompt", `String delegate_prompt);
                        ("worker_backend", `String "local");
                        ("wait_mode", `String (Team_session_types.wait_mode_to_string wait_mode));
                        ("ts_iso", `String (Types.now_iso ()));
                      ])
              in
              let persist_worker_run_snapshot ~worker_run_id ~worker_name
                  ~mode ~wait_mode ?execution_scope ?tool_names ?tool_call_count
                  ?requested_worker_class ?requested_worker_size
                  ?resolved_runtime ?resolved_model ?routing_reason
                  ~status
                  ~success ?output_preview ?error ?trace_capability ?trace_ref
                  ?trace_summary ?trace_validation ?evidence_session_id
                  () =
                let checkpoint_path =
                  Team_session_store.worker_container_checkpoint_path ctx.config
                    session_id worker_name
                in
                let oas_evidence =
                  Option.bind evidence_session_id (fun evidence_session_id ->
                      deps.oas_worker_evidence_payload ~config:ctx.config
                        ~evidence_session_id)
                in
                let effective_trace_ref =
                  match Option.bind oas_evidence (fun payload -> payload.trace_ref) with
                  | Some _ as value -> value
                  | None -> trace_ref
                in
                let effective_trace_summary =
                  match
                    Option.bind oas_evidence (fun payload ->
                        payload.trace_summary_json)
                  with
                  | Some _ as value -> value
                  | None -> trace_summary
                in
                let effective_trace_validation =
                  match
                    Option.bind oas_evidence (fun payload ->
                        payload.trace_validation_json)
                  with
                  | Some _ as value -> value
                  | None -> trace_validation
                in
                let oas_worker =
                  Option.bind oas_evidence (fun payload -> payload.worker)
                in
                let effective_status =
                  match oas_worker with
                  | Some worker -> deps.oas_worker_status_to_json worker.status
                  | None -> deps.worker_run_status_to_json status
                in
                let trace_capability =
                  match trace_capability with
                  | _ when Option.is_some oas_worker ->
                      Option.value ~default:"summary_only"
                        (Option.map
                           (fun worker ->
                             deps.oas_trace_capability_to_string
                               worker.Oas.Sessions.trace_capability)
                           oas_worker)
                  | Some value -> value
                  | None when Option.is_some effective_trace_ref -> "raw"
                  | None -> ignore checkpoint_path; "summary_only"
                in
                let effective_tool_names =
                  match oas_worker with
                  | Some worker when worker.tool_names <> [] -> worker.tool_names
                  | _ -> Option.value ~default:[] tool_names
                in
                let effective_resolved_model =
                  match oas_worker with
                  | Some worker -> (
                      match worker.resolved_model with
                      | Some _ as value -> value
                      | None -> resolved_model)
                  | None -> resolved_model
                in
                let effective_error =
                  match oas_worker with
                  | Some worker -> (
                      match worker.failure_reason with
                      | Some _ as value -> value
                      | None -> (
                          match worker.error with
                          | Some _ as value -> value
                          | None -> error))
                  | None -> error
                in
                let effective_output_preview =
                  match oas_worker with
                  | Some worker -> (
                      match worker.final_text with
                      | Some final_text when String.trim final_text <> "" ->
                          Some (deps.truncate_for_event final_text)
                      | _ -> output_preview)
                  | None -> output_preview
                in
                if Room_utils.path_exists ctx.config checkpoint_path then
                  Team_session_store.save_worker_run_checkpoint_text ctx.config
                    session_id worker_run_id
                    (Team_session_store.read_text_file checkpoint_path);
                Team_session_store.save_worker_run_meta_json ctx.config session_id
                  worker_run_id
                  (`Assoc
                    [
                      ("worker_run_id", `String worker_run_id);
                      ("worker_name", `String worker_name);
                      ("mode", `String mode);
                      ("status", effective_status);
                      ("wait_mode", `String (Team_session_types.wait_mode_to_string wait_mode));
                      ("trace_capability", `String trace_capability);
                      ("success", `Bool success);
                      ("execution_scope", Option.fold ~none:`Null ~some:(fun scope -> `String (Team_session_types.execution_scope_to_string scope)) execution_scope);
                      ("requested_worker_class", Option.fold ~none:`Null ~some:(fun kind -> `String (Team_session_types.worker_class_to_string kind)) requested_worker_class);
                      ("requested_worker_size", Option.fold ~none:`Null ~some:(fun size -> `String (Team_session_types.worker_size_to_string size)) requested_worker_size);
                      ("resolved_runtime", Option.fold ~none:`Null ~some:(fun s -> `String s) resolved_runtime);
                      ("resolved_model", Option.fold ~none:`Null ~some:(fun s -> `String s) effective_resolved_model);
                      ("routing_reason", Option.fold ~none:`Null ~some:(fun s -> `String s) routing_reason);
                      ("tool_names", `List (List.map (fun name -> `String name) effective_tool_names));
                      ("tool_call_count", Option.fold ~none:`Null ~some:(fun n -> `Int n) tool_call_count);
                      ("output_preview", Option.fold ~none:`Null ~some:(fun s -> `String s) effective_output_preview);
                      ("error", Option.fold ~none:`Null ~some:(fun s -> `String s) effective_error);
                      ("trace_ref", Option.fold ~none:`Null ~some:deps.raw_trace_run_ref_to_json effective_trace_ref);
                      ("trace_summary", Option.fold ~none:`Null ~some:(fun json -> json) effective_trace_summary);
                      ("trace_validation", Option.fold ~none:`Null ~some:(fun json -> json) effective_trace_validation);
                      ("evidence_session_id", Option.fold ~none:`Null ~some:(fun s -> `String s) evidence_session_id);
                      ("oas_worker_run", Option.fold ~none:`Null ~some:(fun json -> json) (Option.bind oas_evidence (fun payload -> payload.worker_json)));
                      ("session_conformance", Option.fold ~none:`Null ~some:(fun json -> json) (Option.bind oas_evidence (fun payload -> payload.conformance_json)));
                      ("validated", Option.fold ~none:`Null ~some:(fun worker -> `Bool worker.Oas.Sessions.validated) oas_worker);
                      ("final_text", Option.fold ~none:`Null ~some:(fun worker -> Option.fold ~none:`Null ~some:(fun s -> `String s) worker.Oas.Sessions.final_text) oas_worker);
                      ("stop_reason", Option.fold ~none:`Null ~some:(fun worker -> Option.fold ~none:`Null ~some:(fun s -> `String s) worker.Oas.Sessions.stop_reason) oas_worker);
                      ("failure_reason", Option.fold ~none:`Null ~some:(fun worker -> Option.fold ~none:`Null ~some:(fun s -> `String s) worker.Oas.Sessions.failure_reason) oas_worker);
                      ("ts_iso", `String (Types.now_iso ()));
                    ])
              in
              let release_prepared_runtime (prepared : prepared_spawn) ~success
                  ?error ?latency_ms () =
                match prepared.runtime_lease with
                | Some lease ->
                    Local_runtime_pool.release lease ~success ?error ?latency_ms ()
                | None -> ()
              in
              let release_all_prepared prepareds ~error =
                List.iter
                  (fun prepared ->
                    release_prepared_runtime prepared ~success:false ~error ())
                  prepareds
              in
              let prepare_spawn (spec : spawn_spec) =
                let runtime_actor_name =
                  if deps.is_local_spawn_agent spec.spawn_agent then
                    Some
                      (deps.derived_llama_runtime_actor ~session_id
                         ~prompt:spec.spawn_prompt)
                  else
                    None
                in
                let runtime_model =
                  if deps.is_local_spawn_agent spec.spawn_agent then
                    let model_name =
                      match spec.spawn_model with
                      | Some model_name -> Some model_name
                      | None ->
                          let default_model =
                            Llm_client.default_local_model_spec ()
                          in
                          Some default_model.model_id
                    in
                    match model_name with
                    | None -> Error "local worker model resolution failed"
                    | Some model_name -> (
                        match
                          Local_runtime_pool.acquire
                            ?preferred_pool:spec.runtime_pool
                            ~model_name:(Some model_name) ()
                        with
                        | Ok assignment ->
                            Ok
                              ( Local_runtime_pool.model_spec_of_assignment
                                  assignment,
                                Some assignment.lease,
                                Some assignment.runtime_id )
                        | Error err -> Error err)
                  else
                    Ok (Llm_client.default_local_model_spec (), None, None)
                in
                match runtime_model with
                | Error e -> Error (spec, runtime_actor_name, e)
                | Ok (runtime_model, runtime_lease, assigned_runtime) ->
                    Ok
                      {
                        worker_run_id = deps.make_worker_run_id ();
                        spec;
                        runtime_actor_name;
                        runtime_model;
                        runtime_lease;
                        assigned_runtime;
                      }
              in
              let prepared_spawns_result =
                let rec loop acc = function
                  | [] -> Ok (List.rev acc)
                  | spec :: rest -> (
                      match prepare_spawn spec with
                      | Ok prepared -> loop (prepared :: acc) rest
                      | Error (failed_spec, runtime_actor_name, msg) ->
                          release_all_prepared (List.rev acc) ~error:msg;
                          append_spawn_event ~spawn_agent:failed_spec.spawn_agent
                            ?runtime_actor:runtime_actor_name
                            ?spawn_role:failed_spec.spawn_role
                            ?spawn_model:failed_spec.spawn_model
                            ?execution_scope:
                              (deps.effective_execution_scope_of_spec failed_spec)
                            ?worker_class:failed_spec.worker_class
                            ?worker_size:(deps.worker_size_of_spec failed_spec)
                            ?worker_backend:
                              (if deps.is_local_spawn_agent failed_spec.spawn_agent
                               then Some "local" else None)
                            ?parent_actor:failed_spec.parent_actor
                            ?capsule_mode:failed_spec.capsule_mode
                            ?runtime_pool:failed_spec.runtime_pool
                            ?lane_id:failed_spec.lane_id
                            ?controller_level:(deps.inferred_controller_level_of_spec failed_spec)
                            ?control_domain:failed_spec.control_domain
                            ?supervisor_actor:failed_spec.supervisor_actor
                            ?model_tier:failed_spec.model_tier
                            ?task_profile:failed_spec.task_profile
                            ?risk_level:failed_spec.risk_level
                            ?routing_confidence:failed_spec.routing_confidence
                            ?routing_reason:failed_spec.routing_reason
                            ?spawn_selection_note:failed_spec.spawn_selection_note
                            ~success:false ~error:msg ();
                          Error msg)
                in
                loop [] spawn_specs
              in
              let spawn_result_json =
                match prepared_spawns_result with
                | Error msg -> Some (`Assoc [ ("error", `String msg) ])
                | Ok [] -> None
                | Ok prepared_spawns ->
                    let planned_workers =
                      List.map
                        (fun prepared ->
                          deps.planned_worker_of_spec
                            ?runtime_actor:prepared.runtime_actor_name
                            prepared.spec)
                        prepared_spawns
                    in
                    let planning_error =
                      match
                        deps.register_planned_workers ctx.config session_id
                          planned_workers
                      with
                      | Error msg -> Some msg
                      | Ok () -> None
                    in
                    match planning_error with
                    | Some msg ->
                        List.iter
                          (fun prepared ->
                            release_prepared_runtime prepared ~success:false
                              ~error:msg ();
                            append_spawn_event
                              ~spawn_agent:prepared.spec.spawn_agent
                              ?runtime_actor:prepared.runtime_actor_name
                              ?spawn_role:prepared.spec.spawn_role
                              ?spawn_model:prepared.spec.spawn_model
                              ?execution_scope:
                                (deps.effective_execution_scope_of_spec prepared.spec)
                              ?worker_class:prepared.spec.worker_class
                              ?worker_size:(deps.worker_size_of_spec prepared.spec)
                              ?worker_backend:
                                (if deps.is_local_spawn_agent prepared.spec.spawn_agent
                                 then Some "local" else None)
                              ?parent_actor:prepared.spec.parent_actor
                              ?capsule_mode:prepared.spec.capsule_mode
                              ?runtime_pool:prepared.spec.runtime_pool
                              ?lane_id:prepared.spec.lane_id
                              ?controller_level:(deps.inferred_controller_level_of_spec prepared.spec)
                              ?control_domain:prepared.spec.control_domain
                              ?supervisor_actor:prepared.spec.supervisor_actor
                              ?model_tier:prepared.spec.model_tier
                              ?task_profile:prepared.spec.task_profile
                              ?risk_level:prepared.spec.risk_level
                              ?routing_confidence:prepared.spec.routing_confidence
                              ?routing_reason:prepared.spec.routing_reason
                              ?assigned_runtime:prepared.assigned_runtime
                              ?spawn_selection_note:
                                prepared.spec.spawn_selection_note
                              ~success:false ~error:msg ())
                          prepared_spawns;
                        Some (`Assoc [ ("error", `String msg) ])
                    | None ->
                        match ctx.proc_mgr with
                        | None ->
                            let msg =
                              "process manager unavailable for team step spawn"
                            in
                            List.iter
                              (fun prepared ->
                                release_prepared_runtime prepared ~success:false
                                  ~error:msg ();
                                append_spawn_event
                                  ~worker_run_id:prepared.worker_run_id
                                  ~spawn_agent:prepared.spec.spawn_agent
                                  ?runtime_actor:prepared.runtime_actor_name
                                  ?spawn_role:prepared.spec.spawn_role
                                  ?spawn_model:prepared.spec.spawn_model
                                  ?execution_scope:
                                    (deps.effective_execution_scope_of_spec prepared.spec)
                                  ?worker_class:prepared.spec.worker_class
                                  ?worker_size:(deps.worker_size_of_spec prepared.spec)
                                  ?worker_backend:
                                    (if deps.is_local_spawn_agent prepared.spec.spawn_agent
                                     then Some "local" else None)
                                  ?parent_actor:prepared.spec.parent_actor
                                  ?capsule_mode:prepared.spec.capsule_mode
                                  ?runtime_pool:prepared.spec.runtime_pool
                                  ?lane_id:prepared.spec.lane_id
                                  ?controller_level:(deps.inferred_controller_level_of_spec prepared.spec)
                                  ?control_domain:prepared.spec.control_domain
                                  ?supervisor_actor:prepared.spec.supervisor_actor
                                  ?model_tier:prepared.spec.model_tier
                                  ?task_profile:prepared.spec.task_profile
                                  ?risk_level:prepared.spec.risk_level
                                  ?routing_confidence:
                                    prepared.spec.routing_confidence
                                  ?routing_reason:prepared.spec.routing_reason
                                  ?assigned_runtime:prepared.assigned_runtime
                                  ?spawn_selection_note:
                                    prepared.spec.spawn_selection_note
                                  ~success:false ~error:msg ())
                              prepared_spawns;
                            Some (`Assoc [ ("error", `String msg) ])
                        | Some pm ->
                            let rec ensure_all = function
                              | [] -> Ok ()
                              | prepared :: rest -> (
                                  match prepared.runtime_actor_name with
                                  | None -> ensure_all rest
                                  | Some worker_actor -> (
                                      match
                                        deps.ensure_session_actor ctx.config
                                          session_id worker_actor
                                      with
                                      | Ok () -> ensure_all rest
                                      | Error msg -> Error msg))
                            in
                            match ensure_all prepared_spawns with
                             | Error msg ->
                                 List.iter
                                   (fun prepared ->
                                     release_prepared_runtime prepared
                                       ~success:false ~error:msg ();
                                       append_spawn_event
                                         ~worker_run_id:prepared.worker_run_id
                                         ~spawn_agent:prepared.spec.spawn_agent
                                         ?runtime_actor:prepared.runtime_actor_name
                                         ?spawn_role:prepared.spec.spawn_role
                                         ?spawn_model:prepared.spec.spawn_model
                                         ?execution_scope:
                                           (deps.effective_execution_scope_of_spec prepared.spec)
                                         ?worker_class:prepared.spec.worker_class
                                         ?worker_size:(deps.worker_size_of_spec prepared.spec)
                                         ?worker_backend:
                                           (if deps.is_local_spawn_agent prepared.spec.spawn_agent
                                            then Some "local" else None)
                                         ?parent_actor:prepared.spec.parent_actor
                                       ?capsule_mode:prepared.spec.capsule_mode
                                       ?runtime_pool:prepared.spec.runtime_pool
                                       ?lane_id:prepared.spec.lane_id
                                       ?controller_level:(deps.inferred_controller_level_of_spec prepared.spec)
                                       ?control_domain:prepared.spec.control_domain
                                       ?supervisor_actor:prepared.spec.supervisor_actor
                                       ?model_tier:prepared.spec.model_tier
                                       ?task_profile:prepared.spec.task_profile
                                       ?risk_level:prepared.spec.risk_level
                                       ?routing_confidence:
                                         prepared.spec.routing_confidence
                                       ?routing_reason:
                                         prepared.spec.routing_reason
                                       ?assigned_runtime:prepared.assigned_runtime
                                       ?spawn_selection_note:
                                         prepared.spec.spawn_selection_note
                                       ~success:false ~error:msg ())
                                   prepared_spawns;
                                 Some (`Assoc [ ("error", `String msg) ])
                             | Ok () ->
                                 let execute_spawn index prepared =
                                   let spawn_result =
                                     Spawn_eio.spawn ~sw:ctx.sw ~proc_mgr:pm
                                       ~agent_name:prepared.spec.spawn_agent
                                       ~prompt:prepared.spec.spawn_prompt
                                       ~timeout_seconds:
                                         prepared.spec.spawn_timeout_seconds
                                       ~room_config:ctx.config
                                       ?runtime_agent_name:
                                         prepared.runtime_actor_name
                                       ~runtime_model:prepared.runtime_model
                                       ?runtime_role:prepared.spec.spawn_role
                                       ?runtime_selection_note:
                                         prepared.spec.spawn_selection_note
                                       ~worker_run_id:prepared.worker_run_id
                                       ?worker_class:prepared.spec.worker_class
                                       ?worker_size:(deps.worker_size_of_spec prepared.spec)
                                       ?execution_scope:
                                         (deps.effective_execution_scope_of_spec prepared.spec)
                                       ?thinking_enabled:prepared.spec.thinking_enabled
                                       ?max_turns:prepared.spec.max_turns
                                       ~runtime_session_id:session_id ()
                                   in
                                 let output_preview =
                                     deps.truncate_for_event spawn_result.output
                                   in
                                   let trace_summary_json, trace_validation_json =
                                     match spawn_result.raw_trace_run with
                                     | Some run_ref -> (
                                         match
                                           deps.raw_trace_session_payloads
                                             ~config:ctx.config
                                             ~fallback_session_id:session_id
                                             run_ref
                                         with
                                         | Some pair -> (Some (fst pair), Some (snd pair))
                                         | None -> (None, None))
                                     | None -> (None, None)
                                   in
                                   (match spawn_result.success with
                                   | true ->
                                       release_prepared_runtime prepared
                                         ~success:true
                                         ~latency_ms:spawn_result.elapsed_ms ()
                                   | false ->
                                       release_prepared_runtime prepared
                                         ~success:false
                                         ~error:spawn_result.output
                                         ~latency_ms:spawn_result.elapsed_ms ());
                                   persist_worker_run_snapshot
                                     ~worker_run_id:prepared.worker_run_id
                                     ~worker_name:
                                       (Option.value
                                          ~default:(Printf.sprintf "spawn-%d" index)
                                          prepared.runtime_actor_name)
                                     ~mode:"spawn" ~wait_mode
                                     ~status:
                                       (if spawn_result.success then `Completed else `Failed)
                                     ?execution_scope:
                                       (deps.effective_execution_scope_of_spec prepared.spec)
                                     ?requested_worker_class:prepared.spec.worker_class
                                     ?requested_worker_size:(deps.worker_size_of_spec prepared.spec)
                                     ?resolved_runtime:prepared.assigned_runtime
                                     ~resolved_model:prepared.runtime_model.model_id
                                     ?routing_reason:prepared.spec.routing_reason
                                     ~tool_names:spawn_result.tool_names
                                     ~tool_call_count:spawn_result.tool_call_count
                                     ~success:spawn_result.success
                                     ~output_preview
                                     ~evidence_session_id:
                                       (Local_agent_eio
                                        .oas_worker_evidence_session_id
                                          ~worker_run_id:
                                            prepared.worker_run_id)
                                     ?trace_ref:spawn_result.raw_trace_run
                                     ?trace_summary:trace_summary_json
                                     ?trace_validation:trace_validation_json
                                       ~trace_capability:
                                       (if Option.is_some spawn_result.raw_trace_run then
                                          "raw"
                                        else if deps.is_local_spawn_agent prepared.spec.spawn_agent
                                        then "summary_only"
                                        else "summary_only")
                                     ();
                                   append_spawn_event
                                     ~worker_run_id:prepared.worker_run_id
                                     ~spawn_agent:prepared.spec.spawn_agent
                                     ?runtime_actor:prepared.runtime_actor_name
                                     ?spawn_role:prepared.spec.spawn_role
                                     ?spawn_model:prepared.spec.spawn_model
                                     ?execution_scope:
                                       (deps.effective_execution_scope_of_spec prepared.spec)
                                     ?worker_class:prepared.spec.worker_class
                                     ?worker_size:(deps.worker_size_of_spec prepared.spec)
                                     ?worker_backend:
                                       (if deps.is_local_spawn_agent prepared.spec.spawn_agent
                                        then Some "local" else None)
                                     ~wait_mode:(Team_session_types.wait_mode_to_string wait_mode)
                                     ~trace_capability:
                                       (if deps.is_local_spawn_agent prepared.spec.spawn_agent
                                        then "summary_only"
                                        else "summary_only")
                                     ?parent_actor:prepared.spec.parent_actor
                                     ?capsule_mode:prepared.spec.capsule_mode
                                     ?runtime_pool:prepared.spec.runtime_pool
                                     ?lane_id:prepared.spec.lane_id
                                     ?controller_level:(deps.inferred_controller_level_of_spec prepared.spec)
                                     ?control_domain:prepared.spec.control_domain
                                     ?supervisor_actor:prepared.spec.supervisor_actor
                                     ?model_tier:prepared.spec.model_tier
                                     ?task_profile:prepared.spec.task_profile
                                     ?risk_level:prepared.spec.risk_level
                                     ?routing_confidence:prepared.spec.routing_confidence
                                     ?routing_reason:prepared.spec.routing_reason
                                     ?assigned_runtime:prepared.assigned_runtime
                                     ?spawn_selection_note:
                                       prepared.spec.spawn_selection_note
                                     ~tool_names:spawn_result.tool_names
                                     ~tool_call_count:spawn_result.tool_call_count
                                     ~success:spawn_result.success
                                     ~exit_code:spawn_result.exit_code
                                     ~elapsed_ms:spawn_result.elapsed_ms
                                     ~output_preview ();
                                   (match
                                      ( spawn_result.success,
                                        prepared.runtime_actor_name,
                                        deps.auto_note_message_of_spawn_output
                                          spawn_result.output )
                                    with
                                   | true, Some worker_actor, Some auto_note
                                     when not
                                            (deps.session_has_turn_for_actor
                                               ctx.config session_id worker_actor) ->
                                       ignore
                                         (deps.record_session_turn_json
                                            ~config:ctx.config ~session_id
                                            ~actor:worker_actor
                                            ~turn_kind:Team_session_types.Turn_note
                                            ~message:(Some auto_note)
                                            ~target_agent:None
                                            ~task_title:None
                                            ~task_description:None
                                            ~task_priority:3)
                                   | _ -> ());
                                   (match (spawn_result.success, prepared.runtime_actor_name) with
                                   | false, Some worker_actor ->
                                       ignore
                                         (deps.reconcile_failed_spawn_actor
                                            ctx.config session_id worker_actor)
                                   | _ -> ());
                                   `Assoc
                                     [
                                       ("worker_run_id", `String prepared.worker_run_id);
                                       ("runtime_actor", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.runtime_actor_name);
                                       ("spawn_role", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.spec.spawn_role);
                                       ("execution_scope", Option.fold ~none:`Null ~some:(fun scope -> `String (Team_session_types.execution_scope_to_string scope)) (deps.effective_execution_scope_of_spec prepared.spec));
                                       ("thinking_enabled", Option.fold ~none:`Null ~some:(fun v -> `Bool v) prepared.spec.thinking_enabled);
                                       ("max_turns", Option.fold ~none:`Null ~some:(fun n -> `Int n) prepared.spec.max_turns);
                                       ("worker_class", Option.fold ~none:`Null ~some:(fun kind -> `String (Team_session_types.worker_class_to_string kind)) prepared.spec.worker_class);
                                       ("worker_size", Option.fold ~none:`Null ~some:(fun size -> `String (Team_session_types.worker_size_to_string size)) (deps.worker_size_of_spec prepared.spec));
                                       ("worker_backend", if deps.is_local_spawn_agent prepared.spec.spawn_agent then `String "local" else `Null);
                                       ("wait_mode", `String (Team_session_types.wait_mode_to_string wait_mode));
                                       ("status", `String "completed");
                                       ("trace_capability", `String (if Option.is_some spawn_result.raw_trace_run then "raw" else "summary_only"));
                                       ("resolved_runtime", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.assigned_runtime);
                                       ("resolved_model", `String prepared.runtime_model.model_id);
                                       ("routing_reason", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.spec.routing_reason);
                                       ("tool_call_count", `Int spawn_result.tool_call_count);
                                       ("tool_names", `List (List.map (fun name -> `String name) spawn_result.tool_names));
                                       ("success", `Bool spawn_result.success);
                                       ("elapsed_ms", `Int spawn_result.elapsed_ms);
                                       ("output_preview", `String output_preview);
                                     ]
                                 in
                                 (match wait_mode with
                                 | Team_session_types.Wait_background ->
                                     let sw_bg =
                                       Option.value ~default:ctx.sw
                                         (Eio_context.get_switch_opt ())
                                     in
                                     List.iter
                                       (fun prepared ->
                                         append_spawn_requested_event
                                           ~worker_run_id:prepared.worker_run_id
                                           prepared;
                                         Eio.Fiber.fork ~sw:sw_bg (fun () ->
                                             try ignore (execute_spawn 0 prepared)
                                             with
                                             | Eio.Cancel.Cancelled _ as exn -> raise exn
                                             | exn ->
                                               Log.Spawn.error
                                                 "background spawn failed (worker_run_id=%s, agent=%s): %s"
                                                 prepared.worker_run_id
                                                 prepared.spec.spawn_agent
                                                 (Printexc.to_string exn)))
                                       prepared_spawns;
                                     let accepted =
                                       prepared_spawns
                                       |> List.map (fun prepared ->
                                              `Assoc
                                                [
                                                  ("worker_run_id", `String prepared.worker_run_id);
                                                  ("status", `String "accepted");
                                                  ("wait_mode", `String "background");
                                                  ("runtime_actor", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.runtime_actor_name);
                                                  ("spawn_role", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.spec.spawn_role);
                                                  ("worker_class", Option.fold ~none:`Null ~some:(fun kind -> `String (Team_session_types.worker_class_to_string kind)) prepared.spec.worker_class);
                                                  ("worker_size", Option.fold ~none:`Null ~some:(fun size -> `String (Team_session_types.worker_size_to_string size)) (deps.worker_size_of_spec prepared.spec));
                                                  ("resolved_runtime", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.assigned_runtime);
                                                  ("resolved_model", `String prepared.runtime_model.model_id);
                                                  ("routing_reason", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.spec.routing_reason);
                                                  ("ready", `Bool false);
                                                ])
                                     in
                                     Some
                                       (if List.length accepted = 1 then
                                          List.hd accepted
                                        else
                                          `Assoc
                                            [
                                              ("mode", `String "batch");
                                              ("count", `Int (List.length accepted));
                                              ("results", `List accepted);
                                            ])
                                 | Team_session_types.Wait_blocking ->
                                     let results =
                                       Array.make (List.length prepared_spawns) None
                                     in
                                     Eio.Fiber.all
                                       (List.mapi
                                          (fun index prepared () ->
                                            results.(index) <- Some (execute_spawn index prepared))
                                          prepared_spawns);
                                     let spawn_results =
                                       results |> Array.to_list
                                       |> List.filter_map (fun item -> item)
                                     in
                                     Some
                                       (if List.length spawn_results = 1 then
                                          List.hd spawn_results
                                        else
                                          `Assoc
                                            [
                                              ("mode", `String "batch");
                                              ("count", `Int (List.length spawn_results));
                                              ("results", `List spawn_results);
                                            ]))
              in
              let spawn_error =
                match spawn_result_json with
                | Some (`Assoc fields) -> (
                    match List.assoc_opt "error" fields with
                    | Some (`String e) when String.trim e <> "" -> Some e
                    | _ -> None)
                | _ -> None
              in
              match spawn_error with
              | Some e -> (false, deps.json_error e)
              | None ->
                  let turn_json_result =
                    match turn_kind_opt with
                    | None -> Ok None
                    | Some turn_kind ->
                        deps.record_session_turn_json ~config:ctx.config ~session_id
                          ~actor ~turn_kind ~message:base_message
                          ~target_agent ~task_title ~task_description
                          ~task_priority
                        |> Result.map Option.some
                  in
                  match turn_json_result with
                  | Error e -> (false, deps.json_error e)
                  | Ok turn_json ->
                      let delegate_result_json =
                        match (delegate_prompt, target_agent) with
                        | None, _ -> None
                        | Some _, _ when spawn_specs <> [] ->
                            Some
                              (`Assoc
                                [
                                  ( "error",
                                    `String
                                      "delegate_prompt cannot be combined with worker spawn" );
                                ])
                        | Some _, None ->
                            Some
                              (`Assoc
                                [
                                  ( "error",
                                    `String
                                      "target_agent is required when delegate_prompt is provided" );
                                ])
                        | Some delegate_prompt, Some target_agent -> (
                            match session_opt with
                            | None ->
                                Some
                                  (`Assoc
                                    [
                                      ("error", `String "team session not found");
                                    ])
                            | Some session -> (
                                match
                                  deps.resolve_target_worker_name ctx.config session
                                    target_agent
                                with
                                | None ->
                                    Some
                                      (`Assoc
                                        [
                                          ( "error",
                                            `String
                                              "target_agent did not match a known worker container"
                                          );
                                        ])
                                | Some worker_name -> (
                                    let worker_run_id = deps.make_worker_run_id () in
                                    let execution_scope =
                                      Option.bind session_opt (fun session ->
                                          List.find_map
                                            (fun w ->
                                              match
                                                w.Team_session_types.runtime_actor
                                              with
                                              | Some actor
                                                when String.equal actor
                                                       worker_name ->
                                                  w.execution_scope
                                              | _ -> None)
                                            session.planned_workers)
                                    in
                                    let run_delegate () =
                                      match
                                        Local_agent_eio.continue_worker ~sw:ctx.sw
                                          ~base_path:ctx.config.base_path
                                          ~room_config:(Some ctx.config)
                                          ~worker_name ~team_session_id:session_id
                                          ~worker_run_id
                                          ~prompt:delegate_prompt ()
                                      with
                                      | Ok run_result ->
                                          let output_preview =
                                            deps.truncate_for_event run_result.output
                                          in
                                          let trace_summary_json, trace_validation_json =
                                            match run_result.raw_trace_run with
                                            | Some run_ref -> (
                                                match
                                                  deps.raw_trace_session_payloads
                                                    ~config:ctx.config
                                                    ~fallback_session_id:session_id
                                                    run_ref
                                                with
                                                | Some pair -> (Some (fst pair), Some (snd pair))
                                                | None -> (None, None))
                                            | None -> (None, None)
                                          in
                                          persist_worker_run_snapshot
                                            ~worker_run_id ~worker_name
                                            ~mode:"delegate"
                                            ~wait_mode ?execution_scope
                                            ~status:`Completed
                                            ~resolved_model:run_result.model_used
                                            ~resolved_runtime:"local"
                                            ~tool_names:run_result.tool_names
                                            ~tool_call_count:
                                              run_result.tool_call_count
                                            ~success:true ~output_preview
                                            ~evidence_session_id:
                                              (Local_agent_eio
                                               .oas_worker_evidence_session_id
                                                 ~worker_run_id)
                                            ?trace_ref:run_result.raw_trace_run
                                            ?trace_summary:trace_summary_json
                                            ?trace_validation:trace_validation_json
                                            ~trace_capability:
                                              (if Option.is_some run_result.raw_trace_run
                                               then "raw"
                                               else "summary_only") ();
                                          append_delegate_event ~worker_run_id
                                            ~worker_name ~delegate_prompt
                                            ?execution_scope
                                            ~wait_mode:(Team_session_types.wait_mode_to_string wait_mode)
                                            ~trace_capability:
                                              (if Option.is_some run_result.raw_trace_run
                                               then "raw"
                                               else "summary_only")
                                            ~resolved_runtime:"local"
                                            ~resolved_model:run_result.model_used
                                            ~success:true
                                            ~tool_names:run_result.tool_names
                                            ~tool_call_count:
                                              run_result.tool_call_count
                                            ~routing_reason:
                                              (Option.value ~default:"continued_worker"
                                                 (List.find_map
                                                    (fun w ->
                                                      match
                                                        w.Team_session_types.runtime_actor
                                                      with
                                                      | Some actor
                                                        when String.equal actor worker_name ->
                                                            w.routing_reason
                                                      | _ -> None)
                                                    session.planned_workers))
                                            ~output_preview ();
                                          `Assoc
                                            [
                                              ("worker_run_id", `String worker_run_id);
                                              ("worker_name", `String worker_name);
                                              ("worker_backend", `String "local");
                                              ("wait_mode", `String (Team_session_types.wait_mode_to_string wait_mode));
                                              ("status", `String "completed");
                                              ("trace_capability", `String (if Option.is_some run_result.raw_trace_run then "raw" else "summary_only"));
                                              ("resolved_runtime", `String "local");
                                              ("resolved_model", `String run_result.model_used);
                                              ( "output",
                                                `String run_result.output );
                                              ( "output_preview",
                                                `String output_preview );
                                              ( "tool_call_count",
                                                `Int run_result.tool_call_count );
                                              ( "tool_names",
                                                `List
                                                  (List.map
                                                     (fun name -> `String name)
                                                     run_result.tool_names) );
                                              ( "input_tokens",
                                                deps.int_opt_to_json run_result.input_tokens );
                                              ( "output_tokens",
                                                deps.int_opt_to_json run_result.output_tokens );
                                              ( "cost_usd",
                                                deps.float_opt_to_json run_result.cost_usd );
                                            ]
                                      | Error err ->
                                          persist_worker_run_snapshot
                                            ~worker_run_id ~worker_name
                                            ~mode:"delegate" ~wait_mode
                                            ~status:`Failed
                                            ~resolved_runtime:"local"
                                            ~success:false ~error:err
                                            ~evidence_session_id:
                                              (Local_agent_eio
                                               .oas_worker_evidence_session_id
                                                 ~worker_run_id)
                                            ~trace_capability:"summary_only" ();
                                          append_delegate_event ~worker_run_id
                                            ~worker_name ~delegate_prompt
                                            ?execution_scope
                                            ~wait_mode:(Team_session_types.wait_mode_to_string wait_mode)
                                            ~trace_capability:"summary_only"
                                            ~resolved_runtime:"local"
                                            ~success:false ~error:err ();
                                          `Assoc [ ("error", `String err) ]
                                    in
                                    (match wait_mode with
                                    | Team_session_types.Wait_blocking ->
                                        Some (run_delegate ())
                                    | Team_session_types.Wait_background ->
                                        let sw_bg =
                                          Option.value ~default:ctx.sw
                                            (Eio_context.get_switch_opt ())
                                        in
                                        append_delegate_requested_event
                                          ~worker_run_id ~worker_name
                                          ~delegate_prompt;
                                        Eio.Fiber.fork ~sw:sw_bg (fun () ->
                                            ignore (run_delegate ()));
                                        Some
                                          (`Assoc
                                            [
                                              ("worker_run_id", `String worker_run_id);
                                              ("worker_name", `String worker_name);
                                              ("worker_backend", `String "local");
                                              ("status", `String "accepted");
                                              ("wait_mode", `String "background");
                                            ])))))
                      in
                      let delegate_error =
                        match delegate_result_json with
                        | Some (`Assoc fields) -> (
                            match List.assoc_opt "error" fields with
                            | Some (`String e) when String.trim e <> "" ->
                                Some e
                            | _ -> None)
                        | _ -> None
                      in
                      match delegate_error with
                      | Some e -> (false, deps.json_error e)
                      | None ->
                      let vote_result_json =
                        match get_string_opt args "vote_topic" with
                        | None -> None
                        | Some vote_topic ->
                            let vote_options = get_string_list args "vote_options" in
                            if List.length vote_options < 2 then
                              Some
                                (`Assoc
                                  [
                                    ("error", `String "vote_options requires at least 2 items");
                                  ])
                            else
                              let required_votes = get_int args "vote_required_votes" 2 in
                              let vote_create_msg =
                                Room.vote_create ctx.config ~proposer:actor
                                  ~topic:vote_topic ~options:vote_options
                                  ~required_votes
                              in
                              let vote_id = deps.extract_vote_id vote_create_msg in
                              Team_session_store.append_event ctx.config session_id
                                ~event_type:"team_vote_created"
                                ~detail:
                                  (`Assoc
                                    [
                                      ("actor", `String actor);
                                      ("topic", `String vote_topic);
                                      ("required_votes", `Int required_votes);
                                      ("options", `List (List.map (fun o -> `String o) vote_options));
                                      ("vote_id", Option.fold ~none:`Null ~some:(fun s -> `String s) vote_id);
                                      ("result", `String vote_create_msg);
                                      ("ts_iso", `String (Types.now_iso ()));
                                    ]);
                              let cast_json =
                                match (vote_id, get_string_opt args "vote_choice") with
                                | Some vid, Some choice ->
                                    let cast_msg =
                                      Room.vote_cast ctx.config ~agent_name:actor
                                        ~vote_id:vid ~choice
                                    in
                                    Team_session_store.append_event ctx.config session_id
                                      ~event_type:"team_vote_cast"
                                      ~detail:
                                        (`Assoc
                                          [
                                            ("actor", `String actor);
                                            ("vote_id", `String vid);
                                            ("choice", `String choice);
                                            ("result", `String cast_msg);
                                            ("ts_iso", `String (Types.now_iso ()));
                                          ]);
                                    Some (`Assoc [ ("vote_id", `String vid); ("choice", `String choice); ("result", `String cast_msg) ])
                                | _ -> None
                              in
                              Some
                                (`Assoc
                                  [
                                    ("created", `String vote_create_msg);
                                    ("vote_id", Option.fold ~none:`Null ~some:(fun s -> `String s) vote_id);
                                    ("cast", Option.fold ~none:`Null ~some:(fun j -> j) cast_json);
                                  ])
                      in
                      let vote_error =
                        match vote_result_json with
                        | Some (`Assoc fields) -> (
                            match List.assoc_opt "error" fields with
                            | Some (`String e) when String.trim e <> "" -> Some e
                            | _ -> None)
                        | _ -> None
                      in
                      match vote_error with
                      | Some e -> (false, deps.json_error e)
                      | None ->
                          let run_json =
                            match get_string_opt args "run_task_id" with
                            | None -> None
                            | Some run_task_id ->
                                let run_agent = actor in
                                let init_json =
                                  match
                                    Run_eio.init ctx.config ~task_id:run_task_id
                                      ~agent_name:(Some run_agent)
                                  with
                                  | Ok run -> `Assoc [ ("status", `String "initialized"); ("run", Run_eio.run_record_to_json run) ]
                                  | Error e -> `Assoc [ ("status", `String "init_failed"); ("error", `String e) ]
                                in
                                let note_json =
                                  match get_string_opt args "run_note" with
                                  | None -> `Null
                                  | Some note -> (
                                      match Run_eio.append_log ctx.config ~task_id:run_task_id ~note with
                                      | Ok entry -> `Assoc [ ("status", `String "ok"); ("entry", Run_eio.log_entry_to_json entry) ]
                                      | Error e -> `Assoc [ ("status", `String "error"); ("message", `String e) ])
                                in
                                let deliverable_json =
                                  match get_string_opt args "run_deliverable" with
                                  | None -> `Null
                                  | Some content -> (
                                      match
                                        Run_eio.set_deliverable ctx.config
                                          ~task_id:run_task_id ~content
                                      with
                                      | Ok run ->
                                          Team_session_store.append_event ctx.config
                                            session_id
                                            ~event_type:"team_run_deliverable"
                                            ~detail:
                                              (`Assoc
                                                [
                                                  ("actor", `String actor);
                                                  ("run_task_id", `String run_task_id);
                                                  ("deliverable_preview", `String (deps.truncate_for_event content));
                                                  ("ts_iso", `String (Types.now_iso ()));
                                                ]);
                                          `Assoc [ ("status", `String "ok"); ("run", Run_eio.run_record_to_json run) ]
                                      | Error e ->
                                          `Assoc [ ("status", `String "error"); ("message", `String e) ])
                                in
                                Some
                                  (`Assoc
                                    [
                                      ("task_id", `String run_task_id);
                                      ("init", init_json);
                                      ("note", note_json);
                                      ("deliverable", deliverable_json);
                                    ])
                          in
                          let response =
                            `Assoc
                              [
                                ("session_id", `String session_id);
                                ("turn", Option.value ~default:`Null turn_json);
                                ("spawn", Option.fold ~none:`Null ~some:(fun j -> j) spawn_result_json);
                                ("delegate", Option.fold ~none:`Null ~some:(fun j -> j) delegate_result_json);
                                ("vote", Option.fold ~none:`Null ~some:(fun j -> j) vote_result_json);
                                ("run", Option.fold ~none:`Null ~some:(fun j -> j) run_json);
                              ]
                          in
                          (true, deps.json_ok [ ("result", response) ]))
