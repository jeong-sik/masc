(** Cascade attempt-liveness driver, RFC-0022 PR-3/4.

    Implementation note: the FSM state itself is held in a [ref] inside
    the handle.  Concurrency safety is the caller's responsibility —
    the streaming [on_event] callback and the clock-fiber [on_tick]
    invocation must run on the same Eio fiber, or the caller must
    serialise them externally.  The keeper turn loop already holds an
    [Eio.Mutex.t] per turn, which makes this trivial in practice. *)

module L = Cascade_attempt_liveness
module R = Cascade_attempt_liveness_runtime
module Adapter = Cascade_attempt_liveness_oas_adapter

type t = {
  budget : L.budget;
  mode : Env_config_keeper.CascadeAttemptLiveness.mode;
  provider_label : string;
  state : L.state ref;
}

type verdict =
  | Continue
  | Abort

let create ~budget ~mode ~provider_label ~started_at = {
  budget;
  mode;
  provider_label;
  state = ref (L.initial ~started_at);
}

let current_state t = !(t.state)

let tick_period t =
  let p = Float.min t.budget.ttft_max t.budget.inter_chunk_max /. 4.0 in
  Float.max 0.05 p

let apply_output t (out : L.output) : verdict =
  let verdict, side_effect = R.decide ~mode:t.mode out in
  (match side_effect with
   | R.Nothing -> ()
   | R.Record_kill { kind; mode_label } ->
       let kind_label = L.failure_kind_label kind in
       Prometheus.inc_counter
         Prometheus.metric_cascade_attempt_liveness_kill
         ~labels:[
           "kind", kind_label;
           "mode", mode_label;
           "provider", t.provider_label;
         ]
         ();
       Log.warn ~ctx:"CascadeAttemptLiveness"
         "kill kind=%s mode=%s provider=%s"
         kind_label mode_label t.provider_label);
  match verdict with
  | R.Continue_attempt -> Continue
  | R.Abort_attempt _ -> Abort

let step_event t (event : L.event) : verdict =
  let next_state, out = L.step t.budget !(t.state) event in
  t.state := next_state;
  apply_output t out

let observe_sse t evt received_at =
  match Adapter.kind_of_sse_event evt with
  | None -> Continue
  | Some kind -> step_event t (L.Chunk (kind, received_at))

let on_tick t now =
  step_event t (L.Tick now)
