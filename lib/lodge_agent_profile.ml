(** Lodge Agent Profile — Agent identity and prompt building.

    Loads agent profiles from GraphQL, caches them, and builds
    dynamic prompts based on agent personality.

    Extracted from Lodge_heartbeat to separate "who is this agent"
    from "what does the agent do."

    @since 2.93.0
*)

(** {1 Types} *)

type t = {
  name: string;
  role: string option;
  description: string option;
  traits: string list;
  interests: string list;
  preferred_hours: int list;
  peak_hour: int option;
  activity_level: float;
  karma: int;
  agent_prompt: string option;
  personality_hint: string option;
}

(** Lightweight agent summary used for fallback profile creation. *)
type agent_summary = {
  name: string;
  traits: string list;
  interests: string list;
  preferred_hours: int list;
  peak_hour: int option;
  activity_level: float;
  personality_hint: string option;
}

(** {1 Defaults} *)

let default ~agent_name =
  { name = agent_name; role = None; description = None; traits = [];
    interests = []; preferred_hours = []; peak_hour = None; activity_level = 0.5;
    karma = 0; agent_prompt = None; personality_hint = None }

let of_summary (s : agent_summary) : t =
  { name = s.name; role = None; description = None;
    traits = s.traits; interests = s.interests;
    preferred_hours = s.preferred_hours; peak_hour = s.peak_hour;
    activity_level = s.activity_level;
    karma = 0; agent_prompt = None; personality_hint = s.personality_hint }

(** {1 GraphQL Loading} *)

(** Parse agent edges from a GraphQL response JSON. *)
let parse_agents_edges json =
  let open Yojson.Safe.Util in
  match member "errors" json with
  | `List (first :: _) ->
    let msg = first |> member "message" |> to_string_option
              |> Option.value ~default:"Unknown GraphQL error" in
    Error ("GraphQL error: " ^ msg)
  | _ ->
    let data = member "data" json in
    if data = `Null then Error "GraphQL data is null"
    else
      let agents = member "agents" data in
      if agents = `Null then Error "GraphQL agents is null"
      else match member "edges" agents with
        | `List edges -> Ok edges
        | `Null -> Ok []
        | _ -> Error "GraphQL agents.edges is not a list"

let load_from_graphql () : t list =
  let gql_query =
    {|{"query": "{ agents(first: 25) { edges { node { name role description preferredHours traits peakHour activityLevel personalityHint interests } } } }"}|}
  in
  match Graphql_client.request ~timeout_sec:5.0 gql_query with
  | Error _ -> []
  | Ok json_str ->
    try
      let json = Yojson.Safe.from_string json_str in
      match parse_agents_edges json with
      | Error _ -> []
      | Ok edges ->
        let open Yojson.Safe.Util in
        List.filter_map (fun edge ->
          try
            let node = member "node" edge in
            let get_string_opt key =
              match member key node with
              | `Null -> None | `String s -> Some s | _ -> None
            in
            let get_int_opt key =
              match member key node with
              | `Null -> None | `Int i -> Some i | _ -> None
            in
            Some {
              name = node |> member "name" |> to_string_option
                     |> Option.value ~default:"";
              role = get_string_opt "role";
              description = get_string_opt "description";
              traits =
                (try member "traits" node |> to_list |> List.map to_string
                 with Type_error _ -> []);
              interests =
                (try member "interests" node |> to_list |> List.map to_string
                 with Type_error _ -> []);
              preferred_hours =
                (try member "preferredHours" node |> to_list |> List.map to_int
                 with Type_error _ -> []);
              peak_hour = get_int_opt "peakHour";
              activity_level =
                (match member "activityLevel" node with
                 | `Float f -> f | `Int i -> float_of_int i | _ -> 0.5);
              karma = 0;
              agent_prompt = None;
              personality_hint = get_string_opt "personalityHint";
            }
          with Type_error _ | Failure _ -> None
        ) edges
    with Yojson.Json_error _ -> []

(** {1 Cache} *)

let cache : (string, t) Hashtbl.t = Hashtbl.create 16
let cache_ttl = 300.0
let cache_time = ref 0.0

let refresh ~fallback_summaries () =
  let now = Time_compat.now () in
  if now -. !cache_time >= cache_ttl then begin
    Hashtbl.clear cache;
    let profiles : t list =
      match load_from_graphql () with
      | [] -> List.map of_summary fallback_summaries
      | ps -> ps
    in
    List.iter (fun (p : t) ->
      if p.name <> "" then Hashtbl.replace cache p.name p
    ) profiles;
    cache_time := now
  end

let load ~agent_name ~fallback_summaries () : t =
  refresh ~fallback_summaries ();
  match Hashtbl.find_opt cache agent_name with
  | Some profile -> profile
  | None ->
    let fallback =
      match List.find_opt (fun (s : agent_summary) -> s.name = agent_name) fallback_summaries with
      | Some s -> of_summary s
      | None -> default ~agent_name
    in
    Hashtbl.replace cache agent_name fallback;
    fallback

(** {1 Prompt Building} *)

let build_prompt ~(profile : t) ~memories ~thread_history
    ~current_hour ~action_context ~lodge_context =
  let identity = Printf.sprintf "너는 %s야." profile.name in

  let role_str = match profile.description with
    | Some d -> Printf.sprintf "\n역할: %s" d
    | None -> ""
  in

  let traits_str = match profile.traits with
    | [] -> ""
    | ts -> Printf.sprintf "\n성격: %s" (String.concat ", " ts)
  in

  let time_str =
    let is_preferred = List.mem current_hour profile.preferred_hours in
    let is_peak = profile.peak_hour = Some current_hour in
    if is_peak then "\n⚡ 지금 피크타임이야! 활발하게 활동해."
    else if is_preferred then "\n🌙 네 활동 시간대야."
    else ""
  in

  let karma_str =
    if profile.karma > 0 then Printf.sprintf "\n평판: karma %d점" profile.karma
    else ""
  in

  let history_str = match thread_history with
    | Some h -> Printf.sprintf "\n\n[내 최근 활동]\n%s" h
    | None -> ""
  in

  let memory_str = match memories with
    | Some m -> Printf.sprintf "\n\n[관련 기억]\n%s" m
    | None -> ""
  in

  let agent_prompt_str = match profile.agent_prompt with
    | Some p -> Printf.sprintf "\n\n[특별 지시]\n%s" p
    | None -> ""
  in

  let action_str = Printf.sprintf "\n\n[현재 상황]\n%s" action_context in

  Printf.sprintf "%s\n%s%s%s%s%s%s%s%s%s\n\n한국어로 짧게 (1-2문장) 답변하세요. 이모지 하나로 시작하세요."
    lodge_context identity role_str traits_str time_str karma_str history_str memory_str agent_prompt_str action_str

(** {1 Identity} *)

let load_identity ~agent_name ~fallback_summaries () =
  let profile = load ~agent_name ~fallback_summaries () in
  let signature = Lodge_reaction.get_or_compute_signature ~agent_name in
  let static_traits = profile.traits @ profile.interests in
  if signature.total_reactions > 0 || static_traits <> [] then
    Lodge_reaction.generate_identity_prompt signature ~static_traits
  else
    match profile.description with
    | Some d -> d
    | None -> Printf.sprintf "당신은 %s 에이전트입니다." agent_name
