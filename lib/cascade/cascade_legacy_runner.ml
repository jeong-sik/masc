(** Cascade_legacy_runner — Cascade metrics types, observation building, and recording.

    Tracks per-cascade call counts, model selection distribution, fallback
    hops, and per-attempt latency/error detail. Aggregate counters stay
    in-process (mutable Hashtbl), while per-call observations are also
    appended to a dated JSONL audit log under [.masc/cascade_audit].

    @since God file decomposition — extracted from oas_worker.ml *)

(* ================================================================ *)
(* Inference defaults — delegated to OAS Constants.Inference_profile. *)
(* SSOT: agent_sdk/lib/llm_provider/constants.ml                     *)
(* See jeong-sik/oas#598, jeong-sik/me#915.                         *)
(* ================================================================ *)

let default_temperature =
  Llm_provider.Constants.Inference_profile.agent_default.temperature

let default_max_tokens =
  Llm_provider.Constants.Inference_profile.agent_default.max_tokens

(** Deterministic temperature (0.0) for evaluation, verification, routing.
    Delegates to OAS Inference_profile.deterministic. *)
let deterministic_temperature =
  Llm_provider.Constants.Inference_profile.deterministic.temperature

(** Worker defaults — SSOT for worker_oas.ml + worker_container.ml.
    temperature delegates to OAS Inference_profile.worker_default.
    top_p/top_k/min_p are provider-specific sampling params (not in OAS profiles). *)
let worker_temperature =
  Llm_provider.Constants.Inference_profile.worker_default.temperature
let worker_top_p = 0.95
let worker_top_k = 20
let worker_min_p = 0.0
let worker_max_tool_calls_per_turn = 12

(* ================================================================ *)
(* Cascade types                                                     *)
(* ================================================================ *)

type cascade_observation = {
  cascade_name : Keeper_cascade_profile.runtime_name;
  strategy : string option;
  configured_labels : string list;
  candidate_models : string list;
  primary_model : string option;
  selected_model : string option;
  selected_model_raw : string option;
  selected_index : int option;
  fallback_hops : int option;
  fallback_applied : bool;
  attempts : cascade_attempt list;
  fallback_events : cascade_fallback_event list;
  attempt_details_available : bool;
  attempt_details_source : string;
}

and cascade_attempt = {
  attempt_index : int;
  model_id : string;
  model_label : string option;
  latency_ms : int option;
  error : string option;
}

and cascade_fallback_event = {
  from_model_id : string;
  from_model_label : string option;
  to_model_id : string;
  to_model_label : string option;
  reason : string;
}

module StringMap = Map.Make(String)

let public_runtime_model_label = "runtime"

type cascade_counter = {
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
  last_attempts : cascade_attempt list;
  last_fallback_events : cascade_fallback_event list;
  last_attempt_details_available : bool;
  last_attempt_details_source : string option;
  last_used_at : float;
  selected_models : int StringMap.t;
  attempted_models : int StringMap.t;
  errored_models : int StringMap.t;
}

let cascade_max_keys = 256

let create_cascade_counter ~now () =
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

type cascade_eviction = {
  name : string;
  calls : int;
  last_used_at : float;
}

let find_cascade_eviction_candidate counters =
  StringMap.fold
    (fun name (counter : cascade_counter) best ->
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

(** Map provider_kind to cascade-label prefix (e.g. "claude", "gemini").
    Delegates to the current OAS registry helper so endpoint-distinct
    providers such as [glm], [glm-coding], and [openrouter] track the
    pinned agent_sdk behavior exactly. *)
let provider_name_of_config (cfg : Llm_provider.Provider_config.t) =
  Provider_adapter.provider_label_of_config cfg

let display_provider_name_of_config (cfg : Llm_provider.Provider_config.t) =
  Provider_adapter.display_provider_name_of_config cfg

let model_label_of_config (cfg : Llm_provider.Provider_config.t) =
  Provider_adapter.model_label_of_config cfg

let strip_latest_suffix s =
  let trimmed = String.trim s in
  if String.length trimmed > 7
     && String.sub trimmed (String.length trimmed - 7) 7 = ":latest"
  then String.sub trimmed 0 (String.length trimmed - 7)
  else trimmed

(* ================================================================ *)
(* Observation building                                              *)
(* ================================================================ *)

let cascade_observation_of_candidates ~cascade_name ?strategy ~configured_labels
    ~(candidate_count : int)
    ~selected_model_raw:(_ : string option)
    ?(attempts = [])
    ?(fallback_events = [])
    ?(attempt_details_available = false)
    ?(attempt_details_source = "opaque_named_cascade")
    () : cascade_observation =
  let candidate_models =
    List.init (max 0 candidate_count) (fun _ -> public_runtime_model_label)
  in
  let primary_model =
    match candidate_models with first :: _ -> Some first | [] -> None
  in
  let selected_index = None in
  let selected_model = None in
  let fallback_hops = Option.map (fun idx -> max 0 idx) selected_index in
  let fallback_applied =
    match fallback_hops with
    | Some hops -> hops > 0
    | None -> false
  in
  {
    cascade_name;
    strategy;
    configured_labels = [];
    candidate_models;
    primary_model;
    selected_model;
    selected_model_raw = None;
    selected_index;
    fallback_hops;
    fallback_applied;
    attempts;
    fallback_events;
    attempt_details_available;
    attempt_details_source;
  }

(* ================================================================ *)
(* Metrics capture callbacks                                         *)
(* ================================================================ *)

type cascade_metrics_capture = {
  mutable next_attempt_index : int;
  mutable attempts_rev : cascade_attempt list;
  mutable fallback_events_rev : cascade_fallback_event list;
}

let cascade_attempt_to_json (attempt : cascade_attempt) : Yojson.Safe.t =
  `Assoc
    [
      ("attempt_index", `Int attempt.attempt_index);
      ("model_id", `String public_runtime_model_label);
      ("model_label", `Null);
      ("latency_ms", Json_util.int_opt_to_json attempt.latency_ms);
      ("error", Json_util.string_opt_to_json attempt.error);
    ]

