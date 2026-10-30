(** Runtime_observation — one runtime's per-turn observation: the attempts it
    made, with their latency and errors, the model it selected, and its
    streaming timings, captured through AGENT_CORE's per-call metrics sink.

    Runtime observations shared by the MASC execution boundary. *)

(* ================================================================ *)
(* Runtime types                                                     *)
(* ================================================================ *)

type request_cache = {
  cache_creation_input_tokens : int;
  cache_read_input_tokens : int;
}

type request_context = {
  input_tokens : int;
  cache : request_cache option;
  output_tokens : int option;
}

type host_acceptance = Accepted | Rejected of string
type execution_evidence = Captured_execution | Uncaptured_failure of string

type runtime_observation = {
  observation_id : string;
  host_acceptance : host_acceptance option;
  execution_evidence : execution_evidence;
  runtime_id : string;
  selected_model : string option;
  attempts : runtime_attempt list;
  attempt_details_available : bool;
  attempt_details_source : string;
  agent_core_internal_runtime_allowed : bool;
  streaming_ttfrc_ms : float option;
  streaming_inter_chunk_count : int;
  streaming_inter_chunk_avg_ms : float option;
  usage_scope : Runtime_usage_scope.t;
  request_context : request_context option;
  reported_context_window : int option;
}

and runtime_attempt = {
  attempt_index : int;
  model_id : string;
  model_label : string option;
  latency_ms : int option;
  error : string option;
}

(* RFC-0132 PR-2: runtime observation AGENT_CORE/dashboard surface = external boundary; redact via SSOT. *)
let public_runtime_model_label =
  Boundary_redaction.to_string Boundary_redaction.runtime_model_label

(* ================================================================ *)
(* Observation building                                              *)
(* ================================================================ *)

let runtime_observation_of_candidates ~observation_id ~runtime_id
    ~(selected_model : string option)
    ?(attempts = [])
    ?(attempt_details_available = false)
    ?(attempt_details_source = "opaque_named_runtime")
    ?(agent_core_internal_runtime_allowed = false)
    ?(streaming_ttfrc_ms = None)
    ?(streaming_inter_chunk_count = 0)
    ?(streaming_inter_chunk_avg_ms = None)
    ?(usage_scope = Runtime_usage_scope.Usage_scope_unavailable)
    ?request_context
    ?reported_context_window
    () : runtime_observation =
  (* Without [selected_model], success rows lose model attribution at
     construction time and downstream consumers (model_inference_metrics
     parse_telemetry_entry, execution receipts, composite observer) drop the
     row as Missing_success_model. Nothing is redacted here; the redacted
     JSON emitters write it as null and attempt model ids as
     [public_runtime_model_label]. *)
  {
    observation_id;
    host_acceptance = None;
    execution_evidence = Captured_execution;
    runtime_id;
    selected_model;
    attempts;
    attempt_details_available;
    attempt_details_source;
    agent_core_internal_runtime_allowed;
    streaming_ttfrc_ms;
    streaming_inter_chunk_count;
    streaming_inter_chunk_avg_ms;
    usage_scope;
    request_context;
    reported_context_window;
  }

(* ================================================================ *)
(* Metrics capture callbacks                                         *)
(* ================================================================ *)

type streaming_metrics_capture = {
  mutable ttfrc_ms : float option;
      (** Time To First Response Chunk in milliseconds. [None] until
          the first [on_streaming_first_chunk] callback fires. *)
  mutable inter_chunk_count : int;
      (** Number of inter-chunk intervals observed. *)
  mutable inter_chunk_total_ms : float;
      (** Cumulative inter-chunk latency in milliseconds. *)
}

type runtime_metrics_capture = {
  observation_id : string;
  runtime_id : string;
  keeper_name : string option;
  turn_id : int option;
  mutable next_attempt_index : int;
  mutable attempts_rev : runtime_attempt list;
  streaming : streaming_metrics_capture;
}

