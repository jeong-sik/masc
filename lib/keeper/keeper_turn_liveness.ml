(* Keeper_turn_liveness — phase-buffer cascade liveness decisions, ollama
   saturation pre-skip, and turn liveload configuration.

   Extracted from keeper_unified_turn.ml (L328-499) during the god-file split. *)

open Keeper_types

type local_only_liveness_decision =
  | Keep_effective_cascade of string
  | Probe_local_only_urls of {
      effective_cascade : string;
      fallback_cascade : string;
      probeable_base_urls : string list;
    }

let decide_local_only_liveness
    ?resolve_label
    ~(base_cascade : string)
    ~(effective_cascade : string)
    (labels : string list) : local_only_liveness_decision =
  let resolve_label =
    match resolve_label with
    | Some resolve_label -> resolve_label
    | None -> fun label -> Cascade_config.parse_model_string label
  in
  let normalized_base =
    Keeper_cascade_profile.normalize_declared_name base_cascade
  in
  let normalized_effective =
    Keeper_cascade_profile.normalize_declared_name effective_cascade
  in
  if not (String.equal normalized_effective Keeper_config.local_only_cascade_name)
     || String.equal normalized_base Keeper_config.local_only_cascade_name
  then Keep_effective_cascade normalized_effective
  else
    let ollama_urls =
      labels
      |> List.filter_map resolve_label
      |> List.filter_map (fun (cfg : Llm_provider.Provider_config.t) ->
             if Cascade_capacity_probe.can_probe ~url:cfg.base_url then
               Some cfg.base_url
             else None)
      |> dedupe_keep_order
    in
    match ollama_urls with
    | [] -> Keep_effective_cascade normalized_effective
    | probeable_base_urls ->
        Probe_local_only_urls
          {
            effective_cascade = normalized_effective;
            fallback_cascade = normalized_base;
            probeable_base_urls;
          }

let fail_open_local_only_when_unavailable
    ?resolve_label
    ?probe_base_url
    ~(base_cascade : string)
    ~(effective_cascade : string)
    (labels : string list) : string =
  match
    decide_local_only_liveness ?resolve_label ~base_cascade ~effective_cascade
      labels
  with
  | Keep_effective_cascade cascade -> cascade
  | Probe_local_only_urls
      { effective_cascade; fallback_cascade; probeable_base_urls } ->
      let probe_base_url =
        match probe_base_url with
        | Some probe -> Some probe
        | None ->
          (match Eio_context.get_switch_opt (), Eio_context.get_net_opt () with
           | Some sw, Some net ->
             Some (fun base_url ->
               Option.is_some (Cascade_capacity_probe.probe ~sw ~net ~url:base_url ()))
           | _ -> None)
      in
      (match probe_base_url with
       | None -> effective_cascade
       | Some probe ->
         if List.exists probe probeable_base_urls then effective_cascade
         else fallback_cascade)

(** PR-B: ollama saturation pre-skip support.

    When every label in the resolved cascade points at the same
    ollama [base_url] (single-provider profile), we can pre-check the
    [Cascade_capacity_probe] cache before paying an [Agent.run] dispatch.
    If the probe reports [process_available <= 0] the request would
    queue on a busy slot and very likely blow the keeper turn budget,
    causing a cascading FAILED cycle.  Skipping the turn here keeps
    the keeper alive without burning the budget. *)

(** [resolve_ollama_only_base_url ?resolve_label labels] returns
    [Some url] when [labels] is non-empty AND every label parses to
    an ollama provider config sharing the same [base_url].  Returns
    [None] when the cascade has zero candidates, when any candidate
    is non-ollama, when ollama candidates point at different hosts,
    or when any label fails to parse.

    Pure: [resolve_label] is the only injected dependency for tests. *)
let resolve_ollama_only_base_url
    ?resolve_label
    (labels : string list) : string option =
  let resolve_label =
    match resolve_label with
    | Some f -> f
    | None -> fun label -> Cascade_config.parse_model_string label
  in
  match labels with
  | [] -> None
  | first :: rest ->
      let is_ollama_cfg (cfg : Llm_provider.Provider_config.t) =
        match cfg.kind with
        | Llm_provider.Provider_config.Ollama -> true
        | _ -> false
      in
      (match resolve_label first with
       | Some cfg when is_ollama_cfg cfg ->
           let base_url = cfg.base_url in
           let same_ollama_host label =
             match resolve_label label with
             | Some other when is_ollama_cfg other ->
                 String.equal other.base_url base_url
             | _ -> false
           in
           if List.for_all same_ollama_host rest then Some base_url
           else None
       | _ -> None)

