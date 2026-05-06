(* Keeper_turn_liveness — phase-buffer cascade liveness decisions, ollama
   saturation pre-skip, and turn liveload configuration.

   Extracted from keeper_unified_turn.ml (L328-499) during the god-file split. *)

open Keeper_types

type local_only_liveness_decision =
  | Keep_effective_cascade of string
  | Probe_local_only_urls of {
      effective_cascade : string;
      fallback_cascade : string;
      ollama_base_urls : string list;
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
             if Cascade_ollama_probe.is_ollama_url cfg.base_url then
               Some cfg.base_url
             else None)
      |> dedupe_keep_order
    in
    match ollama_urls with
    | [] -> Keep_effective_cascade normalized_effective
    | ollama_base_urls ->
        Probe_local_only_urls
          {
            effective_cascade = normalized_effective;
            fallback_cascade = normalized_base;
            ollama_base_urls;
          }

let fail_open_local_only_when_unavailable
    ?resolve_label
    ?probe_ollama_base_url
    ~(base_cascade : string)
    ~(effective_cascade : string)
    (labels : string list) : string =
  match
    decide_local_only_liveness ?resolve_label ~base_cascade ~effective_cascade
      labels
  with
  | Keep_effective_cascade cascade -> cascade
  | Probe_local_only_urls
      { effective_cascade; fallback_cascade; ollama_base_urls } ->
      let probe_ollama_base_url =
        match probe_ollama_base_url with
        | Some probe -> Some probe
        | None ->
          (match Eio_context.get_switch_opt (), Eio_context.get_net_opt () with
           | Some sw, Some net ->
             Some (fun base_url ->
               Option.is_some (Cascade_ollama_probe.try_probe ~sw ~net base_url))
           | _ -> None)
      in
      (match probe_ollama_base_url with
       | None -> effective_cascade
       | Some probe ->
         if List.exists probe ollama_base_urls then effective_cascade
         else fallback_cascade)

(** PR-B: ollama saturation pre-skip support.

    When every label in the resolved cascade points at the same
    ollama [base_url] (single-provider profile), we can pre-check the
    [Cascade_ollama_probe] cache before paying an [Agent.run] dispatch.
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
    fail-open policy in [Cascade_ollama_probe.try_probe].

    After [max_consecutive_saturation_skips] consecutive saturated
    checks for the same keeper, returns [false] to force a turn and
    break the noop_failure_loop → watchdog kill death spiral. *)
let max_consecutive_saturation_skips =
  Env_config_core.get_int_nonneg ~default:6
    "MASC_KEEPER_MAX_SATURATION_SKIPS"

let saturation_skip_count : (string, int) Hashtbl.t = Hashtbl.create 16

let is_ollama_saturated
    ?(keeper_name = "")
    ?capacity_lookup
    (base_url : string) : bool =
  let capacity_lookup =
    match capacity_lookup with
    | Some f -> f
    | None -> fun url -> Cascade_ollama_probe.cached_capacity url
  in
  match capacity_lookup base_url with
  | None -> false
  | Some (info : Cascade_throttle.capacity_info) ->
      let saturated =
        info.process_available <= 0
        && (info.process_active > 0 || info.process_queue_length > 0)
      in
      if not saturated then begin
        Hashtbl.remove saturation_skip_count keeper_name;
        false
      end else begin
        let count = Hashtbl.find_opt saturation_skip_count keeper_name
                    |> Option.value ~default:0
        in
        if count >= max_consecutive_saturation_skips then begin
          Log.Keeper.info
            "%s: ollama saturation skip count %d >= max %d, forcing turn"
            keeper_name count max_consecutive_saturation_skips;
          Hashtbl.remove saturation_skip_count keeper_name;
          false
        end else begin
          Hashtbl.replace saturation_skip_count keeper_name (count + 1);
          true
        end
      end

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
