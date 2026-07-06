(** Runtime_observation — Runtime metrics types, observation building, and recording.

    Tracks per-runtime call counts, model selection distribution, fallback
    hops, and per-attempt latency/error detail. Aggregate counters stay
    in-process (mutable Hashtbl), while per-call observations are also
    appended to a dated JSONL audit log under [.masc/runtime_audit].

    @since God file decomposition — extracted from oas_worker.ml *)

(* ================================================================ *)
(* Runtime types                                                     *)
(* ================================================================ *)

type runtime_observation = {
  runtime_id : string;
  strategy : string option;
  configured_labels : string list;
  candidate_models : string list;
  primary_model : string option;
  selected_model : string option;
  selected_model_raw : string option;
  selected_index : int option;
  fallback_hops : int option;
  fallback_applied : bool;
  attempts : runtime_attempt list;
  fallback_events : runtime_fallback_event list;
  attempt_details_available : bool;
  attempt_details_source : string;
  oas_internal_runtime_allowed : bool;
  streaming_ttfrc_ms : float option;
  streaming_inter_chunk_count : int;
  streaming_inter_chunk_avg_ms : float option;
}

and runtime_attempt = {
  attempt_index : int;
  model_id : string;
  model_label : string option;
  latency_ms : int option;
  error : string option;
}

and runtime_fallback_event = {
  from_model_id : string;
  from_model_label : string option;
  to_model_id : string;
  to_model_label : string option;
  reason : string;
}

module StringMap = Set_util.StringMap

(* RFC-0132 PR-2: runtime observation OAS/dashboard surface = external boundary; redact via SSOT. *)
let public_runtime_model_label =
  Boundary_redaction.to_string Boundary_redaction.runtime_model_label

type runtime_counter = {
  calls : int;
  successes : int;
  failures : int;
  rejected : int;
  fallback_calls : int;
  total_attempts : int;
  total_fallback_events : int;
  last_selected_model : string option;
  last_selected_index : int option;
  last_candidate_models : string list;
  last_attempts : runtime_attempt list;
  last_fallback_events : runtime_fallback_event list;
  last_attempt_details_available : bool;
  last_attempt_details_source : string option;
  last_used_at : float;
  selected_models : int StringMap.t;
  attempted_models : int StringMap.t;
  errored_models : int StringMap.t;
}

let runtime_max_keys = 256

let create_runtime_counter ~now () =
  {
    calls = 0;
    successes = 0;
    failures = 0;
    rejected = 0;
    fallback_calls = 0;
    total_attempts = 0;
    total_fallback_events = 0;
    last_selected_model = None;
    last_selected_index = None;
    last_candidate_models = [];
    last_attempts = [];
    last_fallback_events = [];
    last_attempt_details_available = false;
    last_attempt_details_source = None;
    last_used_at = now;
    selected_models = StringMap.empty;
    attempted_models = StringMap.empty;
    errored_models = StringMap.empty;
  }

type runtime_eviction = {
  name : string;
  calls : int;
  last_used_at : float;
}

let find_runtime_eviction_candidate counters =
  StringMap.fold
    (fun name (counter : runtime_counter) best ->
      match best with
      | None ->
          Some { name; calls = counter.calls; last_used_at = counter.last_used_at }
      | Some current ->
          if counter.calls < current.calls
             || (counter.calls = current.calls
                 && counter.last_used_at < current.last_used_at)
          then
            Some
              { name; calls = counter.calls; last_used_at = counter.last_used_at }
          else
            best)
    counters None


(* ================================================================ *)
(* Provider label helpers                                            *)
(* ================================================================ *)

(** Map provider_kind to a runtime-label prefix. Delegates to the
    current OAS registry helper so endpoint-distinct providers track
    the pinned agent_sdk behavior. The function does not enumerate
    specific providers; the registry resolves them. *)
let provider_name_of_config (cfg : Llm_provider.Provider_config.t) =
  match Agent_sdk.Provider_runtime_binding.binding_for_provider_config cfg with
  | Some binding -> binding.Agent_sdk.Provider_runtime_binding.id
  | None -> Llm_provider.Provider_registry.provider_name_of_config cfg

