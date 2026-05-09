(** JSON config loading with mtime-based hot-reload.

    Loads and caches cascade profile JSON files.  The cache is keyed by
    file path and invalidated when the file mtime changes.

    @since 0.59.0
    @since 0.92.0 extracted from Cascade_config *)

let config_cache : (string, float * Yojson.Safe.t) Hashtbl.t =
  Hashtbl.create 4

(** Stdlib Mutex — no Eio dependency. Keep the critical section limited to
    cache access so file I/O and JSON parsing do not block unrelated fibers
    longer than necessary when called from an Eio domain. *)
let config_cache_mu = Mutex.create ()

let with_cache_lock f =
  Mutex.lock config_cache_mu;
  Fun.protect ~finally:(fun () -> Mutex.unlock config_cache_mu) f

let invalidate_cache_entry path =
  with_cache_lock (fun () -> Hashtbl.remove config_cache path)

(* 2026-05-05: load_catalog runs 7-10× per startup (snapshot, validation,
   mcp_audit, dashboard cache warm-up, etc.).  Without dedup, every cycle
   detected by [detect_fallback_cycles] re-emits the same WARN line on
   each call → ~10 cascades × 10 phases = 100+ WARN lines per startup that
   say the exact same thing.  We memo the last-warned cycle set per
   config_path; the WARN fires only when the set changes (config edit or
   first load).  Prometheus counter is incremented on every detection so
   metrics stay honest.

   Separate mutex from [config_cache_mu] to avoid lock-ordering issues if
   the caller holds the cache lock during [load_catalog] dispatch. *)
let cycle_warn_seen : (string, string) Hashtbl.t = Hashtbl.create 4
let cycle_warn_mu = Mutex.create ()

let with_cycle_warn_lock f =
  Mutex.lock cycle_warn_mu;
  Fun.protect ~finally:(fun () -> Mutex.unlock cycle_warn_mu) f

let cycle_set_key (cycles : string list list) : string =
  cycles
  |> List.map (fun cycle ->
       cycle |> List.sort compare |> String.concat ",")
  |> List.sort compare
  |> String.concat "|"

let ensure_materialized_json path =
  match Cascade_toml_materializer.ensure_materialized_json ~config_path:path with
  | Ok { wrote_json; _ } ->
      if wrote_json then invalidate_cache_entry path;
      Ok ()
  | Error _ as err -> err

let read_json_file path =
  let ic = open_in path in
  let content =
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
         let len = in_channel_length ic in
         let buf = Bytes.create len in
         really_input ic buf 0 len;
         Bytes.to_string buf)
  in
  Yojson.Safe.from_string content

let load_json path =
  let rec load_current () =
    let mtime = (Unix.stat path).Unix.st_mtime in
    match with_cache_lock (fun () ->
        match Hashtbl.find_opt config_cache path with
        | Some (cached_mtime, json) when Float.equal cached_mtime mtime ->
          Some json
        | _ -> None)
    with
    | Some json -> Ok json
    | None ->
      let json = read_json_file path in
      let refreshed_mtime = (Unix.stat path).Unix.st_mtime in
      if not (Float.equal refreshed_mtime mtime) then
        load_current ()
      else
        (* Keep the critical section to Hashtbl access only. Any Eio-aware
           work (traceln in particular) must run OUTSIDE the Stdlib.Mutex
           because traceln can suspend the fiber while the lock is held,
           blocking unrelated fibers on the domain.
           Ref: memory/feedback_eio-traceln-outside-critical-section.md *)
        let outcome =
          with_cache_lock (fun () ->
              match Hashtbl.find_opt config_cache path with
              | Some (cached_mtime, cached_json)
                when Float.equal cached_mtime refreshed_mtime ->
                `Returning_cached cached_json
              | prior ->
                Hashtbl.replace config_cache path (refreshed_mtime, json);
                `Installed_new (Option.map fst prior))
        in
        (match outcome with
         | `Returning_cached cached_json -> Ok cached_json
         | `Installed_new prior_mtime ->
             (* Observability: trace first-load vs reload so operators
                editing cascade.json can verify their change took effect.
                Keeping this at traceln (stderr) matches existing OAS
                convention (see Cascade_config.apply_provider_filter). *)
             (match prior_mtime with
              | None ->
                  Eio.traceln
                    "[CascadeConfig] loaded %s mtime=%.0f"
                    path refreshed_mtime
              | Some old_mtime ->
                  Eio.traceln
                    "[CascadeConfig] reloaded %s old_mtime=%.0f new_mtime=%.0f"
                    path old_mtime refreshed_mtime);
             Ok json)
  in
  match ensure_materialized_json path with
  | Error _ as err -> err
  | Ok () ->
      (try load_current () with
       | Sys_error msg -> Error msg
       | Unix.Unix_error (err, fn, arg) ->
           Error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message err))
       | Yojson.Json_error msg -> Error (Printf.sprintf "JSON error: %s" msg)
       | End_of_file -> Error "unexpected end of file")

