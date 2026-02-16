(** Game tools - MCP interface with policy, consistency, and harness-friendly state. *)

open Yojson.Safe.Util

type result = bool * string

type context = {
  masc_dir : string;
  agent_name : string;
}

type intent = {
  agent_id : string;
  intent : string;
  declared_at : float;
  resolved_at : float option;
}

type actor_status = {
  frustration : float;
  sanity : float;
  updated_at : float;
}

type judgment = {
  caller_id : string;
  target_agent_id : string;
  ability : string;
  success : bool;
  difficulty_score : int;
  roll : int;
  impact_score : int;
  resolved_at : float;
  intent : string;
}

type game_state = {
  revision : int;
  gm_agents : string list;
  strict_actor_match : bool;
  intents : intent list;
  actors : (string * actor_status) list;
  objects : (string * string) list;
  judgments : judgment list;
}

let () = Random.self_init ()

let default_state =
  {
    revision = 0;
    gm_agents = [];
    strict_actor_match = true;
    intents = [];
    actors = [];
    objects = [];
    judgments = [];
  }

let get_string args key default =
  match args |> member key with
  | `String s -> String.trim s
  | _ -> default

let get_string_list args key =
  match args |> member key with
  | `List xs ->
      xs
      |> List.filter_map (function
           | `String s ->
               let trimmed = String.trim s in
               if trimmed = "" then None else Some trimmed
           | _ -> None)
  | _ -> []

let get_int args key default =
  match args |> member key with
  | `Int n -> n
  | `Float f -> int_of_float f
  | _ -> default

let get_float args key default =
  match args |> member key with
  | `Float f -> f
  | `Int n -> float_of_int n
  | _ -> default

let get_bool args key default =
  match args |> member key with
  | `Bool b -> b
  | _ -> default

let clamp ~min_v ~max_v x = Float.min max_v (Float.max min_v x)

let dedupe_strings xs =
  let rec loop seen acc = function
    | [] -> List.rev acc
    | x :: tl ->
        if List.mem x seen then loop seen acc tl
        else loop (x :: seen) (x :: acc) tl
  in
  loop [] [] xs

let game_dir masc_dir = Filename.concat masc_dir "game"
let state_path masc_dir = Filename.concat (game_dir masc_dir) "state.json"

let rec ensure_dir path =
  if path <> "" && not (Sys.file_exists path) then (
    let parent = Filename.dirname path in
    if parent <> path then ensure_dir parent;
    try Unix.mkdir path 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())

let write_json_atomic path json =
  let dir = Filename.dirname path in
  ensure_dir dir;
  let tmp =
    Filename.concat dir
      (Printf.sprintf ".%s.tmp.%d" (Filename.basename path) (Unix.getpid ()))
  in
  let oc = open_out tmp in
  let closed = ref false in
  Fun.protect
    ~finally:(fun () ->
      if not !closed then (try close_out oc with _ -> ());
      if Sys.file_exists tmp then (try Sys.remove tmp with _ -> ()))
    (fun () ->
      output_string oc (Yojson.Safe.pretty_to_string json);
      flush oc;
      close_out oc;
      closed := true;
      Sys.rename tmp path)

let read_json path =
  try
    let ic = open_in path in
    let content =
      Fun.protect
        ~finally:(fun () -> close_in_noerr ic)
        (fun () -> really_input_string ic (in_channel_length ic))
    in
    Some (Yojson.Safe.from_string content)
  with _ -> None

let intent_to_json (x : intent) =
  `Assoc
    [
      ("agent_id", `String x.agent_id);
      ("intent", `String x.intent);
      ("declared_at", `Float x.declared_at);
      ( "resolved_at",
        match x.resolved_at with Some v -> `Float v | None -> `Null );
    ]

let intent_of_json json =
  let resolved_at =
    match json |> member "resolved_at" with
    | `Float v -> Some v
    | `Int n -> Some (float_of_int n)
    | _ -> None
  in
  {
    agent_id = json |> member "agent_id" |> to_string;
    intent = json |> member "intent" |> to_string;
    declared_at = json |> member "declared_at" |> to_float;
    resolved_at;
  }

