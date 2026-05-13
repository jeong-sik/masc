(** JSON config loading with mtime-based hot-reload.

    Loads and caches cascade profile JSON files.  The cache is keyed by
    file path and invalidated when the file mtime changes.

    @since 0.59.0
    @since 0.92.0 extracted from Cascade_config *)

let config_cache : (string, float * Yojson.Safe.t) Hashtbl.t = Hashtbl.create 4

(** Stdlib Mutex — no Eio dependency. Keep the critical section limited to
    cache access so file I/O and JSON parsing do not block unrelated fibers
    longer than necessary when called from an Eio domain. *)
let config_cache_mu = Mutex.create ()

let with_cache_lock f =
  Mutex.lock config_cache_mu;
  Fun.protect ~finally:(fun () -> Mutex.unlock config_cache_mu) f
;;

let invalidate_cache_entry path =
  with_cache_lock (fun () -> Hashtbl.remove config_cache path)
;;

(* RFC-0058 §9 Phase 9.2: previous [ensure_materialized_json] wrapper
   removed — it was private (not in [.mli]) and had zero call sites.
   In-process callers route through [load_toml_in_memory] which never
   touches the JSON sibling on disk. *)

let read_json_file path =
  let ic = open_in path in
  let content =
    Eio_guard.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
         let len = in_channel_length ic in
         let buf = Bytes.create len in
         really_input ic buf 0 len;
         Bytes.to_string buf)
  in
  Yojson.Safe.from_string content
;;

(* Race-aware in-memory TOML loader.

   Previous design (kept here for context — do not regress to it):
     1. render TOML → json_string
     2. stat → mtime  (after the read)
     3. cache (mtime, json)
   Failure mode: between steps 1 and 2 the operator atomically replaces
   cascade.toml.  Step 1 captured the OLD content; step 2 captured the
   NEW mtime.  The pair (NEW_mtime, OLD_content) lands in the cache and
   pins stale config until the NEXT mtime change — operator's reload
   silently lost.  Also: cache lookup happened after the render, so a
   cache hit still paid the full TOML parse + JSON parse + serialize
   cost.

   Current design:
     1. stat → mtime_pre                         (cheap; no read)
     2. cache lookup keyed by (path, mtime_pre)
          HIT  → return cached JSON, skip render entirely
          MISS → render TOML → json_string
                 stat → mtime_post
                 if mtime_pre = mtime_post:  cache (mtime_pre, json)
                 else:                       race; serve fresh json
                                             but DO NOT cache
   The skip-cache-on-race arm bounds the staleness window to a single
   call; the next caller re-stats and either gets the settled mtime or
   detects another race.  Cache-hit fast path drops TOML reparse cost
   on every steady-state load.

   The mtime drift is also surfaced via
   [Cascade_metrics.on_toml_read_race] so operators can alert on
   pathological reload churn (e.g. a writer that fsyncs in a tight
   loop). *)
