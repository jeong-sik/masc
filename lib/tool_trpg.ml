(** Tool_trpg - Strict TRPG action tools for AI agents.

    Exposes:
    - masc_trpg_dice_roll
    - masc_trpg_turn_advance
    - masc_trpg_stream
*)

open Yojson.Safe.Util

type result = bool * string

type context = {
  config : Room.config;
  agent_name : string;
}

let schemas : Types.tool_schema list =
  [
    {
      name = "masc_trpg_dice_roll";
      description =
        "Roll D20 for an actor and append dice.rolled event. \
         Required: room_id, actor_id, action, stat_value, dc. \
         Optional: raw_d20 (1-20), rule_module (default: dnd5e-lite).";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("room_id", `Assoc [ ("type", `String "string") ]);
                  ("actor_id", `Assoc [ ("type", `String "string") ]);
                  ("action", `Assoc [ ("type", `String "string") ]);
                  ("stat_value", `Assoc [ ("type", `String "integer") ]);
                  ("dc", `Assoc [ ("type", `String "integer") ]);
                  ("raw_d20", `Assoc [ ("type", `String "integer") ]);
                  ("rule_module", `Assoc [ ("type", `String "string") ]);
                ] );
            ( "required",
              `List
                [
                  `String "room_id";
                  `String "actor_id";
                  `String "action";
                  `String "stat_value";
                  `String "dc";
                ] );
          ];
    };
    {
      name = "masc_trpg_turn_advance";
      description =
        "Advance turn by appending turn.started and optional phase.changed event. \
         Required: room_id. Optional: phase, rule_module.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("room_id", `Assoc [ ("type", `String "string") ]);
                  ("phase", `Assoc [ ("type", `String "string") ]);
                  ("rule_module", `Assoc [ ("type", `String "string") ]);
                ] );
            ("required", `List [ `String "room_id" ]);
          ];
    };
    {
      name = "masc_trpg_stream";
      description =
        "Read TRPG event stream window from storage. \
         Required: room_id. Optional: after_seq, event_type.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("room_id", `Assoc [ ("type", `String "string") ]);
                  ("after_seq", `Assoc [ ("type", `String "integer") ]);
                  ("event_type", `Assoc [ ("type", `String "string") ]);
                ] );
            ("required", `List [ `String "room_id" ]);
          ];
    };
  ]

let ok_json json = (true, Yojson.Safe.to_string json)
let err msg = (false, msg)

let get_required_string args key =
  match args |> member key with
  | `String s ->
      let s = String.trim s in
      if s = "" then Error (Printf.sprintf "%s cannot be empty" key) else Ok s
  | `Null -> Error (Printf.sprintf "%s is required" key)
  | _ -> Error (Printf.sprintf "%s must be string" key)

let get_optional_string args key =
  match args |> member key with
  | `String s ->
      let s = String.trim s in
      if s = "" then Ok None else Ok (Some s)
  | `Null -> Ok None
  | _ -> Error (Printf.sprintf "%s must be string" key)

let get_required_int args key =
  match args |> member key with
  | `Int i -> Ok i
  | `Intlit s -> (
      try Ok (int_of_string s)
      with _ -> Error (Printf.sprintf "%s must be int" key))
  | `Null -> Error (Printf.sprintf "%s is required" key)
  | _ -> Error (Printf.sprintf "%s must be int" key)

let get_optional_int args key =
  match args |> member key with
  | `Int i -> Ok (Some i)
  | `Intlit s -> (
      try Ok (Some (int_of_string s))
      with _ -> Error (Printf.sprintf "%s must be int" key))
  | `Null -> Ok None
  | _ -> Error (Printf.sprintf "%s must be int" key)

let validate_rule_module = function
  | "" | "dnd5e-lite" -> Ok ()
  | other -> Error (Printf.sprintf "unsupported rule_module: %s" other)

