module Agent = Agent_core.Agent
module Native = Keeper_native_call
module Owner = Keeper_owner_registry
module Checkpoint = Keeper_checkpoint_store
let ( let* ) = Result.bind

type binding =
  { base_path : string
  ; keeper_name : string
  ; operation_id : Keeper_chat_operation.Operation_id.t
  ; execution_digest : string
  ; session_dir : string
  ; session_id : string
  }

type input =
  | New_input of
      { blocks : Agent_core.Types.content_block list
      ; metadata : Agent_core.Types.metadata
      }
  | Continue_from_checkpoint

type resumed =
  { call : Native.t
  ; checkpoint : Agent_core.Checkpoint.t
  ; initial_messages : Agent_core.Types.message list
  ; system_prompt : string
  ; input : input
  }

type admission =
  | No_pending
  | Resume of resumed
  | Terminal_pending of Native.t * Agent.execution_terminal_disposition

type prepared =
  { binding : binding
  ; config : Runtime_agent.config
  ; checkpoint : Agent_core.Checkpoint.t option
  ; input : input
  }

type retired_history_cut =
  { observed : Native.state
  ; proof : Keeper_input_history_cut.t
  }

let owner result = Result.map_error Owner.command_error_to_string result
let state binding =
  Owner.direct_native_call ~base_path:binding.base_path
    ~keeper_name:binding.keeper_name ~operation_id:binding.operation_id |> owner

let runtime_id resumed = resumed.call.runtime_id
let system_prompt (resumed : resumed) = resumed.system_prompt
let checkpoint (resumed : resumed) = resumed.checkpoint
let restored_context (resumed : resumed) =
  Agent_core.Context.copy ~eio:true resumed.checkpoint.context
let initial_messages (resumed : resumed) = resumed.initial_messages
let input (resumed : resumed) = resumed.input
let config (prepared : prepared) = prepared.config
let prepared_checkpoint (prepared : prepared) = prepared.checkpoint
let prepared_input (prepared : prepared) = prepared.input

let rec is_prefix prefix messages =
  match prefix, messages with
  | [], _ -> true
  | expected :: prefix, actual :: messages -> expected = actual && is_prefix prefix messages
  | _ :: _, [] -> false

let validate_scope binding (checkpoint : Agent_core.Checkpoint.t) =
  let* frame = Keeper_repetition_context.load checkpoint.context
    |> Result.map_error Keeper_repetition_snapshot.error_to_string in
  match Keeper_repetition_snapshot.active frame with
  | Some scope when Keeper_execution_scope_id.equal scope
      (Keeper_execution_scope_id.direct_operation binding.operation_id) -> Ok ()
  | Some _ | None -> Error "native checkpoint does not own the direct operation"

let load_checkpoint_snapshot binding reference =
  let* () =
    if Keeper_id.Trace_id.to_string reference.Keeper_checkpoint_ref.trace_id = binding.session_id
    then Ok () else Error "native checkpoint belongs to another session" in
  let* snapshot = Checkpoint.load_retained_exact_snapshot
      ~session_dir:binding.session_dir ~reference
    |> Result.map_error (fun _ -> "exact native checkpoint is unavailable") in
  let checkpoint = Checkpoint.exact_snapshot_checkpoint snapshot in
  let* () = validate_scope binding checkpoint in
  Ok snapshot

let load_checkpoint binding reference =
  load_checkpoint_snapshot binding reference |> Result.map Checkpoint.exact_snapshot_checkpoint

let restore_checkpoints binding (call : Native.t) =
  let* () = if call.operation_digest = binding.execution_digest then Ok ()
    else Error "native call operation input changed" in
  let* seed = load_checkpoint binding call.seed_checkpoint in
  let* checkpoint = load_checkpoint binding call.checkpoint in
  let* () = if seed.agent_name = checkpoint.agent_name && seed.model = checkpoint.model
      && is_prefix seed.messages checkpoint.messages then Ok ()
    else Error "native checkpoint no longer contains its exact admitted seed" in
  let* system_prompt = match seed.system_prompt with
    | Some prompt -> Ok prompt
    | None -> Error "native seed has no original system prompt" in
  let* initial_messages, input = match call.api with
    | Native.Continue_from_checkpoint -> Ok (seed.messages, Continue_from_checkpoint)
    | Native.New_input {seed_message_count} ->
      (match List.nth_opt seed.messages seed_message_count with
       | Some {Agent_core.Types.role = User; content; metadata; _}
         when List.length seed.messages = seed_message_count + 1 ->
         Ok (List.take seed_message_count seed.messages,
             New_input {blocks=content; metadata})
       | Some {Agent_core.Types.role = (User | Assistant | System | Tool); _}
       | None -> Error "native seed does not contain its exact original input") in
  Ok (seed, {call; checkpoint; initial_messages; system_prompt; input})