(** A model entry with an optional weight for weighted cascade selection.
    Weight defaults to 1 when not specified (backward compatible).
    [secondary] is the RFC-0027 PR-9 dual-track fallback (CLI primary +
    direct-API secondary), [None] for legacy entries. *)
type weighted_entry = {
  model: string;
  weight: int;
  supports_tool_choice: bool option;
  secondary: string option;
  secondary_supports_tool_choice: bool option;
}

let parse_weight_field = function
  | `Int i when i > 0 -> i
  | `Float f when f > 0.0 ->
    let i = int_of_float f in
    if i > 0 && Float.equal f (float_of_int i) then i else 1
  | _ -> 1

let parse_supports_tool_choice_field = function
  | `Bool b -> Some b
  | _ -> None

(* Trim, then treat empty / whitespace-only secondary as absent (None) —
   identical to the field being missing.  Returning None rather than an
   error keeps the JSON loader permissive (typed materializer is the
   strict source of truth) and avoids producing an invalid provider
   scheme downstream. *)
let parse_secondary_field = function
  | `String s ->
    let trimmed = String.trim s in
    if trimmed = "" then None else Some trimmed
  | _ -> None

let parse_weighted_item = function
  | `String s ->
    Some {
      model = String.trim s;
      weight = 1;
      supports_tool_choice = None;
      secondary = None;
      secondary_supports_tool_choice = None;
    }
  | `Assoc fields ->
    let open Yojson.Safe.Util in
    let json = `Assoc fields in
    (match json |> member "model" with
     | `String s when String.trim s <> "" ->
       let w = parse_weight_field (json |> member "weight") in
       let stc =
         parse_supports_tool_choice_field
           (json |> member "supports_tool_choice")
       in
       let sec = parse_secondary_field (json |> member "secondary") in
       let sec_stc =
         match sec with
         | None -> None  (* drop override when no secondary declared *)
         | Some _ ->
           parse_supports_tool_choice_field
             (json |> member "secondary_supports_tool_choice")
       in
       Some {
         model = String.trim s;
         weight = w;
         supports_tool_choice = stc;
         secondary = sec;
         secondary_supports_tool_choice = sec_stc;
       }
     | _ -> None)
  | _ -> None

type catalog_entry = {
  name : string;
  keeper_assignable : bool;
  fallback_cascade : string option;
  required_capability_profile : Cascade_capability_profile.profile option;
}

module StringMap = Map.Make (String)

type catalog_field =
  | Schema_field
  | Keeper_assignable_field
  | Fallback_cascade_field
  | Required_capability_profile_field

