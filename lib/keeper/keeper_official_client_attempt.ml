type outcome =
  { result : (Runtime_agent.run_result, Agent_core.Error.t) result
  ; settled_session : Keeper_official_client_session_store.t option
  ; pending_result_receipts : Keeper_client_tool_outbox.consumption option
  ; effect_disposition : Keeper_provider_attempt_effect.t
  }

let refused_before_dispatch error =
  { result = Error error
  ; settled_session = None
  ; pending_result_receipts = None
  ; effect_disposition = Keeper_provider_attempt_effect.No_effect_observed
  }
;;

module Effect_cell = struct
  type t = Keeper_provider_attempt_effect.t Atomic.t

  let create () = Atomic.make Keeper_provider_attempt_effect.No_effect_observed
  let attempted cell = Atomic.set cell Keeper_provider_attempt_effect.Effect_attempted

  let move cell ~from ~to_ =
    match Atomic.compare_and_set cell from to_ with
    | true | false -> ()
  ;;

  let unobserved cell =
    move cell
      ~from:Keeper_provider_attempt_effect.No_effect_observed
      ~to_:Keeper_provider_attempt_effect.Observation_unavailable
  ;;

  let quiet cell =
    move cell
      ~from:Keeper_provider_attempt_effect.Observation_unavailable
      ~to_:Keeper_provider_attempt_effect.No_effect_observed
  ;;

  let read = Atomic.get
end

type recorder =
  { on_session_settled : Keeper_official_client_session_store.t -> unit
  ; on_results_ready : Keeper_client_tool_outbox.consumption option -> unit
  ; effect_cell : Effect_cell.t
  }

let run ~event_bus ~keeper_name attempt =
  let settled_session = Atomic.make None in
  let pending_result_receipts = Atomic.make None in
  let recorder =
    { on_session_settled = (fun value -> Atomic.set settled_session (Some value))
    ; on_results_ready = (fun value -> Atomic.set pending_result_receipts value)
    ; effect_cell = Effect_cell.create ()
    }
  in
  let result =
    Eio.Switch.run (fun result_scope ->
      Keeper_official_client_host.with_run_lifecycle_events ~event_bus ~keeper_name
        (fun () -> attempt ~result_scope recorder))
  in
  { result
  ; settled_session = Atomic.get settled_session
  ; pending_result_receipts =
      (match result with
       | Ok _ -> Atomic.get pending_result_receipts
       | Error _ -> None)
  ; effect_disposition = Effect_cell.read recorder.effect_cell
  }
;;