let load_toml_in_memory ~emit_telemetry config_path =
  let source_state =
    Cascade_toml_materializer.source_state ~config_path
  in
  let cache_key = source_state.info.source_path in
  match source_state.source_mtime with
  | None ->
    (* Couldn't stat the resolved path.  Skip the pre-stat fast path
       and let [render_toml_to_json_string] surface the real error
       (file missing, permission denied, etc.) — its error message is
       more actionable than what we could synthesize here. *)
    (match Cascade_toml_materializer.render_toml_to_json_string ~config_path with
     | Error msg -> Error msg
     | Ok (_source, json_string) -> Ok (Yojson.Safe.from_string json_string))
  | Some mtime_pre ->
    let cached =
      with_cache_lock (fun () ->
        match Hashtbl.find_opt config_cache cache_key with
        | Some (cached_mtime, cached_json)
          when Float.equal cached_mtime mtime_pre ->
          Some cached_json
        | _ -> None)
    in
    (match cached with
     | Some cached_json -> Ok cached_json
     | None ->
       (match Cascade_toml_materializer.render_toml_to_json_string ~config_path with
        | Error msg -> Error msg
        | Ok (_source, json_string) ->
          let mtime_post =
            try Some (Unix.stat cache_key).Unix.st_mtime with
            | Unix.Unix_error _ | Sys_error _ -> None
          in
          let json = Yojson.Safe.from_string json_string in
          (match mtime_post with
           | Some mp when Float.equal mp mtime_pre ->
             with_cache_lock (fun () ->
               Hashtbl.replace config_cache cache_key (mp, json));
            if emit_telemetry then
              Eio.traceln
                "[CascadeConfig] loaded TOML %s mtime=%.0f (in-memory)"
                cache_key
                mp;
            Ok json
           | Some mp ->
             (* mtime moved between the pre-stat and the post-stat.
                The rendered content is fresh-as-of mp but we cannot
                prove it matches either sample, so we don't cache —
                next call will re-stat and converge. *)
             if emit_telemetry then begin
               Cascade_metrics.on_toml_read_race ();
               Log.warn
                 ~ctx:"CascadeConfig"
                 "TOML changed mid-read (mtime %.0f -> %.0f) for %s; \
                  serving fresh content but skipping cache update to \
                  force re-stat on next call"
                 mtime_pre
                 mp
                 cache_key
             end;
             Ok json
           | None ->
             (* Post-stat failed (file vanished mid-read).  Treat
                like a race so the caller re-converges next time. *)
             if emit_telemetry then begin
               Cascade_metrics.on_toml_read_race ();
               Log.warn
                 ~ctx:"CascadeConfig"
                 "TOML disappeared mid-read after mtime=%.0f for %s; \
                  returning in-memory render but skipping cache update"
                 mtime_pre
                 cache_key
             end;
             Ok json)))
;;

(* RFC-0058 §9 Phase 9.3: TOML is the only cascade source. The previous
   JSON-only disk-read branch has been removed along with
   [source_kind = Json]. All paths flow through
   [load_toml_in_memory], which renders TOML to JSON in memory and
   caches by source-path mtime.

   Named [load_catalog_source] rather than [load_json] because no
   on-disk JSON is read: [cascade.toml] is parsed and rendered to an
   in-memory [Yojson.Safe.t] view for internal consumers. *)
let load_catalog_source_impl ~emit_telemetry path =
  try load_toml_in_memory ~emit_telemetry path with
  | Sys_error msg -> Error msg
  | Unix.Unix_error (err, fn, arg) ->
    Error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message err))
  | Yojson.Json_error msg -> Error (Printf.sprintf "JSON error: %s" msg)
  | End_of_file ->
    (* [Fs_compat.load_file_unix] reads [in_channel_length] first, then
       [really_input_string len]. If the file is truncated between the
       two calls (concurrent writer, atomic-rename mid-flight), the
       second call raises [End_of_file]. Surface as an [Error] instead
       of crashing the loader. *)
    Error (Printf.sprintf "cascade source truncated mid-read: %s" path)
;;

let load_catalog_source path =
  load_catalog_source_impl ~emit_telemetry:true path
;;

let load_catalog_source_for_diagnostics path =
  load_catalog_source_impl ~emit_telemetry:false path
;;

(** A model entry with an optional weight for weighted cascade selection.
    Weight defaults to 1 when not specified (backward compatible).
    [secondary] is the RFC-0027 PR-9 dual-track fallback (CLI primary +
    direct-API secondary), [None] for legacy entries. *)
type weighted_entry =
  { model : string
  ; weight : int
  ; supports_tool_choice : bool option
  ; secondary : string option
  ; secondary_supports_tool_choice : bool option
  }