let extract_config_from_events (events : Trpg_engine_event.t list) : Yojson.Safe.t =
  let rec loop = function
    | [] -> `Assoc []
    | (ev : Trpg_engine_event.t) :: tl -> (
        match ev.event_type with
        | Trpg_engine_event.Room_created -> (
            match ev.payload with
            | `Assoc fields -> (
                match List.assoc_opt "config" fields with
                | Some c -> c
                | None -> ev.payload)
            | _ -> `Assoc [])
        | _ -> loop tl)
  in
  loop events

let next_seq ~base_dir ~room_id =
  match Trpg_engine_store_sqlite.read_events ~base_dir ~room_id with
  | Error e -> Error e
  | Ok events ->
      Ok
        (1
        + List.fold_left
            (fun acc (ev : Trpg_engine_event.t) -> max acc ev.seq)
            0 events)

let append_event ~base_dir ~room_id ~event_type ?actor_id ?ts ?seq ~payload () =
  let room_id = String.trim room_id in
  if room_id = "" then Error "room_id is required"
  else
    let seq_result =
      match seq with
      | Some s when s <= 0 -> Error "seq must be positive"
      | Some s -> Ok s
      | None -> next_seq ~base_dir ~room_id
    in
    match seq_result with
    | Error e -> Error e
    | Ok seq ->
        let ts = Option.value ~default:(Types.now_iso ()) ts in
        let event =
          Trpg_engine_event.make
            ~seq ~room_id ~ts ~event_type ?actor_id ~payload ()
        in
        (match Trpg_engine_store_sqlite.append_event ~base_dir ~event with
        | Ok () -> Ok event
        | Error e -> Error e)

let derive_state ~base_dir ~room_id ~rule_module =
  match validate_rule_module rule_module with
  | Error e -> Error e
  | Ok () -> (
      match Trpg_engine_store_sqlite.read_events ~base_dir ~room_id with
      | Error e -> Error e
      | Ok events ->
          let config = extract_config_from_events events in
          let rule = (module Trpg_rule_dnd5e_lite : Trpg_rule.S) in
          let state = Trpg_engine_replay.derive_state ~rule ~config ~events in
          Ok
            (`Assoc
              [
                ("ok", `Bool true);
                ("room_id", `String room_id);
                ("rule_module", `String rule_module);
                ("event_count", `Int (List.length events));
                ("state", state);
              ]))

let state_of_derived derived =
  match derived |> member "state" with `Null -> `Assoc [] | v -> v