let actor_to_json (agent_id, st : string * actor_status) =
  `Assoc
    [
      ("agent_id", `String agent_id);
      ("frustration", `Float st.frustration);
      ("sanity", `Float st.sanity);
      ("updated_at", `Float st.updated_at);
    ]

let actor_of_json json =
  let st =
    {
      frustration = json |> member "frustration" |> to_float;
      sanity = json |> member "sanity" |> to_float;
      updated_at = json |> member "updated_at" |> to_float;
    }
  in
  (json |> member "agent_id" |> to_string, st)

let object_to_json (id, status : string * string) =
  `Assoc [ ("object_id", `String id); ("status", `String status) ]

let object_of_json json =
  ( json |> member "object_id" |> to_string,
    json |> member "status" |> to_string )

let judgment_to_json (j : judgment) =
  `Assoc
    [
      ("caller_id", `String j.caller_id);
      ("target_agent_id", `String j.target_agent_id);
      ("ability", `String j.ability);
      ("success", `Bool j.success);
      ("difficulty_score", `Int j.difficulty_score);
      ("roll", `Int j.roll);
      ("impact_score", `Int j.impact_score);
      ("resolved_at", `Float j.resolved_at);
      ("intent", `String j.intent);
    ]

let judgment_of_json json =
  {
    caller_id = json |> member "caller_id" |> to_string;
    target_agent_id = json |> member "target_agent_id" |> to_string;
    ability = json |> member "ability" |> to_string;
    success = json |> member "success" |> to_bool;
    difficulty_score = json |> member "difficulty_score" |> to_int;
    roll = json |> member "roll" |> to_int;
    impact_score = json |> member "impact_score" |> to_int;
    resolved_at = json |> member "resolved_at" |> to_float;
    intent = json |> member "intent" |> to_string;
  }