let cascade_fallback_event_to_json (event : cascade_fallback_event) :
    Yojson.Safe.t =
  `Assoc
    [
      ("from_model_id", `String public_runtime_model_label);
      ("from_model_label", `Null);
      ("to_model_id", `String public_runtime_model_label);
      ("to_model_label", `Null);
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

let record_attempt_start (capture : cascade_metrics_capture) ~model_id:_ =
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

(** [cascade_attempt_terminal_event_json] builds the structured details payload
    emitted to system_log when a cascade candidate reaches its terminal state
    (success: latency_ms set, error none; failure: error set). The shape is the
    contract for downstream log analysers and external operators looking for
    "why did the cascade exhaust" signals. Errors are recorded verbatim — no
    string-based classification at this layer (see #12817 spirit and the
    project memory rule "no string matching for classification"). *)
let cascade_attempt_terminal_event_json ?slot_release_at_phase
    ?productive_phase_elapsed_ms ?retry_phase_elapsed_ms ~model_id:_
    ~model_label:_
    ~latency_ms ~error () =
  let outcome = if Option.is_some error then "failure" else "success" in
  `Assoc
    [
      ("event", `String "cascade_attempt_terminal");
      ("model_id", `String public_runtime_model_label);
      ("model_label", `Null);
      ( "latency_ms",
        match latency_ms with Some n -> `Int n | None -> `Null );
      ("outcome", `String outcome);
      ( "error_message",
        match error with Some s -> `String s | None -> `Null );
      ( "slot_release_at_phase",
        match slot_release_at_phase with Some s -> `String s | None -> `Null );
      ( "productive_phase_elapsed_ms",
        match productive_phase_elapsed_ms with
        | Some n -> `Int n
        | None -> `Null );
      ( "retry_phase_elapsed_ms",
        match retry_phase_elapsed_ms with Some n -> `Int n | None -> `Null );
    ]

let log_cascade_attempt_terminal ~model_id ~model_label ~latency_ms ~error =
  let outcome = if Option.is_some error then "failure" else "success" in
  let details =
    cascade_attempt_terminal_event_json ~model_id ~model_label ~latency_ms
      ~error ()
  in
  let summary =
    Printf.sprintf
      "cascade candidate terminal: model=%s outcome=%s latency_ms=%s"
      public_runtime_model_label outcome
      (match latency_ms with Some n -> string_of_int n | None -> "n/a")
  in
  Log.Telemetry.emit Log.Info ~details summary

let ensure_terminal_attempt (capture : cascade_metrics_capture)
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
  log_cascade_attempt_terminal ~model_id ~model_label ~latency_ms ~error

let record_fallback_event (capture : cascade_metrics_capture)
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

let cascade_metrics_for_candidates ~candidate_count:(_ : int) () =
  let capture =
    { next_attempt_index = 0; attempts_rev = []; fallback_events_rev = [] }
  in
  let metrics =
    Oas_compat.Metrics.make
      ~on_cache_hit:(fun ~model_id ->
        Llm_metric_bridge.emit_cache_hit ~model_id)
      ~on_cache_miss:(fun ~model_id ->
        Llm_metric_bridge.emit_cache_miss ~model_id)
      ~on_request_start:(fun ~model_id ->
        record_attempt_start capture ~model_id;
        Llm_metric_bridge.emit_request_start ~model_id)
      ~on_request_end:(fun ~model_id ~latency_ms ->
        ensure_terminal_attempt capture ~model_id ~latency_ms ~error:None;
        (* Forward to Prometheus so per-model latency is visible on
           the dashboard. Without this, the cascade capture records
           latency internally but never exports it — the global
           Llm_metric_bridge sink is not consulted because this
           per-call metrics object takes precedence. *)
        match latency_ms with
        | Some latency_ms ->
            Llm_metric_bridge.emit_request_latency ~model_id ~latency_ms
        | None -> ())
      ~on_error:(fun ~model_id ~error ->
        ensure_terminal_attempt capture ~model_id ~latency_ms:None
          ~error:(Some error);
        Llm_metric_bridge.emit_error ~model_id ~error)
      ~on_capability_drop:(fun ~model_id ~field ->
        (* The explicit cascade metrics object bypasses the global
           Llm_metric_bridge sink, so capability-drop telemetry must be
           forwarded here just like latency and HTTP status. *)
        Llm_metric_bridge.emit_capability_drop ~model_id ~field)
      ~on_http_status:(fun ~provider ~model_id ~status ->
        (* Forward HTTP status to the Prometheus counter. When callers
           pass this per-call metrics sink explicitly (cascade
           observation path), OAS does not consult the global
           Llm_metric_bridge sink, so we must re-emit here to avoid
           blackholing provider counters for captured turns.
           Delegating to [Llm_metric_bridge.emit_http_status] keeps
           the label shape a single source of truth. *)
        Llm_metric_bridge.emit_http_status ~provider ~model_id ~status)
      ~on_retry:(fun ~provider ~model_id ~attempt ->
        Llm_metric_bridge.emit_retry ~provider ~model_id ~attempt)
      ~on_token_usage:(fun ~provider ~model_id ~input_tokens ~output_tokens ->
        Llm_metric_bridge.emit_token_usage
          ~provider ~model_id ~input_tokens ~output_tokens)
      ()
  in
  (capture, metrics)

let cascade_observation_with_metrics ~cascade_name ?strategy ~configured_labels
    ~(candidate_count : int)
    ~(selected_model_raw : string option) ~(capture : cascade_metrics_capture) () =
  cascade_observation_of_candidates ~cascade_name ?strategy ~configured_labels
    ~candidate_count ~selected_model_raw
    ~attempts:(List.rev capture.attempts_rev)
    ~fallback_events:(List.rev capture.fallback_events_rev)
    ~attempt_details_available:true
    ~attempt_details_source:"oas_metrics_callbacks"
    ()

(* ================================================================ *)
(* JSON serialization                                                *)
(* ================================================================ *)

let cascade_observation_to_json (obs : cascade_observation) : Yojson.Safe.t =
  let cascade_name =
    Keeper_cascade_profile.runtime_name_to_string obs.cascade_name
  in
  `Assoc
    [
      ("cascade_name", `String cascade_name);
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
        `List (List.map cascade_attempt_to_json obs.attempts) );
      ( "fallback_events",
        `List
          (List.map cascade_fallback_event_to_json obs.fallback_events) );
      ("attempt_details_available", `Bool obs.attempt_details_available);
      ("attempt_details_source", `String obs.attempt_details_source);
    ]

