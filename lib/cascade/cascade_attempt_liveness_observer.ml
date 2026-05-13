(* See cascade_attempt_liveness_observer.mli for documentation.

   RFC-0022 PR-2/4 §4-5 — observer constructor, on_event wrapper,
   tick fiber, finalizer. *)

module L = Cascade_attempt_liveness
module Cfg = Cascade_attempt_liveness_config

exception Liveness_kill of L.failure

type t = {
  mode : Cfg.mode;
  budget : L.budget;
  cascade_label : string;
  candidate_key : string option;
  started_at : float;
  first_chunk_at : float option ref;
  last_chunk_at : float option ref;
  max_inter_chunk_s : float ref;
  success_sample : (string * Cfg.success_sample) option ref;
  state : L.state ref;
  sw_ref : Eio.Switch.t option ref;
  finalized : bool ref;
  stop_tick_p : unit Eio.Promise.t;
  stop_tick_r : unit Eio.Promise.u;
  stop_tick_requested : bool Atomic.t;
}

let mode (t : t) : Cfg.mode = t.mode

let public_runtime_provider_label = "runtime"

let create ~mode ~budget ~cascade_label ?candidate_key ~started_at () =
  let stop_tick_p, stop_tick_r = Eio.Promise.create () in
  {
    mode;
    budget;
    cascade_label;
    candidate_key;
    started_at;
    first_chunk_at = ref None;
    last_chunk_at = ref None;
    max_inter_chunk_s = ref 0.0;
    success_sample = ref None;
    state = ref (L.initial ~started_at);
    sw_ref = ref None;
    finalized = ref false;
    stop_tick_p;
    stop_tick_r;
    stop_tick_requested = Atomic.make false;
  }

let current_state_for_test (t : t) : L.state = !(t.state)

(* -- Prometheus emission ------------------------------------------- *)

let kill_labels (t : t) (failure : L.failure) =
  [
    ("mode", Cfg.mode_label t.mode);
    ("kind", L.failure_kind_label failure);
    ("cascade", t.cascade_label);
    ("provider", public_runtime_provider_label);
  ]

let observed_labels (t : t) ~outcome =
  [
    ("cascade", t.cascade_label);
    ("provider", public_runtime_provider_label);
    ("outcome", outcome);
  ]

let emit_kill_counter (t : t) (failure : L.failure) =
  Prometheus.inc_counter Prometheus.metric_cascade_attempt_liveness_kill
    ~labels:(kill_labels t failure) ()

(* -- Event translation -------------------------------------------- *)

(* Translate an SSE event into a {!Stream_chunk.kind}, returning
   None for events that the FSM should not see (e.g. Ping that does
   not advance the clock — RFC §4.4 invariant S3 forbids treating
   raw Ping as motion).

   MessageStop maps to Done; ContentBlockDelta maps to the matching
   Answer/Thinking delta; ContentBlockStart with content_type
   "tool_use" maps to Tool_call_start; SSEError and explicit parser
   failures map to wire errors; MessageStart / MessageDelta / Ping /
   ContentBlockStop are ignored as they are protocol scaffolding
   without forward motion. *)

let event_to_chunk_kind (evt : Agent_sdk.Types.sse_event)
    : L.Stream_chunk.kind option =
  match evt with
  | Agent_sdk.Types.MessageStop -> Some L.Stream_chunk.Done
  | Agent_sdk.Types.ContentBlockDelta { delta; _ } -> (
      match delta with
      | TextDelta _ -> Some L.Stream_chunk.Answer_delta
      | ThinkingDelta _ -> Some L.Stream_chunk.Thinking_delta
      | InputJsonDelta _ -> Some L.Stream_chunk.Tool_call_arg_delta)
  | Agent_sdk.Types.ContentBlockStart { content_type; tool_name; _ } -> (
      match content_type with
      | "tool_use" ->
          Some
            (L.Stream_chunk.Tool_call_start
               { tool_name = Option.value ~default:"" tool_name })
      | _ -> None)
  | Agent_sdk.Types.ContentBlockStop _ ->
      Some L.Stream_chunk.Tool_call_complete
  | Agent_sdk.Types.MessageStart _ -> None
  | Agent_sdk.Types.MessageDelta _ -> None
  | Agent_sdk.Types.Ping -> None
  | Agent_sdk.Types.SSEError _ -> None
  | Agent_sdk.Types.SSEParseFailed _ -> None
  | Agent_sdk.Types.SSEUnknownEventType _ -> None