let state_to_json (s : game_state) =
  `Assoc
    [
      ("revision", `Int s.revision);
      ("gm_agents", `List (List.map (fun x -> `String x) s.gm_agents));
      ("strict_actor_match", `Bool s.strict_actor_match);
      ("intents", `List (List.map intent_to_json s.intents));
      ("actors", `List (List.map actor_to_json s.actors));
      ("objects", `List (List.map object_to_json s.objects));
      ("judgments", `List (List.map judgment_to_json s.judgments));
    ]

let state_of_json json =
  let list_field key =
    match json |> member key with `List xs -> xs | _ -> []
  in
  {
    revision = json |> member "revision" |> to_int_option |> Option.value ~default:0;
    gm_agents =
      list_field "gm_agents"
      |> List.filter_map (function `String s -> Some (String.trim s) | _ -> None)
      |> List.filter (fun s -> s <> "");
    strict_actor_match =
      json |> member "strict_actor_match" |> to_bool_option
      |> Option.value ~default:true;
    intents =
      list_field "intents"
      |> List.filter_map (fun x -> try Some (intent_of_json x) with _ -> None);
    actors =
      list_field "actors"
      |> List.filter_map (fun x -> try Some (actor_of_json x) with _ -> None);
    objects =
      list_field "objects"
      |> List.filter_map (fun x -> try Some (object_of_json x) with _ -> None);
    judgments =
      list_field "judgments"
      |> List.filter_map (fun x -> try Some (judgment_of_json x) with _ -> None);
  }

let load_state masc_dir =
  match read_json (state_path masc_dir) with
  | Some json -> (try state_of_json json with _ -> default_state)
  | None -> default_state

let save_state masc_dir state = write_json_atomic (state_path masc_dir) (state_to_json state)

let broadcast_game_event ~event_type ~actor ~data =
  let payload =
    `Assoc
      [
        ("jsonrpc", `String "2.0");
        ("method", `String "masc/event");
        ( "params",
          `Assoc
            [
              ("type", `String event_type);
              ("actor", `String actor);
              ("data", data);
              ("timestamp", `Float (Time_compat.now ()));
            ] );
      ]
  in
  Sse.broadcast payload

let json_ok payload : result = (true, Yojson.Safe.to_string payload)

let effective_actor ~claimed ~authenticated =
  if claimed <> "" then claimed else authenticated

let ensure_actor_match state ~claimed ~authenticated =
  if
    state.strict_actor_match && claimed <> "" && authenticated <> ""
    && claimed <> authenticated
  then
    Error
      (Printf.sprintf
         "strict_actor_match enabled: claimed actor (%s) differs from authenticated \
          actor (%s)"
         claimed authenticated)
  else Ok ()

let is_gm state agent_id =
  if state.gm_agents = [] then true else List.mem agent_id state.gm_agents

let take n xs =
  let rec loop k acc = function
    | [] -> List.rev acc
    | _ when k <= 0 -> List.rev acc
    | x :: tl -> loop (k - 1) (x :: acc) tl
  in
  loop n [] xs

let rec contains_substring_at haystack needle i j =
  if j = String.length needle then true
  else if i + j >= String.length haystack then false
  else if haystack.[i + j] <> needle.[j] then false
  else contains_substring_at haystack needle i (j + 1)

let contains_substring haystack needle =
  let hs = String.lowercase_ascii haystack in
  let nd = String.lowercase_ascii needle in
  if nd = "" then false
  else
    let rec loop i =
      if i > String.length hs - String.length nd then false
      else if contains_substring_at hs nd i 0 then true
      else loop (i + 1)
    in
    loop 0

let object_is_blocking_status status =
  match String.lowercase_ascii (String.trim status) with
  | "broken" | "destroyed" | "removed" | "missing" -> true
  | _ -> false

let find_blocking_object objects intent_text =
  List.find_opt
    (fun (object_id, status) ->
      object_is_blocking_status status && contains_substring intent_text object_id)
    objects

let handle_policy_get ctx : result =
  let state = load_state ctx.masc_dir in
  json_ok
    (`Assoc
      [
        ("revision", `Int state.revision);
        ("gm_agents", `List (List.map (fun x -> `String x) state.gm_agents));
        ("strict_actor_match", `Bool state.strict_actor_match);
        ("mode", `String (if state.gm_agents = [] then "open" else "restricted"));
      ])

