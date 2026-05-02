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
  status : string;
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
  allowed_tool_names : string list;
  latest_tool_names : string list;
  latest_tool_call_count : int option;
  latest_action_source : string option;
  tool_audit_source : string option;
  tool_audit_at : string option;
}

let json_string_option value =
  match value with
  | Some text ->
      let trimmed = String.trim text in
      if trimmed <> "" then `String trimmed else `Null
  | None -> `Null

let option_or_else fallback = function
  | Some _ as value -> value
  | None -> fallback ()

let option_to_json f = function
  | Some value -> f value
  | None -> `Null

let member_assoc key json =
  match json with
  | `Assoc fields -> (match List.assoc_opt key fields with Some value -> value | None -> `Null)
  | _ -> `Null

let string_field ?(default = "") key json =
  match member_assoc key json with
  | `String value -> value
  | _ -> default

let string_field_opt key json =
  match member_assoc key json with
  | `String value ->
      let trimmed = String.trim value in
      if trimmed <> "" then Some trimmed else None
  | _ -> None

let take n lst = List.filteri (fun i _ -> i < n) lst

let int_field ?(default = 0) key json =
  match member_assoc key json with
  | `Int value -> value
  | `Intlit raw -> (Option.value ~default:default (int_of_string_opt raw))
  | `Float value -> int_of_float value
  | _ -> default

let list_field key json =
  match member_assoc key json with
  | `List items -> items
  | _ -> []

let trim_to_option = Dashboard_utils.trim_to_option

let compact_text ?(max_len = 160) raw =
  let normalized =
    String.trim raw
    |> String.split_on_char '\n'
    |> List.map String.trim
    |> List.filter (fun value -> value <> "")
    |> String.concat " "
    |> String.trim
  in
  if normalized = "" then ""
  else String_util.utf8_safe ~max_bytes:((max_len - 1) + 3) ~suffix:"…" normalized |> String_util.to_string

let parse_iso_opt = Dashboard_utils.parse_iso_opt
let string_list_of_json = Dashboard_utils.string_list_of_json

let latest_iso_timestamp values =
  let pick_latest best candidate =
    match candidate with
    | None -> best
    | Some candidate -> (
        match parse_iso_opt (Some candidate) with
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

let string_list_json values =
  `List (List.map (fun value -> `String value) values)

let string_list_of_field key json =
  member_assoc key json |> string_list_of_json

(** Status/health predicates — re-exported from Dashboard_utils (SSOT). *)
let is_keeper_offline = Dashboard_utils.is_keeper_offline
let is_health_critical = Dashboard_utils.is_health_critical
let is_health_warning = Dashboard_utils.is_health_warning
let is_health_at_risk = Dashboard_utils.is_health_at_risk
let is_session_terminal = Dashboard_utils.is_session_terminal
let is_session_blocked = Dashboard_utils.is_session_blocked

let string_of_tone = Dashboard_utils.string_of_tone

let execution_tool_preview_limit = 8

let cap_string_list ?(limit = execution_tool_preview_limit) values =
  take limit values

let tool_preview_fields ?(limit = execution_tool_preview_limit) field values =
  let preview = cap_string_list ~limit values in
  [
    (field ^ "_count", `Int (List.length values));
    (field ^ "_preview", string_list_json preview);
  ]

let tool_audit_snapshot agent_name =
  {
    allowed_tool_names = [];
    latest_tool_names = [];
    latest_tool_call_count = None;
    latest_action_source = None;
    tool_audit_source = None;
    tool_audit_at = None;
  }

let skill_route_summary_of_keeper keeper =
  let route = member_assoc "skill_route" keeper in
  let primary =
    trim_to_option (string_field "primary" route)
    |> option_or_else (fun () -> trim_to_option (string_field "skill_primary" keeper))
  in
  let secondary =
    let route_secondary = string_list_of_field "secondary" route in
    if route_secondary <> [] then route_secondary
    else string_list_of_field "skill_secondary" keeper
  in
  let provenance = trim_to_option (string_field "provenance" route) in
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

