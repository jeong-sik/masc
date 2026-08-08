type usage_delta =
  { turns : int
  ; input_tokens : int
  ; output_tokens : int
  ; total_tokens : int
  ; cost_usd : float
  ; last_turn_ts : float
  ; last_input_tokens : int
  ; last_output_tokens : int
  ; last_total_tokens : int
  ; last_usage_reported_at : float option
  ; last_latency_ms : int
  }

type identity_handoff =
  { keeper_id : Keeper_id.Uid.t option
  ; agent_name : string
  ; trace_id : Keeper_id.Trace_id.t
  ; trace_history : string list
  ; generation : int
  ; updated_at : string
  }

type compaction_result =
  { count_delta : int
  ; at : float
  ; before_tokens : int
  ; after_tokens : int
  ; checked_at : float
  ; decision : Keeper_meta_contract.compaction_runtime_decision
  ; updated_at : string
  }

type meta_command =
  | Create of Keeper_meta_contract.keeper_meta
  | Pause of
      { reason : Keeper_latched_reason.t
      ; updated_at : string
      }
  | Resume of { updated_at : string }
  | Reset_latch of { updated_at : string }
  | Set_autoboot of
      { enabled : bool
      ; updated_at : string
      }
  | Handoff_identity of identity_handoff
  | Repair_trace_generation of
      { trace_id : Keeper_id.Trace_id.t
      ; trace_history : string list
      ; generation : int
      ; updated_at : string
      }
  | Delete
  | Turn_started_projection of { updated_at : string }
  | Turn_succeeded of
      { usage : usage_delta
      ; updated_at : string
      }
  | Turn_failed of
      { blocker : Keeper_meta_contract.blocker_info
      ; usage : usage_delta option
      ; updated_at : string
      }
  | Add_usage of usage_delta
  | Set_current_task of
      { task_id : Keeper_id.Task_id.t option
      ; updated_at : string
      }
  | Set_blocker of
      { blocker : Keeper_meta_contract.blocker_info option
      ; updated_at : string
      }
  | Record_compaction of compaction_result
  | Ack_message_scope of
      { message_id : string option
      ; updated_at : string
      }

type state =
  { meta : Keeper_meta_contract.keeper_meta option
  ; running_operation_id : string option
  ; stopping : bool
  }

type projection =
  { meta : Keeper_meta_contract.keeper_meta option
  ; running_operation_id : string option
  ; stopping : bool
  }

type persistence_intent =
  | No_persistence
  | Replace_snapshot of Keeper_meta_contract.keeper_meta
  | Remove_snapshot of Keeper_meta_contract.keeper_meta

type post_commit_effect =
  | Publish_projection of projection
  | Start_turn_child of { operation_id : string }

type transition =
  { state : state
  ; persistence : persistence_intent
  ; effects : post_commit_effect list
  }

type error =
  | Meta_missing
  | Meta_already_exists
  | Owner_stopping
  | Turn_already_running of string
  | Turn_not_running
  | Turn_identity_mismatch of
      { expected : string
      ; actual : string
      }
  | Invalid_delta of string

let create meta : state = { meta; running_operation_id = None; stopping = false }

let projection (state : state) : projection =
  { meta = state.meta
  ; running_operation_id = state.running_operation_id
  ; stopping = state.stopping
  }
;;

let publish_transition (state : state) persistence extra_effects =
  let projection = projection state in
  { state
  ; persistence
  ; effects = Publish_projection projection :: extra_effects
  }
;;

let with_meta (state : state) meta =
  let state = { state with meta = Some meta } in
  publish_transition state (Replace_snapshot meta) []
;;