let handle_policy_set ctx args : result =
  let state = load_state ctx.masc_dir in
  if state.gm_agents <> [] && not (List.mem ctx.agent_name state.gm_agents) then
    (false, "only GM can change policy")
  else
    let gm_agents =
      get_string_list args "gm_agents" |> dedupe_strings |> List.filter (( <> ) "")
    in
    let strict_actor_match =
      get_bool args "strict_actor_match" state.strict_actor_match
    in
    let next_state =
      {
        state with
        revision = state.revision + 1;
        gm_agents;
        strict_actor_match;
      }
    in
    save_state ctx.masc_dir next_state;
    json_ok
      (`Assoc
        [
          ("ok", `Bool true);
          ("revision", `Int next_state.revision);
          ("gm_agents", `List (List.map (fun x -> `String x) next_state.gm_agents));
          ("strict_actor_match", `Bool next_state.strict_actor_match);
          ( "mode",
            `String
              (if next_state.gm_agents = [] then "open" else "restricted") );
        ])

let handle_object_set ctx args : result =
  let state = load_state ctx.masc_dir in
  if not (is_gm state ctx.agent_name) then (false, "only GM can update object state")
  else
    let object_id = get_string args "object_id" "" in
    let status = get_string args "status" "" in
    if object_id = "" || status = "" then
      (false, "object_id and status are required")
    else
      let next_objects =
        (object_id, status)
        :: List.filter (fun (id, _) -> id <> object_id) state.objects
      in
      let next_state =
        { state with revision = state.revision + 1; objects = next_objects }
      in
      save_state ctx.masc_dir next_state;
      broadcast_game_event ~event_type:"game.object_state_changed"
        ~actor:ctx.agent_name
        ~data:(`Assoc [ ("object_id", `String object_id); ("status", `String status) ]);
      json_ok
        (`Assoc
          [
            ("ok", `Bool true);
            ("revision", `Int next_state.revision);
            ("object_id", `String object_id);
            ("status", `String status);
          ])

let handle_state_get ctx : result =
  let state = load_state ctx.masc_dir in
  json_ok
    (`Assoc
      [
        ("revision", `Int state.revision);
        ("gm_agents", `List (List.map (fun x -> `String x) state.gm_agents));
        ("strict_actor_match", `Bool state.strict_actor_match);
        ("mode", `String (if state.gm_agents = [] then "open" else "restricted"));
        ("intents", `List (List.map intent_to_json state.intents));
        ("actors", `List (List.map actor_to_json state.actors));
        ("objects", `List (List.map object_to_json state.objects));
        ("judgments", `List (List.map judgment_to_json state.judgments));
      ])

let handle_declare_intent ctx args : result =
  let state = load_state ctx.masc_dir in
  let claimed_agent = get_string args "agent_id" "" in
  let intent_text = get_string args "intent" "" in
  let actor = effective_actor ~claimed:claimed_agent ~authenticated:ctx.agent_name in
  if actor = "" then (false, "agent_id is required")
  else if intent_text = "" then (false, "intent is required")
  else
    match ensure_actor_match state ~claimed:claimed_agent ~authenticated:ctx.agent_name with
    | Error e -> (false, e)
    | Ok () ->
        let now = Time_compat.now () in
        let resolved_intents =
          List.map
            (fun it ->
              if it.agent_id = actor && it.resolved_at = None then
                { it with resolved_at = Some now }
              else it)
            state.intents
        in
        let new_intent =
          { agent_id = actor; intent = intent_text; declared_at = now; resolved_at = None }
        in
        let next_state =
          {
            state with
            revision = state.revision + 1;
            intents = new_intent :: resolved_intents;
          }
        in
        save_state ctx.masc_dir next_state;
        broadcast_game_event ~event_type:"game.intent_declared" ~actor
          ~data:(`Assoc [ ("intent", `String intent_text) ]);
        json_ok
          (`Assoc
            [
              ("ok", `Bool true);
              ("revision", `Int next_state.revision);
              ("agent_id", `String actor);
              ("intent", `String intent_text);
            ])

let consume_latest_pending_intent intents target_agent_id resolved_at =
  let rec loop acc = function
    | [] -> (List.rev acc, None)
    | it :: tl ->
        if it.agent_id = target_agent_id && it.resolved_at = None then
          (List.rev_append acc ({ it with resolved_at = Some resolved_at } :: tl), Some it)
        else loop (it :: acc) tl
  in
  loop [] intents

let handle_resolve_judgment ctx args : result =
  let state = load_state ctx.masc_dir in
  let claimed_caller = get_string args "caller_id" "" in
  let caller = effective_actor ~claimed:claimed_caller ~authenticated:ctx.agent_name in
  let target_agent_id = get_string args "target_agent_id" "" in
  let ability = get_string args "ability" "unknown" in
  let proposed_narrative = get_string args "proposed_narrative" "" in
  let difficulty_score = max 1 (get_int args "difficulty_score" 10) in
  if caller = "" then (false, "caller_id is required")
  else if target_agent_id = "" then (false, "target_agent_id is required")
  else if proposed_narrative = "" then (false, "proposed_narrative is required")
  else
    match ensure_actor_match state ~claimed:claimed_caller ~authenticated:ctx.agent_name with
    | Error e -> (false, e)
    | Ok () ->
        if not (is_gm state caller) then
          (false, Printf.sprintf "agent [%s] is not authorized as GM by policy" caller)
        else
          let now = Time_compat.now () in
          let updated_intents, pending_intent_opt =
            consume_latest_pending_intent state.intents target_agent_id now
          in
          (match pending_intent_opt with
          | None ->
              ( false,
                Printf.sprintf "no pending intent for target_agent_id=%s"
                  target_agent_id )
          | Some pending_intent -> (
              match find_blocking_object state.objects pending_intent.intent with
              | Some (object_id, status) ->
                  ( false,
                    Printf.sprintf
                      "Reality Anchor blocked action: intent references object %s in \
                       status %s"
                      object_id status )
              | None ->
                  let roll = 1 + Random.int 20 in
                  let success = roll >= difficulty_score in
                  let impact_score = if success then 80 else 20 in
                  let judgment =
                    {
                      caller_id = caller;
                      target_agent_id;
                      ability;
                      success;
                      difficulty_score;
                      roll;
                      impact_score;
                      resolved_at = now;
                      intent = pending_intent.intent;
                    }
                  in
                  let next_state =
                    {
                      state with
                      revision = state.revision + 1;
                      intents = updated_intents;
                      judgments = take 200 (judgment :: state.judgments);
                    }
                  in
                  save_state ctx.masc_dir next_state;
                  broadcast_game_event ~event_type:"game.judgment_resolved"
                    ~actor:caller
                    ~data:
                      (`Assoc
                        [
                          ("target_agent_id", `String target_agent_id);
                          ("intent", `String pending_intent.intent);
                          ("ability", `String ability);
                          ("success", `Bool success);
                          ("difficulty_score", `Int difficulty_score);
                          ("roll", `Int roll);
                          ("impact_score", `Int impact_score);
                          ("proposed_narrative", `String proposed_narrative);
                        ]);
                  json_ok
                    (`Assoc
                      [
                        ("ok", `Bool true);
                        ("revision", `Int next_state.revision);
                        ("caller_id", `String caller);
                        ("target_agent_id", `String target_agent_id);
                        ("ability", `String ability);
                        ("success", `Bool success);
                        ("difficulty_score", `Int difficulty_score);
                        ("roll", `Int roll);
                        ("impact_score", `Int impact_score);
                        ("intent", `String pending_intent.intent);
                      ])))

let handle_status_update ctx args : result =
  let state = load_state ctx.masc_dir in
  let claimed_agent = get_string args "agent_id" "" in
  let agent_id = effective_actor ~claimed:claimed_agent ~authenticated:ctx.agent_name in
  if agent_id = "" then (false, "agent_id is required")
  else
    match ensure_actor_match state ~claimed:claimed_agent ~authenticated:ctx.agent_name with
    | Error e -> (false, e)
    | Ok () ->
        let frustration = clamp ~min_v:0.0 ~max_v:100.0 (get_float args "frustration" 0.0) in
        let sanity = clamp ~min_v:0.0 ~max_v:100.0 (get_float args "sanity" 100.0) in
        let updated_at = Time_compat.now () in
        let next_actors =
          (agent_id, { frustration; sanity; updated_at })
          :: List.filter (fun (id, _) -> id <> agent_id) state.actors
        in
        let next_state =
          {
            state with
            revision = state.revision + 1;
            actors = next_actors;
          }
        in
        save_state ctx.masc_dir next_state;
        broadcast_game_event ~event_type:"game.status_updated" ~actor:agent_id
          ~data:
            (`Assoc
              [
                ("frustration", `Float frustration);
                ("sanity", `Float sanity);
              ]);
        json_ok
          (`Assoc
            [
              ("ok", `Bool true);
              ("revision", `Int next_state.revision);
              ("agent_id", `String agent_id);
              ("frustration", `Float frustration);
              ("sanity", `Float sanity);
            ])

let tool_declare_intent : Types.tool_schema =
  {
    name = "masc_game_declare_intent";
    description = "Declare an actor intent for the next game judgment.";
    input_schema =
      `Assoc
        [
          ("type", `String "object");
          ( "properties",
            `Assoc
              [
                ("agent_id", `Assoc [ ("type", `String "string") ]);
                ("intent", `Assoc [ ("type", `String "string") ]);
              ] );
          ("required", `List [ `String "intent" ]);
        ];
  }

let tool_resolve_judgment : Types.tool_schema =
  {
    name = "masc_game_resolve_judgment";
    description =
      "Resolve pending intent using GM policy, reality anchor checks, and RNG.";
    input_schema =
      `Assoc
        [
          ("type", `String "object");
          ( "properties",
            `Assoc
              [
                ("caller_id", `Assoc [ ("type", `String "string") ]);
                ("target_agent_id", `Assoc [ ("type", `String "string") ]);
                ("ability", `Assoc [ ("type", `String "string") ]);
                ("proposed_narrative", `Assoc [ ("type", `String "string") ]);
                ("difficulty_score", `Assoc [ ("type", `String "integer") ]);
              ] );
          ("required", `List [ `String "target_agent_id"; `String "proposed_narrative" ]);
        ];
  }

let tool_status_update : Types.tool_schema =
  {
    name = "masc_game_status_update";
    description = "Update actor emotional state with bounded values [0,100].";
    input_schema =
      `Assoc
        [
          ("type", `String "object");
          ( "properties",
            `Assoc
              [
                ("agent_id", `Assoc [ ("type", `String "string") ]);
                ("frustration", `Assoc [ ("type", `String "number") ]);
                ("sanity", `Assoc [ ("type", `String "number") ]);
              ] );
        ];
  }

let tool_policy_get : Types.tool_schema =
  {
    name = "masc_game_policy_get";
    description = "Get current game policy (GM allowlist and actor-match mode).";
    input_schema = `Assoc [ ("type", `String "object"); ("properties", `Assoc []) ];
  }

let tool_policy_set : Types.tool_schema =
  {
    name = "masc_game_policy_set";
    description =
      "Set game policy. gm_agents empty means open mode; non-empty means GM allowlist.";
    input_schema =
      `Assoc
        [
          ("type", `String "object");
          ( "properties",
            `Assoc
              [
                ( "gm_agents",
                  `Assoc
                    [
                      ("type", `String "array");
                      ("items", `Assoc [ ("type", `String "string") ]);
                    ] );
                ("strict_actor_match", `Assoc [ ("type", `String "boolean") ]);
              ] );
        ];
  }

let tool_object_set : Types.tool_schema =
  {
    name = "masc_game_object_set";
    description = "Set world object status for reality-anchor causality checks.";
    input_schema =
      `Assoc
        [
          ("type", `String "object");
          ( "properties",
            `Assoc
              [
                ("object_id", `Assoc [ ("type", `String "string") ]);
                ("status", `Assoc [ ("type", `String "string") ]);
              ] );
          ("required", `List [ `String "object_id"; `String "status" ]);
        ];
  }

let tool_state_get : Types.tool_schema =
  {
    name = "masc_game_state_get";
    description = "Get full game state snapshot (policy, intents, actors, objects).";
    input_schema = `Assoc [ ("type", `String "object"); ("properties", `Assoc []) ];
  }

let schemas =
  [
    tool_declare_intent;
    tool_resolve_judgment;
    tool_status_update;
    tool_policy_get;
    tool_policy_set;
    tool_object_set;
    tool_state_get;
  ]

let dispatch (ctx : context) ~name ~args : result option =
  match name with
  | "masc_game_declare_intent" | "game.declare_intent" ->
      Some (handle_declare_intent ctx args)
  | "masc_game_resolve_judgment" | "game.resolve_judgment" ->
      Some (handle_resolve_judgment ctx args)
  | "masc_game_status_update" | "game.status_update" ->
      Some (handle_status_update ctx args)
  | "masc_game_policy_get" | "game.policy.get" -> Some (handle_policy_get ctx)
  | "masc_game_policy_set" | "game.policy.set" ->
      Some (handle_policy_set ctx args)
  | "masc_game_object_set" | "game.object.set" ->
      Some (handle_object_set ctx args)
  | "masc_game_state_get" | "game.state.get" -> Some (handle_state_get ctx)
  | _ -> None