let read_state_turn derived =
  match state_of_derived derived |> member "turn" with
  | `Int i -> Ok i
  | _ -> Error "state.turn must be int"

let handle_dice_roll ctx args : result =
  let ( let* ) = Result.bind in
  let base_dir = ctx.config.base_path in
  let result_json =
    let* room_id = get_required_string args "room_id" in
    let* actor_id = get_required_string args "actor_id" in
    let* action = get_required_string args "action" in
    let* stat_value = get_required_int args "stat_value" in
    let* dc = get_required_int args "dc" in
    let* raw_opt = get_optional_int args "raw_d20" in
    let* rule_opt = get_optional_string args "rule_module" in
    let rule_module = Option.value ~default:"dnd5e-lite" rule_opt in
    let* () = validate_rule_module rule_module in
    let* raw_d20 =
      match raw_opt with
      | Some i ->
          if i < 1 || i > 20 then Error "raw_d20 must be between 1 and 20" else Ok i
      | None -> Ok (1 + Random.int 20)
    in
    let bonus = Trpg_rule_dnd5e_lite.stat_bonus stat_value in
    let total = raw_d20 + bonus in
    let c = Trpg_rule_dnd5e_lite.classify_roll ~raw_d20 ~total in
    let payload =
      `Assoc
        [
          ("actor_id", `String actor_id);
          ("action", `String action);
          ("stat_value", `Int stat_value);
          ("dc", `Int dc);
          ("raw_d20", `Int raw_d20);
          ("bonus", `Int bonus);
          ("total", `Int total);
          ("tier", `String (Trpg_rule_dnd5e_lite.roll_tier_to_string c.tier));
          ("label", `String c.label);
          ("passed", `Bool c.passed);
        ]
    in
    let* event =
      append_event
        ~base_dir
        ~room_id
        ~event_type:Trpg_engine_event.Dice_rolled
        ~actor_id
        ~payload
        ()
    in
    let* derived = derive_state ~base_dir ~room_id ~rule_module in
    Ok
      (`Assoc
        [
          ("ok", `Bool true);
          ("event", Trpg_engine_event.to_yojson event);
          ( "roll",
            `Assoc
              [
                ("raw_d20", `Int raw_d20);
                ("bonus", `Int bonus);
                ("total", `Int total);
                ("dc", `Int dc);
                ("passed", `Bool c.passed);
                ("label", `String c.label);
              ] );
          ("state", state_of_derived derived);
        ])
  in
  match result_json with Ok j -> ok_json j | Error e -> err e

let handle_turn_advance ctx args : result =
  let ( let* ) = Result.bind in
  let base_dir = ctx.config.base_path in
  let result_json =
    let* room_id = get_required_string args "room_id" in
    let* phase_opt = get_optional_string args "phase" in
    let* rule_opt = get_optional_string args "rule_module" in
    let rule_module = Option.value ~default:"dnd5e-lite" rule_opt in
    let* () = validate_rule_module rule_module in
    let* () =
      match phase_opt with
      | None -> Ok ()
      | Some p -> (
          match Trpg_engine_types.phase_of_string p with
          | Ok _ -> Ok ()
          | Error e -> Error e)
    in
    let* derived = derive_state ~base_dir ~room_id ~rule_module in
    let* current_turn = read_state_turn derived in
    let next_turn = max 1 (current_turn + 1) in
    let* turn_event =
      append_event
        ~base_dir
        ~room_id
        ~event_type:Trpg_engine_event.Turn_started
        ~payload:(`Assoc [ ("turn", `Int next_turn) ])
        ()
    in
    let* phase_event_opt =
      match phase_opt with
      | None -> Ok None
      | Some p ->
          let* ev =
            append_event
              ~base_dir
              ~room_id
              ~event_type:Trpg_engine_event.Phase_changed
              ~payload:(`Assoc [ ("phase", `String p) ])
              ()
          in
          Ok (Some ev)
    in
    let* next_derived = derive_state ~base_dir ~room_id ~rule_module in
    let events_json =
      [ Some turn_event; phase_event_opt ]
      |> List.filter_map (fun x -> x)
      |> List.map Trpg_engine_event.to_yojson
    in
    Ok
      (`Assoc
        [
          ("ok", `Bool true);
          ("room_id", `String room_id);
          ("turn", `Int next_turn);
          ("events", `List events_json);
          ("state", state_of_derived next_derived);
        ])
  in
  match result_json with Ok j -> ok_json j | Error e -> err e

let handle_stream ctx args : result =
  let ( let* ) = Result.bind in
  let base_dir = ctx.config.base_path in
  let result_json =
    let* room_id = get_required_string args "room_id" in
    let* after_seq_opt = get_optional_int args "after_seq" in
    let after_seq = Option.value ~default:0 after_seq_opt in
    let* event_type_opt = get_optional_string args "event_type" in
    let* parsed_event_type =
      match event_type_opt with
      | None -> Ok None
      | Some s -> (
          match Trpg_engine_event.event_type_of_string s with
          | Ok et -> Ok (Some et)
          | Error _ -> Error (Printf.sprintf "invalid event_type: %s" s))
    in
    let* events =
      if after_seq > 0 then
        Trpg_engine_store_sqlite.read_events_after ~base_dir ~room_id ~after_seq
      else Trpg_engine_store_sqlite.read_events ~base_dir ~room_id
    in
    let events =
      match parsed_event_type with
      | None -> events
      | Some et ->
          List.filter
            (fun (ev : Trpg_engine_event.t) -> ev.event_type = et)
            events
    in
    Ok
      (`Assoc
        [
          ("ok", `Bool true);
          ("stream", `Bool true);
          ("room_id", `String room_id);
          ("after_seq", `Int after_seq);
          ("count", `Int (List.length events));
          ("events", `List (List.map Trpg_engine_event.to_yojson events));
        ])
  in
  match result_json with Ok j -> ok_json j | Error e -> err e

let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_trpg_dice_roll" -> Some (handle_dice_roll ctx args)
  | "masc_trpg_turn_advance" -> Some (handle_turn_advance ctx args)
  | "masc_trpg_stream" -> Some (handle_stream ctx args)
  | _ -> None
