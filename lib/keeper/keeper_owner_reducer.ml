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

type turn_counter_deltas =
  { proactive_count : int
  ; proactive_visible_count : int
  }

type 'a observed_change =
  | Unchanged
  | Changed of 'a

type turn_runtime_delta =
  { expected_trace_id : Keeper_id.Trace_id.t
  ; usage : usage_delta
  ; counters : turn_counter_deltas
  ; next_keeper_id : Keeper_id.Uid.t option
  ; next_trace_id : Keeper_id.Trace_id.t
  ; next_trace_history : string list
  ; next_last_handoff_ts : float
  ; proactive_observation : Keeper_meta_contract.proactive_runtime observed_change
  ; usage_cursor : Keeper_usage_resolution.cursor option observed_change
  ; last_usage_resolution : Keeper_usage_resolution.t option observed_change
  ; message_scope_ack_id : string option observed_change
  ; updated_at : string
  }


type shutdown_latch = Operator_stopped

type profile_update =
  { instructions : string
  ; sandbox_profile : Keeper_types_profile.sandbox_profile
  ; sandbox_image : string option
  ; network_mode : Keeper_types_profile.network_mode
  ; mention_targets : string list
  ; proactive_enabled : bool
  ; max_context_override : int option
  ; autoboot_enabled : bool
  ; telemetry_feedback_enabled : bool option
  ; telemetry_feedback_window_hours : int option
  ; always_allow : bool option
  ; voice_always_allow : bool option
  ; agent_core_env : (string * string) list
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
  | Retain_shutdown_latch of
      { latch : shutdown_latch
      ; updated_at : string
      }
  | Set_autoboot of
      { enabled : bool
      ; updated_at : string
      }
  | Update_profile of profile_update
  | Repair_trace_identity of
      { trace_id : Keeper_id.Trace_id.t
      ; trace_history : string list
      ; updated_at : string
      }
  | Delete_if_snapshot of Keeper_meta_json.Snapshot_digest.t
  | Turn_started_projection of { updated_at : string }
  | Turn_succeeded of
      { usage : usage_delta
      ; updated_at : string
      }
  | Turn_failed of
      { usage : usage_delta option
      ; updated_at : string
      }
  | Commit_turn_runtime of turn_runtime_delta
  | Add_usage of usage_delta
  | Set_current_task of
      { task_id : Keeper_id.Task_id.t option
      ; updated_at : string
      }
  | Ack_message_scope of
      { message_id : string option
      ; updated_at : string
      }

type state =
  { keeper_name : string
  ; meta : Keeper_meta_contract.keeper_meta option
  ; stopping : bool
  }

type projection =
  { meta : Keeper_meta_contract.keeper_meta option
  ; stopping : bool
  }

type persistence_intent =
  | No_persistence
  | Replace_snapshot of Keeper_meta_contract.keeper_meta
  | Remove_snapshot of Keeper_meta_contract.keeper_meta

type transition =
  { state : state
  ; persistence : persistence_intent
  ; projection : projection
  }

type error =
  | Meta_missing
  | Meta_already_exists
  | Owner_stopping
  | Invalid_delta of string
  | Keeper_identity_mismatch of
      { expected : string
      ; actual : string
      }
  | Identity_mismatch
  | Snapshot_changed

let create ~keeper_name meta =
  match meta with
  | Some meta when not (String.equal keeper_name meta.Keeper_meta_contract.name) ->
    Error (Keeper_identity_mismatch { expected = keeper_name; actual = meta.name })
  | Some _ | None -> Ok { keeper_name; meta; stopping = false }
;;

let projection (state : state) : projection =
  { meta = state.meta
  ; stopping = state.stopping
  }
;;

let publish_transition (state : state) persistence =
  let projection = projection state in
  { state
  ; persistence
  ; projection
  }
;;

let with_meta (state : state) meta =
  let state = { state with meta = Some meta } in
  publish_transition state (Replace_snapshot meta)
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

let nonnegative_difference field before after =
  if after < before
  then Error (Invalid_delta (field ^ " regressed"))
  else Ok (after - before)
;;

let observed_change before after =
  if before = after then Unchanged else Changed after
;;

let turn_runtime_delta_of_snapshots
      ~(before : Keeper_meta_contract.keeper_meta)
      ~(after : Keeper_meta_contract.keeper_meta)
  =
  if not (String.equal before.name after.name)
  then
    Error
      (Keeper_identity_mismatch
         { expected = before.name; actual = after.name })
  else
    let before_rt = before.runtime in
    let after_rt = after.runtime in
    let before_usage = before_rt.usage in
    let after_usage = after_rt.usage in
    let* turns =
      nonnegative_difference "total_turns" before_usage.total_turns after_usage.total_turns
    in
    let* input_tokens =
      nonnegative_difference
        "total_input_tokens"
        before_usage.total_input_tokens
        after_usage.total_input_tokens
    in
    let* output_tokens =
      nonnegative_difference
        "total_output_tokens"
        before_usage.total_output_tokens
        after_usage.total_output_tokens
    in
    let* total_tokens =
      nonnegative_difference
        "total_tokens"
        before_usage.total_tokens
        after_usage.total_tokens
    in
    let cost_usd = after_usage.total_cost_usd -. before_usage.total_cost_usd in
    let* proactive_count =
      nonnegative_difference
        "proactive_count_total"
        before_rt.proactive_rt.count_total
        after_rt.proactive_rt.count_total
    in
    let* proactive_visible_count =
      nonnegative_difference
        "proactive_visible_count_total"
        before_rt.proactive_rt.visible_count_total
        after_rt.proactive_rt.visible_count_total
    in
    let usage =
      { turns
      ; input_tokens
      ; output_tokens
      ; total_tokens
      ; cost_usd
      ; last_turn_ts = after_usage.last_turn_ts
      ; last_input_tokens = after_usage.last_input_tokens
      ; last_output_tokens = after_usage.last_output_tokens
      ; last_total_tokens = after_usage.last_total_tokens
      ; last_usage_reported_at = after_usage.last_usage_reported_at
      ; last_latency_ms = after_usage.last_latency_ms
      }
    in
    let* () = validate_delta usage in
    Ok
      { expected_trace_id = before_rt.trace_id
      ; usage
      ; counters =
          { proactive_count
          ; proactive_visible_count
          }
      ; next_keeper_id = after.keeper_id
      ; next_trace_id = after_rt.trace_id
      ; next_trace_history = after_rt.trace_history
      ; next_last_handoff_ts = after_rt.last_handoff_ts
      ; proactive_observation =
          observed_change before_rt.proactive_rt after_rt.proactive_rt
      ; usage_cursor = observed_change before_rt.usage_cursor after_rt.usage_cursor
      ; last_usage_resolution =
          observed_change
            before_rt.last_usage_resolution
            after_rt.last_usage_resolution
      ; message_scope_ack_id =
          observed_change before_rt.message_scope_ack_id after_rt.message_scope_ack_id
      ; updated_at = after.updated_at
      }
;;

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

let apply_observed_change current = function
  | Unchanged -> current
  | Changed value -> value
;;

let apply_turn_runtime_delta
      (meta : Keeper_meta_contract.keeper_meta)
      (delta : turn_runtime_delta)
  =
  if
    not (Keeper_id.Trace_id.equal meta.runtime.trace_id delta.expected_trace_id)
  then Error Identity_mismatch
  else
    let* meta = add_usage meta delta.usage in
    let runtime = meta.runtime in
    let counters = delta.counters in
    let* proactive_count_total =
      checked_add
        "proactive_count_total"
        runtime.proactive_rt.count_total
        counters.proactive_count
    in
    let* proactive_visible_count_total =
      checked_add
        "proactive_visible_count_total"
        runtime.proactive_rt.visible_count_total
        counters.proactive_visible_count
    in
    let proactive_observation =
      apply_observed_change runtime.proactive_rt delta.proactive_observation
    in
    let proactive_rt =
      { proactive_observation with
        count_total = proactive_count_total
      ; visible_count_total = proactive_visible_count_total
      }
    in
    let runtime =
      { runtime with
        trace_id = delta.next_trace_id
      ; trace_history = delta.next_trace_history
      ; last_handoff_ts = delta.next_last_handoff_ts
      ; proactive_rt
      ; usage_cursor = apply_observed_change runtime.usage_cursor delta.usage_cursor
      ; last_usage_resolution =
          apply_observed_change
            runtime.last_usage_resolution
            delta.last_usage_resolution
      ; message_scope_ack_id =
          apply_observed_change runtime.message_scope_ack_id delta.message_scope_ack_id
      }
    in
    Ok
      { meta with
        keeper_id = delta.next_keeper_id
      ; runtime
      ; updated_at = delta.updated_at
      }
;;

let apply_existing (state : state) meta command =
  match command with
  | Create _ -> Error Meta_already_exists
  | Delete_if_snapshot expected_digest ->
    let actual_digest = Keeper_meta_json.Snapshot_digest.of_meta meta in
    if Keeper_meta_json.Snapshot_digest.equal expected_digest actual_digest
    then
      let state = { state with meta = None } in
      Ok (publish_transition state (Remove_snapshot meta))
    else Error Snapshot_changed
  | Pause { reason; updated_at } ->
    Ok (with_meta state { meta with paused = true; latched_reason = Some reason; updated_at })
  | Resume { updated_at } ->
    let resumed = Keeper_meta_contract.mark_resumed meta in
    Ok (with_meta state { resumed with updated_at })
  | Reset_latch { updated_at } ->
    Ok
      (with_meta
         state
         { meta with paused = false; latched_reason = None; updated_at })
  | Retain_shutdown_latch { latch; updated_at } ->
    let (Operator_stopped : shutdown_latch) = latch in
    let latched_reason =
      Keeper_latched_reason.Operator_paused
        { operator_actor = Keeper_latched_reason.operator_actor_keeper_down }
    in
    let runtime = meta.runtime in
    Ok
      (with_meta
         state
         { meta with
           current_task_id = None
         ; paused = true
         ; latched_reason = Some latched_reason
         ; updated_at
         ; runtime
         })
  | Set_autoboot { enabled; updated_at } ->
    Ok (with_meta state { meta with autoboot_enabled = enabled; updated_at })
  | Update_profile update ->
    Ok
      (with_meta
         state
         { meta with
           instructions = update.instructions
         ; sandbox_profile = update.sandbox_profile
         ; sandbox_image = update.sandbox_image
         ; network_mode = update.network_mode
         ; mention_targets = update.mention_targets
         ; proactive = { enabled = update.proactive_enabled }
         ; max_context_override = update.max_context_override
         ; autoboot_enabled = update.autoboot_enabled
         ; telemetry_feedback_enabled = update.telemetry_feedback_enabled
         ; telemetry_feedback_window_hours = update.telemetry_feedback_window_hours
         ; always_allow = update.always_allow
         ; voice_always_allow = update.voice_always_allow
         ; agent_core_env = update.agent_core_env
         ; updated_at = update.updated_at
         })
  | Repair_trace_identity repair ->
    let runtime =
      { meta.runtime with
        trace_id = repair.trace_id
      ; trace_history = repair.trace_history
      }
    in
    Ok (with_meta state { meta with runtime; updated_at = repair.updated_at })
  | Turn_started_projection { updated_at } ->
    Ok (with_meta state { meta with updated_at })
  | Turn_succeeded { usage; updated_at } ->
    (match add_usage meta usage with
     | Error _ as error -> error
     | Ok meta -> Ok (with_meta state { meta with updated_at }))
  | Turn_failed { usage; updated_at } ->
    (match update_usage meta usage with
     | Error _ as error -> error
     | Ok meta -> Ok (with_meta state { meta with updated_at }))
  | Commit_turn_runtime delta ->
    (match apply_turn_runtime_delta meta delta with
     | Error _ as error -> error
     | Ok meta -> Ok (with_meta state meta))
  | Add_usage delta ->
    (match add_usage meta delta with
     | Error _ as error -> error
     | Ok meta -> Ok (with_meta state meta))
  | Set_current_task { task_id; updated_at } ->
    Ok (with_meta state { meta with current_task_id = task_id; updated_at })
  | Ack_message_scope { message_id; updated_at } ->
    let runtime = { meta.runtime with message_scope_ack_id = message_id } in
    Ok (with_meta state { meta with runtime; updated_at })
;;

let apply_meta (state : state) command =
  if state.stopping
  then Error Owner_stopping
  else
    match state.meta, command with
    | None, Create meta when String.equal state.keeper_name meta.name ->
      Ok (with_meta state meta)
    | None, Create meta ->
      Error
        (Keeper_identity_mismatch
           { expected = state.keeper_name; actual = meta.name })
    | None, Delete_if_snapshot _ -> Ok (publish_transition state No_persistence)
    | None, _ -> Error Meta_missing
    | Some meta, command -> apply_existing state meta command
;;

let begin_stopping (state : state) =
  let state = { state with stopping = true } in
  publish_transition state No_persistence
;;

let error_to_string = function
  | Meta_missing -> "keeper metadata does not exist"
  | Meta_already_exists -> "keeper metadata already exists"
  | Owner_stopping -> "keeper owner is stopping"
  | Invalid_delta detail -> "invalid additive delta: " ^ detail
  | Keeper_identity_mismatch { expected; actual } ->
    Printf.sprintf "Keeper identity mismatch: expected=%s actual=%s" expected actual
  | Identity_mismatch -> "Keeper trace identity changed"
  | Snapshot_changed -> "Keeper metadata changed after cleanup was prepared"
;;
