open Tool_args
open Tool_repair_loop_types

module Ocaml = Tool_repair_loop_ocaml
let repair_loop_rng = Random.State.make_self_init ()

let schemas : Types.tool_schema list =
  [
    {
      Types.name = "masc_repair_loop_start";
      description =
        "Start a detachable internal code repair loop and persist its initial state.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("plugin_id", `Assoc [ ("type", `String "string") ]);
                  ("task_spec", `Assoc [ ("type", `String "string") ]);
                  ("target_mode", `Assoc [ ("type", `String "string") ]);
                  ("working_dir", `Assoc [ ("type", `String "string") ]);
                  ("target_file", `Assoc [ ("type", `String "string") ]);
                  ("source_text", `Assoc [ ("type", `String "string") ]);
                  ("validator_profile", `Assoc [ ("type", `String "string") ]);
                  ("model_label", `Assoc [ ("type", `String "string") ]);
                  ("max_attempts", `Assoc [ ("type", `String "integer") ]);
                  ("artifact_session_id", `Assoc [ ("type", `String "string") ]);
                ] );
            ("required", `List [ `String "task_spec" ]);
          ];
    };
    {
      Types.name = "masc_repair_loop_status";
      description = "Read the persisted state of an internal code repair loop.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc [ ("loop_id", `Assoc [ ("type", `String "string") ]) ] );
            ("required", `List [ `String "loop_id" ]);
          ];
    };
    {
      Types.name = "masc_repair_loop_iterate";
      description =
        "Execute exactly one repair-loop attempt: validate provided code, generate, or repair.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc [ ("loop_id", `Assoc [ ("type", `String "string") ]) ] );
            ("required", `List [ `String "loop_id" ]);
          ];
    };
    {
      Types.name = "masc_repair_loop_stop";
      description = "Stop an internal code repair loop and persist terminal state.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc [ ("loop_id", `Assoc [ ("type", `String "string") ]) ] );
            ("required", `List [ `String "loop_id" ]);
          ];
    };
  ]

let make_loop_id () =
  Printf.sprintf "repair-%s" (Uuidm.to_string (Uuidm.v4_gen repair_loop_rng ()))

let resolve_target_mode args =
  match String.lowercase_ascii (get_string args "target_mode" "snippet") with
  | "repo" -> Repo
  | _ -> Snippet

let resolve_plugin_id args =
  match String.lowercase_ascii (get_string args "plugin_id" Ocaml.plugin_id) with
  | "ocaml" -> Ok Ocaml.plugin_id
  | other -> Error (Printf.sprintf "unsupported repair plugin: %s" other)

let default_model_label () =
  match Sys.getenv_opt "MODEL_LABEL" with
  | Some value when String.trim value <> "" -> String.trim value
  | _ -> Env_config.Local_runtime.default_model

let load_state_required config loop_id =
  match Tool_repair_loop_storage.load_state config loop_id with
  | Ok state -> Ok state
  | Error message -> Error message