let catalog_key_specs =
  [
    ("_models", Schema_field);
    ("_temperature", Schema_field);
    ("_max_tokens", Schema_field);
    ("_api_key_env", Schema_field);
    ("_strategy", Schema_field);
    ("_max_cycles", Schema_field);
    ("_backoff_base_ms", Schema_field);
    ("_backoff_cap_ms", Schema_field);
    ("_ollama_max_concurrent", Schema_field);
    ("_cli_max_concurrent", Schema_field);
    ("_tiers", Schema_field);
    ("_sticky_ttl_ms", Schema_field);
    ("_keep_alive", Schema_field);
    ("_num_ctx", Schema_field);
    ("_thinking_enabled", Schema_field);
    ("_thinking_budget", Schema_field);
    (* Scoring parameter overrides (Weighted_random strategy) *)
    ("_latency_baseline_ms", Schema_field);
    ("_rate_limit_recency_window_s", Schema_field);
    ("_rate_limit_decay_base", Schema_field);
    ("_rate_limit_skip_after", Schema_field);
    ("_server_error_recency_window_s", Schema_field);
    ("_server_error_decay_base", Schema_field);
    ("_server_error_skip_after", Schema_field);
    ("_keeper_assignable", Keeper_assignable_field);
    ("_fallback_cascade", Fallback_cascade_field);
    ("_required_capability_profile", Required_capability_profile_field);
  ]

let split_catalog_key key =
  let key_len = String.length key in
  if key_len = 0 || key.[0] = '_' then None
  else
    List.find_map
      (fun (suffix, field) ->
        let suffix_len = String.length suffix in
        if key_len > suffix_len
           && String.sub key (key_len - suffix_len) suffix_len = suffix
        then Some (String.sub key 0 (key_len - suffix_len), field)
        else None)
      catalog_key_specs

(* [required_capability_profile] is a Result so unknown profile names
   surface to [load_catalog] as a fail-closed [Error] instead of a
   silent [None].  Keeping the error inside the builder lets us defer
   the abort to entry-construction time after every key has been
   visited, so the operator gets one consolidated error message even
   when multiple profiles are misconfigured. *)
type capability_profile_parse =
  | Cp_unset
  | Cp_set of Cascade_capability_profile.profile
  | Cp_invalid of string

type catalog_builder = {
  has_schema_field : bool;
  keeper_assignable : bool option;
  fallback_cascade : string option;
  required_capability_profile : capability_profile_parse;
}

let deprecated_logical_profile_names =
  [
    "";
    "default";
    "default_models";
    "oas-keeper_unified";
    "coding_first";
    "oas-coding_first";
    "keeper_reply";
    "keeper_unified";
    "phase_recovery";
    "phase_buffer";
    (* [local_recovery] is intentionally not listed here. Operators can
       declare it as a concrete fallback_cascade profile, and the loader must
       keep that profile visible so fallback chains do not collapse back into
       routes.phase_recovery. *)
    "local_only";
    "tool_required";
    "tool_use_strict";
    "resilient_breaker";
    "governance_judge";
    "operator_judge";
    "cross_verifier";
    "verifier";
    "autoresearch";
    "adversarial_reviewer";
    "auto_responder";
    "routing";
    "routing_judge";
    "openai_compat";
    "persona_generation";
    "provider_benchmark";
    "llm_rerank";
  ]

let is_deprecated_logical_profile_name raw =
  let normalized = String.trim raw |> String.lowercase_ascii in
  List.mem normalized deprecated_logical_profile_names

let empty_catalog_builder = {
  has_schema_field = false;
  keeper_assignable = None;
  fallback_cascade = None;
  required_capability_profile = Cp_unset;
}