let update_first_attempt_if ~predicate ~update attempts_rev =
  let rec loop = function
    | [] -> None
    | attempt :: rest ->
        if predicate attempt then
          let updated = update attempt in
          Some (updated, updated :: rest)
        else Option.map (fun (updated, rest') -> updated, attempt :: rest') (loop rest)
  in
  loop attempts_rev

let record_attempt_start (capture : runtime_metrics_capture) ~model_id:_ =
  let attempt_index = capture.next_attempt_index in
  capture.next_attempt_index <- capture.next_attempt_index + 1;
  capture.attempts_rev <-
    {
      attempt_index;
      model_id = public_runtime_model_label;
      model_label = None;
      latency_ms = None;
      error = None;
    }
    :: capture.attempts_rev

type observation_stage = Runtime_execution | Host_acceptance | Observation_gap

let stage_name = function
  | Runtime_execution -> "runtime_execution"
  | Host_acceptance -> "host_acceptance"
  | Observation_gap -> "observation_gap"

let event_name = function
  | Runtime_execution -> "runtime_execution_terminal"
  | Host_acceptance -> "runtime_host_acceptance"
  | Observation_gap -> "runtime_observation_gap"

let identity_fields stage ~observation_id ~runtime_id =
  [ "event", `String (event_name stage)
  ; "stage", `String (stage_name stage)
  ; "observation_id", `String observation_id
  ; "runtime_id", `String runtime_id
  ]

let log_runtime_attempt_terminal (capture : runtime_metrics_capture)
    (attempt : runtime_attempt) =
  let outcome = if Option.is_some attempt.error then "failure" else "success" in
  let details = `Assoc
    (identity_fields Runtime_execution
       ~observation_id:capture.observation_id ~runtime_id:capture.runtime_id
     @ [ "attempt_index", `Int attempt.attempt_index
       ; "model_id", `String public_runtime_model_label
       ; "model_label", `Null
       ; "latency_ms", Json_util.int_opt_to_json attempt.latency_ms
       ; "outcome", `String outcome
       ; "error_message", Json_util.string_opt_to_json attempt.error
       ]) in
  Log.Telemetry.emit Log.Info ?keeper_name:capture.keeper_name ?turn_id:capture.turn_id
    ~details
    (Printf.sprintf "runtime execution terminal: observation=%s attempt=%d outcome=%s"
       capture.observation_id attempt.attempt_index outcome)

let ensure_terminal_attempt (capture : runtime_metrics_capture)
    ~model_id:_ ~(latency_ms : int option) ~(error : string option) =
  let model_id = public_runtime_model_label in
  let is_open attempt =
    String.equal attempt.model_id model_id
    && Option.is_none attempt.latency_ms
    && Option.is_none attempt.error
  in
  let update attempt = { attempt with latency_ms; error } in
  let terminal =
    match update_first_attempt_if ~predicate:is_open ~update capture.attempts_rev with
    | Some (terminal, attempts_rev) ->
      capture.attempts_rev <- attempts_rev;
      terminal
    | None ->
      let attempt_index = capture.next_attempt_index in
      capture.next_attempt_index <- capture.next_attempt_index + 1;
      let terminal = { attempt_index; model_id; model_label = None; latency_ms; error } in
      capture.attempts_rev <- terminal :: capture.attempts_rev;
      terminal
  in
  log_runtime_attempt_terminal capture terminal

let host_acceptance_to_json = function
  | None -> `Null
  | Some Accepted -> `Assoc [ "outcome", `String "accepted" ]
  | Some (Rejected error) ->
    `Assoc [ "outcome", `String "rejected"; "error_message", `String error ]

let execution_evidence_to_json = function
  | Captured_execution -> `Assoc ["status", `String "captured"]
  | Uncaptured_failure error ->
    `Assoc ["status", `String "uncaptured_failure"; "error_message", `String error]

let observe_uncaptured_failure ~runtime_id ?keeper_name ?turn_id ~error () =
  let observation_id = Agent_core.Event_bus.fresh_id () in
  let execution_evidence = Uncaptured_failure error in
  let observation = runtime_observation_of_candidates ~observation_id ~runtime_id
    ~selected_model:None ~attempt_details_source:"runtime_failure_without_capture" () in
  let details = `Assoc
    (identity_fields Observation_gap ~observation_id ~runtime_id
     @ ["execution_evidence", execution_evidence_to_json execution_evidence]) in
  Log.Telemetry.emit Log.Warn ?keeper_name ?turn_id ~details
    (Printf.sprintf "runtime failure without execution capture: observation=%s" observation_id);
  { observation with execution_evidence }

let record_host_acceptance ?keeper_name ?turn_id
    (observation : runtime_observation) acceptance =
  let outcome, level = match acceptance with
    | Accepted -> "accepted", Log.Info
    | Rejected _ -> "rejected", Log.Warn in
  let error = match acceptance with Accepted -> None | Rejected detail -> Some detail in
  let details = `Assoc
    (identity_fields Host_acceptance ~observation_id:observation.observation_id
       ~runtime_id:observation.runtime_id
     @ [ "outcome", `String outcome
       ; "error_message", Json_util.string_opt_to_json error ]) in
  Log.Telemetry.emit level ?keeper_name ?turn_id ~details
    (Printf.sprintf "runtime host acceptance: observation=%s outcome=%s"
       observation.observation_id outcome);
  { observation with host_acceptance = Some acceptance }

let record_attempt_terminal = ensure_terminal_attempt

let empty_streaming_capture () : streaming_metrics_capture =
  { ttfrc_ms = None; inter_chunk_count = 0; inter_chunk_total_ms = 0.0 }

let streaming_metrics_of_capture (s : streaming_metrics_capture) =
  let avg =
    if s.inter_chunk_count > 0
    then Some (s.inter_chunk_total_ms /. Float.of_int s.inter_chunk_count)
    else None
  in
  (s.ttfrc_ms, s.inter_chunk_count, avg)

let runtime_metrics_for_candidates ~runtime_id ?keeper_name ?turn_id () =
  let capture =
    { observation_id = Agent_core.Event_bus.fresh_id ()
    ; runtime_id
    ; keeper_name
    ; turn_id
    ; next_attempt_index = 0
    ; attempts_rev = []
    ; streaming = empty_streaming_capture ()
    }
  in
  let metrics : Llm_provider.Metrics.t =
    { Llm_provider.Metrics.
      on_cache_hit = (fun ~model_id:_ -> ());
      on_cache_miss = (fun ~model_id:_ -> ());
      on_request_start = (fun ~model_id ->
        record_attempt_start capture ~model_id);
      on_request_end = (fun ~model_id ~latency_ms ->
        ensure_terminal_attempt capture ~model_id ~latency_ms ~error:None);
      on_error = (fun ~model_id ~message ~reason:_ ->
        ensure_terminal_attempt capture ~model_id ~latency_ms:None
          ~error:(Some message));
      on_capability_drop = (fun ~model_id:_ ~field:_ -> ());
      on_http_status = (fun ~provider:_ ~model_id:_ ~status:_ -> ());
      on_retry = (fun ~provider:_ ~model_id:_ ~attempt:_ -> ());
      on_token_usage =
        (fun ~provider:_ ~model_id:_ ~input_tokens:_ ~output_tokens:_ -> ());
      on_tool_calls = (fun ~provider:_ ~model_id:_ ~count:_ -> ());
      on_streaming_first_chunk = (fun ~provider:_ ~model_id:_ ~ttfrc_ms ->
        capture.streaming.ttfrc_ms <- Some ttfrc_ms);
      on_streaming_chunk = (fun ~provider:_ ~model_id:_ ~chunk_index:_ ~inter_chunk_ms ->
        capture.streaming.inter_chunk_count <-
          capture.streaming.inter_chunk_count + 1;
        capture.streaming.inter_chunk_total_ms <-
          capture.streaming.inter_chunk_total_ms +. inter_chunk_ms);
    }
  in
  (capture, metrics)

let runtime_observation_with_metrics
    ~(selected_model : string option) ~(capture : runtime_metrics_capture)
    ?(attempt_details_source = "agent_core_metrics_callbacks")
    ?(agent_core_internal_runtime_allowed = false)
    ?(usage_scope = Runtime_usage_scope.Usage_scope_unavailable)
    ?request_context
    ?reported_context_window
    () =
  let ttfrc, chunk_count, chunk_avg =
    streaming_metrics_of_capture capture.streaming
  in
  runtime_observation_of_candidates ~observation_id:capture.observation_id
    ~runtime_id:capture.runtime_id ~selected_model
    ~attempts:(List.rev capture.attempts_rev)
    ~attempt_details_available:true
    ~attempt_details_source
    ~agent_core_internal_runtime_allowed
    ~streaming_ttfrc_ms:ttfrc
    ~streaming_inter_chunk_count:chunk_count
    ~streaming_inter_chunk_avg_ms:chunk_avg
    ~usage_scope
    ?request_context
    ?reported_context_window
    ()
