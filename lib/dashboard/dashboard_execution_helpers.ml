(** Tone ADT — must precede record types that use it. *)
type tone = Dashboard_utils.tone = Tone_ok | Tone_warn | Tone_bad

type queue_context = {
  severity_rank : int;
  last_seen_ts : float;
  json : Yojson.Safe.t;
}

type session_seed = {
  session_id : string;
  goal : string;
  namespace : string option;
  status : string option;
  health : string;
  member_names : string list;
  last_activity_at : string option;
  last_activity_ts : float;
  last_activity_summary : string;
  communication_summary : string;
  active_count : int;
  seen_count : int;
  planned_count : int;
  required_count : int;
  counts_basis : string;
  runtime_blocker : string option;
  worker_gap_summary : string option;
  top_attention : Yojson.Safe.t option;
  top_recommendation : Yojson.Safe.t option;
}

type session_context = {
  session_id : string;
  severity : tone;
  last_seen_ts : float;
  linked_operation_id : string option;
  member_names : string list;
  json : Yojson.Safe.t;
}

type operation_context = {
  operation_id : string;
  severity : tone;
  last_seen_ts : float;
  linked_session_id : string option;
  linked_detachment_id : string option;
  json : Yojson.Safe.t;
}

type worker_context = {
  tone_rank : int;
  last_signal_ts : float;
  related_session_id : string option;
  json : Yojson.Safe.t;
}

type continuity_context = {
  tone_rank : int;
  last_signal_ts : float;
  related_session_id : string option;
  json : Yojson.Safe.t;
}

type tool_audit_snapshot = {
  latest_tool_names : string list;
  latest_tool_call_count : int option;
  latest_action_source : string option;
  tool_audit_source : string option;
  tool_audit_at : string option;
}

let option_or_else fallback = function
  | Some _ as value -> value
  | None -> fallback ()

let member_assoc = Dashboard_utils.member_assoc
let string_field = Dashboard_utils.string_field
let take = List.take
let list_field = Dashboard_utils.list_field
let compact_text = String_util.compact_text
let session_payload_json = Dashboard_utils.session_payload_json
let session_meta_json = Dashboard_utils.session_meta_json
let session_summary_json = Dashboard_utils.session_summary_json
let session_team_health_json = Dashboard_utils.session_team_health_json
let session_communication_json = Dashboard_utils.session_communication_json
let session_status_opt = Dashboard_utils.session_status_opt
let session_recent_events = Dashboard_utils.session_recent_events
let event_detail_json = Dashboard_utils.event_detail_json


let latest_iso_timestamp values =
  let pick_latest best candidate =
    match candidate with
    | None -> best
    | Some candidate -> (
        match Dashboard_utils.parse_iso_opt (Some candidate) with
        | None -> best
        | Some candidate_ts -> (
            match best with
            | Some (best_value, best_ts) when best_ts >= candidate_ts ->
                Some (best_value, best_ts)
            | _ -> Some (candidate, candidate_ts)))
  in
  values
  |> List.fold_left pick_latest None
  |> Option.map fst

let string_list_of_field key json =
  member_assoc key json |> Dashboard_utils.string_list_of_json

(** Status/health predicates — re-exported from Dashboard_utils (SSOT). *)


let execution_tool_preview_limit = 8

let cap_string_list ?(limit = execution_tool_preview_limit) values =
  take limit values

let tool_audit_snapshot agent_name =
  {
    latest_tool_names = [];
    latest_tool_call_count = None;
    latest_action_source = None;
    tool_audit_source = None;
    tool_audit_at = None;
  }

let skill_route_summary_of_keeper keeper =
  let route = member_assoc "skill_route" keeper in
  let primary =
    String_util.trim_to_option (string_field "primary" route)
    |> option_or_else (fun () -> String_util.trim_to_option (string_field "skill_primary" keeper))
  in
  let secondary =
    let route_secondary = string_list_of_field "secondary" route in
    if route_secondary <> [] then route_secondary
    else string_list_of_field "skill_secondary" keeper
  in
  let provenance = String_util.trim_to_option (string_field "provenance" route) in
  match primary, secondary, provenance with
  | None, [], None -> None
  | Some value, [], None -> Some value
  | Some value, [], Some source -> Some (Printf.sprintf "%s · %s" value source)
  | Some value, extra, source ->
      let extra_summary =
        if extra = [] then None else Some (Printf.sprintf "+%d" (List.length extra))
      in
      Some
        (String.concat " · "
           (List.filter_map (fun item -> item) [ Some value; extra_summary; source ]))
  | None, extra, source ->
      Some
        (String.concat " · "
           (List.filter_map
              (fun item -> item)
              [
                (if extra = [] then None else Some (Printf.sprintf "%d route(s)" (List.length extra)));
                source;
              ]))

let dedup_strings = Dashboard_utils.dedup_strings

(** severity_rank works on raw JSON strings — broader matching than Dashboard_utils.tone_rank.
    Used by dashboard_briefing / dashboard_briefing_assembly for external JSON data. *)
let severity_rank = function
  | "bad" | "critical" | "failed" -> 2
  | "warn" | "blocked" | "paused" | "interrupted" -> 1
  | _ -> 0