let update_catalog_builder builder field value =
  match field with
  | Schema_field -> { builder with has_schema_field = true }
  | Keeper_assignable_field ->
      let keeper_assignable =
        match value with
        | `Bool b -> Some b
        | _ -> builder.keeper_assignable
      in
      { builder with keeper_assignable }
  | Fallback_cascade_field ->
      let fallback_cascade =
        match value with
        | `String s ->
            let trimmed = String.trim s in
            if String.equal trimmed "" then None else Some trimmed
        | _ -> builder.fallback_cascade
      in
      { builder with fallback_cascade }
  | Required_capability_profile_field ->
      let required_capability_profile =
        match value with
        | `String s ->
            let trimmed = String.trim s in
            if String.equal trimmed "" then Cp_unset
            else
              (match Cascade_capability_profile.profile_of_string trimmed with
               | Some p -> Cp_set p
               | None -> Cp_invalid trimmed)
        | _ -> builder.required_capability_profile
      in
      { builder with required_capability_profile }

(* Detect fallback_cascade cycles in a freshly loaded catalog.

   2026-05-05 fleet-stuck root cause: the operator-side cascade.toml
   declared [default.fallback_cascade = "glm_coding_plan_only"] AND
   [glm_coding_plan_only.fallback_cascade = "default"].  When the
   GLM provider stalled, both cascades escalated to each other,
   producing a silent 600s+ timeout chain with no operator-visible
   reason.  This helper walks the fallback graph and emits a Prometheus
   counter + WARN log per cycle entry point so a CI test or operator
   alert can catch the same shape before it goes live. *)
let detect_fallback_cycles (entries : catalog_entry list) :
    string list list =
  let by_name =
    List.fold_left
      (fun acc e -> StringMap.add e.name e acc)
      StringMap.empty entries
  in
  let rec walk visited current =
    match StringMap.find_opt current by_name with
    | None -> None
    | Some entry ->
      (match entry.fallback_cascade with
       | None -> None
       | Some next when List.mem next visited ->
         (* Cycle: trim [visited] to start at [next]. *)
         let rec trim = function
           | [] -> []
           | x :: _ as l when String.equal x next -> List.rev l
           | _ :: rest -> trim rest
         in
         Some (trim (current :: visited))
       | Some next ->
         walk (current :: visited) next)
  in
  List.filter_map
    (fun entry -> walk [] entry.name)
    entries
  |> (* Deduplicate cycles up to rotation: sort each cycle and keep
        unique sets so [A→B→A] and [B→A→B] count as one. *)
     List.fold_left
       (fun (seen, acc) cycle ->
         let key = String.concat "|" (List.sort compare cycle) in
         if List.mem key seen then (seen, acc)
         else (key :: seen, cycle :: acc))
       ([], [])
  |> snd
  |> List.rev

(* RFC-0055: capability monotonicity on fallback edges.

   A fallback edge source -> target is valid only if:
   1. target's capability profile is a superset of source's profile.
   2. An assignable cascade cannot fall back to a non-assignable (sink)
      cascade. *)
let detect_capability_mismatches (entries : catalog_entry list) :
    (string * string * string) list =
  let by_name =
    List.fold_left
      (fun acc e -> StringMap.add e.name e acc)
      StringMap.empty entries
  in
  List.filter_map
    (fun (entry : catalog_entry) ->
      match entry.fallback_cascade with
      | None -> None
      | Some target_name -> (
          match StringMap.find_opt target_name by_name with
          | None -> None
          | Some (target : catalog_entry) ->
              let assignable_violation =
                if entry.keeper_assignable && not target.keeper_assignable then
                  Some
                    ( entry.name,
                      target_name,
                      "assignable cascade falls back to sink \
                       (keeper_assignable=false)" )
                else None
              in
              let cap_violation =
                match
                  ( entry.required_capability_profile,
                    target.required_capability_profile )
                with
                | Some src_p, Some dst_p ->
                    if not (Cascade_tier.is_subset_profile src_p dst_p) then
                      Some
                        ( entry.name,
                          target_name,
                          Printf.sprintf
                            "capability profile %s is not a subset of target \
                             profile %s"
                            (Cascade_capability_profile.profile_to_string src_p)
                            (Cascade_capability_profile.profile_to_string dst_p) )
                    else None
                | _ -> None
              in
              match assignable_violation, cap_violation with
              | Some v, _ -> Some v
              | None, Some v -> Some v
              | None, None -> None))
    entries

let load_catalog ~config_path =
  match load_json config_path with
  | Error _ as err -> err
  | Ok (`Assoc fields) ->
      let builders =
        List.fold_left
          (fun acc (key, value) ->
            match split_catalog_key key with
            | None -> acc
            | Some (name, field) ->
                let prior =
                  match StringMap.find_opt name acc with
                  | Some builder -> builder
                  | None -> empty_catalog_builder
                in
                StringMap.add name (update_catalog_builder prior field value) acc)
          StringMap.empty
          fields
      in
      let active_builders =
        builders
        |> StringMap.bindings
        |> List.filter (fun (name, builder) ->
               builder.has_schema_field
               && not (is_deprecated_logical_profile_name name))
      in
      let invalid_profile_errors =
        List.filter_map
          (fun (name, builder) ->
            match builder.required_capability_profile with
            | Cp_invalid raw ->
                Some
                  (Printf.sprintf
                     "cascade %s: unknown required_capability_profile %S \
                      (known: %s)"
                     name raw
                     (Cascade_capability_profile.all_profiles
                      |> List.map Cascade_capability_profile.profile_to_string
                      |> String.concat ", "))
            | _ -> None)
          active_builders
      in
      if invalid_profile_errors <> [] then
        Error (String.concat "; " invalid_profile_errors)
      else
      let entries =
        List.map
          (fun (name, builder) ->
            let required_capability_profile =
              match builder.required_capability_profile with
              | Cp_set p -> Some p
              | Cp_unset -> None
              | Cp_invalid _ -> None  (* unreachable: filtered above *)
            in
            {
              name;
              keeper_assignable =
                Option.value builder.keeper_assignable ~default:true;
              fallback_cascade = builder.fallback_cascade;
              required_capability_profile;
            })
          active_builders
      in
      let cycles = detect_fallback_cycles entries in
      let key = cycle_set_key cycles in
      let should_warn =
        with_cycle_warn_lock (fun () ->
          match Hashtbl.find_opt cycle_warn_seen config_path with
          | Some k when String.equal k key -> false
          | _ ->
            Hashtbl.replace cycle_warn_seen config_path key;
            true)
      in
      List.iter
        (fun cycle ->
          let entry = match cycle with x :: _ -> x | [] -> "?" in
          Prometheus.inc_counter
            Prometheus.metric_cascade_fallback_cycle_detected_total
            ~labels:[("cascade", entry)] ();
          if should_warn then
            Log.warn ~ctx:"CascadeConfig"
              "fallback_cascade cycle detected at [%s]: %s — provider \
               stalls in any participant will silently propagate through \
               the entire loop (no escape).  Break the cycle by setting \
               at least one fallback_cascade to a non-participating \
               cascade (e.g. local_recovery) or removing the field."
              entry (String.concat " → " (cycle @ [entry])))
        cycles;
      let mismatches = detect_capability_mismatches entries in
      if mismatches <> [] then
        Error
          (Printf.sprintf "cascade capability mismatch (RFC-0055): %s"
             (mismatches
             |> List.map (fun (src, dst, reason) ->
                    Printf.sprintf "%s -> %s: %s" src dst reason)
             |> String.concat "; "))
      else
        Ok entries
  | Ok _ -> Ok []