let execution_dir binding call_id =
  match Fs_compat.get_fs_opt () with
  | None -> Error "native execution requires the application filesystem capability"
  | Some fs ->
    Ok Eio.Path.(fs / binding.session_dir / "native-executions" / call_id)

let open_projection binding (call : Native.t) =
  let* () = if call.operation_digest = binding.execution_digest then Ok ()
    else Error "native call operation input changed before journal inspection" in
  let* runtime = match Runtime_agent_execution_runtime.get () with
    | Some runtime -> Ok runtime
    | None -> Error "native execution runtime has not been initialized" in
  let* dir = execution_dir binding call.call_id in
  Agent.open_execution_projection ~runtime ~dir call.locator
  |> Result.map_error Agent.Execution_projection.error_to_string

let restore binding call =
  let* seed, resumed = restore_checkpoints binding call in
  let* projection = open_projection binding call in
  let* settled = Agent.Execution_projection.settled_tool_invocations projection
    |> Result.map_error Agent.Execution_projection.error_to_string in
  let* seed = Keeper_repetition_context.load seed.context
    |> Result.map_error Keeper_repetition_snapshot.error_to_string in
  let* checkpoint = Keeper_repetition_context.load resumed.checkpoint.context
    |> Result.map_error Keeper_repetition_snapshot.error_to_string in
  let* recovered = Domain_pool_ref.submit_io_or_inline (fun () ->
    Keeper_native_repetition_recovery.reconcile ~base_path:binding.base_path
      ~scope:(Keeper_execution_scope_id.direct_operation binding.operation_id)
      ~seed ~checkpoint ~settled ()
    |> Result.map_error Keeper_native_repetition_recovery.error_to_string) in
  (* Reconcile only in memory. The retained seed/latest artifacts and Owner
     references remain exact; the next normal checkpoint CAS commits this
     recovered projection. Both setup's source and the shared context copy
     must carry it, otherwise strict repetition restore would conflict. *)
  let context = Agent_core.Context.copy ~eio:true resumed.checkpoint.context in
  Keeper_repetition_context.save context recovered;
  Ok {resumed with checkpoint={resumed.checkpoint with context}}

let inspect_terminal binding call =
  let* projection = open_projection binding call in
  Agent.read_execution_terminal projection
  |> Result.map_error Agent.Execution_projection.error_to_string

let reconcile_terminal binding (call : Native.t) =
  let* terminal = inspect_terminal binding call in
  match terminal with
  | None -> Ok None
  | Some terminal ->
    let* () = Owner.terminal_direct_native_call ~base_path:binding.base_path
        ~keeper_name:binding.keeper_name ~operation_id:binding.operation_id
        ~execution_digest:binding.execution_digest ~call_id:call.call_id
        ~disposition:terminal.disposition |> owner in
    Ok (Some terminal)

(* Core records the terminal disposition under cancellation protection, but a
   cancelled writer supervisor, or a failed Owner write, can leave the Owner
   call Active while the journal holds the terminal. When the dispatch ends,
   whether it returns or raises, copy whatever terminal the journal holds into
   the Owner receipt before the result reaches the Owner's settlement. A journal
   with no terminal leaves the call Active; the Owner then decides from how the
   child ended. *)
let reconcile_after_dispatch binding run =
  let reconcile () =
    Eio.Cancel.protect (fun () ->
      let reconciled =
        let* observed = state binding in
        match observed with
        | Native.Active call -> reconcile_terminal binding call |> Result.map ignore
        | Native.No_native_call | Native.Terminal_unacknowledged _ -> Ok () in
      match reconciled with
      | Ok () -> ()
      | Error detail ->
        Log.Keeper.warn ~keeper_name:binding.keeper_name
          "native terminal reconciliation after dispatch failed operation=%s: %s"
          (Keeper_chat_operation.Operation_id.to_string binding.operation_id) detail) in
  match run () with
  | value -> reconcile (); value
  | exception exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    reconcile ();
    Printexc.raise_with_backtrace exn backtrace

