(** Game tools - MCP interface for reality-anchor style game actions. *)

open Yojson.Safe.Util

type result = bool * string

let () = Random.self_init ()

let get_string args key default =
  match args |> member key with
  | `String s -> String.trim s
  | _ -> default

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

let game_event ~event_type ~actor ~data =
  let notification =
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
  Sse.broadcast notification

let json_ok payload : result = (true, Yojson.Safe.to_string payload)

let is_authorized_gm agent_id = agent_id = "SYSTEM_GM" || agent_id = "DM"

let handle_declare_intent ~agent_id ~intent : result =
  if agent_id = "" then (false, "agent_id is required")
  else if intent = "" then (false, "intent is required")
  else (
    game_event
      ~event_type:"game.intent_declared"
      ~actor:agent_id
      ~data:(`Assoc [ ("intent", `String intent) ]);
    json_ok
      (`Assoc
        [
          ("ok", `Bool true);
          ("agent_id", `String agent_id);
          ("intent", `String intent);
          ("message", `String "Intent broadcasted to world");
        ]))

let handle_resolve_judgment
    ~caller_id
    ~target_agent_id
    ~ability
    ~proposed_narrative
    ~difficulty_score
  : result =
  if caller_id = "" then (false, "caller_id is required")
  else if target_agent_id = "" then (false, "target_agent_id is required")
  else if not (is_authorized_gm caller_id) then
    (false, Printf.sprintf "Agent [%s] is not authorized as a GM." caller_id)
  else
    let dc = max 1 difficulty_score in
    let roll = 1 + Random.int 20 in
    let success = roll >= dc in
    let impact = if success then 80 else 20 in
    game_event
      ~event_type:"game.judgment_resolved"
      ~actor:caller_id
      ~data:
        (`Assoc
          [
            ("target_agent_id", `String target_agent_id);
            ("ability", `String ability);
            ("success", `Bool success);
            ("narrative", `String proposed_narrative);
            ("difficulty_score", `Int dc);
            ("roll", `Int roll);
            ("impact_score", `Int impact);
          ]);
    json_ok
      (`Assoc
        [
          ("ok", `Bool true);
          ("caller_id", `String caller_id);
          ("target_agent_id", `String target_agent_id);
          ("ability", `String ability);
          ("success", `Bool success);
          ("roll", `Int roll);
          ("difficulty_score", `Int dc);
          ("impact_score", `Int impact);
        ])

let handle_status_update ~agent_id ~frustration ~sanity : result =
  if agent_id = "" then (false, "agent_id is required")
  else
    game_event
      ~event_type:"game.status_update"
      ~actor:agent_id
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
          ("agent_id", `String agent_id);
          ("frustration", `Float frustration);
          ("sanity", `Float sanity);
          ("message", `String "Personal state synced");
        ])

let tool_declare_intent : Types.tool_schema =
  {
    name = "masc_game_declare_intent";
    description = "Declare an in-world intent before judgment resolution.";
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
          ("required", `List [ `String "agent_id"; `String "intent" ]);
        ];
  }

let tool_resolve_judgment : Types.tool_schema =
  {
    name = "masc_game_resolve_judgment";
    description =
      "GM-authoritative judgment resolution with RNG roll and outcome event.";
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
          ( "required",
            `List
              [
                `String "caller_id";
                `String "target_agent_id";
                `String "proposed_narrative";
              ] );
        ];
  }

let tool_status_update : Types.tool_schema =
  {
    name = "masc_game_status_update";
    description = "Publish actor internal state (frustration/sanity) as game event.";
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
          ("required", `List [ `String "agent_id" ]);
        ];
  }

let schemas = [ tool_declare_intent; tool_resolve_judgment; tool_status_update ]

let dispatch ~name ~args : result option =
  match name with
  | "masc_game_declare_intent" | "game.declare_intent" ->
      let agent_id = get_string args "agent_id" "" in
      let intent = get_string args "intent" "" in
      Some (handle_declare_intent ~agent_id ~intent)
  | "masc_game_resolve_judgment" | "game.resolve_judgment" ->
      let caller_id = get_string args "caller_id" "" in
      let target_agent_id = get_string args "target_agent_id" "" in
      let ability = get_string args "ability" "unknown" in
      let proposed_narrative = get_string args "proposed_narrative" "" in
      let difficulty_score = get_int args "difficulty_score" 10 in
      Some
        (handle_resolve_judgment ~caller_id ~target_agent_id ~ability
           ~proposed_narrative ~difficulty_score)
  | "masc_game_status_update" | "game.status_update" ->
      let agent_id = get_string args "agent_id" "" in
      let frustration = get_float args "frustration" 0.0 in
      let sanity = get_float args "sanity" 100.0 in
      Some (handle_status_update ~agent_id ~frustration ~sanity)
  | _ -> None