let load_profile_weighted ~config_path ~name =
  let key = name ^ "_models" in
  match load_json config_path with
  | Error msg ->
      (* Surface the load failure on the standard logging channel so
         operators see it without tailing stderr. Returning the empty
         list still lets callers fall back through the configured
         keeper route (see [Cascade_config.resolve_model_strings_traced_with]),
         but the elevated WARN gives observability into what would
         otherwise be a silent permissive-default cascade. *)
      Log.warn ~ctx:"CascadeConfig"
        "load_profile_weighted: %s (profile=%s, path=%s)"
        msg name config_path;
      []
  | Ok json ->
    let open Yojson.Safe.Util in
    match json |> member key with
    | `List items -> List.filter_map parse_weighted_item items
    | _ -> []

let load_profile ~config_path ~name =
  load_profile_weighted ~config_path ~name
  |> List.map (fun e -> e.model)

(* ── Inference parameter resolution ───────────────────── *)

type inference_params = {
  temperature: float option;
  max_tokens: int option;
  keep_alive: string option;
  (** Ollama [keep_alive] override: integer seconds ("-1", "3600") or
      duration string ("5m", "30m"). Honored only when the resolved
      provider is Ollama. *)
  num_ctx: int option;
  (** Ollama [num_ctx] override: per-request KV cache allocation in
      tokens. Honored only when the resolved provider is Ollama. *)
  thinking_enabled: bool option;
  thinking_budget: int option;
  (** [thinking_budget] is a per-turn thinking token budget seed.
      Keeper adaptive logic may adjust this per turn based on intent
      classification and error/retry signals.  Provider-specific
      mapping (e.g. to Anthropic [budget_tokens] or DeepSeek
      [reasoning_effort]) happens downstream in OAS. *)
}

let read_float_field json key =
  let open Yojson.Safe.Util in
  match json |> member key with
  | `Float f -> Some f
  | `Int i -> Some (float_of_int i)
  | _ -> None

let read_int_field json key =
  let open Yojson.Safe.Util in
  match json |> member key with
  | `Int i -> Some i
  | `Float f -> Some (int_of_float f)
  | _ -> None

let read_string_field json key =
  let open Yojson.Safe.Util in
  match json |> member key with
  | `String s ->
      let trimmed = String.trim s in
      if trimmed <> "" then Some trimmed else None
  | _ -> None