let wire_error_of_event (evt : Agent_sdk.Types.sse_event) : string option =
  match evt with
  | Agent_sdk.Types.SSEError msg -> Some msg
  | Agent_sdk.Types.SSEParseFailed { reason; _ } ->
      Some ("sse_parse_failed: " ^ reason)
  | Agent_sdk.Types.SSEUnknownEventType { event_type; _ } ->
      Some ("sse_unknown_event_type: " ^ event_type)
  | _ -> None

(* -- React to FSM output ------------------------------------------ *)

let react_to_output (t : t) (output : L.output) : unit =
  match output with
  | L.Continue -> ()
  | L.Completed -> ()
  | L.Outcome failure ->
      emit_kill_counter t failure;
      (match t.mode with
       | Cfg.Off -> ()  (* unreachable: caller bypassed wrapper *)
       | Cfg.Observe -> ()  (* shadow only — never raise *)
       | Cfg.Enforce -> (
           match !(t.sw_ref) with
           | Some sw -> Eio.Switch.fail sw (Liveness_kill failure)
           | None ->
               (* Enforce without a switch wired is a programmer error;
                  log and degrade to Observe rather than raise. *)
               Log.Misc.warn
                 "cascade_attempt_liveness: enforce mode but no switch \
                  registered (cascade=%s provider=runtime); shadowing kill"
                 t.cascade_label))

(* -- on_event wrapper --------------------------------------------- *)

let now_seconds () = Time_compat.now ()

let observe_chunk_clock (t : t) ~(at : float) : unit =
  (match !(t.first_chunk_at) with
   | None -> t.first_chunk_at := Some at
   | Some _ -> ());
  (match !(t.last_chunk_at) with
   | None -> ()
   | Some prev ->
     let gap = at -. prev in
     if Float.is_finite gap && gap > !(t.max_inter_chunk_s)
     then t.max_inter_chunk_s := gap);
  t.last_chunk_at := Some at

let prometheus_recorder (t : t) : L.recorder =
  let labels =
    [ ("cascade", t.cascade_label); ("provider", public_runtime_provider_label) ]
  in
  {
    L.record_ttft = (fun seconds ->
        Prometheus.observe_histogram Prometheus.metric_cascade_ttfb_seconds
          ~labels seconds);
    record_inter_chunk = (fun seconds ->
        Prometheus.observe_histogram Prometheus.metric_cascade_inter_chunk_seconds
          ~labels seconds);
    record_liveness_outcome = (fun _ -> ());
  }

let stop_tick_fiber (t : t) : unit =
  if Atomic.compare_and_set t.stop_tick_requested false true then
    Eio.Promise.resolve t.stop_tick_r ()

let step_with_event (t : t) (evt : Agent_sdk.Types.sse_event) : unit =
  if L.is_terminal !(t.state) then ()
  else
    let now = now_seconds () in
    let liveness_event =
      match wire_error_of_event evt with
      | Some msg -> Some (L.Provider_wire_error msg)
      | None -> (
          match event_to_chunk_kind evt with
          | None -> None
          | Some kind -> Some (L.Chunk (kind, now)))
    in
    match liveness_event with
    | None -> ()
    | Some le ->
        (match le with
         | L.Chunk (_, at) -> observe_chunk_clock t ~at
         | L.Tick _ | L.Provider_wire_error _ -> ());
        let new_state, output =
          L.step ~recorder:(prometheus_recorder t) t.budget !(t.state) le
        in
        t.state := new_state;
        if L.is_terminal new_state then stop_tick_fiber t;
        react_to_output t output