let validate_delta delta =
  if delta.turns < 0
  then Error (Invalid_delta "turns must be non-negative")
  else if delta.input_tokens < 0
  then Error (Invalid_delta "input_tokens must be non-negative")
  else if delta.output_tokens < 0
  then Error (Invalid_delta "output_tokens must be non-negative")
  else if delta.total_tokens < 0
  then Error (Invalid_delta "total_tokens must be non-negative")
  else if delta.cost_usd < 0.0 || not (Float.is_finite delta.cost_usd)
  then Error (Invalid_delta "cost_usd must be finite and non-negative")
  else if not (Float.is_finite delta.last_turn_ts)
  then Error (Invalid_delta "last_turn_ts must be finite")
  else if delta.last_input_tokens < 0
  then Error (Invalid_delta "last_input_tokens must be non-negative")
  else if delta.last_output_tokens < 0
  then Error (Invalid_delta "last_output_tokens must be non-negative")
  else if delta.last_total_tokens < 0
  then Error (Invalid_delta "last_total_tokens must be non-negative")
  else if delta.last_latency_ms < 0
  then Error (Invalid_delta "last_latency_ms must be non-negative")
  else if
    Option.fold
      ~none:false
      ~some:(fun observed_at -> not (Float.is_finite observed_at))
      delta.last_usage_reported_at
  then Error (Invalid_delta "last_usage_reported_at must be finite")
  else Ok ()
;;

let checked_add field current delta =
  if current > max_int - delta
  then Error (Invalid_delta (field ^ " overflow"))
  else Ok (current + delta)
;;

let ( let* ) result f = Result.bind result f

let add_usage meta delta =
  match validate_delta delta with
  | Error _ as error -> error
  | Ok () ->
    let usage = meta.Keeper_meta_contract.runtime.usage in
    let total_cost_usd = usage.total_cost_usd +. delta.cost_usd in
    if not (Float.is_finite total_cost_usd)
    then Error (Invalid_delta "total_cost_usd overflow")
    else
      let* total_turns = checked_add "total_turns" usage.total_turns delta.turns in
      let* total_input_tokens =
        checked_add "total_input_tokens" usage.total_input_tokens delta.input_tokens
      in
      let* total_output_tokens =
        checked_add "total_output_tokens" usage.total_output_tokens delta.output_tokens
      in
      let* total_tokens = checked_add "total_tokens" usage.total_tokens delta.total_tokens in
      let usage : Keeper_meta_contract.usage_metrics =
        { total_turns
        ; total_input_tokens
        ; total_output_tokens
        ; total_tokens
        ; total_cost_usd
        ; last_turn_ts = delta.last_turn_ts
        ; last_input_tokens = delta.last_input_tokens
        ; last_output_tokens = delta.last_output_tokens
        ; last_total_tokens = delta.last_total_tokens
        ; last_usage_reported_at = delta.last_usage_reported_at
        ; last_latency_ms = delta.last_latency_ms
        }
      in
      Ok (Keeper_meta_contract.map_usage (fun _ -> usage) meta)
;;

let update_usage meta usage =
  match usage with
  | None -> Ok meta
  | Some delta -> add_usage meta delta
;;