let read_bool_field json key =
  let open Yojson.Safe.Util in
  match json |> member key with
  | `Bool b -> Some b
  | _ -> None

let resolve_inference_params ~config_path ~name =
  match load_json config_path with
  | Error msg ->
      Log.Misc.warn "[CascadeConfig] resolve_inference_params: %s (name=%s, path=%s)"
        msg name config_path;
      { temperature = None; max_tokens = None;
        keep_alive = None; num_ctx = None;
        thinking_enabled = None; thinking_budget = None }
  | Ok json ->
    let temp =
      match read_float_field json (name ^ "_temperature") with
      | Some _ as v -> v
      | None -> read_float_field json "default_temperature"
    in
    let max_tok =
      match read_int_field json (name ^ "_max_tokens") with
      | Some _ as v -> v
      | None -> read_int_field json "default_max_tokens"
    in
    let keep_alive =
      match read_string_field json (name ^ "_keep_alive") with
      | Some _ as v -> v
      | None -> read_string_field json "default_keep_alive"
    in
    let num_ctx =
      match read_int_field json (name ^ "_num_ctx") with
      | Some n when n > 0 -> Some n
      | _ ->
        (match read_int_field json "default_num_ctx" with
         | Some n when n > 0 -> Some n
         | _ -> None)
    in
    let thinking_enabled =
      match read_bool_field json (name ^ "_thinking_enabled") with
      | Some _ as v -> v
      | None -> read_bool_field json "default_thinking_enabled"
    in
    let thinking_budget =
      match read_int_field json (name ^ "_thinking_budget") with
      | Some n when n > 0 -> Some n
      | _ ->
        (match read_int_field json "default_thinking_budget" with
         | Some n when n > 0 -> Some n
         | _ -> None)
    in
    { temperature = temp; max_tokens = max_tok; keep_alive; num_ctx;
      thinking_enabled; thinking_budget }

(* ── Per-cascade API key env override ────────────────── *)

(** Read an api_key_env override object from JSON.

    The JSON value can be:
    - A string: applies to all providers in the cascade.
      [{"{name}_api_key_env": "ZAI_API_KEY_SB"}]
    - An object mapping provider names to env var names:
      [{"{name}_api_key_env": {"glm": "ZAI_API_KEY_SB", "glm-coding": "ZAI_API_KEY_SB"}}]

    Returns an association list of [(provider_name, env_var_name)].
    The special key ["*"] means "all providers". *)
let read_api_key_env_field json key =
  let open Yojson.Safe.Util in
  match json |> member key with
  | `String s ->
      let trimmed = String.trim s in
      if trimmed <> "" then [("*", trimmed)] else []
  | `Assoc pairs ->
    List.filter_map (fun (k, v) ->
      match v with
      | `String s ->
          let trimmed_s = String.trim s in
          if trimmed_s <> "" then
            Some (String.lowercase_ascii (String.trim k), trimmed_s)
          else None
      | _ -> None
    ) pairs
  | _ -> []

