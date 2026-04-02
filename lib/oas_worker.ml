(** Oas_worker — Unified entry point for OAS-based MASC tool modules.

    Reusable OAS Agent build/run/checkpoint/events template.  Any MASC module that needs to run an OAS Agent
    uses this instead of duplicating boilerplate.

    Phases:
    1. Build  — construct [Agent.t] via [Agent_sdk.Builder]
    2. Run    — execute [Agent.run ~sw agent goal]
    3. Checkpoint — persist [Agent.checkpoint] + optional MASC context
    4. Events — bridge lifecycle events to [Event_bus]

    @since Phase 1 — MASC→OAS migration *)

module Oas = Agent_sdk

(* ================================================================ *)
(* Inference defaults — single definition point (ADR D2).            *)
(* Callers override via optional params.                             *)
(* Cascade config auto-resolution tracked in jeong-sik/me#915.      *)
(* ================================================================ *)

let default_temperature = 0.7
let default_max_tokens = 4096

(* ================================================================ *)
(* Cascade metrics                                                   *)
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
  selected_models : (string, int) Hashtbl.t;
  attempted_models : (string, int) Hashtbl.t;
  errored_models : (string, int) Hashtbl.t;
}

let cascade_counters : (string, cascade_counter) Hashtbl.t = Hashtbl.create 8
let cascade_max_keys = 256