let get_cascade_audit_store store_opt =
  match store_opt with
  | Some store -> Some store
  | None ->
      let base_path = Env_config_core.base_path () in
      let dir =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "cascade_audit"
      in
      (match Dated_jsonl.create ~base_dir:dir () with
      | store -> Some store
      | exception (Eio.Cancel.Cancelled _ as e) -> raise e
      | exception exn ->
          (* Iter 47: tick counter so audit-subsystem health is
             observable.  Audit failure here disables the subsystem
             for the process lifetime — operators need to know. *)
          Cascade_metrics.on_cascade_audit_failure ~stage:"store_creation";
          Log.Misc.warn "cascade audit store creation failed: %s"
            (Printexc.to_string exn);
          None)

let cascade_outcome_to_string = function
  | `Success -> "success"
  | `Failure -> "failure"
  | `Rejected -> "rejected"

(* Promotes the most-recent fallback event reason as a top-level field for
   first-class aggregation/alerting (issue #11081).  Last (not first) event
   is chosen because for terminal Failure/Rejected outcomes the final event's
   reason is the actual cause of exhaustion; the first event reflects only
   the initial fallback trigger.  Empty list -> null. *)
let top_level_reason_of_observation (observation : cascade_observation option) =
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

let cascade_audit_json ~now ~keeper_name ~cascade_name ~observation ~outcome =
  let cascade_name =
    Keeper_cascade_profile.runtime_name_to_string cascade_name
  in
  `Assoc
    [
      ("ts", `Float now);
      ("keeper_name", keeper_name_to_json keeper_name);
      ("cascade_name", `String cascade_name);
      ("outcome", `String (cascade_outcome_to_string outcome));
      ("top_level_reason", top_level_reason_of_observation observation);
      ( "observation",
        match observation with
        | Some obs -> cascade_observation_to_json obs
        | None -> `Null );
    ]