let resolve_api_key_env ~config_path ~name =
  match load_json config_path with
  | Error msg ->
      Log.Misc.warn "[CascadeConfig] resolve_api_key_env: %s (name=%s, path=%s)"
        msg name config_path;
      []
  | Ok json ->
    match read_api_key_env_field json (name ^ "_api_key_env") with
    | [] -> read_api_key_env_field json "default_api_key_env"
    | overrides -> overrides

(* ── Per-cascade pluggable-strategy override ──────────── *)

type strategy_config = {
  kind : string option;
  max_cycles : int option;
  backoff_base_ms : int option;
  backoff_cap_ms : int option;
  ollama_max_concurrent : int option;
  cli_max_concurrent : int option;
  tiers : string list list option;
  sticky_ttl_ms : int option;
  (* ── Scoring parameter overrides (Weighted_random strategy) ── *)
  latency_baseline_ms : float option;
  (** Milliseconds.  Provider p50 above this value incurs a fractional
      score penalty.  When [None], falls back to
      [MASC_CASCADE_LATENCY_BASELINE_MS] env var, then default 2000.0. *)
  rate_limit_recency_window_s : float option;
  (** Seconds.  Lookback window for counting recent 429 events.
      When [None], falls back to env var, then default 60.0. *)
  rate_limit_decay_base : float option;
  (** Per-event decay multiplier in (0.0, 1.0).
      When [None], falls back to env var, then default 0.5. *)
  rate_limit_skip_after : int option;
  (** Hard-skip threshold for 429 events.
      When [None], falls back to env var, then default 3. *)
  server_error_recency_window_s : float option;
  (** Seconds.  Lookback window for counting recent 5xx events.
      When [None], falls back to env var, then default 120.0. *)
  server_error_decay_base : float option;
  (** Per-event decay multiplier in (0.0, 1.0).
      When [None], falls back to env var, then default 0.6. *)
  server_error_skip_after : int option;
  (** Hard-skip threshold for 5xx events.
      When [None], falls back to env var, then default 4. *)
}

(* Read a [string list list] from a JSON [list of list of string].
   Returns [None] when the key is missing or any element has the
   wrong shape; tier configuration must be all-or-nothing to avoid
   silent misroutes. *)
let read_tiers_field json key =
  let open Yojson.Safe.Util in
  match json |> member key with
  | `Null -> None
  | `List outer ->
    let parse_tier = function
      | `List inner ->
        let strs = List.filter_map (function
            | `String s when String.trim s <> "" -> Some (String.trim s)
            | _ -> None) inner
        in
        if List.length strs = List.length inner && strs <> [] then Some strs
        else None
      | _ -> None
    in
    let tiers = List.filter_map parse_tier outer in
    if List.length tiers = List.length outer && tiers <> [] then Some tiers
    else None
  | _ -> None

let empty_strategy_config = {
  kind = None;
  max_cycles = None;
  backoff_base_ms = None;
  backoff_cap_ms = None;
  ollama_max_concurrent = None;
  cli_max_concurrent = None;
  tiers = None;
  sticky_ttl_ms = None;
  latency_baseline_ms = None;
  rate_limit_recency_window_s = None;
  rate_limit_decay_base = None;
  rate_limit_skip_after = None;
  server_error_recency_window_s = None;
  server_error_decay_base = None;
  server_error_skip_after = None;
}

let resolve_strategy_config ~config_path ~name =
  match load_json config_path with
  | Error msg ->
      Log.Misc.warn "[CascadeConfig] resolve_strategy_config: %s (name=%s, path=%s)"
        msg name config_path;
      empty_strategy_config
  | Ok json ->
    {
      kind = read_string_field json (name ^ "_strategy");
      max_cycles = read_int_field json (name ^ "_max_cycles");
      backoff_base_ms = read_int_field json (name ^ "_backoff_base_ms");
      backoff_cap_ms = read_int_field json (name ^ "_backoff_cap_ms");
      ollama_max_concurrent =
        read_int_field json (name ^ "_ollama_max_concurrent");
      cli_max_concurrent =
        read_int_field json (name ^ "_cli_max_concurrent");
      tiers = read_tiers_field json (name ^ "_tiers");
      sticky_ttl_ms = read_int_field json (name ^ "_sticky_ttl_ms");
      latency_baseline_ms =
        read_float_field json (name ^ "_latency_baseline_ms");
      rate_limit_recency_window_s =
        read_float_field json (name ^ "_rate_limit_recency_window_s");
      rate_limit_decay_base =
        read_float_field json (name ^ "_rate_limit_decay_base");
      rate_limit_skip_after =
        read_int_field json (name ^ "_rate_limit_skip_after");
      server_error_recency_window_s =
        read_float_field json (name ^ "_server_error_recency_window_s");
      server_error_decay_base =
        read_float_field json (name ^ "_server_error_decay_base");
      server_error_skip_after =
        read_int_field json (name ^ "_server_error_skip_after");
    }