let dashboard_fixture_name ?fixture () =
  let fixtures_enabled = Env_config.Dashboard_config.fixtures_enabled () in
  if not fixtures_enabled then None
  else
    match fixture with
    | Some value ->
        let trimmed = String.trim value in
        if trimmed <> "" then Some trimmed else Env_config.Dashboard_config.fixture_opt ()
    | None -> Env_config.Dashboard_config.fixture_opt ()

(** Agent profile enriched from persona profile.json or Neo4j cache. *)
type agent_profile = {
  emoji : string;
  korean_name : string;
  model : string option;
  traits : string list;
  interests : string list;
  activity_level : float option;
  primary_value : string option;
  profile_errors : agent_profile_error list;
}

and agent_profile_error = {
  source : agent_profile_error_source;
  path : string option;
  detail : string;
}

and agent_profile_error_source =
  | Profile_identity_normalization
  | Persona_profile_file

let agent_profile_error_source_to_string = function
  | Profile_identity_normalization -> "identity_normalization"
  | Persona_profile_file -> "persona_profile_file"

let agent_profile_error_json error =
  `Assoc
    [
      ("source", `String (agent_profile_error_source_to_string error.source));
      ("path", Json_util.string_opt_to_json error.path);
      ("detail", `String error.detail);
    ]

let agent_profile_errors_json profile =
  `List (List.map agent_profile_error_json profile.profile_errors)

let with_profile_errors errors profile =
  { profile with profile_errors = profile.profile_errors @ errors }

let fallback_agent_profile ?(profile_errors = []) name =
  {
    emoji = "🤖";
    korean_name = name;
    model = None;
    traits = [];
    interests = [];
    activity_level = None;
    primary_value = None;
    profile_errors;
  }

type persona_name_resolution =
  | Persona_name_resolved of string
  | Persona_name_invalid of agent_profile_error

let resolve_persona_name agent_name =
  match Keeper_identity.normalize_all_names ~input_agent_name:agent_name () with
  | Ok bundle -> Persona_name_resolved bundle.persona_name
  | Error err ->
      let detail = Keeper_identity.show_validation_error err in
      Log.Dashboard.warn
        "agent profile identity normalization failed for %S: %s"
        agent_name detail;
      Persona_name_invalid
        {
          source = Profile_identity_normalization;
          path = None;
          detail;
        }

type persona_profile_lookup =
  | Persona_profile_absent
  | Persona_profile_loaded of agent_profile
  | Persona_profile_read_error of agent_profile_error

let persona_profile_path persona_name =
  match Config_dir_resolver.personas_dir_opt () with
  | Some personas_root ->
      Some
        (Filename.concat (Filename.concat personas_root persona_name) "profile.json")
  | None -> None

(** Try loading agent profile from local persona profile.json.
    Path: resolved personas root / <persona_name> / profile.json *)
let load_persona_profile (persona_name : string) : persona_profile_lookup =
  match persona_profile_path persona_name with
  | None -> Persona_profile_absent
  | Some path ->
    if not (Sys.file_exists path) then Persona_profile_absent
    else
      match Safe_ops.read_json_file_safe path with
      | Error detail ->
          Persona_profile_read_error
            { source = Persona_profile_file; path = Some path; detail }
    | Ok json ->
        let name_val =
          Safe_ops.json_string_opt "name" json
          |> Option.value ~default:persona_name
        in
        let keeper_json =
          Safe_ops.protect ~default:None (fun () ->
            Some (Option.value ~default:`Null (Json_util.assoc_member_opt "keeper" json)))
        in
        let model =
          match keeper_json with
          | Some kj -> Safe_ops.json_string_opt "active_model" kj
          | None -> None
        in
        let trait = Safe_ops.json_string_opt "trait" json in
        let traits = match trait with Some t -> [t] | None -> [] in
        Some
          {
            emoji = "🤖";  (* generic default — enriched from Neo4j later *)
            korean_name = name_val;
            model;
            traits;
            interests = [];
            activity_level = None;
            primary_value = None;
            profile_errors = [];
          }
        |> fun profile -> Persona_profile_loaded profile

(** Neo4j agent identity cache.  Loaded lazily on first lookup; once
    populated the Hashtbl is read-only.

    Invariant: [neo4j_cache_loaded] flips to true only after the
    populate attempt finishes (success or error), so any fiber that
    observes it set will never read an empty Hashtbl, and a failed
    GraphQL load is not retried within the process lifetime.

    Locking via [Eio_guard.with_mutex] so a contending fiber suspends
    instead of freezing the whole Eio domain during the up to 10 s
    GraphQL round-trip on first load. *)
let neo4j_identity_cache : (string, agent_profile) Hashtbl.t = Hashtbl.create 32
let neo4j_cache_loaded = ref false
let neo4j_cache_mu = Eio.Mutex.create ()

let is_neo4j_identity_context_error message =
  String_util.contains_substring message "Switch accessed from wrong domain"

let populate_neo4j_identity_cache_locked () =
  let body =
    {|{"query":"{ agents(first: 50) { edges { node { name emoji koreanName model traits interests activityLevel primaryValue } } } }"}|}
  in
  match Graphql_client.request body with
  | Error e when is_neo4j_identity_context_error e ->
      Log.Dashboard.info "neo4j identity cache skipped: %s" e
  | Error e -> Log.Dashboard.warn "neo4j identity cache load failed: %s" e
  | Ok output -> (
      try
        let json = Yojson.Safe.from_string output in
        let m key source = Option.value ~default:`Null (Json_util.assoc_member_opt key source) in
        let edges =
          (match json |> m "data" |> m "agents" |> m "edges" with
           | `List l -> l | _ -> [])
        in
        List.iter
          (fun edge ->
            let node = edge |> m "node" in
            let name = Safe_ops.json_string ~default:"" "name" node in
            if name <> "" then begin
              let emoji =
                Safe_ops.json_string_opt "emoji" node
                |> Option.value ~default:"🤖"
              in
              let korean_name =
                Safe_ops.json_string_opt "koreanName" node
                |> Option.value ~default:name
              in
              let model = Safe_ops.json_string_opt "model" node in
              let traits =
                Safe_ops.protect ~default:[] (fun () ->
                  (match node |> m "traits" with `List l -> List.filter_map (function `String s -> Some s | _ -> None) l | _ -> []))
              in
              let interests =
                Safe_ops.protect ~default:[] (fun () ->
                  (match node |> m "interests" with `List l -> List.filter_map (function `String s -> Some s | _ -> None) l | _ -> []))
              in
              let activity_level = Safe_ops.json_float_opt "activityLevel" node in
              let primary_value = Safe_ops.json_string_opt "primaryValue" node in
              Hashtbl.replace neo4j_identity_cache name
                {
                  emoji;
                  korean_name;
                  model;
                  traits;
                  interests;
                  activity_level;
                  primary_value;
                  profile_errors = [];
                }
            end)
          edges
      with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
        Log.Dashboard.warn "neo4j identity cache update failed: %s" (Printexc.to_string exn))

let lookup_neo4j_profile persona_name =
  Eio_guard.with_mutex neo4j_cache_mu (fun () ->
    if not !neo4j_cache_loaded then begin
      populate_neo4j_identity_cache_locked ();
      neo4j_cache_loaded := true
    end;
    Hashtbl.find_opt neo4j_identity_cache persona_name)

(** Merge two profiles: prefer non-default values from [overlay] over [base]. *)
let merge_profiles ~(base : agent_profile) ~(overlay : agent_profile) : agent_profile =
  {
    emoji = (if overlay.emoji <> "🎭" && overlay.emoji <> "🤖" then overlay.emoji else base.emoji);
    korean_name = (if overlay.korean_name <> "" then overlay.korean_name else base.korean_name);
    model = (match overlay.model with Some _ -> overlay.model | None -> base.model);
    traits = (if overlay.traits <> [] then overlay.traits else base.traits);
    interests = (if overlay.interests <> [] then overlay.interests else base.interests);
    activity_level = (match overlay.activity_level with Some _ -> overlay.activity_level | None -> base.activity_level);
    primary_value = (match overlay.primary_value with Some _ -> overlay.primary_value | None -> base.primary_value);
    profile_errors = base.profile_errors @ overlay.profile_errors;
  }

(** Get full agent profile: persona + Neo4j merged -> fallback profile. *)
let get_agent_profile (name : string) : agent_profile =
  let persona_profile_lookup, neo4j_profile, identity_errors =
    match resolve_persona_name name with
    | Persona_name_resolved persona_name ->
        load_persona_profile persona_name, lookup_neo4j_profile persona_name, []
    | Persona_name_invalid error -> Persona_profile_absent, None, [ error ]
  in
  match (persona_profile_lookup, neo4j_profile) with
  | (Persona_profile_loaded persona, Some neo4j) ->
      (* Merge: Neo4j has emoji/traits/interests, persona has model/korean_name *)
      merge_profiles ~base:persona ~overlay:neo4j
      |> with_profile_errors identity_errors
  | (Persona_profile_loaded persona, None) -> with_profile_errors identity_errors persona
  | (Persona_profile_absent, Some neo4j) -> with_profile_errors identity_errors neo4j
  | (Persona_profile_absent, None) -> fallback_agent_profile ~profile_errors:identity_errors name
  | (Persona_profile_read_error error, Some neo4j) ->
      with_profile_errors (identity_errors @ [ error ]) neo4j
  | (Persona_profile_read_error error, None) ->
      fallback_agent_profile ~profile_errors:(identity_errors @ [ error ]) name

let handoff_json ~surface ?command_surface ?operation_id ~label ~target_type ~target_id
    ~focus_kind () =
  `Assoc
    ([
       ("surface", `String surface);
       ("label", `String label);
       ("target_type", `String target_type);
       ("target_id", `String target_id);
       ("focus_kind", `String focus_kind);
     ]
    @
    match command_surface with
    | Some value -> [ ("command_surface", `String value) ]
    | None -> []
    @
    match operation_id with
    | Some value -> [ ("operation_id", `String value) ]
    | None -> [])