let apply_existing (state : state) meta command =
  match command with
  | Create _ -> Error Meta_already_exists
  | Delete ->
    let state = { state with meta = None } in
    Ok (publish_transition state (Remove_snapshot meta) [])
  | Pause { reason; updated_at } ->
    Ok (with_meta state { meta with paused = true; latched_reason = Some reason; updated_at })
  | Resume { updated_at } ->
    let resumed = Keeper_meta_contract.mark_resumed meta in
    Ok (with_meta state { resumed with updated_at })
  | Reset_latch { updated_at } ->
    let runtime = { meta.runtime with last_blocker = None } in
    Ok
      (with_meta
         state
         { meta with paused = false; latched_reason = None; runtime; updated_at })
  | Set_autoboot { enabled; updated_at } ->
    Ok (with_meta state { meta with autoboot_enabled = enabled; updated_at })
  | Handoff_identity handoff ->
    let runtime =
      { meta.runtime with
        trace_id = handoff.trace_id
      ; trace_history = handoff.trace_history
      ; nonce = handoff.generation
      }
    in
    Ok
      (with_meta
         state
         { meta with
           keeper_id = handoff.keeper_id
         ; agent_name = handoff.agent_name
         ; runtime
         ; updated_at = handoff.updated_at
         })
  | Repair_trace_generation repair ->
    let runtime =
      { meta.runtime with
        trace_id = repair.trace_id
      ; trace_history = repair.trace_history
      ; nonce = repair.generation
      }
    in
    Ok (with_meta state { meta with runtime; updated_at = repair.updated_at })
  | Turn_started_projection { updated_at } ->
    Ok (with_meta state { meta with updated_at })
  | Turn_succeeded { usage; updated_at } ->
    (match add_usage meta usage with
     | Error _ as error -> error
     | Ok meta ->
       let runtime = { meta.runtime with last_blocker = None } in
       Ok (with_meta state { meta with runtime; updated_at }))
  | Turn_failed { blocker; usage; updated_at } ->
    (match update_usage meta usage with
     | Error _ as error -> error
     | Ok meta ->
       let runtime = { meta.runtime with last_blocker = Some blocker } in
       Ok (with_meta state { meta with runtime; updated_at }))
  | Add_usage delta ->
    (match add_usage meta delta with
     | Error _ as error -> error
     | Ok meta -> Ok (with_meta state meta))
  | Set_current_task { task_id; updated_at } ->
    Ok (with_meta state { meta with current_task_id = task_id; updated_at })
  | Set_blocker { blocker; updated_at } ->
    let runtime = { meta.runtime with last_blocker = blocker } in
    Ok (with_meta state { meta with runtime; updated_at })
  | Record_compaction result ->
    if result.count_delta < 0
    then Error (Invalid_delta "compaction count_delta must be non-negative")
    else
      let previous = meta.runtime.compaction_rt in
      (match checked_add "compaction count" previous.count result.count_delta with
       | Error _ as error -> error
       | Ok count ->
         let compaction_rt =
           { Keeper_meta_contract.count
           ; last_ts = result.at
           ; last_before_tokens = result.before_tokens
           ; last_after_tokens = result.after_tokens
           ; last_check_ts = result.checked_at
           ; last_decision = result.decision
           }
         in
         let meta = Keeper_meta_contract.map_compaction_rt (fun _ -> compaction_rt) meta in
         Ok (with_meta state { meta with updated_at = result.updated_at }))
  | Ack_message_scope { message_id; updated_at } ->
    let runtime = { meta.runtime with message_scope_ack_id = message_id } in
    Ok (with_meta state { meta with runtime; updated_at })
;;

let apply_meta (state : state) command =
  if state.stopping
  then Error Owner_stopping
  else
    match state.meta, command with
    | None, Create meta -> Ok (with_meta state meta)
    | None, _ -> Error Meta_missing
    | Some meta, command -> apply_existing state meta command
;;

let begin_turn (state : state) ~operation_id =
  if state.stopping
  then Error Owner_stopping
  else
    match state.running_operation_id with
    | Some running -> Error (Turn_already_running running)
    | None ->
      let state = { state with running_operation_id = Some operation_id } in
      Ok
        (publish_transition
           state
           No_persistence
           [ Start_turn_child { operation_id } ])
;;

let finish_turn (state : state) ~operation_id =
  match state.running_operation_id with
  | None -> Error Turn_not_running
  | Some actual when String.equal actual operation_id ->
    let state = { state with running_operation_id = None } in
    Ok (publish_transition state No_persistence [])
  | Some actual ->
    Error (Turn_identity_mismatch { expected = operation_id; actual })
;;

let begin_stopping (state : state) =
  let state = { state with stopping = true } in
  publish_transition state No_persistence []
;;

let error_to_string = function
  | Meta_missing -> "keeper metadata does not exist"
  | Meta_already_exists -> "keeper metadata already exists"
  | Owner_stopping -> "keeper owner is stopping"
  | Turn_already_running operation_id ->
    Printf.sprintf "keeper turn %s is already running" operation_id
  | Turn_not_running -> "keeper has no running turn"
  | Turn_identity_mismatch { expected; actual } ->
    Printf.sprintf "turn identity mismatch: expected=%s actual=%s" expected actual
  | Invalid_delta detail -> "invalid additive delta: " ^ detail
;;