let retired_evidence binding call disposition =
  let* terminal = inspect_terminal binding call in
  match terminal with
  | Some terminal when terminal.disposition = disposition -> Ok terminal
  | Some _ -> Error "native terminal receipt disagrees with its canonical journal"
  | None -> Error "native terminal receipt has no matching terminal journal"

let retains_settled_results binding (call : Native.t) messages results =
  let* seed = load_checkpoint binding call.seed_checkpoint in
  Ok (Domain_pool_ref.submit_cpu_or_inline (fun () ->
    Keeper_native_result_retention.retains ~seed:seed.messages ~messages ~results))

let load ~binding =
  let* observed = state binding in
  match observed with
  | Native.No_native_call -> Ok No_pending
  | Native.Active call ->
    let* terminal = reconcile_terminal binding call in
    (match terminal with
     | Some terminal -> Ok (Terminal_pending (call, terminal.disposition))
     | None -> restore binding call |> Result.map (fun resumed -> Resume resumed))
  | Native.Terminal_unacknowledged (call, disposition) ->
    let* () = if call.operation_digest = binding.execution_digest then Ok ()
      else Error "terminal native call operation input changed" in
    Ok (Terminal_pending (call, disposition))

let authorize_incomplete_response_cut ~binding ~checkpoint () =
  let* observed=state binding in
  let* source=match observed with
    | Native.Terminal_unacknowledged (call,{Agent.recovery=Retire;_}) ->
      let* ()=if call.operation_digest=binding.execution_digest then Ok ()
        else Error "native call input changed before response cut" in
      load_checkpoint_snapshot binding call.checkpoint
    | No_native_call | Active _
    | Terminal_unacknowledged (_, {Agent.recovery=Operator_repair_required Effect_outcome_unknown;_}) ->
      Error "response cut requires an exact retired native call" in
  let* proof=Keeper_input_history_cut.prepare ~source ~candidate:checkpoint in
  Ok {observed;proof}

let binding_effect_observation ~binding =
  let settled =
    let* admission = load ~binding in
    match admission with
    | No_pending -> Ok true
    | Resume _ -> Ok false
    | Terminal_pending (call, ({Agent.recovery=Retire; _} as disposition)) ->
      let* terminal = retired_evidence binding call disposition in
      let* checkpoint = load_checkpoint binding call.checkpoint in
      retains_settled_results binding call checkpoint.messages terminal.settled_tool_results
    | Terminal_pending
        (_, {Agent.recovery=Operator_repair_required Effect_outcome_unknown; _}) -> Ok false in
  match settled with
  | Ok true ->
    Keeper_provider_attempt_effect.No_effect_observed
  | Error _ | Ok false ->
    Keeper_provider_attempt_effect.Observation_unavailable

let effect_observation prepared = binding_effect_observation ~binding:prepared.binding

let retain binding (checkpoint : Agent_core.Checkpoint.t) =
  let* session_id = Keeper_id.Trace_id.of_string binding.session_id in
  let* snapshot = Checkpoint.exact_snapshot_of_value ~expected_session_id:session_id checkpoint
    |> Result.map_error Checkpoint.checkpoint_ref_load_error_to_string in
  let* () = validate_scope binding (Checkpoint.exact_snapshot_checkpoint snapshot) in
  Checkpoint.retain_exact_snapshot ~session_dir:binding.session_dir snapshot
  |> Checkpoint.require_confirmed_installation
  |> Result.map_error (fun _ -> "native checkpoint retention is not durably confirmed")

let call_checkpoint binding (config : Runtime_agent.config) agent_ref =
  match !agent_ref with
  | None -> Error "native Agent is unavailable before scope publication"
  | Some agent ->
    Ok (Agent.checkpoint ~session_id:binding.session_id
      ?working_context:config.checkpoint_sidecar agent)

type terminal_checkpoint_source = Agent_snapshot | Retained_input_owner