let state_json_string ?cdal_refs ?cdal_error (state : state) =
  let base = state_status_json state in
  let augmented =
    match base with
    | `Assoc fields ->
        let fields =
          match cdal_refs with
          | Some refs ->
              ("cdal_refs", `List (List.map (fun item -> `String item) refs)) :: fields
          | None -> fields
        in
        let fields =
          match cdal_error with
          | Some err -> ("cdal_projection_error", `String err) :: fields
          | None -> fields
        in
        `Assoc fields
    | other -> other
  in
  Yojson.Safe.pretty_to_string augmented

let emit_advisory_artifacts_json (state : state) =
  match Tool_repair_loop_cdal.emit_advisory_artifacts state with
  | Ok refs -> state_json_string ~cdal_refs:refs state
  | Error err -> state_json_string ~cdal_error:err state

let validator_output_of_attempt (attempt : attempt_record) =
  Ocaml.validator_output_text attempt.validation

let current_attempt_phase (state : state) =
  if state.attempt_count = 0 then
    match state.source_text with
    | Some _ -> Provided
    | None -> Generate
  else
    Repair

let generate_or_repair_code (ctx : _ context) (state : state) :
    (attempt_phase * string, string) result =
  match current_attempt_phase state with
  | Provided -> (
      match state.source_text with
      | Some source -> Ok (Provided, source)
      | None -> Error "source_text is required for provided phase")
  | Generate ->
      let prompt = Ocaml.build_generate_prompt ~task_spec:state.task_spec in
      let result =
        Oas_worker.run_model_by_label ~model_label:state.model_label
          ~goal:prompt ~system_prompt:Ocaml.system_prompt ~max_turns:1
          ~temperature:Oas_worker_cascade.deterministic_temperature ~max_tokens:1024 ~enable_thinking:false
          ?sw:ctx.sw ()
      in
      result
      |> Result.map_error Oas.Error.to_string
      |> Result.map (fun (run_result : Oas_worker.run_result) ->
          (Generate, Oas_response.text_of_response run_result.response))
  | Repair ->
      let previous_code =
        Option.value ~default:"" state.current_code
      in
      let previous_attempt =
        match List.rev state.attempts with
        | latest :: _ -> latest
        | [] ->
            raise
              (Invalid_argument
                 "repair loop entered repair phase without a previous attempt")
      in
      let prompt =
        Ocaml.build_repair_prompt ~task_spec:state.task_spec
          ~previous_code
          ~validator_output:(validator_output_of_attempt previous_attempt)
      in
      let result =
        Masc_oas_bridge.run_safe ~timeout_s:180.0 (fun () ->
          Oas_worker.run_model_by_label ~model_label:state.model_label
            ~goal:prompt ~system_prompt:Ocaml.system_prompt ~max_turns:1
            ~temperature:Oas_worker_cascade.deterministic_temperature ~max_tokens:1024 ~enable_thinking:false
            ?sw:ctx.sw ()
        )
      in
      result
      |> Result.map_error Oas.Error.to_string
      |> Result.map (fun (run_result : Oas_worker.run_result) ->
          (Repair, Oas_response.text_of_response run_result.response))

(* Security: Ensure [child] is either equal to [parent] or located under [parent]. *)
let is_safe_subpath ~parent ~child =
  if child = parent then
    true
  else
    let parent_with_sep =
      if Filename.check_suffix parent Filename.dir_sep then
        parent
      else
        parent ^ Filename.dir_sep
    in
    let plen = String.length parent_with_sep in
    String.length child >= plen
    && String.sub child 0 plen = parent_with_sep

(* Security: Validate that [target_file], if provided, is a relative path whose
   resolved location stays within [working_dir]. *)
let validate_target_file ~working_dir ~target_file =
  match target_file with
  | None -> Ok None
  | Some tf ->
      if not (Filename.is_relative tf) then
        Error "target_file must be a relative path"
      else
        let candidate = Filename.concat working_dir tf in
        let resolved =
          try Unix.realpath candidate with
          | Unix.Unix_error _ -> candidate
        in
        if is_safe_subpath ~parent:working_dir ~child:resolved then
          Ok (Some tf)
        else
          Error "target_file must reside within working_dir"

let update_state_with_attempt (state : state) ~(attempt : attempt_record)
    ~(classification : attempt_classification) ~(status : repair_status)
    ~(last_error : string option) ~(current_code : string) =
  let now = Time_compat.now () in
  {
    state with
    attempt_count = attempt.attempt_index;
    status;
    last_error;
    current_code = Some current_code;
    attempts = state.attempts @ [ { attempt with classification } ];
    updated_at = now;
    stopped_at = if is_terminal_status status then Some now else None;
  }

(* #6641 iter10 — per-agent playground containment for repair loop.

   Resolves [working_dir] against the caller's playground bundle root
   (.masc/playground/<agent_name>/) so keepers cannot pass a foreign
   playground clone as the repair target. The default when [working_dir]
   is omitted is the caller's own playground, not [Sys.getcwd ()].

   Takes [agent_name] and [base_path] directly rather than a context
   record so both [Tool_repair_loop.context] and [Keeper_types.context]
   call sites can share the same helper without type unification. *)
let resolve_playground_working_dir ~agent_name ~base_path ~working_dir_arg =
  let playground_rel =
    Keeper_alerting_path.playground_path_of_keeper agent_name
  in
  let playground_abs_raw =
    Filename.concat base_path playground_rel
  in
  let playground_abs =
    try Unix.realpath playground_abs_raw with
    | Unix.Unix_error _ -> playground_abs_raw
  in
  let effective_arg =
    if String.trim working_dir_arg = "" then playground_abs
    else working_dir_arg
  in
  let resolved =
    try Ok (Unix.realpath effective_arg) with
    | Unix.Unix_error _ ->
        Error "working_dir does not exist or is not accessible"
  in
  match resolved with
  | Error msg -> Error msg
  | Ok working_dir ->
      if is_safe_subpath ~parent:playground_abs ~child:working_dir then
        Ok working_dir
      else
        Error
          (Printf.sprintf
             "working_dir must be inside your own keeper playground \
              (%s). Cross-keeper repair loops are blocked — use \
              masc_worktree_create to provision a workspace under your \
              playground first. See #6527/#6641."
             playground_rel)

let handle_start (ctx : _ context) args : tool_result =
  let*! task_spec = get_string_required args "task_spec" in
  match resolve_plugin_id args with
  | Error message -> error_result message
  | Ok plugin_id ->
      let target_mode = resolve_target_mode args in
      let working_dir_arg = get_string args "working_dir" "" in
      let target_file = get_string_opt args "target_file" in
      (match
         resolve_playground_working_dir
           ~agent_name:ctx.agent_name
           ~base_path:ctx.config.base_path
           ~working_dir_arg
       with
      | Error msg -> error_result msg
      | Ok working_dir ->
          begin match validate_target_file ~working_dir ~target_file with
            | Error msg -> error_result msg
            | Ok validated_target_file ->
                let validator_profile =
                  get_string args "validator_profile"
                    (Ocaml.default_validator_profile target_mode)
                in
                (* Cap max_attempts to prevent DoS *)
                let max_attempts = min 10 (max 1 (get_int args "max_attempts" 2)) in
                if target_mode = Repo && Option.is_none validated_target_file then
                  error_result "target_file is required when target_mode=repo"
                else
                  let loop_id = make_loop_id () in
                  let state =
                    {
                      loop_id;
                      plugin_id;
                      target_mode;
                      task_spec;
                      working_dir;
                      target_file = validated_target_file;
                      validator_profile;
                      model_label =
                        get_string args "model_label" (default_model_label ());
                      max_attempts;
                      attempt_count = 0;
                      artifact_session_id =
                        get_string args "artifact_session_id" loop_id;
                      status = Running;
                      last_error = None;
                      source_text = get_string_opt args "source_text";
                      current_code = None;
                      attempts = [];
                      created_at = Time_compat.now ();
                      updated_at = Time_compat.now ();
                      stopped_at = None;
                    }
                  in
                  Tool_repair_loop_storage.save_state ctx.config state;
                  Tool_repair_loop_storage.append_event ctx.config state.loop_id
                    "started"
                    (`Assoc
                      [
                        ("agent_name", `String ctx.agent_name);
                        ("plugin_id", `String state.plugin_id);
                        ( "target_mode",
                          `String (target_mode_to_string state.target_mode) );
                      ]);
                  (true, state_json_string state)
          end)

let handle_status (ctx : _ context) args : tool_result =
  let*! loop_id = get_string_required args "loop_id" in
  match load_state_required ctx.config loop_id with
  | Ok state -> (true, state_json_string state)
  | Error message -> error_result message

let handle_stop (ctx : _ context) args : tool_result =
  let*! loop_id = get_string_required args "loop_id" in
  match load_state_required ctx.config loop_id with
  | Error message -> error_result message
  | Ok state ->
      let stopped =
        {
          state with
          status = Stopped;
          updated_at = Time_compat.now ();
          stopped_at = Some (Time_compat.now ());
        }
      in
      Tool_repair_loop_storage.save_state ctx.config stopped;
      Tool_repair_loop_storage.append_event ctx.config stopped.loop_id "stopped"
        (`Assoc [ ("agent_name", `String ctx.agent_name) ]);
      (true, emit_advisory_artifacts_json stopped)

let handle_iterate (ctx : _ context) args : tool_result =
  let*! loop_id = get_string_required args "loop_id" in
  match load_state_required ctx.config loop_id with
  | Error message -> error_result message
  | Ok state ->
      if is_terminal_status state.status then
        (true, emit_advisory_artifacts_json state)
      else
        match generate_or_repair_code ctx state with
        | Error message ->
            let failed =
              {
                state with
                status = Terminal_failure;
                last_error = Some message;
                updated_at = Time_compat.now ();
                stopped_at = Some (Time_compat.now ());
              }
            in
            Tool_repair_loop_storage.save_state ctx.config failed;
            Tool_repair_loop_storage.append_event ctx.config failed.loop_id
              "model_error"
              (`Assoc [ ("message", `String message) ]);
            (false, emit_advisory_artifacts_json failed)
        | Ok (phase, raw_code) ->
            let code = Ocaml.strip_markdown_fences raw_code in
            let attempt_index = state.attempt_count + 1 in
            let attempt =
              Ocaml.validate_candidate ctx state ~attempt_index ~phase ~code
            in
            let classification, status, last_error =
              Ocaml.classify_attempt state attempt
            in
            let updated =
              update_state_with_attempt state ~attempt ~classification ~status
                ~last_error ~current_code:code
            in
            Tool_repair_loop_storage.save_state ctx.config updated;
            Tool_repair_loop_storage.append_event ctx.config updated.loop_id
              "attempt"
              (`Assoc
                [
                  ("attempt_index", `Int attempt.attempt_index);
                  ("phase", `String (attempt_phase_to_string attempt.phase));
                  ("status", `String (repair_status_to_string status));
                ]);
            let body = emit_advisory_artifacts_json updated in
            (status <> Terminal_failure && status <> Timed_out, body)

let dispatch (ctx : _ context) ~name ~args : tool_result option =
  match name with
  | "masc_repair_loop_start" -> Some (handle_start ctx args)
  | "masc_repair_loop_status" -> Some (handle_status ctx args)
  | "masc_repair_loop_iterate" -> Some (handle_iterate ctx args)
  | "masc_repair_loop_stop" -> Some (handle_stop ctx args)
  | _ -> None

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let () =
  List.iter
    (fun (s : Types.tool_schema) ->
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_repair_loop
           ~input_schema:s.input_schema
           ~handler_binding:Tag_dispatch
           ()))
    schemas