let display_provider_name_of_config (cfg : Llm_provider.Provider_config.t) =
  provider_name_of_config cfg

let model_label_of_config (cfg : Llm_provider.Provider_config.t) =
  Printf.sprintf "%s:%s" (display_provider_name_of_config cfg) cfg.model_id

let strip_latest_suffix s =
  let trimmed = String.trim s in
  if String.length trimmed > 7
     && String.sub trimmed (String.length trimmed - 7) 7 = ":latest"
  then String.sub trimmed 0 (String.length trimmed - 7)
  else trimmed

(* ================================================================ *)
(* Observation building                                              *)
(* ================================================================ *)

let runtime_observation_of_candidates ~runtime_id ?strategy ~configured_labels
    ~(candidate_count : int)
    ~(selected_model_raw : string option)
    ?(attempts = [])
    ?(fallback_events = [])
    ?(attempt_details_available = false)
    ?(attempt_details_source = "opaque_named_runtime")
    ?(oas_internal_runtime_allowed = false)
    ?(streaming_ttfrc_ms = None)
    ?(streaming_inter_chunk_count = 0)
    ?(streaming_inter_chunk_avg_ms = None)
    () : runtime_observation =
  let candidate_models =
    List.init (max 0 candidate_count) (fun _ -> public_runtime_model_label)
  in
  let primary_model =
    match candidate_models with first :: _ -> Some first | [] -> None
  in
  let selected_index = None in
  (* Thread the caller-supplied raw model attribution into both fields.
     Without this, success rows lose model attribution at construction
     time and downstream consumers (model_inference_metrics
     parse_telemetry_entry, execution receipts, composite observer)
     drop the row as Missing_success_model. Public-surface redaction to
     [public_runtime_model_label] happens at the redacted JSON emitter
     layer, not at observation construction. *)
  let selected_model = selected_model_raw in
  let fallback_hops = Option.map (fun idx -> max 0 idx) selected_index in
  let fallback_applied =
    match fallback_hops with
    | Some hops -> hops > 0
    | None -> false
  in
  {
    runtime_id;
    strategy;
    configured_labels = [];
    candidate_models;
    primary_model;
    selected_model;
    selected_model_raw;
    selected_index;
    fallback_hops;
    fallback_applied;
    attempts;
    fallback_events;
    attempt_details_available;
    attempt_details_source;
    oas_internal_runtime_allowed;
    streaming_ttfrc_ms;
    streaming_inter_chunk_count;
    streaming_inter_chunk_avg_ms;
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
  mutable fallback_events_rev : runtime_fallback_event list;
  mutable streaming : streaming_metrics_capture;
}

(* Non-redacted JSON encoders for the internal audit log
   (runtime_observation_to_json → record_runtime_audit). Sibling fields
   in the same observation envelope (selected_model, primary_model,
   candidate_models) are already emitted as real strings; the per-attempt
   and per-fallback model_id were the only fields collapsed to the
   [public_runtime] placeholder by #15040. Sibling parity restored.

   The redacted variants for external boundaries (keeper metrics consumed
   by dashboard/OAS) live in lib/keeper/keeper_unified_metrics.ml as
   [redacted_runtime_attempt_to_json] etc. and intentionally omit
   model_id/model_label entirely. Those are not touched here. *)