let prepare ~binding ~runtime_id ~config ~agent_core_checkpoint ~input ~agent_ref
    ?retired_history_cut () =
  let* runtime = match Runtime_agent_execution_runtime.get () with
    | Some runtime -> Ok runtime
    | None -> Error "native execution runtime has not been initialized" in
  let* () = match config.Runtime_agent.execution_store with
    | None -> Ok ()
    | Some _ -> Error "native dispatch already carries an explicit execution store" in
  let* observed = state binding in
  let* () = match retired_history_cut with
    | None -> Ok ()
    | Some cut when Native.equal_state cut.observed observed -> Ok ()
    | Some _ -> Error "retired native call changed after response-cut authorization" in
  let* resumed = match observed with
    | Native.Active call -> restore binding call |> Result.map Option.some
    | Native.No_native_call
    | Native.Terminal_unacknowledged (_, {Agent.recovery=Retire; _}) -> Ok None
    | Native.Terminal_unacknowledged
        (_, {Agent.recovery=Operator_repair_required Effect_outcome_unknown; _}) ->
      Error "native call has an unknown tool effect requiring reconciliation" in
  let* config, agent_core_checkpoint, input = match resumed with
    | None -> Ok (config, agent_core_checkpoint, input)
    | Some resumed ->
      let* () = if runtime_id = resumed.call.runtime_id
          && config.name = resumed.checkpoint.agent_name
          && config.model_id = resumed.checkpoint.model
          && config.provider_cfg.model_id = resumed.checkpoint.model then Ok ()
        else Error "saved native runtime or model identity changed" in
      (* Keeper restored this context before building tools and hooks. They
         close over that object, so replacing it here would lose their new
         receipts and repetition observations from Core's checkpoints. *)
      let context = match config.context with
        | Some context -> context
        | None -> restored_context resumed in
      Ok ({config with system_prompt=resumed.system_prompt;
                       initial_messages=resumed.initial_messages;
                       context=Some context;
                       checkpoint_sidecar=resumed.checkpoint.working_context},
          Some resumed.checkpoint, resumed.input) in
  let* input_trace = Keeper_id.Trace_id.of_string binding.session_id in
  let* input_source=match retired_history_cut with
    | None -> Ok agent_core_checkpoint
    | Some cut ->
      let* ()=Keeper_input_history_cut.validate_candidate cut.proof agent_core_checkpoint in
      Keeper_input_history_cut.source_checkpoint cut.proof |> Result.map Option.some in
  let* input_producer = Keeper_input_checkpoint_producer.prepare
      ~base_path:binding.base_path ~keeper_name:binding.keeper_name ~session_dir:binding.session_dir
      ~trace_id:input_trace
      ~source:input_source
    |> Result.map_error Keeper_input_checkpoint_producer.error_to_string in
  let input_producer = ref input_producer in
  let call_id, api, resume, initial_call = match resumed with
    | Some resumed ->
      resumed.call.call_id, resumed.call.api, Some resumed.call.locator, Some resumed.call
    | None ->
      let api = match input with
        | Continue_from_checkpoint -> Native.Continue_from_checkpoint
        | New_input _ ->
          let messages = match agent_core_checkpoint with
            | Some checkpoint -> checkpoint.Agent_core.Checkpoint.messages
            | None -> config.initial_messages in
          Native.New_input {seed_message_count=List.length messages} in
      Random_id.uuid_v7 (), api, None, None in
  let* dir = execution_dir binding call_id in
  let* () = match resumed with
    | Some _ -> Ok ()
    | None ->
      (try Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 dir; Ok () with
       | Eio.Io _ as exn -> Error (Format.asprintf "%a" Eio.Exn.pp exn)) in
  let current_call = ref initial_call in
  let advance checkpoint =
    match !current_call with
    | None -> Error "native checkpoint was emitted before locator publication"
    | Some call ->
      let* reference = retain binding checkpoint in
      let* () = Owner.checkpoint_direct_native_call ~base_path:binding.base_path
          ~keeper_name:binding.keeper_name ~operation_id:binding.operation_id
          ~execution_digest:binding.execution_digest ~call_id
          ~observed:call.checkpoint ~checkpoint:reference |> owner in
      let* next = Native.advance call ~observed:call.checkpoint ~checkpoint:reference in
      current_call := Some next;
      Ok () in
  let on_scope_ready locator =
    let* call = match resumed with
      | Some resumed -> Ok resumed.call
      | None ->
        let* seed = call_checkpoint binding config agent_ref in
        let* () = match observed with
          | Native.Terminal_unacknowledged (previous, ({Agent.recovery=Retire; _} as disposition)) ->
            let* settled = load_checkpoint binding previous.checkpoint in
            let* terminal = retired_evidence binding previous disposition in
            let* retained = retains_settled_results binding previous seed.messages
                terminal.settled_tool_results in
            let* () = if retained then Ok ()
              else Error "next native call is missing a canonically settled ToolResult" in
            let* expected = match retired_history_cut with
              | None -> Ok settled.messages
              | Some cut -> Keeper_input_history_cut.cut_checkpoint cut.proof
                  |> Result.map (fun checkpoint -> checkpoint.Agent_core.Checkpoint.messages) in
            if not terminal.has_tool_attempts || is_prefix expected seed.messages then Ok ()
            else Error "next native call does not retain the settled call's exact history"
          | Native.No_native_call -> Ok ()
          | Native.Active _
          | Native.Terminal_unacknowledged
              (_, {Agent.recovery=Operator_repair_required Effect_outcome_unknown; _}) ->
            Error "native call cannot replace unsettled execution authority" in
        let* seed_checkpoint = retain binding seed in
        Native.create ~call_id ~runtime_id ~operation_digest:binding.execution_digest
          ~api ~seed_checkpoint ~locator in
    let* ()=match retired_history_cut with
      | None -> Owner.bind_direct_native_call ~base_path:binding.base_path
          ~keeper_name:binding.keeper_name ~operation_id:binding.operation_id
          ~execution_digest:binding.execution_digest ~observed ~call |> owner
      | Some cut ->
        let* seed=Checkpoint.load_retained_exact_snapshot ~session_dir:binding.session_dir
            ~reference:call.seed_checkpoint
          |> Result.map_error (fun _ -> "exact next native seed is unavailable") in
        let* producer=Keeper_input_checkpoint_producer.bind_retired_input_cut !input_producer
            ~cut:cut.proof ~seed ~operation_id:binding.operation_id
            ~execution_digest:binding.execution_digest ~observed ~call
          |> Result.map_error Keeper_input_checkpoint_producer.error_to_string in
        input_producer:=producer; Ok () in
    current_call := Some call;
    Ok () in
  let terminal_checkpoint_source = ref Agent_snapshot in
  let on_terminal_disposition disposition =
    let* () = match !terminal_checkpoint_source with
      | Agent_snapshot ->
        let* checkpoint = call_checkpoint binding config agent_ref in
        advance checkpoint
      | Retained_input_owner ->
        (* The input sink can have advanced the Owner before a later canonical
           write or journal acknowledgement failed. Terminal uses that Owner's
           actual retained reference; an older Agent snapshot cannot undo it.
           Do not retry a write with an uncertain outcome here. *)
        Ok () in
    Owner.terminal_direct_native_call ~base_path:binding.base_path
      ~keeper_name:binding.keeper_name ~operation_id:binding.operation_id
      ~execution_digest:binding.execution_digest ~call_id ~disposition |> owner in
  let checkpoint_sink (snapshot : Agent.checkpoint_snapshot) =
    (match snapshot.stage with
     | Agent.After_input_wait_changed ->
       terminal_checkpoint_source := Retained_input_owner
     | After_assistant_collected | After_tool_results_appended
     | After_context_injection | After_rejected_response_dropped -> ());
    let checkpoint = {snapshot.checkpoint with Agent_core.Checkpoint.session_id=binding.session_id;
      working_context=(match config.checkpoint_sidecar with
        | Some _ as sidecar -> sidecar | None -> snapshot.checkpoint.working_context)} in
    let* () = match snapshot.stage with
      | Agent.After_input_wait_changed ->
        (match !current_call with
         | None -> Error "native input checkpoint preceded locator publication"
         | Some call ->
           let* () = validate_scope binding checkpoint in
           let* producer, reference = Keeper_input_checkpoint_producer.publish_direct !input_producer
               ~operation_id:binding.operation_id ~execution_digest:binding.execution_digest
               ~call_id ~observed:call.checkpoint checkpoint
             |> Result.map_error Keeper_input_checkpoint_producer.error_to_string in
           (* Publication returned a confirmed atomic input/native advance. *)
           let* next = Native.advance call ~observed:call.checkpoint ~checkpoint:reference in
           input_producer := producer;
           current_call := Some next;
           Ok ())
      | After_assistant_collected | After_tool_results_appended
      | After_context_injection | After_rejected_response_dropped -> advance checkpoint in
    let* () = match config.checkpoint_sink with
      | None -> Ok ()
      | Some sink -> sink {snapshot with checkpoint} in
    (match snapshot.stage with
     | Agent.After_input_wait_changed -> ()
     | After_assistant_collected | After_tool_results_appended
     | After_context_injection | After_rejected_response_dropped ->
       terminal_checkpoint_source := Agent_snapshot);
    Ok () in
  let execution_store = Agent.execution_store ~runtime ~dir ?resume
      ~on_scope_ready ~on_terminal_disposition () in
  Ok {binding; config={config with execution_store=Some execution_store;
                                  checkpoint_sink=Some checkpoint_sink};
      checkpoint=agent_core_checkpoint; input}