let provider_name_of_config (cfg : Llm_provider.Provider_config.t) =
  match cfg.kind with
  | Llm_provider.Provider_config.Anthropic -> "claude"
  | Llm_provider.Provider_config.OpenAI_compat -> "openai"
  | Llm_provider.Provider_config.Gemini -> "gemini"
  | Llm_provider.Provider_config.Glm -> "glm"
  | Llm_provider.Provider_config.Claude_code -> "claude_code"

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
    match selected_index with
    | Some idx -> List.nth_opt candidate_models idx
    | None -> Option.map String.trim selected_model_raw
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
            ~latency_ms:(Some latency_ms) ~error:None);
      on_error =
        (fun ~model_id ~error ->
          ensure_terminal_attempt capture ~candidate_cfgs ~model_id
            ~latency_ms:None ~error:(Some error));
      on_cascade_fallback =
        (fun ~from_model ~to_model ~reason ->
          record_fallback_event capture ~candidate_cfgs ~from_model ~to_model
            ~reason);
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
  let c = match Hashtbl.find_opt cascade_counters cascade_name with
    | Some c -> c
    | None ->
      if Hashtbl.length cascade_counters >= cascade_max_keys then
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
          selected_models = Hashtbl.create 8;
          attempted_models = Hashtbl.create 8;
          errored_models = Hashtbl.create 8;
        }
      else begin
        let c =
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
            selected_models = Hashtbl.create 8;
            attempted_models = Hashtbl.create 8;
            errored_models = Hashtbl.create 8;
          }
        in
        Hashtbl.replace cascade_counters cascade_name c; c
      end
  in
  c.calls <- c.calls + 1;
  (match observation with
  | Some obs ->
      c.last_candidate_models <- obs.candidate_models;
      c.last_selected_model <- obs.selected_model;
      c.last_selected_index <- obs.selected_index;
      c.last_attempts <- obs.attempts;
      c.last_fallback_events <- obs.fallback_events;
      c.last_attempt_details_available <- obs.attempt_details_available;
      c.last_attempt_details_source <- Some obs.attempt_details_source;
      if obs.fallback_applied then c.fallback_calls <- c.fallback_calls + 1;
      c.total_attempts <- c.total_attempts + List.length obs.attempts;
      c.total_fallback_events <-
        c.total_fallback_events + List.length obs.fallback_events;
      (match obs.selected_model with
      | Some model when String.trim model <> "" ->
          increment_counter c.selected_models model
      | _ -> ());
      List.iter
        (fun attempt ->
          increment_counter c.attempted_models (attempt_model_display attempt);
          match attempt.error with
          | Some _ -> increment_counter c.errored_models (attempt_model_display attempt)
          | None -> ())
        obs.attempts
  | None -> ());
  (match outcome with
  | `Success -> c.successes <- c.successes + 1
  | `Failure -> c.failures <- c.failures + 1
  | `Rejected -> c.rejected <- c.rejected + 1)

let cascade_metrics_json () : Yojson.Safe.t =
  let entries = Hashtbl.fold (fun name c acc ->
    let error_rate = if c.calls > 0
      then float_of_int (c.failures + c.rejected) /. float_of_int c.calls
      else 0.0 in
    `Assoc [
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
      ] :: acc
    ) cascade_counters [] in
    `List (List.sort (fun a b ->
      let get_calls j = Yojson.Safe.Util.(j |> member "calls" |> to_int) in
      Int.compare (get_calls b) (get_calls a)
    ) entries)

(* ================================================================ *)
(* Configuration                                                     *)
(* ================================================================ *)

type config = {
  name : string;
  provider : Oas.Provider.config;
  model_id : string;
  system_prompt : string;
  tools : Oas.Tool.t list;
  max_turns : int;
  max_idle_turns : int;
  max_tokens : int;
  temperature : float;
  hooks : Oas.Hooks.hooks option;
  context_reducer : Oas.Context_reducer.t option;
  guardrails : Oas.Guardrails.t option;
  event_bus : Oas.Event_bus.t option;
  checkpoint_dir : string option;
  session_id : string option;
  description : string option;
  memory : Oas.Memory.t option;
  named_cascade : Oas.Api.named_cascade option;
  initial_messages : Oas.Types.message list;
  raw_trace : Oas.Raw_trace.t option;
  enable_thinking : bool option;
  transport : Masc_grpc_transport.t;
  allowed_paths : string list;
  working_context : Yojson.Safe.t option;
  cache_system_prompt : bool;
  yield_on_tool : bool;
}

let default_config ~name ~provider ~model_id ~system_prompt ~tools : config =
  { name; provider; model_id; system_prompt; tools;
    max_turns = 20;
    max_idle_turns = 3;
    max_tokens = default_max_tokens;
    temperature = default_temperature;
    hooks = None;
    context_reducer = None;
    guardrails = None;
    event_bus = None;
    checkpoint_dir = None;
    session_id = None;
    description = None;
    memory = None;
    named_cascade = None;
    initial_messages = [];
    raw_trace = None;
    enable_thinking = None;
    transport = Masc_grpc_transport.from_env ();
    allowed_paths = [];
    working_context = None;
    cache_system_prompt = false;
    yield_on_tool = false;
  }

(* ================================================================ *)
(* Result type                                                       *)
(* ================================================================ *)

type stop_reason =
  | Completed
  | TurnBudgetExhausted of { turns_used : int; limit : int }

type run_result = {
  response : Oas.Types.api_response;
  checkpoint : Oas.Checkpoint.t option;
  session_id : string;
  turns : int;
  trace_ref : Oas.Raw_trace.run_ref option;
  proof : Oas.Cdal_proof.t option;
  cascade_observation : cascade_observation option;
  stop_reason : stop_reason;
}

(* ================================================================ *)
(* Internal: resolve provider                                        *)
(* ================================================================ *)

(** Resolve a model label string to an OAS Provider.config.
    Uses OAS Cascade_config.parse_model_string (Provider_registry SSOT).
    Falls back to glm when parsing fails.

    Note: the previous middle fallback via [to_oas_provider_of_label]
    was dead code — it calls parse_model_string internally, so if
    line 84 fails, line 88 also fails. Removed in v2.136.0. *)
let resolve_provider_of_label (label : string) : Oas.Provider.config =
  match Llm_provider.Cascade_config.parse_model_string label with
  | Some pc -> Oas.Provider.config_of_provider_config pc
  | None ->
    (* No vendor-specific fallback — use local llama via OAS round-robin *)
    Oas.Provider.config_of_provider_config
      (Llm_provider.Provider_config.make
         ~kind:Llm_provider.Provider_config.OpenAI_compat
         ~model_id:"auto"
         ~base_url:(Llm_provider.Provider_registry.next_llama_endpoint ())
         ~request_path:"/v1/chat/completions" ())

(* ================================================================ *)
(* Internal: event publishing                                        *)
(* ================================================================ *)

let publish_lifecycle bus ~name ~event ~detail =
  Oas.Event_bus.publish bus
    (Oas.Event_bus.Custom
      (Printf.sprintf "masc:oas_worker:%s" event,
       `Assoc [
         ("agent", `String name);
         ("detail", `String detail);
         ("timestamp", `Float (Time_compat.now ()));
       ]))

(* ================================================================ *)
(* Internal: checkpoint persistence                                  *)
(* ================================================================ *)

let persist_checkpoint ~dir ~session_id (ckpt : Oas.Checkpoint.t) =
  let path = Filename.concat dir (session_id ^ ".json") in
  Fs_compat.mkdir_p dir;
  Fs_compat.save_file path (Oas.Checkpoint.to_string ckpt)

let build_checkpoint ~session_id ?working_context (agent : Oas.Agent.t) =
  match working_context with
  | None -> Oas.Agent.checkpoint ~session_id agent
  | Some json ->
      Oas.Agent_checkpoint.build_checkpoint
        ~session_id ~working_context:json
        ~state:(Oas.Agent.state agent)
        ~tools:(Oas.Agent.tools agent)
        ~context:(Oas.Agent.context agent)
        ~mcp_clients:(Oas.Agent.options agent).mcp_clients
        ()

(* ================================================================ *)
(* Build                                                             *)
(* ================================================================ *)

let build
    ~(net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t)
    ~(config : config)
  : (Oas.Agent.t, string) result =
  let tool_names =
    List.map (fun (t : Oas.Tool.t) -> t.schema.name) config.tools in
  let guardrails = match config.guardrails with
    | Some g -> g
    | None ->
      { Oas.Guardrails.default with
        tool_filter =
          if tool_names <> [] then Oas.Guardrails.AllowList tool_names
          else Oas.Guardrails.AllowAll }
  in
  let builder =
    Oas.Builder.create ~net ~model:config.model_id
    |> Oas.Builder.with_name config.name
    |> Oas.Builder.with_system_prompt config.system_prompt
    |> Oas.Builder.with_max_tokens config.max_tokens
    |> Oas.Builder.with_max_turns config.max_turns
    |> Oas.Builder.with_max_idle_turns config.max_idle_turns
    |> Oas.Builder.with_temperature config.temperature
    |> Oas.Builder.with_provider config.provider
    |> Oas.Builder.with_tools config.tools
    |> Oas.Builder.with_guardrails guardrails
  in
  (* When tools are present, set tool_choice=Auto so models that require
     explicit tool_choice (e.g. GLM-5.1) will actually invoke tools. *)
  let builder =
    if config.tools <> [] then
      Oas.Builder.with_tool_choice Oas.Types.Auto builder
    else builder
  in
  let builder = match config.hooks with
    | Some h -> Oas.Builder.with_hooks h builder
    | None -> builder
  in
  let builder = match config.context_reducer with
    | Some r -> Oas.Builder.with_context_reducer r builder
    | None -> builder
  in
  let builder = match config.description with
    | Some d -> Oas.Builder.with_description d builder
    | None -> builder
  in
  let builder = match config.memory with
    | Some m -> Oas.Builder.with_memory m builder
    | None -> builder
  in
  let builder = match config.raw_trace with
    | Some raw_trace -> Oas.Builder.with_raw_trace raw_trace builder
    | None -> builder
  in
  let builder = match config.named_cascade with
    | Some nc -> Oas.Builder.with_named_cascade nc builder
    | None -> builder
  in
  let builder = match config.enable_thinking with
    | Some enabled -> Oas.Builder.with_enable_thinking enabled builder
    | None -> builder
  in
  let builder =
    if config.initial_messages <> [] then
      Oas.Builder.with_initial_messages config.initial_messages builder
    else builder
  in
  let builder =
    if config.allowed_paths <> [] then
      Oas.Builder.with_allowed_paths config.allowed_paths builder
    else builder
  in
  let builder =
    if config.cache_system_prompt then
      Oas.Builder.with_cache_system_prompt true builder
    else builder
  in
  let builder =
    if config.yield_on_tool then
      Oas.Builder.with_yield_on_tool true builder
    else builder
  in
  Oas.Builder.build_safe builder
  |> Result.map_error Oas.Error.to_string

(* ================================================================ *)
(* Run                                                               *)
(* ================================================================ *)

let run
    ~(sw : Eio.Switch.t)
    ~(net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t)
    ~(config : config)
    ?(on_event : (Oas.Types.sse_event -> unit) option)
    ?(on_yield : (unit -> unit) option)
    ?(on_resume : (unit -> unit) option)
    ?(agent_ref : Oas.Agent.t option ref option)
    ?(proof_ref : Oas.Cdal_proof.t option ref option)
    ?(contract : Oas.Risk_contract.t option)
    (goal : string)
  : (run_result, string) result =
  let session_id = match config.session_id with
    | Some id -> id
    | None ->
      Printf.sprintf "%s-%d-%06x"
        config.name
        (int_of_float (Time_compat.now () *. 1000.0))
        (Hashtbl.hash (Unix.gettimeofday ()) land 0xFFFFFF)
  in
  (match config.transport with
  | Masc_grpc_transport.Local -> ()
  | t ->
    Log.Misc.info "oas_worker %s: transport=%s"
      config.name (Masc_grpc_transport.to_string t));
  Option.iter (fun bus ->
    publish_lifecycle bus ~name:config.name ~event:"build" ~detail:goal
  ) config.event_bus;
  match build ~net ~config with
  | Error e ->
    Option.iter (fun bus ->
      publish_lifecycle bus ~name:config.name ~event:"build_error" ~detail:e
    ) config.event_bus;
    Error (Printf.sprintf "Agent build failed: %s" e)
  | Ok agent ->
  (* Set agent_ref for tools that need post-creation agent access (e.g. extend_turns) *)
  (match agent_ref with Some r -> r := Some agent | None -> ());
  (* Wrap agent execution so Eio/network exceptions become Error results,
     honouring the (run_result, string) result return type promised by .mli.
     Eio.Cancel.Cancelled is re-raised for structured-concurrency safety. *)
  (try
    let result, proof = match contract with
      | Some c ->
        (* on_yield/on_resume not forwarded: Contract_runner.run does not
           expose yield hooks. Slot yielding is inactive during contract runs. *)
        let cr = Oas.Contract_runner.run ~sw ~contract:c agent goal in
        (cr.response, Some cr.proof)
      | None ->
        let r = match on_event with
          | Some cb -> Oas.Agent.run_stream ~sw ?on_yield ?on_resume ~on_event:cb agent goal
          | None -> Oas.Agent.run ~sw ?on_yield ?on_resume agent goal
        in
        (r, None)
    in
    (match proof_ref with Some ref_ -> ref_ := proof | None -> ());
    let checkpoint =
      let ckpt = build_checkpoint ~session_id ?working_context:config.working_context agent in
      (match config.checkpoint_dir with
       | Some dir ->
         (try persist_checkpoint ~dir ~session_id ckpt
          with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
            Log.Misc.error "oas_worker: Checkpoint save failed: %s"
              (Printexc.to_string exn))
       | None -> ());
      Some ckpt
    in
    Option.iter (fun bus ->
      let status = match result with Ok _ -> "completed" | Error _ -> "failed" in
      publish_lifecycle bus ~name:config.name ~event:status
        ~detail:(Printf.sprintf "session=%s" session_id)
    ) config.event_bus;
    let turns = (Oas.Agent.state agent).turn_count in
    let trace_ref = Oas.Agent.last_raw_trace_run agent in
    Oas.Agent.close agent;
    (match result with
    | Ok response ->
      Ok
        {
          response;
          checkpoint;
          session_id;
          turns;
          trace_ref;
          proof;
          cascade_observation = None;
          stop_reason = Completed;
        }
    | Error (Oas.Error.Agent (Oas.Error.MaxTurnsExceeded r)) ->
      (* Turn budget exhaustion is not a fatal error — the agent made progress.
         Return Ok with TurnBudgetExhausted so callers can checkpoint and resume
         instead of treating this as a crash. *)
      let partial_response : Oas.Types.api_response = {
        id = session_id; model = "turn-exhausted";
        stop_reason = Oas.Types.EndTurn;
        content = [Oas.Types.Text (Printf.sprintf
          "[turn budget exhausted: %d/%d turns used]" r.turns r.limit)];
        usage = None;
      } in
      Ok
        {
          response = partial_response;
          checkpoint;
          session_id;
          turns;
          trace_ref;
          proof;
          cascade_observation = None;
          stop_reason = TurnBudgetExhausted { turns_used = r.turns; limit = r.limit };
        }
    | Error err ->
      (match proof with
       | Some p ->
         Log.Misc.warn "oas_worker: agent errored with CDAL proof: run_id=%s status=%s"
           p.run_id
           (match p.result_status with
            | Oas.Cdal_proof.Completed -> "completed"
            | Oas.Cdal_proof.Errored -> "errored"
            | Oas.Cdal_proof.Timed_out -> "timed_out"
            | Oas.Cdal_proof.Cancelled -> "cancelled")
       | None -> ());
      Error (Printf.sprintf "Agent run failed: %s" (Oas.Error.to_string err)))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    (try Oas.Agent.close agent with close_exn ->
      Log.Misc.warn "agent close failed during cleanup: %s" (Printexc.to_string close_exn));
    Error (Printf.sprintf "Agent execution exception: %s" (Printexc.to_string exn)))

(* ================================================================ *)
(* Convenience: run_with_masc_tools                                  *)
(* ================================================================ *)

let run_with_masc_tools
    ~(sw : Eio.Switch.t)
    ~(net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t)
    ~(config : config)
    ~(masc_tools : Types.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> bool * string)
    ?contract
    ?on_event
    ?on_yield
    ?on_resume
    (goal : string)
  : (run_result, string) result =
  let oas_tools = List.map (fun (td : Types.tool_schema) ->
    Tool_bridge.oas_tool_of_masc
      ~name:td.name
      ~description:td.description
      ~input_schema:td.input_schema
      (fun input -> dispatch ~name:td.name ~args:input)
  ) masc_tools in
  let config = { config with tools = oas_tools @ config.tools } in
  run ~sw ~net ~config ?on_event ?on_yield ?on_resume ?contract goal

(* ================================================================ *)
(* Cascade profile defaults (moved from Cascade module)              *)
(* ================================================================ *)

let default_config_path () : string option =
  Config_dir_resolver.log_warnings ~context:"OasWorker" ();
  Config_dir_resolver.cascade_path_opt ()

(** Hardcoded fallback defaults — used only when cascade.json is missing
    and the cascade name has no "{name}_models" entry.
    All profiles are now in config/cascade.json (hot-reloadable). *)
let default_model_strings ~cascade_name:_ =
  let llama_model = Env_config.Llama.default_model in
  let models =
    if llama_model <> "" then [ Printf.sprintf "llama:%s" llama_model ] else []
  in
  if models = [] then
    match Provider_adapter.preferred_execution_model_labels () with
    | [] -> [ "llama:auto" ]
    | labels -> labels
  else models

(* ================================================================ *)
(* Named model execution                                            *)
(* ================================================================ *)

let require_eio ?sw ?net () =
  let sw = match sw with Some s -> Some s | None -> Eio_context.get_switch_opt () in
  let net = match net with Some n -> Some n | None -> Eio_context.get_net_opt () in
  match sw, net with
  | Some sw, Some net -> Ok (sw, net)
  | None, _ -> Error "Eio switch not available (running outside server context)"
  | _, None -> Error "Eio net not available (running outside server context)"

(** Resolve cascade provider configs via OAS Cascade_config.
    Returns OAS Provider_config.t list directly, bypassing the old Model_spec facade. *)
let resolve_cascade_providers ~cascade_name : Llm_provider.Provider_config.t list =
  let defaults = default_model_strings ~cascade_name in
  let config_path = default_config_path () in
  let configured =
    Llm_provider.Cascade_config.resolve_model_strings
      ?config_path ~name:cascade_name ~defaults ()
  in
  let specs = Llm_provider.Cascade_config.parse_model_strings configured in
  if specs <> [] then specs
  else if configured = defaults then (
      Log.Misc.warn "cascade %s: no callable models from built-in defaults" cascade_name;
      [])
    else (
      Log.Misc.warn "cascade %s: configured models unavailable — retrying built-in defaults" cascade_name;
      Llm_provider.Cascade_config.parse_model_strings defaults)

let config_for_label
    ~(name : string)
    ~(model_label : string)
    ~(system_prompt : string)
    ~(tools : Oas.Tool.t list)
    ~(max_turns : int)
    ~(max_tokens : int)
    ~(temperature : float)
    ?(max_idle_turns = 3)
    ?guardrails
    ?hooks
    ?context_reducer
    ?memory
    ?enable_thinking
    ~(description : string option)
    () : config =
  let provider = resolve_provider_of_label model_label in
  let model_id = match Oas_model_resolve.provider_name_of_label model_label with
    | Some _ ->
      (* Extract model_id portion from "provider:model_id" *)
      (match String.index_opt model_label ':' with
       | Some idx -> String.sub model_label (idx + 1) (String.length model_label - idx - 1) |> String.trim
       | None -> model_label)
    | None -> model_label
  in
  {
    (default_config ~name ~provider ~model_id
       ~system_prompt ~tools)
    with
    max_turns;
    max_tokens;
    temperature;
    max_idle_turns;
    guardrails;
    hooks;
    context_reducer;
    memory;
    enable_thinking;
    description;
  }

(** Run a single Agent.run() call with cascade model fallback.

    Tries each model in cascade order. Falls through to the next model
    when:
    - Agent.run() returns an error (model unavailable, network issue)
    - [accept] returns [false] (response validation failure)

    This preserves the cascade fallback behavior of the former [Cascade.complete]
    while routing all MODEL calls through Agent.run().

    @param accept Optional response validator. Default accepts all.
    @since Phase 7 — cascade fallback in Oas_worker *)
let run_named
    ~cascade_name
    ~goal
    ?session_id
    ?(system_prompt = "")
    ?(tools = [])
    ?(initial_messages = [])
    ?(max_turns = 20)
    ?(max_idle_turns = 3)
    ?(temperature = default_temperature)
    ?(max_tokens = default_max_tokens)
    ?(accept = fun (_ : Oas_response.api_response) -> true)
    ?guardrails
    ?hooks
    ?context_reducer
    ?memory
    ?raw_trace
    ?on_event
    ?on_yield
    ?on_resume
    ?agent_ref
    ?proof_ref
    ?contract
    ?transport
    ?(allowed_paths = [])
    ?working_context
    ?(cache_system_prompt = false)
    ?(yield_on_tool = false)
    ?sw
    ?net
    ()
  : (run_result, string) result =
  match require_eio ?sw ?net () with
  | Error e -> Error e
  | Ok (sw, net) ->
  let defaults = default_model_strings ~cascade_name in
  let config_path = default_config_path () in
  let configured_labels =
    Llm_provider.Cascade_config.resolve_model_strings
      ?config_path ~name:cascade_name ~defaults ()
  in
  let candidate_cfgs = resolve_cascade_providers ~cascade_name in
  let capture, metrics = cascade_metrics_for_candidates ~candidate_cfgs () in
  let named_cascade = Oas.Api.named_cascade ?config_path
    ~metrics ~name:cascade_name ~defaults () in
  let name = Printf.sprintf "oas-%s" cascade_name in
  (* Use first available provider config as primary for Builder.
     OAS named_cascade handles actual fallback — this is just the
     initial provider for Agent construction. *)
  let primary_provider = match candidate_cfgs with
    | cfg :: _ -> cfg
    | [] ->
      Llm_provider.Provider_config.make
        ~kind:Llm_provider.Provider_config.Glm
        ~model_id:"auto"
        ~base_url:"https://api.z.ai/api/coding/paas/v4"
        ~request_path:"/chat/completions"
        ()
  in
  let provider : Oas.Provider.config =
    Oas.Provider.config_of_provider_config primary_provider
  in
  let transport_resolved = match transport with
    | Some t -> t
    | None -> Masc_grpc_transport.from_env ()
  in
  let config =
    { (default_config ~name ~provider ~model_id:primary_provider.model_id
         ~system_prompt ~tools)
      with
      max_turns; max_tokens; temperature; max_idle_turns;
      guardrails; hooks; context_reducer; memory;
      description = Some (Printf.sprintf "cascade:%s" cascade_name);
      transport = transport_resolved;
      allowed_paths;
      working_context;
      session_id;
      cache_system_prompt;
    }
  in
  let config = { config with named_cascade = Some named_cascade; initial_messages; raw_trace; yield_on_tool } in
  match run ~sw ~net ~config ?on_event ?on_yield ?on_resume ?agent_ref ?proof_ref ?contract goal with
  | Ok result when accept result.response ->
    let observation =
      cascade_observation_with_metrics ~cascade_name ~configured_labels
        ~candidate_cfgs ~selected_model_raw:(Some result.response.model)
        ~capture
    in
    let result = { result with cascade_observation = Some observation } in
    record_cascade ~cascade_name ~outcome:`Success ~observation:(Some observation);
    Ok result
  | Ok result ->
    let observation =
      cascade_observation_with_metrics ~cascade_name ~configured_labels
        ~candidate_cfgs ~selected_model_raw:(Some result.response.model)
        ~capture
    in
    record_cascade ~cascade_name ~outcome:`Rejected ~observation:(Some observation);
    Error (Printf.sprintf "cascade %s: response rejected by accept" cascade_name)
  | Error e ->
    let observation =
      cascade_observation_with_metrics ~cascade_name ~configured_labels
        ~candidate_cfgs ~selected_model_raw:None ~capture
    in
    record_cascade ~cascade_name ~outcome:`Failure ~observation:(Some observation);
    Error e

(** Run a single Agent.run() using a model label string (e.g. "llama:qwen3.5").
    Validates the label parses before attempting execution. *)
let run_model_by_label
    ~(model_label : string)
    ~goal
    ?(system_prompt = "")
    ?(tools = [])
    ?(max_turns = 20)
    ?(max_idle_turns = 3)
    ?(temperature = default_temperature)
    ?(max_tokens = default_max_tokens)
    ?(accept = fun (_ : Oas_response.api_response) -> true)
    ?guardrails
    ?hooks
    ?context_reducer
    ?memory
    ?enable_thinking
    ?contract
    ?on_event
    ?transport
    ?sw
    ?net
    ()
  : (run_result, string) result =
  (* Validate the label parses before proceeding via OAS Cascade_config *)
  (match Llm_provider.Cascade_config.parse_model_string model_label with
  | None ->
    Error (Printf.sprintf "Cannot parse model label: %s" model_label)
  | Some _pc ->
    match require_eio ?sw ?net () with
    | Error e -> Error e
    | Ok (sw, net) ->
        let transport_resolved = match transport with
          | Some t -> t
          | None -> Masc_grpc_transport.from_env ()
        in
        let config =
          config_for_label ~name:"oas-label-model" ~model_label ~system_prompt
            ~tools ~max_turns ~max_tokens ~temperature ~max_idle_turns ?guardrails ?hooks
            ?context_reducer ?memory ?enable_thinking
            ~description:(Some (Printf.sprintf "model_label:%s" model_label))
            ()
        in
        let config = { config with transport = transport_resolved } in
        (match run ~sw ~net ~config ?on_event ?contract goal with
        | Ok result when accept result.response -> Ok result
        | Ok _ ->
            Error
              (Printf.sprintf "response rejected by accept from %s" model_label)
        | Error e -> Error e))

let run_named_with_masc_tools
    ~cascade_name
    ~goal
    ?(system_prompt = "")
    ~(masc_tools : Types.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> bool * string)
    ?(max_turns = 20)
    ?(temperature = default_temperature)
    ?(max_tokens = default_max_tokens)
    ?guardrails
    ?hooks
    ?memory
    ?raw_trace
    ?on_event
    ?on_yield
    ?on_resume
    ?proof_ref
    ?contract
    ?transport
    ?(yield_on_tool = false)
    ?sw
    ?net
    ()
  : (run_result, string) result =
  (* Convert MASC tools to OAS tools, then delegate to run_named.
     OAS named_cascade handles model fallback internally. *)
  let oas_tools = List.map (fun (td : Types.tool_schema) ->
    Tool_bridge.oas_tool_of_masc
      ~name:td.name ~description:td.description
      ~input_schema:td.input_schema
      (fun input -> dispatch ~name:td.name ~args:input)
  ) masc_tools in
  run_named ~cascade_name ~goal ~system_prompt ~tools:oas_tools
    ~max_turns ~temperature ~max_tokens ?guardrails ?hooks ?memory
    ?raw_trace ?on_event ?on_yield ?on_resume ?proof_ref ?contract
    ?transport ~yield_on_tool ?sw ?net ()

let run_model_with_masc_tools
    ~(model_label : string)
    ~goal
    ?(system_prompt = "")
    ~(masc_tools : Types.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> bool * string)
    ?(max_turns = 20)
    ?(temperature = default_temperature)
    ?(max_tokens = default_max_tokens)
    ?guardrails
    ?hooks
    ?memory
    ?enable_thinking
    ?contract
    ?raw_trace
    ?on_event
    ?transport
    ?sw
    ?net
    ()
  : (run_result, string) result =
  match require_eio ?sw ?net () with
  | Error e -> Error e
  | Ok (sw, net) ->
      let transport_resolved = match transport with
        | Some t -> t
        | None -> Masc_grpc_transport.from_env ()
      in
      let config =
        config_for_label ~name:"oas-explicit-model" ~model_label ~system_prompt
          ~tools:[] ~max_turns ~max_tokens ~temperature ?guardrails ?hooks
          ?memory ?enable_thinking
          ~description:(Some (Printf.sprintf "model_label:%s" model_label))
          ()
      in
      let config = { config with raw_trace; transport = transport_resolved } in
      run_with_masc_tools ~sw ~net ~config ~masc_tools ~dispatch ?contract ?on_event
        goal