(* ── RFC-0041: cascade_profile loader ──────────────────────────────── *)

(** Split a "provider:model" string into (provider, model).
    Returns [None] when the separator is missing. *)
let provider_model_of_string (s : string) : (string * string) option =
  match String.split_on_char ':' s with
  | [provider; model] -> Some (provider, model)
  | _ -> None

(** Convert a [weighted_entry] (from legacy cascade.json) into a
    [Cascade_ref.cascade_item].  [timeout_ms] defaults to 30000;
    [priority] uses the entry's [weight]. *)
let cascade_item_of_weighted_entry (entry : weighted_entry)
    : Cascade_ref.cascade_item option =
  match provider_model_of_string entry.model with
  | Some (provider, model) ->
      Some {
        Cascade_ref.id = entry.model;
        provider;
        model;
        timeout_ms = 30000;
        priority = entry.weight;
      }
  | None -> None

(** Load a [Cascade_ref.cascade_profile] from the hierarchical
    [{name}_groups] format in cascade.json.  Each object in the array
    is parsed through [Cascade_ref.cascade_group_of_json].

    Returns [None] when the key is absent or no groups parse
    successfully. *)
let load_cascade_profile_hierarchical ~(config_path : string) ~(name : string)
    : Cascade_ref.cascade_profile option =
  match load_json config_path with
  | Error _ -> None
  | Ok json ->
      let open Yojson.Safe.Util in
      match json |> member (name ^ "_groups") with
      | `List arr ->
          let groups = List.filter_map Cascade_ref.cascade_group_of_json arr in
          if groups = [] then None
          else Some { Cascade_ref.name; groups }
      | _ -> None

(** Load a [Cascade_ref.cascade_profile] from the legacy cascade.json
    format.  Each profile section becomes a single-group profile;
    [models] become [cascade_item]s and [fallback_cascade] becomes
    [fallback_group].

    Returns [None] when the profile has no parsable model entries.
    This is the bridge between the existing flat cascade.json format
    and the RFC-0041 hierarchical profile model. *)
let load_cascade_profile_legacy ~(config_path : string) ~(name : string)
    : Cascade_ref.cascade_profile option =
  let items =
    load_profile_weighted ~config_path ~name
    |> List.filter_map cascade_item_of_weighted_entry
  in
  if items = [] then None
  else
    let fallback_group =
      match load_catalog ~config_path with
      | Ok entries ->
          (match List.find_opt (fun e -> String.equal e.name name) entries with
           | Some entry -> entry.fallback_cascade
           | None -> None)
      | Error _ -> None
    in
    Some {
      Cascade_ref.name;
      groups = [{
        Cascade_ref.name;
        items;
        strategy = Priority;
        fallback_group;
      }];
    }

(** Load a [Cascade_ref.cascade_profile] from cascade.json.

    Tries the hierarchical [{name}_groups] format first (RFC-0041).
    Falls back to the legacy flat [{name}_models] format for backward
    compatibility.

    Returns [None] when neither format yields a valid profile. *)
let load_cascade_profile ~(config_path : string) ~(name : string)
    : Cascade_ref.cascade_profile option =
  match load_cascade_profile_hierarchical ~config_path ~name with
  | Some profile -> Some profile
  | None -> load_cascade_profile_legacy ~config_path ~name