let deprecated_logical_profile_names =
  [ ""
  ; "default"
  ; "default_models"
  ; "oas-keeper_unified"
  ; "coding_first"
  ; "oas-coding_first"
  ; "keeper_reply"
  ; "keeper_unified"
  ; "phase_recovery"
  ; "phase_buffer"
  ; (* [local_recovery] is intentionally not listed here. Operators can
       declare it as a concrete fallback_cascade profile, and the loader must
       keep that profile visible so fallback chains do not collapse back into
       routes.phase_recovery. *)
    "local_only"
  ; "tool_required"
  ; "tool_use_strict"
  ; "resilient_breaker"
  ; "governance_judge"
  ; "operator_judge"
  ; "cross_verifier"
  ; "verifier"
  ; "autoresearch"
  ; "adversarial_reviewer"
  ; "auto_responder"
  ; "routing"
  ; "routing_judge"
  ; "openai_compat"
  ; "persona_generation"
  ; "provider_benchmark"
  ; "llm_rerank"
  ]
;;

let is_deprecated_logical_profile_name raw =
  let normalized = String.trim raw |> String.lowercase_ascii in
  List.mem normalized deprecated_logical_profile_names
;;

(* ── Inference parameter resolution ───────────────────── *)

type inference_params =
  { temperature : float option
  ; max_tokens : int option
  ; keep_alive : string option
    (** Ollama [keep_alive] override: integer seconds ("-1", "3600") or
      duration string ("5m", "30m"). Honored only when the resolved
      provider is Ollama. *)
  ; num_ctx : int option
    (** Ollama [num_ctx] override: per-request KV cache allocation in
      tokens. Honored only when the resolved provider is Ollama. *)
  ; thinking_enabled : bool option
  ; thinking_budget : int option
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
;;

let read_int_field json key =
  let open Yojson.Safe.Util in
  match json |> member key with
  | `Int i -> Some i
  | `Float f -> Some (int_of_float f)
  | _ -> None
;;

let read_string_field json key =
  let open Yojson.Safe.Util in
  match json |> member key with
  | `String s ->
    let trimmed = String.trim s in
    if trimmed <> "" then Some trimmed else None
  | _ -> None
;;

let read_bool_field json key =
  let open Yojson.Safe.Util in
  match json |> member key with
  | `Bool b -> Some b
  | _ -> None
;;

let resolve_inference_params ~config_path ~name =
  match load_catalog_source config_path with
  | Error msg ->
    Log.Misc.warn
      "[CascadeConfig] resolve_inference_params: %s (name=%s, path=%s)"
      msg
      name
      config_path;
    { temperature = None
    ; max_tokens = None
    ; keep_alive = None
    ; num_ctx = None
    ; thinking_enabled = None
    ; thinking_budget = None
    }
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
    { temperature = temp
    ; max_tokens = max_tok
    ; keep_alive
    ; num_ctx
    ; thinking_enabled
    ; thinking_budget
    }
;;

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
    if trimmed <> "" then [ "*", trimmed ] else []
  | `Assoc pairs ->
    List.filter_map
      (fun (k, v) ->
         match v with
         | `String s ->
           let trimmed_s = String.trim s in
           if trimmed_s <> ""
           then Some (String.lowercase_ascii (String.trim k), trimmed_s)
           else None
         | _ -> None)
      pairs
  | _ -> []
;;

let resolve_api_key_env ~config_path ~name =
  match load_catalog_source config_path with
  | Error msg ->
    Log.Misc.warn
      "[CascadeConfig] resolve_api_key_env: %s (name=%s, path=%s)"
      msg
      name
      config_path;
    []
  | Ok json ->
    (match read_api_key_env_field json (name ^ "_api_key_env") with
     | [] -> read_api_key_env_field json "default_api_key_env"
     | overrides -> overrides)
;;

(* ── Per-cascade pluggable-strategy override ──────────── *)

