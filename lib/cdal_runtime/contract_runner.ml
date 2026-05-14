module Retry = Llm_provider.Retry

type run_result =
  { response : (Types.api_response, Error.sdk_error) result
  ; proof : Cdal_proof.t
  }

let extract_capability_snapshot (agent : Agent.t) : Cdal_proof.capability_snapshot =
  let tools = Agent.tools agent |> Tool_set.to_list in
  let tool_names = List.map (fun (t : Tool.t) -> t.schema.name) tools in
  let config = (Agent.state agent).config in
  { tools = tool_names
  ; mcp_servers = []
  ; max_turns = config.max_turns
  ; max_tokens = config.max_tokens
  ; thinking_enabled = config.enable_thinking
  }
;;

(** Detect context window exhaustion from provider error messages. *)
let is_context_overflow_error (err : Error.sdk_error) : bool =
  Retry.is_context_overflow_message (Error.to_string err)
;;

let map_result_status (response : (Types.api_response, Error.sdk_error) result)
  : Cdal_proof.result_status
  =
  match response with
  | Error err ->
    if is_context_overflow_error err
    then Cdal_proof.Context_overflow
    else Cdal_proof.Errored
  | Ok resp ->
    (match resp.stop_reason with
     | Types.EndTurn -> Cdal_proof.Completed
     | Types.MaxTokens -> Cdal_proof.Completed
     | Types.StopSequence -> Cdal_proof.Completed
     | Types.StopToolUse -> Cdal_proof.Completed
     | Types.Unknown _ -> Cdal_proof.Errored)
;;

let run
      ~sw
      ?clock
      ?(store = Proof_store.default_config)
      ~contract
      (agent : Agent.t)
      prompt
  =
  let capabilities = extract_capability_snapshot agent in
  let requested = contract.Risk_contract.runtime_constraints.requested_execution_mode in
  let risk_class = contract.Risk_contract.runtime_constraints.risk_class in
  match Mode_resolver.resolve ~requested ~risk_class ~capabilities with
  | Error reason ->
    (* Critical risk or mode forbidden -- produce Cancelled proof *)
    let now = Unix.gettimeofday () in
    let proof : Cdal_proof.t =
      { schema_version = Cdal_proof.schema_version_current
      ; run_id =
          Printf.sprintf
            "cdal-rejected-%d-%06x"
            (int_of_float (now *. 1000.0))
            (Random.bits () land 0xFFFFFF)
      ; contract_id = Risk_contract.contract_id contract
      ; requested_execution_mode = requested
      ; effective_execution_mode = Execution_mode.Diagnose
      ; mode_decision_source = "rejected"
      ; risk_class
      ; provider_snapshot =
          { provider_name = "none"; model_id = "none"; api_version = None }
      ; capability_snapshot = capabilities
      ; tool_trace_refs = []
      ; raw_evidence_refs = []
      ; checkpoint_ref = None
      ; result_status = Cancelled
      ; started_at = now
      ; ended_at = now
      ; scope = None
      }
    in
    Proof_store.init_run store ~run_id:proof.run_id;
    Proof_store.write_manifest store ~run_id:proof.run_id proof;
    Proof_store.write_contract store ~run_id:proof.run_id contract;
    { response = Error (Error.Internal (Printf.sprintf "contract rejected: %s" reason))
    ; proof
    }
  | Ok mode_decision ->
    let capture_state =
      Proof_capture.create
        ~store
        ~contract
        ~mode_decision
        ~capability_snapshot:capabilities
        ()
    in
    let tool_classifications =
      Agent.tools agent
      |> Tool_set.to_list
      |> List.filter_map (fun (t : Tool.t) ->
        match t.descriptor with
        | Some d ->
          Option.bind d.Tool.mutation_class Mode_enforcer.mutation_class_of_string
          |> Option.map (fun cls -> t.schema.name, cls)
        | None -> None)
    in
    let enforcer_state =
      Mode_enforcer.create
        ~contract
        ~effective_mode:mode_decision.effective_mode
        ~tool_classifications
        ()
    in
    Proof_capture.set_enforcer capture_state enforcer_state;
    let enforcement_hooks = Mode_enforcer.hooks enforcer_state in
    let proof_hooks = Proof_capture.hooks capture_state in
    let user_hooks = (Agent.options agent).hooks in
    let composed_hooks =
      Hooks.compose
        ~outer:enforcement_hooks
        ~inner:(Hooks.compose ~outer:proof_hooks ~inner:user_hooks)
    in
    let opts = Agent.options agent in
    let new_opts = { opts with hooks = composed_hooks } in
    let config = (Agent.state agent).config in
    let tools = Agent.tools agent |> Tool_set.to_list in
    let context = Agent.context agent in
    let net = Agent.net agent in
    let new_agent = Agent.create ~net ~config ~tools ~context ~options:new_opts () in
    let response = Agent.run ~sw ?clock new_agent prompt in
    (* Sync execution state back to the original agent so that
       downstream checkpoint capture sees the post-run messages,
       turn_count, and usage — not the pre-run empty state. *)
    Agent.set_state agent (Agent.state new_agent);
    let result_status = map_result_status response in
    let proof = Proof_capture.finalize capture_state ~result_status in
    { response; proof }
;;
