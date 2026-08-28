(** Tone ADT — must precede record types that use it. *)
type tone = Dashboard_utils.tone = Tone_ok | Tone_warn | Tone_bad

type operation_context = {
  operation_id : string;
  severity : tone;
  last_seen_ts : float;
  json : Yojson.Safe.t;
}

type worker_context = {
  tone_rank : int;
  last_signal_ts : float;
  json : Yojson.Safe.t;
}

type continuity_context = {
  tone_rank : int;
  last_signal_ts : float;
  json : Yojson.Safe.t;
}

let option_or_else fallback = function
  | Some _ as value -> value
  | None -> fallback ()

let member_assoc = Dashboard_utils.member_assoc
let string_field = Dashboard_utils.string_field
let take = List.take
let list_field = Dashboard_utils.list_field
let compact_text = String_util.compact_text
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

let dedup_strings = Dashboard_utils.dedup_strings

let dashboard_fixture_name ?fixture () =
  let fixtures_enabled = Env_config.Dashboard_config.fixtures_enabled () in
  if not fixtures_enabled then None
  else
    match fixture with
    | Some value ->
        let trimmed = String.trim value in
        if trimmed <> "" then Some trimmed else Env_config.Dashboard_config.fixture_opt ()
    | None -> Env_config.Dashboard_config.fixture_opt ()

(** Agent profile enriched from the Neo4j cache. *)
type agent_profile = {
  emoji : string;
  korean_name : string;
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

let is_neo4j_identity_context_error message =
  String_util.contains_substring message "Switch accessed from wrong domain"

let populate_neo4j_identity_cache_locked () =
  let body =
    {|{"query":"{ agents(first: 50) { edges { node { name emoji koreanName } } } }"}|}
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
              Hashtbl.replace neo4j_identity_cache name
                {
                  emoji;
                  korean_name;
                }
            end)
          edges
      with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
        Log.Dashboard.warn "neo4j identity cache update failed: %s" (Printexc.to_string exn))

let lookup_neo4j_profile keeper_name =
  Eio_guard.with_mutex neo4j_cache_mu (fun () ->
    if not !neo4j_cache_loaded then begin
      populate_neo4j_identity_cache_locked ();
      neo4j_cache_loaded := true
    end;
    Hashtbl.find_opt neo4j_identity_cache keeper_name)

(** Get full agent profile from Neo4j, then use an identity-only fallback. *)
let get_agent_profile (name : string) : agent_profile =
  (* TODO(task-1823): The fallback below is a fake Keeper v2 dashboard field.
     When no Neo4j data exists, we return hardcoded values
     (emoji="🤖", korean_name=name) instead of live-backed surfaces.
     A future change should either:
       (a) require live-backed surfaces and raise/warn when no data is found, or
       (b) populate from a guaranteed registry so no agent falls through. *)
  let keeper_name = name in
  let neo4j_profile = lookup_neo4j_profile keeper_name in
  match neo4j_profile with
  | Some profile -> profile
  | None ->
      {
        emoji = "🤖";
        korean_name = name;
      }

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