type strategy_config =
  { kind : string option
  ; max_cycles : int option
  ; backoff_base_ms : int option
  ; backoff_cap_ms : int option
  ; ollama_max_concurrent : int option
  ; cli_max_concurrent : int option
  ; tiers : string list list option
  ; sticky_ttl_ms : int option
  ; (* ── Scoring parameter overrides (Weighted_random strategy) ── *)
    latency_baseline_ms : float option
    (** Milliseconds.  Provider p50 above this value incurs a fractional
      score penalty.  When [None], falls back to
      [MASC_CASCADE_LATENCY_BASELINE_MS] env var, then default 2000.0. *)
  ; rate_limit_recency_window_s : float option
    (** Seconds.  Lookback window for counting recent 429 events.
      When [None], falls back to env var, then default 60.0. *)
  ; rate_limit_decay_base : float option
    (** Per-event decay multiplier in (0.0, 1.0).
      When [None], falls back to env var, then default 0.5. *)
  ; rate_limit_skip_after : int option
    (** Hard-skip threshold for 429 events.
      When [None], falls back to env var, then default 3. *)
  ; server_error_recency_window_s : float option
    (** Seconds.  Lookback window for counting recent 5xx events.
      When [None], falls back to env var, then default 120.0. *)
  ; server_error_decay_base : float option
    (** Per-event decay multiplier in (0.0, 1.0).
      When [None], falls back to env var, then default 0.6. *)
  ; server_error_skip_after : int option
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
        let strs =
          List.filter_map
            (function
              | `String s when String.trim s <> "" -> Some (String.trim s)
              | _ -> None)
            inner
        in
        if List.length strs = List.length inner && strs <> [] then Some strs else None
      | _ -> None
    in
    let tiers = List.filter_map parse_tier outer in
    if List.length tiers = List.length outer && tiers <> [] then Some tiers else None
  | _ -> None
;;

let empty_strategy_config =
  { kind = None
  ; max_cycles = None
  ; backoff_base_ms = None
  ; backoff_cap_ms = None
  ; ollama_max_concurrent = None
  ; cli_max_concurrent = None
  ; tiers = None
  ; sticky_ttl_ms = None
  ; latency_baseline_ms = None
  ; rate_limit_recency_window_s = None
  ; rate_limit_decay_base = None
  ; rate_limit_skip_after = None
  ; server_error_recency_window_s = None
  ; server_error_decay_base = None
  ; server_error_skip_after = None
  }
;;

let resolve_strategy_config_impl ~emit_telemetry ~config_path ~name =
  match load_catalog_source_impl ~emit_telemetry config_path with
  | Error msg ->
    Log.Misc.warn
      "[CascadeConfig] resolve_strategy_config: %s (name=%s, path=%s)"
      msg
      name
      config_path;
    empty_strategy_config
  | Ok json ->
    { kind = read_string_field json (name ^ "_strategy")
    ; max_cycles = read_int_field json (name ^ "_max_cycles")
    ; backoff_base_ms = read_int_field json (name ^ "_backoff_base_ms")
    ; backoff_cap_ms = read_int_field json (name ^ "_backoff_cap_ms")
    ; ollama_max_concurrent = read_int_field json (name ^ "_ollama_max_concurrent")
    ; cli_max_concurrent = read_int_field json (name ^ "_cli_max_concurrent")
    ; tiers = read_tiers_field json (name ^ "_tiers")
    ; sticky_ttl_ms = read_int_field json (name ^ "_sticky_ttl_ms")
    ; latency_baseline_ms = read_float_field json (name ^ "_latency_baseline_ms")
    ; rate_limit_recency_window_s =
        read_float_field json (name ^ "_rate_limit_recency_window_s")
    ; rate_limit_decay_base = read_float_field json (name ^ "_rate_limit_decay_base")
    ; rate_limit_skip_after = read_int_field json (name ^ "_rate_limit_skip_after")
    ; server_error_recency_window_s =
        read_float_field json (name ^ "_server_error_recency_window_s")
    ; server_error_decay_base = read_float_field json (name ^ "_server_error_decay_base")
    ; server_error_skip_after = read_int_field json (name ^ "_server_error_skip_after")
    }
;;
let resolve_strategy_config ~config_path ~name =
  resolve_strategy_config_impl ~emit_telemetry:true ~config_path ~name
;;

let resolve_strategy_config_for_diagnostics ~config_path ~name =
  resolve_strategy_config_impl ~emit_telemetry:false ~config_path ~name
;;