let wrap_on_event (t : t)
    (original : (Agent_sdk.Types.sse_event -> unit) option)
    : (Agent_sdk.Types.sse_event -> unit) option =
  match t.mode with
  | Cfg.Off -> original
  | Cfg.Observe | Cfg.Enforce ->
      let wrapped (evt : Agent_sdk.Types.sse_event) : unit =
        (* Run the original first so baseline semantics never lose an
           event even if the FSM step would raise (defensive — Observe
           must not raise; Enforce raises only via Switch.fail). *)
        (match original with
         | None -> ()
         | Some f -> (
             try f evt with
             | Eio.Cancel.Cancelled _ as e -> raise e
             | exn ->
                 Log.Misc.warn
                   "cascade_attempt_liveness: original on_event raised \
                    (cascade=%s provider=runtime): %s"
                   t.cascade_label
                   (Printexc.to_string exn)));
        try step_with_event t evt with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | Liveness_kill _ as e -> raise e
        | exn ->
            Log.Misc.warn
              "cascade_attempt_liveness: step raised (cascade=%s \
               provider=runtime): %s"
              t.cascade_label (Printexc.to_string exn)
      in
      Some wrapped

(* -- Tick fiber --------------------------------------------------- *)

let tick_interval_seconds (b : L.budget) : float =
  let smaller = Float.min b.ttft_max b.inter_chunk_max in
  Float.max 0.5 (smaller /. 4.0)

let register_attempt_switch (t : t) ~(sw : Eio.Switch.t) : unit =
  match t.mode with
  | Cfg.Off -> ()
  | Cfg.Observe | Cfg.Enforce -> t.sw_ref := Some sw

let start_tick_fiber (t : t) ~(sw : Eio.Switch.t)
    ~(clock : _ Eio.Time.clock) : unit =
  match t.mode with
  | Cfg.Off -> ()
  | Cfg.Observe | Cfg.Enforce ->
      register_attempt_switch t ~sw;
      let interval = tick_interval_seconds t.budget in
      let await_tick_or_stop () =
        Eio.Fiber.first
          (fun () ->
             Eio.Time.sleep clock interval;
             `Tick)
          (fun () ->
             Eio.Promise.await t.stop_tick_p;
             `Stop)
      in
      Eio.Fiber.fork ~sw (fun () ->
          let rec loop () =
            if L.is_terminal !(t.state) then ()
            else begin
              match await_tick_or_stop () with
              | `Stop -> ()
              | `Tick ->
                if L.is_terminal !(t.state) then ()
                else begin
                  let now = now_seconds () in
                  let new_state, output =
                    L.step ~recorder:(prometheus_recorder t)
                      t.budget !(t.state) (L.Tick now)
                  in
                  t.state := new_state;
                  (try react_to_output t output
                   with Liveness_kill _ as e -> raise e);
                  loop ()
                end
            end
          in
          try loop () with
          | Eio.Cancel.Cancelled _ -> ()
          | Liveness_kill _ -> ()
          | exn ->
              Log.Misc.warn
                "cascade_attempt_liveness tick fiber crashed (cascade=%s \
                 provider=runtime): %s"
                t.cascade_label (Printexc.to_string exn))

(* -- Finalize ----------------------------------------------------- *)

let outcome_of_state = function
  | L.Success -> "success"
  | L.Failed (L.No_first_token | L.Inter_chunk_idle | L.Wall_exceeded) ->
      "kill"
  | L.Failed (L.Provider_error _) -> "wire_error"
  | L.Awaiting _ | L.Streaming _ -> "wire_error"

let finalize (t : t) : unit =
  if !(t.finalized) then ()
  else begin
    t.finalized := true;
    stop_tick_fiber t;
    match t.mode with
    | Cfg.Off -> ()
    | Cfg.Observe | Cfg.Enforce ->
        let outcome = outcome_of_state !(t.state) in
        (match !(t.state), t.candidate_key, !(t.first_chunk_at), !(t.last_chunk_at) with
         | L.Success, Some candidate_key, Some first_chunk_at, Some last_chunk_at ->
           t.success_sample :=
             Some
               ( candidate_key
               , { Cfg.ttft_ms = (first_chunk_at -. t.started_at) *. 1000.0
                 ; max_inter_chunk_ms = !(t.max_inter_chunk_s) *. 1000.0
                 ; wall_ms = (last_chunk_at -. t.started_at) *. 1000.0
                 } )
         | _ -> ());
        Prometheus.inc_counter
          Prometheus.metric_cascade_attempt_liveness_observed
          ~labels:(observed_labels t ~outcome) ()
  end

let success_sample_for_candidate (t : t) = !(t.success_sample)
