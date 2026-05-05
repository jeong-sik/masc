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
  provider_label : string;
  state : L.state ref;
  sw_ref : Eio.Switch.t option ref;
  finalized : bool ref;
}

let mode (t : t) : Cfg.mode = t.mode

let create ~mode ~budget ~cascade_label ~provider_label ~started_at =
  {
    mode;
    budget;
    cascade_label;
    provider_label;
    state = ref (L.initial ~started_at);
    sw_ref = ref None;
    finalized = ref false;
  }

let current_state_for_test (t : t) : L.state = !(t.state)

(* -- Prometheus emission ------------------------------------------- *)

let kill_labels (t : t) (failure : L.failure) =
  [
    ("mode", Cfg.mode_label t.mode);
    ("kind", L.failure_kind_label failure);
    ("cascade", t.cascade_label);
    ("provider", t.provider_label);
  ]

let observed_labels (t : t) ~outcome =
  [
    ("cascade", t.cascade_label);
    ("provider", t.provider_label);
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
  | Agent_sdk.Types.SSEParseFailed { reason; _ } -> Some reason
  | Agent_sdk.Types.SSEUnknownEventType { event_type; _ } ->
      Some (Printf.sprintf "sse_unknown_event_type: %s" event_type)
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
                  registered (cascade=%s provider=%s); shadowing kill"
                 t.cascade_label t.provider_label))

(* -- on_event wrapper --------------------------------------------- *)

let now_seconds () = Time_compat.now ()

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
        let new_state, output = L.step t.budget !(t.state) le in
        t.state := new_state;
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
                    (cascade=%s provider=%s): %s"
                   t.cascade_label t.provider_label
                   (Printexc.to_string exn)));
        try step_with_event t evt with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | Liveness_kill _ as e -> raise e
        | exn ->
            Log.Misc.warn
              "cascade_attempt_liveness: step raised (cascade=%s \
               provider=%s): %s"
              t.cascade_label t.provider_label (Printexc.to_string exn)
      in
      Some wrapped

(* -- Tick fiber --------------------------------------------------- *)

let tick_interval_seconds (b : L.budget) : float =
  let smaller = Float.min b.ttft_max b.inter_chunk_max in
  Float.max 0.5 (smaller /. 4.0)

let start_tick_fiber (t : t) ~(sw : Eio.Switch.t)
    ~(clock : _ Eio.Time.clock) : unit =
  match t.mode with
  | Cfg.Off -> ()
  | Cfg.Observe | Cfg.Enforce ->
      t.sw_ref := Some sw;
      let interval = tick_interval_seconds t.budget in
      Eio.Fiber.fork ~sw (fun () ->
          let rec loop () =
            if L.is_terminal !(t.state) then ()
            else begin
              (try Eio.Time.sleep clock interval
               with Eio.Cancel.Cancelled _ as e -> raise e);
              if L.is_terminal !(t.state) then ()
              else begin
                let now = now_seconds () in
                let new_state, output =
                  L.step t.budget !(t.state) (L.Tick now)
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
                 provider=%s): %s"
                t.cascade_label t.provider_label (Printexc.to_string exn))

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
    match t.mode with
    | Cfg.Off -> ()
    | Cfg.Observe | Cfg.Enforce ->
        let outcome = outcome_of_state !(t.state) in
        Prometheus.inc_counter
          Prometheus.metric_cascade_attempt_liveness_observed
          ~labels:(observed_labels t ~outcome) ()
  end
