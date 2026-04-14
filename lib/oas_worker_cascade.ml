(** Oas_worker_cascade — Cascade metrics types, observation building, and recording.

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
  cascade_name : string;
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

type cascade_counter = {
  mutable calls : int;
  mutable successes : int;
  mutable failures : int;
  mutable rejected : int;
  mutable fallback_calls : int;
  mutable total_attempts : int;
  mutable total_fallback_events : int;
  mutable last_selected_model : string option;
  mutable last_selected_index : int option;
  mutable last_candidate_models : string list;
  mutable last_attempts : cascade_attempt list;
  mutable last_fallback_events : cascade_fallback_event list;
  mutable last_attempt_details_available : bool;
  mutable last_attempt_details_source : string option;
  mutable last_used_at : float;
  selected_models : (string, int) Hashtbl.t;
  attempted_models : (string, int) Hashtbl.t;
  errored_models : (string, int) Hashtbl.t;
}

let cascade_counters : (string, cascade_counter) Hashtbl.t = Hashtbl.create 8
let cascade_counters_mu = Eio.Mutex.create ()
let cascade_max_keys = 256
let cascade_audit_store_ref : Dated_jsonl.t option ref = ref None

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
    selected_models = Hashtbl.create 8;
    attempted_models = Hashtbl.create 8;
    errored_models = Hashtbl.create 8;
  }

type cascade_eviction = {
  name : string;
  calls : int;
  last_used_at : float;
}

let find_cascade_eviction_candidate () =
  Hashtbl.fold
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
    cascade_counters None

let reset_cascade_counters_for_test () =
  Eio.Mutex.use_rw ~protect:true cascade_counters_mu (fun () ->
    Hashtbl.clear cascade_counters);
  cascade_audit_store_ref := None

(* ================================================================ *)
(* Provider label helpers                                            *)
(* ================================================================ *)

(** Map provider_kind to cascade-label prefix (e.g. "claude", "gemini").
    Delegates to Provider_adapter.cascade_prefix_of_provider_kind.
    Note: reverse-mapping from provider_kind is inherently lossy —
    OpenAI_compat conflates codex/openrouter/llama into one kind.
    TODO: pass the provider name from cascade config parsing instead of
    reverse-mapping from provider_kind to avoid this ambiguity. *)
let provider_name_of_config (cfg : Llm_provider.Provider_config.t) =
  Provider_adapter.cascade_prefix_of_provider_kind cfg.kind

let model_label_of_config (cfg : Llm_provider.Provider_config.t) =
  Printf.sprintf "%s:%s" (provider_name_of_config cfg) cfg.model_id

let model_label_option_of_model_id
    ~(candidate_cfgs : Llm_provider.Provider_config.t list)
    (model_id : string) =
  let matches =
    candidate_cfgs
    |> List.filter (fun (cfg : Llm_provider.Provider_config.t) ->
           String.equal cfg.model_id model_id)
    |> List.map model_label_of_config
    |> List.sort_uniq String.compare
  in
  match matches with
  | [ label ] -> Some label
  | _ -> None

let strip_latest_suffix s =
  let trimmed = String.trim s in
  if String.length trimmed > 7
     && String.sub trimmed (String.length trimmed - 7) 7 = ":latest"
  then String.sub trimmed 0 (String.length trimmed - 7)
  else trimmed

let selected_index_of_model ~(selected_model_raw : string option)
    ~(candidate_cfgs : Llm_provider.Provider_config.t list) =
  match selected_model_raw with
  | None -> None
  | Some raw ->
      let selected = strip_latest_suffix raw in
      let rec loop idx = function
        | [] -> None
        | cfg :: rest ->
            let candidate_label = model_label_of_config cfg |> strip_latest_suffix in
            let candidate_model = strip_latest_suffix cfg.model_id in
            if selected = candidate_label || selected = candidate_model then Some idx
            else loop (idx + 1) rest
      in
      loop 0 candidate_cfgs

