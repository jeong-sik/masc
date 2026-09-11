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

(** Agent profile representation for dashboard views. *)
type agent_profile = {
  emoji : string;
  korean_name : string;
}

(** Get agent profile for dashboard projection.
    Returns default identity emoji and agent name without dead Neo4j GraphQL dependency. *)
let get_agent_profile (name : string) : agent_profile =
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