let record_cascade_audit store_opt ~now ~keeper_name ~cascade_name ~observation
    ~outcome =
  let cascade_name_string =
    Keeper_cascade_profile.runtime_name_to_string cascade_name
  in
  match store_opt with
  | None -> ()
  | Some store ->
      (try
         Dated_jsonl.append store
           (cascade_audit_json ~now ~keeper_name ~cascade_name ~observation
              ~outcome)
       with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
          (* Iter 47: tick counter per-record append failure rate
             alertable.  Single-event audit loss compounds over
             time for post-incident analysis. *)
          Cascade_metrics.on_cascade_audit_failure ~stage:"append";
          Log.Misc.warn "cascade audit append failed cascade=%s error=%s"
            cascade_name_string (Printexc.to_string exn))

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

let attempt_model_display (attempt : cascade_attempt) =
  match attempt.model_label with
  | Some label when String.trim label <> "" -> label
  | _ -> attempt.model_id

type msg =
  | Record_cascade of {
      keeper_name : string option;
      cascade_name : Keeper_cascade_profile.runtime_name;
      observation : cascade_observation option;
      outcome : [ `Success | `Failure | `Rejected ];
      now : float;
    }
  | Get_metrics_json of Yojson.Safe.t Eio.Promise.u
  | Reset_counters_for_test

type state = {
  counters : cascade_counter StringMap.t;
  audit_store : Dated_jsonl.t option;
}

let stream = Eio.Stream.create 1024

let handle_record state ~now ~keeper_name ~cascade_name ~observation ~outcome =
  let cascade_name_string =
    Keeper_cascade_profile.runtime_name_to_string cascade_name
  in
  let counters = state.counters in
  let counter, counters, evicted =
    match StringMap.find_opt cascade_name_string counters with
    | Some c -> (c, counters, None)
    | None ->
        let (counters_after_evict, evicted) =
          if StringMap.cardinal counters >= cascade_max_keys then
            match find_cascade_eviction_candidate counters with
            | Some candidate -> (StringMap.remove candidate.name counters, Some candidate)
            | None -> (counters, None)
          else (counters, None)
        in
        let c = create_cascade_counter ~now () in
        (c, StringMap.add cascade_name_string c counters_after_evict, evicted)
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
         (cascade name, age, etc.); metric makes rate aggregation
         tractable. *)
      Cascade_metrics.on_cascade_metrics_eviction ();
      Log.Misc.warn
        "cascade metrics evicted key=%s calls=%d last_used_at=%.3f to admit %s (limit=%d)"
        candidate.name candidate.calls candidate.last_used_at cascade_name_string
        cascade_max_keys)
    evicted;
  let audit_store_next = get_cascade_audit_store state.audit_store in
  record_cascade_audit audit_store_next ~now ~keeper_name ~cascade_name
    ~observation ~outcome;
  {
    counters = StringMap.add cascade_name_string counter counters;
    audit_store = audit_store_next;
  }

let handle_get_metrics state p =
  let counters = state.counters in
  let entries =
    StringMap.fold
      (fun name (c : cascade_counter) acc ->
        let error_rate =
          if c.calls > 0 then
            float_of_int (c.failures + c.rejected) /. float_of_int c.calls
          else
            0.0
        in
        `Assoc
          [
            ("cascade_name", `String name);
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
              `List (List.map cascade_attempt_to_json c.last_attempts) );
            ( "last_fallback_events",
              `List
                (List.map cascade_fallback_event_to_json c.last_fallback_events) );
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
         let get_calls j = Yojson.Safe.Util.(j |> member "calls" |> to_int) in
         Int.compare (get_calls b) (get_calls a))
       entries)
  in
  Eio.Promise.resolve p json

let run_actor () =
  let rec loop state =
    match Eio.Stream.take stream with
    | Record_cascade { keeper_name; cascade_name; observation; outcome; now } ->
        loop
          (handle_record state ~now ~keeper_name ~cascade_name ~observation
             ~outcome)
    | Get_metrics_json p ->
        handle_get_metrics state p;
        loop state
    | Reset_counters_for_test ->
        loop { counters = StringMap.empty; audit_store = None }
  in
  loop { counters = StringMap.empty; audit_store = None }

let start_actor_if_needed ~sw =
  Eio.Fiber.fork ~sw run_actor

let record_cascade ?keeper_name ~observation ~cascade_name ~outcome () =
  let now = Time_compat.now () in
  Eio.Stream.add stream
    (Record_cascade { keeper_name; cascade_name; observation; outcome; now })

let cascade_metrics_json () =
  let p, u = Eio.Promise.create () in
  Eio.Stream.add stream (Get_metrics_json u);
  Eio.Promise.await p

let reset_cascade_counters_for_test () =
  Eio.Stream.add stream Reset_counters_for_test
