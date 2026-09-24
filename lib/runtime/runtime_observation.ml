(** Runtime_observation — one runtime's per-turn observation: the attempts it
    made, with their latency and errors, the model it selected, and its
    streaming timings, captured through AGENT_CORE's per-call metrics sink.

    Runtime observations shared by the MASC execution boundary. *)

(* ================================================================ *)
(* Runtime types                                                     *)
(* ================================================================ *)

type request_context = {
  input_tokens : int;
  cache_creation_input_tokens : int;
  cache_read_input_tokens : int;
}

type runtime_observation = {
  runtime_id : string;
  selected_model : string option;
  selected_model_raw : string option;
  attempts : runtime_attempt list;
  attempt_details_available : bool;
  attempt_details_source : string;
  agent_core_internal_runtime_allowed : bool;
  streaming_ttfrc_ms : float option;
  streaming_inter_chunk_count : int;
  streaming_inter_chunk_avg_ms : float option;
  usage_scope : Runtime_usage_scope.t;
  request_context : request_context option;
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

let runtime_observation_of_candidates ~runtime_id
    ~(selected_model_raw : string option)
    ?(attempts = [])
    ?(attempt_details_available = false)
    ?(attempt_details_source = "opaque_named_runtime")
    ?(agent_core_internal_runtime_allowed = false)
    ?(streaming_ttfrc_ms = None)
    ?(streaming_inter_chunk_count = 0)
    ?(streaming_inter_chunk_avg_ms = None)
    ?(usage_scope = Runtime_usage_scope.Usage_scope_unavailable)
    ?request_context
    () : runtime_observation =
  (* Thread the caller-supplied raw model attribution into both fields.
     Without this, success rows lose model attribution at construction
     time and downstream consumers (model_inference_metrics
     parse_telemetry_entry, execution receipts, composite observer)
     drop the row as Missing_success_model. Public-surface redaction to
     [public_runtime_model_label] happens at the redacted JSON emitter
     layer, not at observation construction. *)
  let selected_model = selected_model_raw in
  {
    runtime_id;
    selected_model;
    selected_model_raw;
    attempts;
    attempt_details_available;
    attempt_details_source;
    agent_core_internal_runtime_allowed;
    streaming_ttfrc_ms;
    streaming_inter_chunk_count;
    streaming_inter_chunk_avg_ms;
    usage_scope;
    request_context;
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
  mutable next_attempt_index : int;
  mutable attempts_rev : runtime_attempt list;
  streaming : streaming_metrics_capture;
}

let update_first_attempt_if ~predicate ~update attempts_rev =
  let rec loop = function
    | [] -> None
    | attempt :: rest ->
        if predicate attempt then Some (update attempt :: rest)
        else Option.map (fun rest' -> attempt :: rest') (loop rest)
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

(** [runtime_attempt_terminal_event_json] builds the structured details payload
    emitted to system_log when a runtime candidate reaches its terminal state
    (success: latency_ms set, error none; failure: error set). The shape is the
    contract for downstream log analysers and external operators looking for
    "why did the runtime exhaust" signals. Errors are recorded verbatim — no
    string-based classification at this layer (see #12817 spirit and the
    project memory rule "no string matching for classification"). *)
let runtime_attempt_terminal_event_json ~model_id:_ ~model_label:_ ~latency_ms
    ~error =
  let outcome = if Option.is_some error then "failure" else "success" in
  `Assoc
    [
      ("event", `String "runtime_attempt_terminal");
      ("model_id", `String public_runtime_model_label);
      ("model_label", `Null);
      ( "latency_ms", Json_util.int_opt_to_json latency_ms );
      ("outcome", `String outcome);
      ( "error_message", Json_util.string_opt_to_json error );
    ]

let log_runtime_attempt_terminal ~model_id ~model_label ~latency_ms ~error =
  let outcome = if Option.is_some error then "failure" else "success" in
  let details =
    runtime_attempt_terminal_event_json ~model_id ~model_label ~latency_ms
      ~error
  in
  let summary =
    Printf.sprintf
      "runtime candidate terminal: model=%s outcome=%s latency_ms=%s"
      public_runtime_model_label outcome
      (match latency_ms with Some n -> string_of_int n | None -> "n/a")
  in
  Log.Telemetry.emit Log.Info ~details summary

let ensure_terminal_attempt (capture : runtime_metrics_capture)
    ~model_id:_ ~(latency_ms : int option) ~(error : string option) =
  let model_id = public_runtime_model_label in
  let is_open attempt =
    String.equal attempt.model_id model_id
    && Option.is_none attempt.latency_ms
    && Option.is_none attempt.error
  in
  let update attempt = { attempt with latency_ms; error } in
  let model_label = None in
  (match update_first_attempt_if ~predicate:is_open ~update capture.attempts_rev with
  | Some attempts_rev -> capture.attempts_rev <- attempts_rev
  | None ->
      let attempt_index = capture.next_attempt_index in
      capture.next_attempt_index <- capture.next_attempt_index + 1;
      capture.attempts_rev <-
        {
          attempt_index;
          model_id;
          model_label;
          latency_ms;
          error;
        }
        :: capture.attempts_rev);
  log_runtime_attempt_terminal ~model_id ~model_label ~latency_ms ~error

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

let runtime_metrics_for_candidates () =
  let capture =
    { next_attempt_index = 0
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

let runtime_observation_with_metrics ~runtime_id
    ~(selected_model_raw : string option) ~(capture : runtime_metrics_capture)
    ?(attempt_details_source = "agent_core_metrics_callbacks")
    ?(agent_core_internal_runtime_allowed = false)
    ?(usage_scope = Runtime_usage_scope.Usage_scope_unavailable)
    ?request_context
    () =
  let ttfrc, chunk_count, chunk_avg =
    streaming_metrics_of_capture capture.streaming
  in
  runtime_observation_of_candidates ~runtime_id ~selected_model_raw
    ~attempts:(List.rev capture.attempts_rev)
    ~attempt_details_available:true
    ~attempt_details_source
    ~agent_core_internal_runtime_allowed
    ~streaming_ttfrc_ms:ttfrc
    ~streaming_inter_chunk_count:chunk_count
    ~streaming_inter_chunk_avg_ms:chunk_avg
    ~usage_scope
    ?request_context
    ()