let normalized_selected_model ~(selected_model_raw : string option)
    ~(candidate_cfgs : Llm_provider.Provider_config.t list)
    ~(candidate_models : string list) ~(selected_index : int option) =
  match selected_index with
  | Some idx -> List.nth_opt candidate_models idx
  | None ->
      (match selected_model_raw with
      | None -> None
      | Some raw ->
          let trimmed = String.trim raw in
          if trimmed = "" then None
          else
            let stripped = strip_latest_suffix trimmed in
            match model_label_option_of_model_id ~candidate_cfgs stripped with
            | Some label -> Some label
            | None -> Some trimmed)

(* ================================================================ *)
(* Observation building                                              *)
(* ================================================================ *)

let cascade_observation_of_candidates ~cascade_name ~configured_labels
    ~(candidate_cfgs : Llm_provider.Provider_config.t list)
    ~(selected_model_raw : string option)
    ?(attempts = [])
    ?(fallback_events = [])
    ?(attempt_details_available = false)
    ?(attempt_details_source = "opaque_named_cascade")
    () : cascade_observation =
  let candidate_models = List.map model_label_of_config candidate_cfgs in
  let primary_model = match candidate_models with first :: _ -> Some first | [] -> None in
  let selected_index =
    selected_index_of_model ~selected_model_raw ~candidate_cfgs
  in
  let selected_model =
    normalized_selected_model ~selected_model_raw ~candidate_cfgs
      ~candidate_models ~selected_index
  in
  let fallback_hops = Option.map (fun idx -> max 0 idx) selected_index in
  let fallback_applied =
    match fallback_hops with
    | Some hops -> hops > 0
    | None -> false
  in
  {
    cascade_name;
    configured_labels;
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
      ("model_id", `String attempt.model_id);
      ("model_label", Json_util.string_opt_to_json attempt.model_label);
      ("latency_ms", Json_util.int_opt_to_json attempt.latency_ms);
      ("error", Json_util.string_opt_to_json attempt.error);
    ]

let cascade_fallback_event_to_json (event : cascade_fallback_event) :
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

let record_attempt_start (capture : cascade_metrics_capture)
    ~(candidate_cfgs : Llm_provider.Provider_config.t list) ~(model_id : string) =
  let attempt_index = capture.next_attempt_index in
  capture.next_attempt_index <- capture.next_attempt_index + 1;
  capture.attempts_rev <-
    {
      attempt_index;
      model_id;
      model_label = model_label_option_of_model_id ~candidate_cfgs model_id;
      latency_ms = None;
      error = None;
    }
    :: capture.attempts_rev

let ensure_terminal_attempt (capture : cascade_metrics_capture)
    ~(candidate_cfgs : Llm_provider.Provider_config.t list)
    ~(model_id : string) ~(latency_ms : int option) ~(error : string option) =
  let is_open attempt =
    String.equal attempt.model_id model_id
    && Option.is_none attempt.latency_ms
    && Option.is_none attempt.error
  in
  let update attempt = { attempt with latency_ms; error } in
  match update_first_attempt_if ~predicate:is_open ~update capture.attempts_rev with
  | Some attempts_rev -> capture.attempts_rev <- attempts_rev
  | None ->
      let attempt_index = capture.next_attempt_index in
      capture.next_attempt_index <- capture.next_attempt_index + 1;
      capture.attempts_rev <-
        {
          attempt_index;
          model_id;
          model_label = model_label_option_of_model_id ~candidate_cfgs model_id;
          latency_ms;
          error;
        }
        :: capture.attempts_rev

let record_fallback_event (capture : cascade_metrics_capture)
    ~(candidate_cfgs : Llm_provider.Provider_config.t list)
    ~(from_model : string) ~(to_model : string) ~(reason : string) =
  capture.fallback_events_rev <-
    {
      from_model_id = from_model;
      from_model_label =
        model_label_option_of_model_id ~candidate_cfgs from_model;
      to_model_id = to_model;
      to_model_label = model_label_option_of_model_id ~candidate_cfgs to_model;
      reason;
    }
    :: capture.fallback_events_rev

let cascade_metrics_for_candidates
    ~(candidate_cfgs : Llm_provider.Provider_config.t list) () =
  let capture =
    { next_attempt_index = 0; attempts_rev = []; fallback_events_rev = [] }
  in
  let metrics : Llm_provider.Metrics.t =
    {
      on_cache_hit = (fun ~model_id:_ -> ());
      on_cache_miss = (fun ~model_id:_ -> ());
      on_request_start =
        (fun ~model_id ->
          record_attempt_start capture ~candidate_cfgs ~model_id);
      on_request_end =
        (fun ~model_id ~latency_ms ->
          ensure_terminal_attempt capture ~candidate_cfgs ~model_id
            ~latency_ms:(Some latency_ms) ~error:None;
          (* Forward to Prometheus so per-model latency is visible on
             the dashboard.  Without this, the cascade capture records
             latency internally but never exports it — the global
             Llm_metric_bridge sink is not consulted because this
             per-call metrics object takes precedence. *)
          Llm_metric_bridge.emit_request_latency ~model_id ~latency_ms);
      on_error =
        (fun ~model_id ~error ->
          ensure_terminal_attempt capture ~candidate_cfgs ~model_id
            ~latency_ms:None ~error:(Some error));
      on_cascade_fallback =
        (fun ~from_model ~to_model ~reason ->
          record_fallback_event capture ~candidate_cfgs ~from_model ~to_model
            ~reason);
      (* Forward HTTP status to the Prometheus counter.  When callers
         pass this per-call metrics sink explicitly (cascade
         observation path), OAS does not consult the global
         Llm_metric_bridge sink, so we must re-emit here to avoid
         blackholing provider counters for captured turns.  Delegating
         to [Llm_metric_bridge.emit_http_status] keeps the label shape
         a single source of truth. *)
      on_http_status =
        (fun ~provider ~model_id ~status ->
          Llm_metric_bridge.emit_http_status ~provider ~model_id ~status);
    }
  in
  (capture, metrics)

let cascade_observation_with_metrics ~cascade_name ~configured_labels
    ~(candidate_cfgs : Llm_provider.Provider_config.t list)
    ~(selected_model_raw : string option) ~(capture : cascade_metrics_capture) =
  cascade_observation_of_candidates ~cascade_name ~configured_labels
    ~candidate_cfgs ~selected_model_raw
    ~attempts:(List.rev capture.attempts_rev)
    ~fallback_events:(List.rev capture.fallback_events_rev)
    ~attempt_details_available:true
    ~attempt_details_source:"oas_metrics_callbacks"
    ()

(* ================================================================ *)
(* JSON serialization                                                *)
(* ================================================================ *)

let cascade_observation_to_json (obs : cascade_observation) : Yojson.Safe.t =
  `Assoc
    [
      ("cascade_name", `String obs.cascade_name);
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

let get_cascade_audit_store () =
  match !cascade_audit_store_ref with
  | Some store -> Some store
  | None ->
      let base_path = Env_config_core.base_path () in
      let dir = Filename.concat base_path ".masc/cascade_audit" in
      (match Dated_jsonl.create ~base_dir:dir () with
      | store ->
          cascade_audit_store_ref := Some store;
          Some store
      | exception (Eio.Cancel.Cancelled _ as e) -> raise e
      | exception exn ->
          Log.Misc.warn "cascade audit store creation failed: %s"
            (Printexc.to_string exn);
          None)

let cascade_outcome_to_string = function
  | `Success -> "success"
  | `Failure -> "failure"
  | `Rejected -> "rejected"

let cascade_audit_json ~now ~cascade_name ~observation ~outcome =
  `Assoc
    [
      ("ts", `Float now);
      ("cascade_name", `String cascade_name);
      ("outcome", `String (cascade_outcome_to_string outcome));
      ( "observation",
        match observation with
        | Some obs -> cascade_observation_to_json obs
        | None -> `Null );
    ]

let record_cascade_audit ~now ~cascade_name ~observation ~outcome =
  match get_cascade_audit_store () with
  | None -> ()
  | Some store ->
      (try
         Dated_jsonl.append store
           (cascade_audit_json ~now ~cascade_name ~observation ~outcome)
       with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
          Log.Misc.warn "cascade audit append failed cascade=%s error=%s"
            cascade_name (Printexc.to_string exn))

(* ================================================================ *)
(* Aggregate metrics recording                                       *)
(* ================================================================ *)

let increment_counter table key =
  let count = Option.value ~default:0 (Hashtbl.find_opt table key) in
  Hashtbl.replace table key (count + 1)

let distribution_json table =
  Hashtbl.fold
    (fun model count acc ->
      `Assoc [ ("model", `String model); ("count", `Int count) ] :: acc)
    table []
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

let record_cascade ~observation ~cascade_name ~outcome =
  let now = Time_compat.now () in
  let evicted =
    Eio.Mutex.use_rw ~protect:true cascade_counters_mu (fun () ->
      let counter, evicted =
        match Hashtbl.find_opt cascade_counters cascade_name with
        | Some c -> (c, None)
        | None ->
            let evicted =
              if Hashtbl.length cascade_counters >= cascade_max_keys then
                match find_cascade_eviction_candidate () with
                | Some candidate ->
                    Hashtbl.remove cascade_counters candidate.name;
                    Some candidate
                | None -> None
              else
                None
            in
            let c = create_cascade_counter ~now () in
            Hashtbl.replace cascade_counters cascade_name c;
            (c, evicted)
      in
      counter.calls <- counter.calls + 1;
      counter.last_used_at <- now;
      (match observation with
      | Some obs ->
          counter.last_candidate_models <- obs.candidate_models;
          counter.last_selected_model <- obs.selected_model;
          counter.last_selected_index <- obs.selected_index;
          counter.last_attempts <- obs.attempts;
          counter.last_fallback_events <- obs.fallback_events;
          counter.last_attempt_details_available <- obs.attempt_details_available;
          counter.last_attempt_details_source <- Some obs.attempt_details_source;
          if obs.fallback_applied then
            counter.fallback_calls <- counter.fallback_calls + 1;
          counter.total_attempts <- counter.total_attempts + List.length obs.attempts;
          counter.total_fallback_events <-
            counter.total_fallback_events + List.length obs.fallback_events;
          (match obs.selected_model with
          | Some model when String.trim model <> "" ->
              increment_counter counter.selected_models model
          | _ -> ());
          List.iter
            (fun attempt ->
              increment_counter
                counter.attempted_models
                (attempt_model_display attempt);
              match attempt.error with
              | Some _ ->
                  increment_counter
                    counter.errored_models
                    (attempt_model_display attempt)
              | None -> ())
            obs.attempts
      | None -> ());
      (match outcome with
      | `Success -> counter.successes <- counter.successes + 1
      | `Failure -> counter.failures <- counter.failures + 1
      | `Rejected -> counter.rejected <- counter.rejected + 1);
      evicted)
  in
  Option.iter
    (fun candidate ->
      Log.Misc.warn
        "cascade metrics evicted key=%s calls=%d last_used_at=%.3f to admit %s (limit=%d)"
        candidate.name candidate.calls candidate.last_used_at cascade_name
        cascade_max_keys)
    evicted;
  record_cascade_audit ~now ~cascade_name ~observation ~outcome

let cascade_metrics_json () : Yojson.Safe.t =
  Eio.Mutex.use_rw ~protect:true cascade_counters_mu (fun () ->
    let entries =
      Hashtbl.fold
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
        cascade_counters []
    in
    `List
      (List.sort
         (fun a b ->
           let get_calls j = Yojson.Safe.Util.(j |> member "calls" |> to_int) in
           Int.compare (get_calls b) (get_calls a))
         entries))