(** [is_ollama_saturated ?capacity_lookup base_url] returns [true]
    only when the cache has a fresh entry whose
    [process_available <= 0] AND there is at least one queued or
    active request.  [None] (no cache entry / probe never ran) and
    failed probes are deliberately treated as "not saturated" so a
    flaky probe never starves the keeper.  Mirrors the conservative
    fail-open policy in [Cascade_http_probe.try_probe]. *)
let is_ollama_saturated
    ?capacity_lookup
    (base_url : string) : bool =
  let capacity_lookup =
    match capacity_lookup with
    | Some f -> f
    | None -> fun url -> Cascade_capacity_probe.cached ~url ()
  in
  match capacity_lookup base_url with
  | None -> false
  | Some (info : Cascade_throttle.capacity_info) ->
      info.process_available <= 0
      && (info.process_active > 0 || info.process_queue_length > 0)

(** Backoff sleep applied after a saturation skip so the keeper does
    not hot-spin against a busy ollama instance. Short by design:
    the heartbeat loop already has its own pacing (see
    [keeper_keepalive.ml]); this only covers the case where multiple
    keepers race the probe cache. *)
let saturation_skip_backoff_sec = 5.0

let saturation_skip_jitter_factor = 0.4

let saturation_skip_sleep_duration () =
  let jitter =
    saturation_skip_backoff_sec
    *. saturation_skip_jitter_factor
    *. Random.float 1.0
  in
  saturation_skip_backoff_sec +. jitter

let turn_livelock_max_attempts () =
  Int.max 1
    (Env_config_core.get_int ~default:3
       "MASC_KEEPER_TURN_LIVELOCK_MAX_ATTEMPTS")

let turn_livelock_stuck_after_sec () =
  Float.max 1.0
    (Env_config_core.get_float ~default:1800.0
       "MASC_KEEPER_TURN_LIVELOCK_STUCK_AFTER_SEC")

(* PR-B follow-up: bound consecutive saturation skips per keeper.

   Pre-existing PR-B logic skips a turn whenever the ollama probe
   cache reports saturation, with a 5s jittered backoff.  Without an
   upper bound, a stuck or stale probe (e.g. /api/ps handler hung
   behind a model load) can produce indefinite consecutive skips —
   the keeper makes no progress, the watchdog stays unaware (each
   skip records as a soft "skipped" terminal observation rather than
   a FAILED→DEAD escalation), and a saturated cache poisons
   subsequent cycles.

   The cap is intentionally a per-keeper count rather than a global
   one: different keepers race the same probe cache, and cross-talk
   between keepers should not consume each other's skip budget.

   Reset rule: any non-skip path clears the counter.  A single
   successful probe (saturated → false) wipes the history, matching
   the documented fail-open invariant. *)

let saturation_skip_counts : (string, int) Hashtbl.t = Hashtbl.create 32

let saturation_skip_counts_mutex = Eio.Mutex.create ()

let max_consecutive_saturation_skips_default = 5

let max_consecutive_saturation_skips_env =
  "MASC_MAX_CONSECUTIVE_SATURATION_SKIPS"

let max_consecutive_saturation_skips () =
  Int.max 1
    (Env_config_core.get_int
       ~default:max_consecutive_saturation_skips_default
       max_consecutive_saturation_skips_env)

let saturation_skip_count_get ~keeper_name =
  Eio.Mutex.use_ro saturation_skip_counts_mutex (fun () ->
    Option.value ~default:0
      (Hashtbl.find_opt saturation_skip_counts keeper_name))

let saturation_skip_count_inc ~keeper_name =
  Eio.Mutex.use_rw ~protect:false saturation_skip_counts_mutex (fun () ->
    let cur =
      Option.value ~default:0
        (Hashtbl.find_opt saturation_skip_counts keeper_name)
    in
    let next = cur + 1 in
    Hashtbl.replace saturation_skip_counts keeper_name next;
    next)

let saturation_skip_count_reset ~keeper_name =
  Eio.Mutex.use_rw ~protect:false saturation_skip_counts_mutex (fun () ->
    Hashtbl.remove saturation_skip_counts keeper_name)

let saturation_skip_count_clear_all () =
  Eio.Mutex.use_rw ~protect:false saturation_skip_counts_mutex (fun () ->
    Hashtbl.clear saturation_skip_counts)
