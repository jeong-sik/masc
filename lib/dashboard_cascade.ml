module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Dashboard projection for cascade configuration and runtime health. *)

module CC = Cascade_config
module Health = Cascade_health_tracker
module StringSet = Set.Make (String)

(* ── Shared helpers ─────────────────────────────────── *)

let now_iso () = Masc_domain.now_iso ()

let candidate_to_json (c : CC.candidate_info) : Yojson.Safe.t =
  `Assoc
    [ "model", `String c.model_string
    ; "display_model", `String c.display_model_string
    ; "provider_name", Json_util.string_opt_to_json c.provider_name
    ; "display_provider_name", Json_util.string_opt_to_json c.display_provider_name
    ; "runtime_kind", Json_util.string_opt_to_json c.runtime_kind
    ; "expanded_models", `List (List.map (fun model -> `String model) c.expanded_models)
    ; "config_weight", `Int c.config_weight
    ; "effective_weight", `Int c.effective_weight
    ; "success_rate", `Float c.success_rate
    ; "in_cooldown", `Bool c.in_cooldown
    ]
;;

let source_to_string = function
  | CC.Named -> "named"
  | CC.Default_fallback -> "default_fallback"
  | CC.Hardcoded_defaults -> "hardcoded_defaults"
  | CC.Load_failed _ -> "load_failed"
;;

let string_list_to_json values = `List (List.map (fun value -> `String value) values)

let invalid_profile_to_json ((name, errors) : string * string list) =
  `Assoc [ "name", `String name; "errors", string_list_to_json errors ]
;;

let json_assoc_member key = function
  | `Assoc fields -> Option.value (List.assoc_opt key fields) ~default:`Null
  | _ -> `Null
;;

let json_string_list = function
  | `List values ->
    List.filter_map
      (function
        | `String value -> Some value
        | _ -> None)
      values
  | _ -> []
;;

let invalid_profiles_of_rejection_json rejection_json =
  match json_assoc_member "profiles" rejection_json with
  | `List profiles ->
    List.filter_map
      (fun profile_json ->
         match json_assoc_member "name" profile_json with
         | `String name ->
           Some (name, json_string_list (json_assoc_member "errors" profile_json))
         | _ -> None)
      profiles
  | _ -> []
;;

let source_info ?config_path () =
  let config_path =
    match config_path with
    | Some path -> path
    | None -> Config_dir_resolver.cascade_path_candidate ()
  in
  Cascade_toml_materializer.source_info ~config_path
;;

let source_json_fields (source : Cascade_toml_materializer.source_info) =
  [ "source_kind", `String (Cascade_toml_materializer.source_kind_to_string source.kind)
  ; "source_path", `String source.source_path
  ]
;;

(* ── Config projection ──────────────────────────────── *)

(** Profiles to surface in the dashboard.

    When the validated runtime snapshot is unavailable (for example
    before first successful validation), fall back to the active
    [cascade.json] catalog so the dashboard still renders a best-effort
    raw projection instead of failing hard. *)
let live_profiles ?config_path () = Keeper_cascade_profile.catalog_names ?config_path ()

let keeper_assignable_name_set ?config_path () =
  Keeper_cascade_profile.keeper_catalog_names ?config_path ()
  |> List.fold_left (fun acc name -> StringSet.add name acc) StringSet.empty
;;

let profile_json_of_trace ~keeper_assignable name (trace : CC.selection_trace) =
  `Assoc
    [ "name", `String name
    ; "source", `String (source_to_string trace.source)
    ; "keeper_assignable", `Bool keeper_assignable
    ; "candidates", `List (List.map candidate_to_json trace.candidates)
    ]
;;

let profile_json_runtime ~keeper_assignable_names name =
  match Cascade_catalog_runtime.resolve_selection_trace ~name () with
  | Ok trace ->
    Some
      (profile_json_of_trace
         ~keeper_assignable:(StringSet.mem name keeper_assignable_names)
         name
         trace)
  | Error detail ->
    Log.Keeper.warn "dashboard cascade config: skipping profile %s: %s" name detail;
    None
;;

let profile_json_raw ~config_path ~keeper_assignable_names name =
  let defaults =
    Cascade_runtime.default_model_strings
      ~cascade_name:(Keeper_cascade_profile.Runtime_name name)
  in
  let _models, trace =
    CC.resolve_model_strings_with_trace ?config_path ~name ~defaults ()
  in
  profile_json_of_trace
    ~keeper_assignable:(StringSet.mem name keeper_assignable_names)
    name
    trace
;;

(* Two-column contract consumed by the dashboard's "Keeper → Cascade
   Mapping" table:

   - [cascade_name]: raw value from the keeper meta (TOML / state JSON
     round-trip).  NOT canonicalized here — downstream call sites
     canonicalize at point-of-use.
   - [canonical]: the cascade actually used by [Cascade_runtime] for
     model resolution.

   When the two differ, the UI surfaces that the keeper's declared
   cascade is not a recognized variant (classic parse-don't-validate
   drift).  When they match, the UI renders "—" in the canonical column.

   Exposed as a pure helper so the contract can be exercised without
   synthesizing a full [Keeper_registry.registry_entry]. *)
let keeper_profile_fields ~keeper ~cascade_name : (string * Yojson.Safe.t) list =
  [ "keeper", `String keeper
  ; "cascade_name", `String cascade_name
  ; "canonical", `String (Keeper_cascade_profile.resolve_live cascade_name)
  ]
;;

let keeper_profile_json (entry : Keeper_registry.registry_entry) : Yojson.Safe.t =
  `Assoc
    (keeper_profile_fields
       ~keeper:entry.name
       ~cascade_name:(Keeper_types.cascade_name_of_meta entry.meta))
;;

let invalid_name_set = function
  | None -> StringSet.empty
  | Some path ->
    Cascade_catalog_validator.error_messages_by_profile ~config_path:path
    |> List.fold_left (fun acc (name, _reasons) -> StringSet.add name acc) StringSet.empty
;;

let invalid_profiles_of_config_path = function
  | None -> []
  | Some path -> Cascade_catalog_validator.error_messages_by_profile ~config_path:path
;;

let validation_summary_json ?config_path () =
  let fallback_invalid_profiles = invalid_profiles_of_config_path config_path in
  let of_rejection ~status rejection =
    let rejection_json = Cascade_catalog_runtime.rejection_to_yojson rejection in
    let invalid_profiles =
      match invalid_profiles_of_rejection_json rejection_json with
      | [] -> fallback_invalid_profiles
      | profiles -> profiles
    in
    [ "validation_status", `String status
    ; ( "validation_errors"
      , string_list_to_json (json_string_list (json_assoc_member "errors" rejection_json))
      )
    ; "invalid_profiles", `List (List.map invalid_profile_to_json invalid_profiles)
    ]
  in
  match Cascade_catalog_runtime.inspect_active () with
  | Ok (Cascade_catalog_runtime.Validated _) ->
    [ "validation_status", `String "validated"
    ; "validation_errors", `List []
    ; "invalid_profiles", `List []
    ]
  | Ok (Cascade_catalog_runtime.Validated_with_rejections { rejected_update; _ }) ->
    of_rejection ~status:"validated" rejected_update
  | Ok (Cascade_catalog_runtime.Serving_last_known_good { rejected_update; _ }) ->
    of_rejection ~status:"serving_last_known_good" rejected_update
  | Error rejection -> of_rejection ~status:"invalid" rejection
;;

let config_json () =
  let config_path = Cascade_runtime.cascade_config_path () in
  let source : Cascade_toml_materializer.source_info = source_info ?config_path () in
  let keeper_assignable_names = keeper_assignable_name_set ?config_path () in
  let keeper_entries =
    (* Issue #8619: was [with _ -> []] which silently swallowed
       Eio.Cancel.Cancelled. Re-raise cancellation; only fall back
       to empty for non-cancel exceptions (e.g. registry not yet
       initialised). *)
    try Keeper_registry.all () with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | _ -> []
  in
  let active_names =
    List.fold_left
      (fun acc (e : Keeper_registry.registry_entry) -> StringSet.add e.name acc)
      StringSet.empty
      keeper_entries
  in
  let offline_keepers_json =
    try
      Config_dir_resolver.keepers_dir ()
      |> Keeper_types_profile.discover_keepers_toml
      |> List.filter_map (fun (name, doc) ->
        if StringSet.mem name active_names
        then None
        else (
          let cascade_name =
            match doc.Keeper_types_profile.cascade_name with
            | Some c -> c
            | None -> Keeper_config.default_cascade_name
          in
          Some (`Assoc (keeper_profile_fields ~keeper:name ~cascade_name))))
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Keeper.warn
        "dashboard_cascade: offline_keepers_json failed: %s"
        (Printexc.to_string exn);
      []
  in
  let profiles =
    match Cascade_catalog_runtime.known_profile_names () with
    | Ok names -> List.filter_map (profile_json_runtime ~keeper_assignable_names) names
    | Error detail ->
      Log.Keeper.warn "dashboard cascade config: validated catalog unavailable: %s" detail;
      let invalid_names = invalid_name_set config_path in
      let add_profile_name (acc, seen) name =
        let canonical = Keeper_cascade_profile.canonicalize name in
        if StringSet.mem canonical invalid_names || StringSet.mem canonical seen
        then acc, seen
        else canonical :: acc, StringSet.add canonical seen
      in
      let acc_after_catalog, seen_after_catalog =
        List.fold_left
          add_profile_name
          ([], StringSet.empty)
          (live_profiles ?config_path ())
      in
      let names, _ =
        List.fold_left
          (fun (acc, seen) (e : Keeper_registry.registry_entry) ->
             add_profile_name (acc, seen) (Keeper_types.cascade_name_of_meta e.meta))
          (acc_after_catalog, seen_after_catalog)
          keeper_entries
      in
      let names = List.rev names in
      List.map (profile_json_raw ~config_path ~keeper_assignable_names) names
  in
  let fields =
    [ "updated_at", `String (now_iso ())
    ; ( "config_path"
      , match config_path with
        | Some p -> `String p
        | None -> `Null )
    ]
    @ source_json_fields source
    @ validation_summary_json ?config_path ()
    @ [ "profiles", `List profiles
      ; ( "keeper_profiles"
        , `List (List.map keeper_profile_json keeper_entries @ offline_keepers_json) )
      ]
  in
  `Assoc fields
;;

let default_raw_config_json = "{}\n"

let load_raw_config_string path =
  if Fs_compat.file_exists path then Fs_compat.load_file path else default_raw_config_json
;;

let invalidate_cascade_config config_path =
  Cascade_config_loader.invalidate_cache_entry config_path;
  Cascade_catalog_runtime.invalidate_path config_path
;;

let save_config_file path content =
  Fs_compat.mkdir_p (Filename.dirname path);
  Fs_compat.save_file_atomic path content
;;

let raw_config_json () =
  Config_dir_resolver.log_warnings ~context:"DashboardCascade" ();
  let source : Cascade_toml_materializer.source_info = source_info () in
  let config_path = Some source.json_path in
  (* Capture the materialization error so the dashboard response can
     surface it.  Previously the failure was logged and the response
     silently served the stale [raw_json] file, hiding cascade.toml
     parse failures from operators viewing the dashboard. *)
  let materialization_error =
    match
      Cascade_toml_materializer.ensure_materialized_json ~config_path:source.json_path
    with
    | Ok _ -> None
    | Error msg ->
      Log.Keeper.warn
        "DashboardCascade: materialization failed for %s: %s"
        source.json_path
        msg;
      Some msg
  in
  let source_text =
    try load_raw_config_string source.source_path with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | Sys_error msg ->
      Log.Keeper.warn
        "dashboard cascade source config: failed to read %s: %s"
        source.source_path
        msg;
      ""
  in
  let raw_json =
    match config_path with
    | None -> ""
    | Some path ->
      (try load_raw_config_string path with
       | Eio.Cancel.Cancelled _ as exn -> raise exn
       | Sys_error msg ->
         Log.Keeper.warn "dashboard cascade raw config: failed to read %s: %s" path msg;
         "")
  in
  `Assoc
    [ "updated_at", `String (now_iso ())
    ; "config_path", Json_util.string_opt_to_json config_path
    ; "source_kind", `String (Cascade_toml_materializer.source_kind_to_string source.kind)
    ; "source_path", `String source.source_path
    ; "source_editable", `Bool true
    ; "source_text", `String source_text
    ; "raw_json_editable", `Bool source.raw_json_editable
    ; "raw_json", `String raw_json
    ; "materialization_error", Json_util.string_opt_to_json materialization_error
    ]
;;

let save_raw_config_json raw_json =
  Config_dir_resolver.log_warnings ~context:"DashboardCascade" ();
  let source : Cascade_toml_materializer.source_info = source_info () in
  let config_path = source.json_path in
  match source.kind with
  | Cascade_toml_materializer.Json ->
    let parse_result =
      try
        let (_ : Yojson.Safe.t) = Yojson.Safe.from_string raw_json in
        Ok ()
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | Yojson.Json_error msg -> Error (Printf.sprintf "invalid JSON: %s" msg)
      | exn ->
        Error (Printf.sprintf "failed to parse JSON: %s" (Stdlib.Printexc.to_string exn))
    in
    (match parse_result with
     | Error _ as err -> err
     | Ok () ->
       (try
          match save_config_file config_path raw_json with
          | Error msg -> Error msg
          | Ok () ->
            invalidate_cascade_config config_path;
            Ok (config_json ())
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | Sys_error msg -> Error msg))
  | Cascade_toml_materializer.Toml ->
    (match Cascade_toml_materializer.render_toml_string_to_json_string raw_json with
     | Error msg -> Error (Printf.sprintf "invalid TOML: %s" msg)
     | Ok _rendered_json ->
       (try
          match save_config_file source.source_path raw_json with
          | Error msg -> Error msg
          | Ok () ->
            (match Cascade_toml_materializer.ensure_materialized_json ~config_path with
             | Error msg -> Error msg
             | Ok _ ->
               invalidate_cascade_config config_path;
               Ok (config_json ()))
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | Sys_error msg -> Error msg))
;;

(* ── Health projection ──────────────────────────────── *)

(** Classify a provider's operational state for dashboard rendering.

    - [cooldown]: tracker opened a cooldown window.
    - [active]: events arrived in the current window and the tracker is
      not cooled down.
    - [configured]: declared in [cascade.json] but has not produced
      tracker events in the current window (either untouched since
      startup, or expired from the window). The UI uses this to tell
      "declared-but-never-called" apart from the normal healthy case.

    A future [disabled] state (e.g. missing API key, registry drop)
    would live here too, but currently we have no per-provider health
    tracker entry for that condition. *)
let provider_status (info : Health.provider_info) : string =
  if info.in_cooldown
  then "cooldown"
  else if info.events_in_window > 0
  then "active"
  else "configured"
;;

(** Synthesise a provider_info with optimistic defaults for a
    cascade-declared provider that has not been observed by the tracker
    in the current window.  [success_rate = 1.0] mirrors
    [Cascade_health_tracker]'s "unknown = optimistic" convention. *)
let zero_provider_info (key : string) : Health.provider_info =
  { provider_key = key
  ; success_rate = 1.0
  ; consecutive_failures = 0
  ; in_cooldown = false
  ; cooldown_expires_at = None
  ; events_in_window = 0
  ; rejected_in_window = 0
  ; top_fingerprints = []
  ; last_failure_at = None
  ; p50_latency_ms = None
  ; p95_latency_ms = None
  ; latency_samples = 0
  ; avg_confidence = None
  ; confidence_samples = 0
  ; avg_cost_usd = None
  ; cost_samples = 0
  ; health_score = 1.0
  }
;;

(** [provider_entry_to_json ~declared info] serialises a provider_info
    together with two derived fields:

    - [declared : bool]  — [true] iff any [cascade.json] profile lists a
      model whose scheme prefix matches [info.provider_key].  Lets the
      UI distinguish "still referenced in config" from "left over in the
      tracker after a config change".
    - [status : string] — see {!provider_status}.

    Existing callers (tests, UI) read the previous 7 behavioural fields
    unchanged; the two new keys are strictly additive. *)
let provider_entry_to_json
      ~(declared : bool)
      ?(perf : Model_inference_metrics.provider_stats option)
      (info : Health.provider_info)
  : Yojson.Safe.t
  =
  let opt_float = function
    | Some f -> `Float f
    | None -> `Null
  in
  let trust_score = Cascade_trust.trust_score info in
  let health_score =
    let score = Float.max 0.0 (Float.min 1.0 trust_score) in
    int_of_float (floor ((score *. 100.0) +. 0.5))
  in
  let perf_fields =
    match perf with
    | None ->
      (* Distinguish "the aggregator was not available this call"
         (absent base_path) from "the aggregator ran and this provider
         had no entries".  We use [null] in both cases — the UI reads
         the sibling [request_count] to tell them apart: [null] with
         [request_count = null] means no aggregator; [null] with
         [request_count = 0] means aggregator ran and found nothing. *)
      [ "avg_prompt_tok_per_sec", `Null
      ; "avg_decode_tok_per_sec", `Null
      ; "avg_tok_per_sec", `Null
      ; "avg_latency_ms", `Null
      ; "p50_latency_ms", `Null
      ; "p95_latency_ms", `Null
      ; "request_count", `Null
      ]
    | Some (stats : Model_inference_metrics.provider_stats) ->
      [ "avg_prompt_tok_per_sec", opt_float stats.ps_avg_prompt_tok_per_sec
      ; "avg_decode_tok_per_sec", opt_float stats.ps_avg_decode_tok_per_sec
      ; "avg_tok_per_sec", opt_float stats.ps_avg_tok_per_sec
      ; "avg_latency_ms", opt_float stats.ps_avg_latency_ms
      ; "p50_latency_ms", opt_float stats.ps_p50_latency_ms
      ; "p95_latency_ms", opt_float stats.ps_p95_latency_ms
      ; "request_count", `Int stats.ps_entry_count
      ]
  in
  let top_fingerprints_json =
    `List
      (List.map
         (fun (fp, count) -> `Assoc [ "fingerprint", `String fp; "count", `Int count ])
         info.top_fingerprints)
  in
  `Assoc
    ([ "provider_key", `String info.provider_key
     ; "success_rate", `Float info.success_rate
     ; "consecutive_failures", `Int info.consecutive_failures
     ; "in_cooldown", `Bool info.in_cooldown
     ; ( "cooldown_expires_at"
       , match info.cooldown_expires_at with
         | Some t -> `Float t
         | None -> `Null )
     ; "events_in_window", `Int info.events_in_window
     ; "trust_score", `Float trust_score
     ; "health_score", `Int health_score
     ; (* rejected_in_window ⊆ events_in_window: responses that arrived
       but were rejected by the cascade's accept predicate.  Split out
       so dashboards can distinguish "provider down" from "provider
       returns unusable output". *)
       "rejected_in_window", `Int info.rejected_in_window
     ; (* top_fingerprints / last_failure_at are Phase 0 trust observability
       anchors (cumulative, not window-bounded).  Surfaced so dashboards
       can show "which error keeps recurring" alongside the existing
       success-rate snapshot. *)
       "top_fingerprints", top_fingerprints_json
     ; "last_failure_at", opt_float info.last_failure_at
     ; "declared", `Bool declared
     ; "status", `String (provider_status info)
     ; "avg_confidence", opt_float info.avg_confidence
     ; "confidence_samples", `Int info.confidence_samples
     ]
     @ perf_fields)
;;

(** Back-compat alias: older call sites may still reference the previous
    serializer name.  Keeping it as a thin wrapper keeps the diff in
    this PR focused on the health_json merge. *)
let provider_info_to_json (info : Health.provider_info) : Yojson.Safe.t =
  provider_entry_to_json ~declared:false info
;;

(* ── Phase 2a: low-trust operator recommendations ─────────────────────

   Surfaces a dashboard nudge when [trust_score] indicates a provider
   is dragging the cascade.  Observation only — the user runs the
   suggested config edit themselves.  Phase 2b is what would make these
   self-applying, and it is gated by [MASC_CASCADE_TRUST_PERSIST]. *)

type recommendation_action =
  | Reduce_weight (* unreliable but partially working *)
  | Disable (* effectively dead *)
  | Investigate (* high-volume same-fingerprint failures — config bug *)

let recommendation_action_to_string = function
  | Reduce_weight -> "reduce_weight"
  | Disable -> "disable"
  | Investigate -> "investigate"
;;

type recommendation =
  { rec_provider_key : string
  ; rec_trust_score : float
  ; rec_same_fingerprint_count : int
  ; rec_events_in_window : int
  ; rec_top_fingerprint : string option
  ; rec_action : recommendation_action
  ; rec_rationale : string
  }

let top_failure_fingerprint (info : Health.provider_info) =
  match info.top_fingerprints with
  | [] -> None
  | (fingerprint, count) :: _ -> Some (fingerprint, count)
;;

let recommendation_rationale ~provider_key ~trust_score ~events ~top_count action =
  match action with
  | Investigate when top_count >= 5 ->
    Printf.sprintf
      "Provider %s has repeated the same failure fingerprint %d times; inspect \
       config/auth before changing weights."
      provider_key
      top_count
  | Investigate ->
    Printf.sprintf
      "Provider %s has very low trust %.2f across %d recent events; inspect quota/auth \
       before disabling it."
      provider_key
      trust_score
      events
  | Disable ->
    Printf.sprintf
      "Provider %s trust %.2f is below 0.10 after %d recent events; disable until \
       recovery is confirmed."
      provider_key
      trust_score
      events
  | Reduce_weight ->
    Printf.sprintf
      "Provider %s trust %.2f is below 0.30; reduce its routing weight while monitoring \
       recovery."
      provider_key
      trust_score
;;

(* Classifier — see RFC-0009 §"Phase 2a".

   The provider_info record no longer stores a raw [trust_score], so this
   derives it from the live tracker snapshot using [Cascade_trust.trust_score].
   Recommendations stay observation-only: this module never mutates config. *)
let classify_recommendation (info : Health.provider_info) : recommendation option =
  if info.events_in_window <= 0
  then None
  else (
    let trust_score = Cascade_trust.trust_score info in
    let top_fingerprint, same_fingerprint_count =
      match top_failure_fingerprint info with
      | Some (fingerprint, count) -> Some fingerprint, count
      | None -> None, 0
    in
    (* Reviewer #13194: [same_fingerprint_count] is accumulated across the
       provider's lifetime via [provider_info.top_fingerprints], not the
       rolling [events_in_window].  A busy provider that once accumulated
       5+ identical failures would otherwise gate [Investigate] forever
       even when the recent window is healthy.  Couple the gate with a
       rolling-window floor (the recent window must have seen at least
       as many events as the fingerprint count we are reacting to) AND
       a low trust-score check (so a healthy window overrides the
       lifetime artifact).  The two extra conditions keep the
       recommendation responsive to the live signal without losing
       the stuck-fingerprint detection it was built for. *)
    let stuck_fingerprint =
      same_fingerprint_count >= 5 && info.events_in_window >= 5 && trust_score < 0.50
    in
    let action =
      if stuck_fingerprint
      then Some Investigate
      else if trust_score < 0.10 && info.events_in_window >= 30
      then Some Investigate
      else if trust_score < 0.10
      then Some Disable
      else if trust_score < 0.30
      then Some Reduce_weight
      else None
    in
    match action with
    | None -> None
    | Some rec_action ->
      Some
        { rec_provider_key = info.provider_key
        ; rec_trust_score = trust_score
        ; rec_same_fingerprint_count = same_fingerprint_count
        ; rec_events_in_window = info.events_in_window
        ; rec_top_fingerprint = top_fingerprint
        ; rec_action
        ; rec_rationale =
            recommendation_rationale
              ~provider_key:info.provider_key
              ~trust_score
              ~events:info.events_in_window
              ~top_count:same_fingerprint_count
              rec_action
        })
;;

let low_trust_recommendations (infos : Health.provider_info list) : recommendation list =
  List.filter_map classify_recommendation infos
  |> List.sort (fun a b -> Float.compare a.rec_trust_score b.rec_trust_score)
;;

let recommendation_to_json (r : recommendation) : Yojson.Safe.t =
  `Assoc
    [ "provider_key", `String r.rec_provider_key
    ; "trust_score", `Float r.rec_trust_score
    ; "same_fingerprint_count", `Int r.rec_same_fingerprint_count
    ; "events_in_window", `Int r.rec_events_in_window
    ; ( "top_fingerprint"
      , match r.rec_top_fingerprint with
        | Some fp -> `String fp
        | None -> `Null )
    ; "action", `String (recommendation_action_to_string r.rec_action)
    ; "rationale", `String r.rec_rationale
    ]
;;

let recommendations_json () : Yojson.Safe.t =
  let infos = Health.all_providers Health.global in
  `List (List.map recommendation_to_json (low_trust_recommendations infos))
;;

(** [provider_scheme_of_model_string s] returns the text before the first
    [:] in [s], or [s] itself if no colon is present.  The scheme
    corresponds to the provider_key produced by
    [Keeper_hooks_oas.provider_of_model] for prefixed specs; bare model
    ids (rare in cascade.json) fall through unchanged and merge with
    whatever heuristic keeper_hooks_oas assigned them at runtime.  *)
let provider_scheme_of_model_string (s : string) : string =
  match String.index_opt s ':' with
  | Some i -> String.sub s 0 i
  | None -> s
;;

(** Collect the set of provider scheme prefixes declared by any cascade
    profile in [config_path].  Reads the typed catalog (so invalid
    profiles are skipped) and then each profile's raw model list.  Errors
    are swallowed into an empty set — a missing/malformed [cascade.json]
    is already surfaced by [config_json]; we do not want the health
    endpoint to disappear just because the catalog loader fails. *)
let declared_provider_schemes_set ?(config_path : string option) () : StringSet.t =
  match config_path with
  | None -> StringSet.empty
  | Some path ->
    (match Cascade_config_loader.load_catalog ~config_path:path with
     | Error _ -> StringSet.empty
     | Ok entries ->
       List.fold_left
         (fun acc (entry : Cascade_config_loader.catalog_entry) ->
            let models =
              Cascade_config_loader.load_profile ~config_path:path ~name:entry.name
            in
            List.fold_left
              (fun acc m -> StringSet.add (provider_scheme_of_model_string m) acc)
              acc
              models)
         StringSet.empty
         entries)
;;

(** Public list version of {!declared_provider_schemes_set}.  Sorted and
    deduplicated for stable dashboard rendering and easy test assertions
    that do not want to depend on a [Set.Make] type leaking across the
    .mli boundary. *)
let declared_provider_schemes_of_config ?config_path () : string list =
  StringSet.elements (declared_provider_schemes_set ?config_path ())
;;

(** When [?base_path] is supplied, [health_json] augments each provider
    entry with performance fields (see {!provider_entry_to_json}) sourced
    from {!Model_inference_metrics.provider_rollup} over the last
    [?window_minutes] (default 30) of keeper decisions.jsonl.  When
    omitted the perf fields are [null] and no jsonl scan happens — the
    endpoint keeps the zero-dependency behaviour expected by tests that
    run without a room_config.

    Errors from the aggregator (corrupt jsonl, missing directory) are
    caught and the perf fields fall back to [null]; a broken log must
    not take down the dashboard. *)
let health_json ?(window_minutes = 30) ?(base_path : string option) () =
  let config_path = Cascade_runtime.cascade_config_path () in
  let declared = declared_provider_schemes_set ?config_path () in
  let tracked = Health.all_providers Health.global in
  let tracked_keys =
    List.fold_left
      (fun acc (p : Health.provider_info) -> StringSet.add p.provider_key acc)
      StringSet.empty
      tracked
  in
  let perf_by_provider : (string, Model_inference_metrics.provider_stats) Hashtbl.t =
    Hashtbl.create 8
  in
  (match base_path with
   | None -> ()
   | Some base_path ->
     (try
        let agg = Model_inference_metrics.compute ~base_path ~window_minutes in
        let rollup = Model_inference_metrics.provider_rollup agg in
        List.iter
          (fun (s : Model_inference_metrics.provider_stats) ->
             Hashtbl.replace perf_by_provider s.ps_provider s)
          rollup
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        Log.Keeper.warn
          "dashboard_cascade.health_json: provider perf aggregate failed: %s"
          (Stdlib.Printexc.to_string exn)));
  let perf_for key =
    match Hashtbl.find_opt perf_by_provider key with
    | Some _ as some -> some
    | None -> None
  in
  let tracked_entries =
    List.map
      (fun (info : Health.provider_info) ->
         provider_entry_to_json
           ~declared:(StringSet.mem info.provider_key declared)
           ?perf:(perf_for info.provider_key)
           info)
      tracked
  in
  let declared_only = StringSet.diff declared tracked_keys in
  let untouched_entries =
    StringSet.fold
      (fun key acc ->
         provider_entry_to_json
           ~declared:true
           ?perf:(perf_for key)
           (zero_provider_info key)
         :: acc)
      declared_only
      []
  in
  `Assoc
    [ "updated_at", `String (now_iso ())
    ; (* Health tracker is the SSOT for these values; reading env here would
       diverge from what the tracker actually applied (e.g. if the operator
       sets a malformed value that falls back to the default, the tracker
       has the fallback but a second env read would pick up the malformed
       string). *)
      "window_sec", `Float Health.window_sec
    ; "cooldown_threshold", `Int Health.cooldown_threshold
    ; "cooldown_sec", `Float Health.cooldown_sec
    ; "hard_quota_cooldown_sec", `Float Health.hard_quota_cooldown_sec
    ; ( "perf_window_minutes"
      , match base_path with
        | Some _ -> `Int window_minutes
        | None -> `Null )
    ; "providers", `List (tracked_entries @ untouched_entries)
    ; (* Phase 2a: low-trust recommendations attached to health_json so
       operators can see action items next to the raw trust scores.
       The recommendation list reads the same [Health.global] snapshot
       that produced [tracked] above; we recompute from [tracked] rather
       than re-scanning the tracker so both views are temporally
       consistent under concurrent updates. *)
      ( "recommendations"
      , `List (List.map recommendation_to_json (low_trust_recommendations tracked)) )
    ]
;;

(* ── Client capacity projection ─────────────────────── *)

(** Classify a capacity registry key for the dashboard.  Both sentinel
    predicates come from {!Masc_network_defaults}: CLI transports via
    {!Masc_network_defaults.is_cli_sentinel_url} (matches the [cli:]
    prefix) and ollama endpoints via
    {!Masc_network_defaults.is_ollama_url} (matches the well-known
    port).  Everything else is reported as [other] so operators can
    spot surprise registrations (e.g. a manually-registered HTTP
    slot). *)
let classify_capacity_key url =
  if Masc_network_defaults.is_cli_sentinel_url url
  then "cli"
  else if Masc_network_defaults.is_ollama_url url
  then "ollama"
  else "other"
;;

let client_capacity_entry_to_json ((url, info) : string * Cascade_throttle.capacity_info)
  : Yojson.Safe.t
  =
  `Assoc
    [ "key", `String url
    ; "kind", `String (classify_capacity_key url)
    ; "total", `Int info.total
    ; "active", `Int info.process_active
    ; "available", `Int info.process_available
    ]
;;

let client_capacity_json () =
  let entries = Cascade_client_capacity.snapshot () in
  (* Stable ordering by (kind, key) so the dashboard table doesn't
     reshuffle on every poll.  Hashtbl iteration is unordered, so we
     sort here rather than depend on insertion order. *)
  let sorted =
    List.sort
      (fun (k1, _) (k2, _) ->
         let c1 = classify_capacity_key k1 in
         let c2 = classify_capacity_key k2 in
         match String.compare c1 c2 with
         | 0 -> String.compare k1 k2
         | n -> n)
      entries
  in
  `Assoc
    [ "updated_at", `String (now_iso ())
    ; "entries", `List (List.map client_capacity_entry_to_json sorted)
    ]
;;

(* ── Client capacity history projection ─────────────────── *)

let event_kind_to_string = function
  | Cascade_client_capacity_history.Acquired -> "acquired"
  | Released -> "released"
  | Rejected_full -> "rejected_full"
;;

let history_event_to_json (ev : Cascade_client_capacity_history.event) : Yojson.Safe.t =
  `Assoc
    [ "ts", `Float ev.ts
    ; "key", `String ev.key
    ; "kind", `String (event_kind_to_string ev.kind)
    ; "active_after", `Int ev.active_after
    ]
;;

let client_capacity_history_json ?limit ?kind ?since_ts () =
  let events = Cascade_client_capacity_history.snapshot ?limit ?kind ?since_ts () in
  `Assoc
    [ "updated_at", `String (now_iso ())
    ; "total_events", `Int (List.length events)
    ; "events", `List (List.map history_event_to_json events)
    ]
;;

let strategy_trace_event_to_json (ev : Cascade_strategy_trace.event) : Yojson.Safe.t =
  let opt_float = function
    | Some f -> `Float f
    | None -> `Null
  in
  let cascade_name = Keeper_cascade_profile.runtime_name_to_string ev.cascade_name in
  let trace_id_json =
    match ev.trace_id with
    | None -> `Null
    | Some id -> `String id
  in
  `Assoc
    [ "ts", `Float ev.ts
    ; "cascade_name", `String cascade_name
    ; "strategy", `String ev.strategy
    ; "cycle", `Int ev.cycle
    ; "candidates_in", `Int ev.candidates_in
    ; "candidates_out", `Int ev.candidates_out
    ; "backoff_ms", `Int ev.backoff_ms
    ; "kind", `String (Cascade_strategy_trace.kind_to_string ev.kind)
    ; "trace_id", trace_id_json
    ; "confidence_score", opt_float ev.confidence_score
    ]
;;

let strategy_trace_json ?limit ?cascade () =
  let events = Cascade_strategy_trace.snapshot ?limit ?cascade () in
  `Assoc
    [ "updated_at", `String (now_iso ())
    ; "total_events", `Int (List.length events)
    ; "events", `List (List.map strategy_trace_event_to_json events)
    ]
;;

(* ── Cascade inspector projection (O1) ─────────────────────────────

   The runtime writer already persists per-call observations under
   [.masc/cascade_audit/YYYY-MM/DD.jsonl].  This projection keeps that
   durable SSOT and reshapes each record into the O1 inspector contract:
   one cascade run with configured pool, selected model, aggregate
   duration, and ordered hop rows. *)

let json_string_member key json =
  match json_assoc_member key json with
  | `String value -> Some value
  | _ -> None
;;

let json_float_member key json =
  match json_assoc_member key json with
  | `Float value -> Some value
  | `Int value -> Some (float_of_int value)
  | _ -> None
;;

let json_int_member key json =
  match json_assoc_member key json with
  | `Int value -> Some value
  | `Float value -> Some (int_of_float value)
  | _ -> None
;;

let json_list_member key json =
  match json_assoc_member key json with
  | `List values -> values
  | _ -> []
;;

let nonempty_string value =
  match value with
  | Some raw ->
    let trimmed = String.trim raw in
    if String.equal trimmed "" then None else Some trimmed
  | None -> None
;;

let first_nonempty values = List.find_map nonempty_string values
let json_string_opt_member key json = json_string_member key json |> nonempty_string

let audit_store_dir ~base_path =
  Filename.concat (Common.masc_dir_from_base_path ~base_path) "cascade_audit"
;;

let cascade_audit_store ~base_path =
  Dated_jsonl.create ~base_dir:(audit_store_dir ~base_path) ()
;;

let stable_audit_run_id json =
  "cascade-audit-"
  ^ String.sub (Digest.to_hex (Digest.string (Yojson.Safe.to_string json))) 0 16
;;

let model_display_of_attempt attempt =
  first_nonempty
    [ json_string_member "model_label" attempt; json_string_member "model_id" attempt ]
  |> Option.value ~default:"unknown"
;;

let fallback_reason_for_model ~model_id ~model_label fallback_events =
  let matches value =
    match nonempty_string value with
    | None -> false
    | Some value ->
      (match model_id with
       | Some id -> String.equal value id
       | None -> false)
      ||
        (match model_label with
        | Some label -> String.equal value label
        | None -> false)
  in
  List.find_map
    (fun event ->
       if
         matches (json_string_member "from_model_id" event)
         || matches (json_string_member "from_model_label" event)
       then json_string_opt_member "reason" event
       else None)
    fallback_events
;;

let audit_hop_json ~selected_model ~fallback_events attempt =
  let model_id = json_string_opt_member "model_id" attempt in
  let model_label = json_string_opt_member "model_label" attempt in
  let model = model_display_of_attempt attempt in
  let latency_ms = json_int_member "latency_ms" attempt in
  let error = json_string_opt_member "error" attempt in
  let reason =
    match error with
    | Some _ as value -> value
    | None -> fallback_reason_for_model ~model_id ~model_label fallback_events
  in
  let selected =
    match selected_model with
    | Some selected ->
      String.equal selected model
      || (match model_id with
          | Some id -> String.equal selected id
          | None -> false)
      ||
        (match model_label with
        | Some label -> String.equal selected label
        | None -> false)
    | None -> false
  in
  let status =
    match error, reason, selected with
    | Some _, _, _ -> "error"
    | None, _, true -> "success"
    | None, Some _, false -> "fallback"
    | None, None, _ -> "attempted"
  in
  let base =
    [ "i", `Int (Option.value ~default:0 (json_int_member "attempt_index" attempt))
    ; "model", `String model
    ; "status", `String status
    ; "ms", `Int (Option.value ~default:0 latency_ms)
    ; ( "ms_source"
      , `String
          (if Option.is_some latency_ms then "oas_metrics_callbacks" else "unavailable") )
    ]
  in
  let fields =
    match reason with
    | Some value -> base @ [ "reason", `String value ]
    | None -> base
  in
  `Assoc fields
;;

let attempt_latency_total attempts =
  List.fold_left
    (fun acc attempt ->
       acc + Option.value ~default:0 (json_int_member "latency_ms" attempt))
    0
    attempts
;;

let last_attempt_error attempts =
  List.rev attempts |> List.find_map (json_string_opt_member "error")
;;

let audit_run_json_of_record json =
  let observation = json_assoc_member "observation" json in
  let configured_labels =
    json_string_list (json_assoc_member "configured_labels" observation)
  in
  let candidate_models =
    json_string_list (json_assoc_member "candidate_models" observation)
  in
  let configured =
    match configured_labels with
    | [] -> candidate_models
    | labels -> labels
  in
  let attempts = json_list_member "attempts" observation in
  let fallback_events = json_list_member "fallback_events" observation in
  let selected =
    first_nonempty
      [ json_string_member "selected_model" observation
      ; json_string_member "selected_model_raw" observation
      ]
  in
  let primary =
    first_nonempty
      [ json_string_member "primary_model" observation
      ; List.nth_opt configured 0
      ; List.nth_opt candidate_models 0
      ]
  in
  let cascade =
    first_nonempty
      [ json_string_member "cascade_name" json
      ; json_string_member "cascade_name" observation
      ]
    |> Option.value ~default:"unknown"
  in
  let ts = Option.value ~default:0.0 (json_float_member "ts" json) in
  let top_level_reason = json_string_opt_member "top_level_reason" json in
  let error_category =
    match top_level_reason with
    | Some _ as value -> value
    | None -> last_attempt_error attempts
  in
  let base =
    [ "id", `String (stable_audit_run_id json)
    ; "cascade", `String cascade
    ; ( "trigger"
      , `String
          (json_string_opt_member "keeper_name" json |> Option.value ~default:"unknown") )
    ; "at", `Float ts
    ; ( "outcome"
      , `String (json_string_member "outcome" json |> Option.value ~default:"unknown") )
    ; "configured", `List (List.map (fun value -> `String value) configured)
    ; "primary", Json_util.string_opt_to_json primary
    ; "selected", Json_util.string_opt_to_json selected
    ; "total_ms", `Int (attempt_latency_total attempts)
    ; ( "total_ms_source"
      , `String
          (if
             List.exists
               (fun attempt -> Option.is_some (json_int_member "latency_ms" attempt))
               attempts
           then "attempt_latency_sum"
           else "unavailable") )
    ; ( "hops"
      , `List
          (List.map (audit_hop_json ~selected_model:selected ~fallback_events) attempts) )
    ]
  in
  let fields =
    match error_category with
    | Some value -> base @ [ "error_category", `String value ]
    | None -> base
  in
  `Assoc fields
;;

let audit_run_cascade_matches cascade_filter run =
  match cascade_filter with
  | None -> true
  | Some expected ->
    (match json_string_member "cascade" run with
     | Some actual -> String.equal actual expected
     | None -> false)
;;

let audit_runs_json ~base_path ?limit ?cascade () =
  let limit = Option.value ~default:100 limit |> max 1 |> min 1024 in
  let read_limit = if Option.is_some cascade then min 4096 (limit * 4) else limit in
  let runs =
    Dated_jsonl.read_recent (cascade_audit_store ~base_path) read_limit
    |> List.rev
    |> List.map audit_run_json_of_record
    |> List.filter (audit_run_cascade_matches cascade)
  in
  let rec take n = function
    | _ when n <= 0 -> []
    | [] -> []
    | x :: xs -> x :: take (n - 1) xs
  in
  let runs = take limit runs in
  `Assoc
    [ "updated_at", `String (now_iso ())
    ; "total_runs", `Int (List.length runs)
    ; "audit_runs", `List runs
    ]
;;

(* ── SLO projection (LT-11) ─────────────────────────────────

   Targets mirror infrastructure/monitoring/cascade-slo.yml.  Computed
   in-process from the live Cascade_strategy_trace ring so the MASC
   dashboard can render SLO status without reaching Prometheus. *)

let slo_sample_limit = 1000
let slo_target_ordered_ratio = 0.99
let slo_target_exhaustion_count = 10
let slo_target_burn_rate = 1.0

let compute_slo_counts (events : Cascade_strategy_trace.event list) =
  List.fold_left
    (fun (total, ordered, exhausted) (ev : Cascade_strategy_trace.event) ->
       match ev.kind with
       | Ordered -> total + 1, ordered + 1, exhausted
       | Filtered_empty -> total + 1, ordered, exhausted
       | Exhausted -> total + 1, ordered, exhausted + 1)
    (0, 0, 0)
    events
;;

let slo_json () =
  let events = Cascade_strategy_trace.snapshot ~limit:slo_sample_limit () in
  let total, ordered, exhausted = compute_slo_counts events in
  let ordered_ratio =
    if total = 0 then 1.0 else Stdlib.Float.of_int ordered /. Stdlib.Float.of_int total
  in
  let burn_rate = (1.0 -. ordered_ratio) /. 0.01 in
  let ratio_violated = Stdlib.Float.compare ordered_ratio slo_target_ordered_ratio < 0 in
  let exhaustion_violated = exhausted > slo_target_exhaustion_count in
  let burn_violated = Stdlib.Float.compare burn_rate slo_target_burn_rate > 0 in
  let violations =
    List.filter_map
      (fun (name, violated) -> if violated then Some (`String name) else None)
      [ "ordered_ratio", ratio_violated
      ; "exhaustion_count", exhaustion_violated
      ; "burn_rate", burn_violated
      ]
  in
  let status =
    if ratio_violated || exhaustion_violated
    then "violated"
    else if burn_violated
    then "warn"
    else "ok"
  in
  `Assoc
    [ "updated_at", `String (now_iso ())
    ; "window_sample_size", `Int slo_sample_limit
    ; ( "targets"
      , `Assoc
          [ "ordered_ratio_min", `Float slo_target_ordered_ratio
          ; "exhaustion_count_max", `Int slo_target_exhaustion_count
          ; "burn_rate_max", `Float slo_target_burn_rate
          ] )
    ; ( "current"
      , `Assoc
          [ "ordered_ratio", `Float ordered_ratio
          ; "exhaustion_count", `Int exhausted
          ; "burn_rate", `Float burn_rate
          ; "total_events", `Int total
          ] )
    ; "status", `String status
    ; "violations", `List violations
    ]
;;