let runtime_attempt_to_json (attempt : runtime_attempt) : Yojson.Safe.t =
  `Assoc
    [
      ("attempt_index", `Int attempt.attempt_index);
      ("model_id", `String attempt.model_id);
      ("model_label", Json_util.string_opt_to_json attempt.model_label);
      ("latency_ms", Json_util.int_opt_to_json attempt.latency_ms);
      ("error", Json_util.string_opt_to_json attempt.error);
    ]

let runtime_fallback_event_to_json (event : runtime_fallback_event) :
    Yojson.Safe.t =
  `Assoc
    [
      ("from_model_id", `String event.from_model_id);
      ("from_model_label", Json_util.string_opt_to_json event.from_model_label);
      ("to_model_id", `String event.to_model_id);
      ("to_model_label", Json_util.string_opt_to_json event.to_model_label);
      ("reason", `String event.reason);
    ]

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
let runtime_attempt_terminal_event_json ?slot_release_at_phase
    ?productive_phase_elapsed_ms ?retry_phase_elapsed_ms ~model_id:_
    ~model_label:_
    ~latency_ms ~error () =
  let outcome = if Option.is_some error then "failure" else "success" in
  `Assoc
    [
      ("event", `String "runtime_attempt_terminal");
      ("model_id", `String public_runtime_model_label);
      ("model_label", `Null);
      ( "latency_ms", Json_util.int_opt_to_json latency_ms );
      ("outcome", `String outcome);
      ( "error_message", Json_util.string_opt_to_json error );
      ( "slot_release_at_phase", Json_util.string_opt_to_json slot_release_at_phase );
      ( "productive_phase_elapsed_ms", Json_util.int_opt_to_json productive_phase_elapsed_ms );
      ( "retry_phase_elapsed_ms", Json_util.int_opt_to_json retry_phase_elapsed_ms );
    ]

let log_runtime_attempt_terminal ~model_id ~model_label ~latency_ms ~error =
  let outcome = if Option.is_some error then "failure" else "success" in
  let details =
    runtime_attempt_terminal_event_json ~model_id ~model_label ~latency_ms
      ~error ()
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

let record_fallback_event (capture : runtime_metrics_capture)
    ~from_model:_ ~to_model:_ ~(reason : string) =
  capture.fallback_events_rev <-
    {
      from_model_id = public_runtime_model_label;
      from_model_label = None;
      to_model_id = public_runtime_model_label;
      to_model_label = None;
      reason;
    }
    :: capture.fallback_events_rev

let empty_streaming_capture () : streaming_metrics_capture =
  { ttfrc_ms = None; inter_chunk_count = 0; inter_chunk_total_ms = 0.0 }

let streaming_metrics_of_capture (s : streaming_metrics_capture) =
  let avg =
    if s.inter_chunk_count > 0
    then Some (s.inter_chunk_total_ms /. Float.of_int s.inter_chunk_count)
    else None
  in
  (s.ttfrc_ms, s.inter_chunk_count, avg)

let runtime_metrics_for_candidates ~candidate_count:(_ : int) () =
  let capture =
    { next_attempt_index = 0
    ; attempts_rev = []
    ; fallback_events_rev = []
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
      on_error = (fun ~model_id ~error ->
        ensure_terminal_attempt capture ~model_id ~latency_ms:None
          ~error:(Some error));
      on_capability_drop = (fun ~model_id:_ ~field:_ -> ());
      on_http_status = (fun ~provider:_ ~model_id:_ ~status:_ -> ());
      on_circuit_state =
        (fun ~provider:_ ~model_id:_ ~provider_key:_ ~state:_ -> ());
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

let runtime_observation_with_metrics ~runtime_id ?strategy ~configured_labels
    ~(candidate_count : int)
    ~(selected_model_raw : string option) ~(capture : runtime_metrics_capture)
    ?(attempt_details_source = "oas_metrics_callbacks")
    ?(oas_internal_runtime_allowed = false)
    () =
  let ttfrc, chunk_count, chunk_avg =
    streaming_metrics_of_capture capture.streaming
  in
  runtime_observation_of_candidates ~runtime_id ?strategy ~configured_labels
    ~candidate_count ~selected_model_raw
    ~attempts:(List.rev capture.attempts_rev)
    ~fallback_events:(List.rev capture.fallback_events_rev)
    ~attempt_details_available:true
    ~attempt_details_source
    ~oas_internal_runtime_allowed
    ~streaming_ttfrc_ms:ttfrc
    ~streaming_inter_chunk_count:chunk_count
    ~streaming_inter_chunk_avg_ms:chunk_avg
    ()

(* ================================================================ *)
(* JSON serialization                                                *)
(* ================================================================ *)

let runtime_observation_to_json (obs : runtime_observation) : Yojson.Safe.t =
  let runtime_id =
    obs.runtime_id
  in
  `Assoc
    [
      ("runtime_id", `String runtime_id);
      ("strategy", Json_util.string_opt_to_json obs.strategy);
      ( "configured_labels",
        `List (List.map (fun label -> `String label) obs.configured_labels) );
      ( "candidate_models",
        `List (List.map (fun label -> `String label) obs.candidate_models) );
      ("primary_model", Json_util.string_opt_to_json obs.primary_model);
      ("selected_model", Json_util.string_opt_to_json obs.selected_model);
      ("selected_model_raw", Json_util.string_opt_to_json obs.selected_model_raw);
      ("selected_index", Json_util.int_opt_to_json obs.selected_index);
      ("fallback_hops", Json_util.int_opt_to_json obs.fallback_hops);
      ("fallback_applied", `Bool obs.fallback_applied);
      ( "attempts",
        `List (List.map runtime_attempt_to_json obs.attempts) );
      ( "fallback_events",
        `List
          (List.map runtime_fallback_event_to_json obs.fallback_events) );
      ("attempt_details_available", `Bool obs.attempt_details_available);
      ("attempt_details_source", `String obs.attempt_details_source);
      ("oas_internal_runtime_allowed", `Bool obs.oas_internal_runtime_allowed);
      ("streaming_ttfrc_ms", Json_util.float_opt_to_json obs.streaming_ttfrc_ms);
      ("streaming_inter_chunk_count", `Int obs.streaming_inter_chunk_count);
      ("streaming_inter_chunk_avg_ms", Json_util.float_opt_to_json obs.streaming_inter_chunk_avg_ms);
    ]

let get_runtime_audit_store store_opt =
  match store_opt with
  | Some store -> Some store
  | None ->
      let base_path = Env_config_core.base_path () in
      let dir =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "runtime_audit"
      in
      (match Dated_jsonl.create ~base_dir:dir () with
      | store -> Some store
      | exception (Eio.Cancel.Cancelled _ as e) -> raise e
      | exception exn ->
          (* Iter 47: tick counter so audit-subsystem health is
             observable.  Audit failure here disables the subsystem
             for the process lifetime — operators need to know. *)
          Runtime_metrics.on_runtime_audit_failure ~stage:"store_creation";
          Log.Misc.warn "runtime audit store creation failed: %s"
            (Printexc.to_string exn);
          None)

let runtime_outcome_to_string = function
  | `Success -> "success"
  | `Failure -> "failure"
  | `Rejected -> "rejected"

(* Promotes the most-recent fallback event reason as a top-level field for
   first-class aggregation/alerting (issue #11081).  Last (not first) event
   is chosen because for terminal Failure/Rejected outcomes the final event's
   reason is the actual cause of exhaustion; the first event reflects only
   the initial fallback trigger.  Empty list -> null. *)
let top_level_reason_of_observation (observation : runtime_observation option) =
  match observation with
  | None -> `Null
  | Some obs ->
      (match List.rev obs.fallback_events with
      | last :: _ -> `String last.reason
      | [] -> `Null)

let keeper_name_to_json keeper_name =
  match keeper_name with
  | Some name when String.trim name <> "" -> `String name
  | _ -> `Null

let runtime_audit_json ~now ~keeper_name ~runtime_id ~observation ~outcome =
  let runtime_id =
    runtime_id
  in
  `Assoc
    [
      ("ts", `Float now);
      ("keeper_name", keeper_name_to_json keeper_name);
      ("runtime_id", `String runtime_id);
      ("outcome", `String (runtime_outcome_to_string outcome));
      ("top_level_reason", top_level_reason_of_observation observation);
      ( "observation",
        match observation with
        | Some obs -> runtime_observation_to_json obs
        | None -> `Null );
    ]

let record_runtime_audit store_opt ~now ~keeper_name ~runtime_id ~observation
    ~outcome =
  let runtime_id_string =
    runtime_id
  in
  match store_opt with
  | None -> ()
  | Some store ->
      (match
         Dated_jsonl.append_result store
           (runtime_audit_json ~now ~keeper_name ~runtime_id ~observation
              ~outcome)
       with
      | Ok () -> ()
      | Error error ->
          (* Iter 47: tick counter per-record append failure rate
             alertable.  Single-event audit loss compounds over
             time for post-incident analysis. *)
          Runtime_metrics.on_runtime_audit_failure ~stage:"append";
          Log.Misc.warn "runtime audit append failed runtime=%s error=%s"
            runtime_id_string error)

(* ================================================================ *)
(* Aggregate metrics recording                                       *)
(* ================================================================ *)

let increment_counter map key =
  let count = Option.value ~default:0 (StringMap.find_opt key map) in
  StringMap.add key (count + 1) map

let distribution_json map =
  StringMap.fold
    (fun model count acc ->
      `Assoc [ ("model", `String model); ("count", `Int count) ] :: acc)
    map []
  |> List.sort (fun left right ->
         let count_of = function
           | `Assoc fields ->
               (match List.assoc_opt "count" fields with
               | Some (`Int count) -> count
               | _ -> 0)
           | _ -> 0
         in
         Int.compare (count_of right) (count_of left))

let attempt_model_display (attempt : runtime_attempt) =
  match attempt.model_label with
  | Some label when String.trim label <> "" -> label
  | _ -> attempt.model_id

type msg =
  | Record_runtime of {
      keeper_name : string option;
      runtime_id : string;
      observation : runtime_observation option;
      outcome : [ `Success | `Failure | `Rejected ];
      now : float;
    }
  | Get_metrics_json of Yojson.Safe.t Eio.Promise.u
  | Reset_counters_for_test

type state = {
  counters : runtime_counter StringMap.t;
  audit_store : Dated_jsonl.t option;
}

let stream = Eio.Stream.create 1024

let handle_record state ~now ~keeper_name ~runtime_id ~observation ~outcome =
  let runtime_id_string =
    runtime_id
  in
  let counters = state.counters in
  let counter, counters, evicted =
    match StringMap.find_opt runtime_id_string counters with
    | Some c -> (c, counters, None)
    | None ->
        let (counters_after_evict, evicted) =
          if StringMap.cardinal counters >= runtime_max_keys then
            match find_runtime_eviction_candidate counters with
            | Some candidate -> (StringMap.remove candidate.name counters, Some candidate)
            | None -> (counters, None)
          else (counters, None)
        in
        let c = create_runtime_counter ~now () in
        (c, StringMap.add runtime_id_string c counters_after_evict, evicted)
  in
  let counter = { counter with calls = counter.calls + 1; last_used_at = now } in
  let counter =
    match observation with
    | Some obs ->
        let counter = { counter with
          last_candidate_models = obs.candidate_models;
          last_selected_model = obs.selected_model;
          last_selected_index = obs.selected_index;
          last_attempts = obs.attempts;
          last_fallback_events = obs.fallback_events;
          last_attempt_details_available = obs.attempt_details_available;
          last_attempt_details_source = Some obs.attempt_details_source;
          fallback_calls = if obs.fallback_applied then counter.fallback_calls + 1 else counter.fallback_calls;
          total_attempts = counter.total_attempts + List.length obs.attempts;
          total_fallback_events = counter.total_fallback_events + List.length obs.fallback_events;
        } in
        let counter =
          match obs.selected_model with
          | Some model when String.trim model <> "" ->
              { counter with selected_models = increment_counter counter.selected_models model }
          | _ -> counter
        in
        List.fold_left (fun c attempt ->
          let model = attempt_model_display attempt in
          let c = { c with attempted_models = increment_counter c.attempted_models model } in
          match attempt.error with
          | Some _ -> { c with errored_models = increment_counter c.errored_models model }
          | None -> c
        ) counter obs.attempts
    | None -> counter
  in
  let counter =
    match outcome with
    | `Success -> { counter with successes = counter.successes + 1 }
    | `Failure -> { counter with failures = counter.failures + 1 }
    | `Rejected -> { counter with rejected = counter.rejected + 1 }
  in
  Option.iter
    (fun candidate ->
      (* Iter 45: counter ticks on every eviction so the rate is
         alertable.  WARN log already prints per-eviction detail
         (runtime name, age, etc.); metric makes rate aggregation
         tractable. *)
      Runtime_metrics.on_runtime_metrics_eviction ();
      Log.Misc.warn
        "runtime metrics evicted key=%s calls=%d last_used_at=%.3f to admit %s (limit=%d)"
        candidate.name candidate.calls candidate.last_used_at runtime_id_string
        runtime_max_keys)
    evicted;
  let audit_store_next = get_runtime_audit_store state.audit_store in
  record_runtime_audit audit_store_next ~now ~keeper_name ~runtime_id
    ~observation ~outcome;
  {
    counters = StringMap.add runtime_id_string counter counters;
    audit_store = audit_store_next;
  }

let handle_get_metrics state p =
  let counters = state.counters in
  let entries =
    StringMap.fold
      (fun name (c : runtime_counter) acc ->
        let error_rate =
          if c.calls > 0 then
            float_of_int (c.failures + c.rejected) /. float_of_int c.calls
          else
            0.0
        in
        `Assoc
          [
            ("runtime_id", `String name);
            ("calls", `Int c.calls);
            ("successes", `Int c.successes);
            ("failures", `Int c.failures);
            ("rejected", `Int c.rejected);
            ("fallback_calls", `Int c.fallback_calls);
            ("total_attempts", `Int c.total_attempts);
            ("total_fallback_events", `Int c.total_fallback_events);
            ("last_selected_model", Json_util.string_opt_to_json c.last_selected_model);
            ("last_selected_index", Json_util.int_opt_to_json c.last_selected_index);
            ( "last_candidate_models",
              `List (List.map (fun model -> `String model) c.last_candidate_models) );
            ( "last_attempts",
              `List (List.map runtime_attempt_to_json c.last_attempts) );
            ( "last_fallback_events",
              `List
                (List.map runtime_fallback_event_to_json c.last_fallback_events) );
            ("last_attempt_details_available", `Bool c.last_attempt_details_available);
            ( "last_attempt_details_source",
              Json_util.string_opt_to_json c.last_attempt_details_source );
            ("selected_models", `List (distribution_json c.selected_models));
            ("attempted_models", `List (distribution_json c.attempted_models));
            ("errored_models", `List (distribution_json c.errored_models));
            ("error_rate", `Float error_rate);
          ]
        :: acc)
      counters []
  in
  let json = `List
    (List.sort
       (fun a b ->
         let get_calls j = Json_util.get_int j "calls" |> Option.value ~default:0 in
         Int.compare (get_calls b) (get_calls a))
       entries)
  in
  Eio.Promise.resolve p json

let run_actor () =
  let rec loop state =
    match Eio.Stream.take stream with
    | Record_runtime { keeper_name; runtime_id; observation; outcome; now } ->
        loop
          (handle_record state ~now ~keeper_name ~runtime_id ~observation
             ~outcome)
    | Get_metrics_json p ->
        handle_get_metrics state p;
        loop state
    | Reset_counters_for_test ->
        loop { counters = StringMap.empty; audit_store = None }
  in
  loop { counters = StringMap.empty; audit_store = None }

let start_actor_if_needed ~sw =
  Eio.Fiber.fork_daemon ~sw run_actor

let record_runtime ?keeper_name ~observation ~runtime_id ~outcome () =
  let now = Time_compat.now () in
  Eio.Stream.add stream
    (Record_runtime { keeper_name; runtime_id; observation; outcome; now })

let runtime_metrics_json () =
  let p, u = Eio.Promise.create () in
  Eio.Stream.add stream (Get_metrics_json u);
  Eio.Promise.await p

let reset_runtime_counters_for_test () =
  Eio.Stream.add stream Reset_counters_for_test