let dedup_strings items =
  List.sort_uniq String.compare
    (List.filter_map trim_to_option items)

(** severity_rank works on raw JSON strings — broader matching than tone_rank.
    Used by dashboard_mission / dashboard_mission_assembly for external JSON data. *)
let severity_rank = function
  | "bad" | "critical" | "failed" -> 2
  | "warn" | "blocked" | "paused" | "interrupted" -> 1
  | _ -> 0

let tone_rank = Dashboard_utils.tone_rank

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
}

(** Extract persona name from MASC agent name.
    "keeper-sangsu-agent" -> "sangsu", "claude-agent-abc" -> "claude-agent-abc" *)
let extract_persona_name (agent_name : string) : string =
  let s = agent_name in
  let s =
    if String.length s > 7 && String.starts_with ~prefix:"keeper-" s then
      String.sub s 7 (String.length s - 7)
    else s
  in
  let s =
    if String.length s > 6 && String.sub s (String.length s - 6) 6 = "-agent" then
      String.sub s 0 (String.length s - 6)
    else s
  in
  s

(** Try loading agent profile from local persona profile.json.
    Path: resolved personas root / <persona_name> / profile.json *)
let load_persona_profile (persona_name : string) : agent_profile option =
  let path =
    match Config_dir_resolver.personas_dir_opt () with
    | Some personas_root ->
        Filename.concat
          (Filename.concat personas_root persona_name)
          "profile.json"
    | None -> ""
  in
  if not (Sys.file_exists path) then None
  else
    match Safe_ops.read_json_file_safe path with
    | Error _ -> None
    | Ok json ->
        let open Yojson.Safe.Util in
        let name_val =
          Safe_ops.json_string_opt "name" json
          |> Option.value ~default:persona_name
        in
        let keeper_json =
          Safe_ops.protect ~default:None (fun () ->
            Some (json |> member "keeper"))
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
          }

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

let populate_neo4j_identity_cache_locked () =
  let body =
    {|{"query":"{ agents(first: 50) { edges { node { name emoji koreanName model traits interests activityLevel primaryValue } } } }"}|}
  in
  match Graphql_client.request ~timeout_sec:10.0 body with
  | Error e -> Log.Dashboard.warn "neo4j identity cache load failed: %s" e
  | Ok output -> (
      try
        let json = Yojson.Safe.from_string output in
        let open Yojson.Safe.Util in
        let edges =
          json |> member "data" |> member "agents" |> member "edges"
          |> to_list
        in
        List.iter
          (fun edge ->
            let node = edge |> member "node" in
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
                  node |> member "traits" |> to_list |> List.map to_string)
              in
              let interests =
                Safe_ops.protect ~default:[] (fun () ->
                  node |> member "interests" |> to_list |> List.map to_string)
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
  }

(** Get full agent profile: persona + Neo4j merged -> hardcoded fallback *)
let get_agent_profile (name : string) : agent_profile =
  let persona_name = extract_persona_name name in
  let neo4j_profile = lookup_neo4j_profile persona_name in
  let persona_profile = load_persona_profile persona_name in
  match (persona_profile, neo4j_profile) with
  | (Some persona, Some neo4j) ->
      (* Merge: Neo4j has emoji/traits/interests, persona has model/korean_name *)
      merge_profiles ~base:persona ~overlay:neo4j
  | (Some persona, None) -> persona
  | (None, Some neo4j) -> neo4j
  | (None, None) ->
      (* Generic fallback — no persona or Neo4j data available *)
      {
        emoji = "🤖";
        korean_name = name;
        model = None;
        traits = [];
        interests = [];
        activity_level = None;
        primary_value = None;
      }

(** Backward-compatible wrapper: returns (emoji, korean_name) tuple *)
let get_agent_identity (name : string) =
  let profile = get_agent_profile name in
  (profile.emoji, profile.korean_name)

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
