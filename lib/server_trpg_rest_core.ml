[@@@warning "-32-33-69"]

open Server_utils
open Server_auth

let trpg_resolve_room_id ~config request =
  let fallback = Option.value ~default:"default" (Room.read_current_room config) in
  match query_param request "room_id" with
  | None -> fallback
  | Some raw -> (
      let room_id = String.trim raw in
      if room_id = "" then fallback else room_id)

type trpg_api_error_kind = [ `Bad_request | `Internal_server_error ]
type trpg_api_result = (Yojson.Safe.t, trpg_api_error_kind * string) result

let trpg_error_json (msg : string) : Yojson.Safe.t =
  `Assoc [ ("ok", `Bool false); ("error", `String msg) ]

let trpg_normalize_events_json
    ?(default_room_id = "")
    (json : Yojson.Safe.t) : Yojson.Safe.t =
  let normalize_room_id raw =
    let trimmed = String.trim raw in
    if trimmed = "" then default_room_id else trimmed
  in
  let int_of_json = function
    | `Int i -> Some i
    | `Intlit s -> (try Some (int_of_string s) with Failure _ -> None)
    | `Float f -> Some (int_of_float f)
    | `String s -> (
        let s = String.trim s in
        if s = "" then None else (try Some (int_of_string s) with Failure _ -> None))
    | _ -> None
  in
  let json_assoc_member key = function
    | `Assoc fields -> List.assoc_opt key fields
    | _ -> None
  in
  let event_seq idx ev =
    match Option.bind (json_assoc_member "seq" ev) int_of_json with
    | Some seq -> seq
    | None -> (
        match Option.bind (json_assoc_member "event_id" ev) int_of_json with
        | Some seq -> seq
        | None -> idx + 1)
  in
  let event_turn ev =
    let from_keys keys src =
      keys
      |> List.find_map (fun key -> Option.bind (json_assoc_member key src) int_of_json)
    in
    match from_keys [ "turn"; "turn_after"; "turn_before" ] ev with
    | Some turn -> turn
    | None -> (
        match json_assoc_member "payload" ev with
        | Some payload ->
            Option.value
              ~default:0
              (from_keys [ "turn"; "turn_after"; "turn_before" ] payload)
        | None -> 0)
  in
  let event_room_id ev =
    let direct =
      Option.bind
        (json_assoc_member "room_id" ev)
        (function
          | `String s -> Some s
          | _ -> None)
    in
    match direct with
    | Some room -> normalize_room_id room
    | None -> (
        match json_assoc_member "payload" ev with
        | Some payload -> (
            match json_assoc_member "room_id" payload with
            | Some (`String room) -> normalize_room_id room
            | _ -> default_room_id)
        | None -> default_room_id)
  in
  match json with
  | `Assoc fields -> (
      match List.assoc_opt "events" fields with
      | Some (`List events) ->
          let indexed =
            events
            |> List.mapi (fun idx ev ->
                   let room_id = event_room_id ev in
                   let turn = event_turn ev in
                   let seq = event_seq idx ev in
                   (room_id, turn, seq, idx, ev))
            |> List.sort (fun (room_a, turn_a, seq_a, idx_a, _) (room_b, turn_b, seq_b, idx_b, _) ->
                   let c_room = String.compare room_a room_b in
                   if c_room <> 0 then c_room
                   else
                     let c_turn = Int.compare turn_a turn_b in
                     if c_turn <> 0 then c_turn
                     else
                       let c_seq = Int.compare seq_a seq_b in
                       if c_seq <> 0 then c_seq else Int.compare idx_a idx_b)
          in
          let seen = Hashtbl.create (List.length indexed) in
          let deduped =
            indexed
            |> List.filter_map (fun (room_id, turn, seq, _idx, ev) ->
                   let key = Printf.sprintf "%s\x1f%d\x1f%d" room_id turn seq in
                   if Hashtbl.mem seen key then None
                   else (
                     Hashtbl.add seen key ();
                     Some ev))
          in
          let updated =
            ("events", `List deduped) :: List.remove_assoc "events" fields
          in
          let updated =
            if List.mem_assoc "count" fields then
              ("count", `Int (List.length deduped)) :: List.remove_assoc "count" updated
            else
              updated
          in
          `Assoc updated
      | _ -> json)
  | _ -> json

let trpg_rule_by_id (rule_id : string)
  : ((module Trpg_rule.S), trpg_api_error_kind * string) result =
  let normalized = String.trim rule_id |> String.lowercase_ascii in
  match normalized with
  | "" | "dnd5e-lite" -> Ok (module Trpg_rule_dnd5e_lite : Trpg_rule.S)
  | other -> Error (`Bad_request, Printf.sprintf "unsupported rule_module: %s" other)

let trpg_extract_config_from_events (events : Trpg_engine_event.t list)
  : Yojson.Safe.t =
  let rec find_room_created = function
    | [] -> `Assoc []
    | ev :: tl ->
        (match ev.Trpg_engine_event.event_type with
        | Trpg_engine_event.Room_created ->
            (match ev.payload with
            | `Assoc fields -> (
                match List.assoc_opt "config" fields with
                | Some cfg -> cfg
                | None -> ev.payload)
            | _ -> `Assoc [])
        | _ -> find_room_created tl)
  in
  find_room_created events

let trpg_parse_required_string key json =
  match Yojson.Safe.Util.member key json with
  | `String s when String.trim s <> "" -> Ok (String.trim s)
  | `String _ -> Error (`Bad_request, Printf.sprintf "%s cannot be empty" key)
  | `Null -> Error (`Bad_request, Printf.sprintf "%s is required" key)
  | _ -> Error (`Bad_request, Printf.sprintf "%s must be string" key)

let trpg_parse_optional_string key json =
  match Yojson.Safe.Util.member key json with
  | `String s ->
      let s = String.trim s in
      if s = "" then Ok None else Ok (Some s)
  | `Null -> Ok None
  | _ -> Error (`Bad_request, Printf.sprintf "%s must be string" key)

let trpg_parse_optional_int key json =
  match Yojson.Safe.Util.member key json with
  | `Int i -> Ok (Some i)
  | `Intlit s -> (
      try Ok (Some (int_of_string s))
      with _ -> Error (`Bad_request, Printf.sprintf "%s must be int" key))
  | `Null -> Ok None
  | _ -> Error (`Bad_request, Printf.sprintf "%s must be int" key)

let trpg_parse_required_int key json =
  match Yojson.Safe.Util.member key json with
  | `Int i -> Ok i
  | `Intlit s -> (
      try Ok (int_of_string s)
      with _ -> Error (`Bad_request, Printf.sprintf "%s must be int" key))
  | `Null -> Error (`Bad_request, Printf.sprintf "%s is required" key)
  | _ -> Error (`Bad_request, Printf.sprintf "%s must be int" key)

let trpg_parse_optional_bool key json ~default =
  match Yojson.Safe.Util.member key json with
  | `Bool b -> Ok b
  | `Null -> Ok default
  | _ -> Error (`Bad_request, Printf.sprintf "%s must be bool" key)

let trpg_parse_optional_string_list key json =
  match Yojson.Safe.Util.member key json with
  | `List items ->
      Ok (List.filter_map (function `String s -> Some s | _ -> None) items)
  | `Null -> Ok []
  | _ -> Error (`Bad_request, Printf.sprintf "%s must be array of strings" key)

let trpg_parse_optional_object key json =
  match Yojson.Safe.Util.member key json with
  | `Assoc _ as obj -> Ok (Some obj)
  | `Null -> Ok None
  | _ ->
      Error (`Bad_request, Printf.sprintf "%s must be object (객체여야 합니다)" key)

let trpg_validate_actor_role role =
  match role with
  | "dm" | "player" | "npc" -> Ok ()
  | other ->
      Error
        ( `Bad_request,
          Printf.sprintf "invalid role: %s (must be dm, player, or npc)" other
        )

let trpg_parse_event_type_filter event_type_filter =
  match event_type_filter with
  | None -> Ok None
  | Some raw -> (
      match Trpg_engine_event.event_type_of_string raw with
      | Ok et -> Ok (Some et)
      | Error _ ->
          Error (`Bad_request, Printf.sprintf "invalid event_type filter: %s" raw))

let trpg_read_events_list ~base_dir ~room_id ~after_seq ~event_type_filter
  : (Trpg_engine_event.t list, trpg_api_error_kind * string) result =
  try
    let room_id = String.trim room_id in
    if room_id = "" then
      Error (`Bad_request, "room_id is required")
    else
      match trpg_parse_event_type_filter event_type_filter with
      | Error _ as e -> e
      | Ok event_type_opt ->
          let read_result =
            if after_seq > 0 then
              Trpg_engine_store_sqlite.read_events_after ~base_dir ~room_id ~after_seq
            else
              Trpg_engine_store_sqlite.read_events ~base_dir ~room_id
          in
          (match read_result with
          | Error e ->
              Log.Trpg.error "read_events failed room=%s after_seq=%d: %s; returning empty list"
                room_id after_seq e;
              Ok []
          | Ok events ->
              let events =
                match event_type_opt with
                | None -> events
                | Some et ->
                    List.filter
                      (fun (ev : Trpg_engine_event.t) -> ev.event_type = et)
                      events
              in
              Ok events)
  with exn ->
    Error
      ( `Internal_server_error,
        Printf.sprintf "trpg_read_events_list failed: %s"
          (Printexc.to_string exn) )

let trpg_read_events_json ~base_dir ~room_id ~after_seq ~event_type_filter : trpg_api_result =
  let room_id = String.trim room_id in
  match trpg_read_events_list ~base_dir ~room_id ~after_seq ~event_type_filter with
  | Error _ as e -> e
  | Ok events ->
      Ok
        (`Assoc
          [
            ("ok", `Bool true);
            ("room_id", `String room_id);
            ("after_seq", `Int after_seq);
            ("count", `Int (List.length events));
            ("events", `List (List.map Trpg_engine_event.to_yojson events));
          ])

let trpg_next_seq ~base_dir ~room_id =
  match Trpg_engine_store_sqlite.read_events ~base_dir ~room_id with
  | Ok events ->
      Ok
        (1
        + List.fold_left
            (fun acc (ev : Trpg_engine_event.t) -> max acc ev.seq)
            0 events)
  | Error e -> Error (`Internal_server_error, e)

let trpg_append_event
    ~base_dir ~room_id ~event_type ?actor_id ?ts ?seq ~payload () =
  let room_id = String.trim room_id in
  if room_id = "" then Error (`Bad_request, "room_id is required")
  else
    let seq_result =
      match seq with
      | Some s when s <= 0 -> Error (`Bad_request, "seq must be positive")
      | Some s -> Ok s
      | None -> trpg_next_seq ~base_dir ~room_id
    in
    match seq_result with
    | Error _ as e -> e
    | Ok seq ->
        let ts = Option.value ~default:(Types.now_iso ()) ts in
        let event =
          Trpg_engine_event.make
            ~seq ~room_id ~ts ~event_type ?actor_id ~payload ()
        in
        (match Trpg_engine_store_sqlite.append_event ~base_dir ~event with
        | Ok () -> Ok event
        | Error e -> Error (`Internal_server_error, e))

let trpg_append_event_json ~base_dir ~body_str : trpg_api_result =
  try
    let json = Yojson.Safe.from_string body_str in
    match trpg_parse_required_string "room_id" json with
    | Error _ as e -> e
    | Ok room_id -> (
    match trpg_parse_required_string "event_type" json with
    | Error _ as e -> e
    | Ok event_type_str -> (
      match Trpg_engine_event.event_type_of_string event_type_str with
      | Error e -> Error (`Bad_request, e)
      | Ok event_type -> (
          match trpg_parse_optional_string "actor_id" json with
          | Error _ as e -> e
          | Ok actor_id -> (
              match trpg_parse_optional_string "ts" json with
              | Error _ as e -> e
              | Ok ts_opt -> (
                  match trpg_parse_optional_int "seq" json with
                  | Error _ as e -> e
                  | Ok seq_opt ->
                      let payload =
                        match Yojson.Safe.Util.member "payload" json with
                        | `Null -> `Assoc []
                        | v -> v
                      in
                      (match
                         trpg_append_event
                           ~base_dir
                           ~room_id
                           ~event_type
                           ?actor_id
                           ?ts:ts_opt
                           ?seq:seq_opt
                           ~payload
                           ()
                       with
                      | Error _ as e -> e
                      | Ok event ->
                          Ok
                            (`Assoc
                              [
                                ("ok", `Bool true);
                                ("event", Trpg_engine_event.to_yojson event);
                              ]))))))
      )
  with Yojson.Json_error e -> Error (`Bad_request, Printf.sprintf "invalid json: %s" e)

let trpg_derive_state_json ~base_dir ~room_id ~rule_module : trpg_api_result =
  try
    let room_id = String.trim room_id in
    if room_id = "" then
      Error (`Bad_request, "room_id is required")
    else
      match trpg_rule_by_id rule_module with
      | Error _ as e -> e
      | Ok rule ->
          let events, read_failed =
            match Trpg_engine_store_sqlite.read_events ~base_dir ~room_id with
            | Ok events -> (events, false)
            | Error e ->
                Log.Trpg.error "derive_state read_events failed room=%s: %s; deriving from empty events"
                  room_id e;
                ([], true)
          in
          let config = trpg_extract_config_from_events events in
          let state =
            Trpg_engine_replay.derive_state ~rule ~config ~events
          in
          let module R = (val rule : Trpg_rule.S) in
          let warning_fields =
            if read_failed then
              [
                ( "warning",
                  `String
                    "event_store_unavailable: derived from empty event stream"
                );
              ]
            else []
          in
          Ok
            (`Assoc
              ([
                 ("ok", `Bool true);
                 ("room_id", `String room_id);
                 ("rule_module", `String R.id);
                 ("event_count", `Int (List.length events));
                 ("state", state);
               ]
              @ warning_fields))
  with exn ->
    Error
      ( `Internal_server_error,
        Printf.sprintf "trpg_derive_state_json failed: %s"
          (Printexc.to_string exn) )

let trpg_state_from_derived derived_json =
  try
    match Yojson.Safe.Util.member "state" derived_json with
    | `Null -> `Assoc []
    | v -> v
  with
  | Yojson.Safe.Util.Type_error (msg, _) ->
      Log.Trpg.warn "trpg_state_from_derived type error: %s" msg;
      `Assoc []
  | exn ->
      Log.Trpg.warn "trpg_state_from_derived unexpected: %s" (Printexc.to_string exn);
      `Assoc []

let trpg_extract_state_int derived_json field ~default =
  try
    match Yojson.Safe.Util.member field (trpg_state_from_derived derived_json) with
    | `Int i -> i
    | _ -> default
  with
  | Yojson.Safe.Util.Type_error (msg, _) ->
      Log.Trpg.warn "trpg_extract_state_int %s type error: %s" field msg;
      default
  | exn ->
      Log.Trpg.warn "trpg_extract_state_int %s unexpected: %s" field (Printexc.to_string exn);
      default

let trpg_read_state_int derived_json field =
  try
    match Yojson.Safe.Util.member field (trpg_state_from_derived derived_json) with
    | `Int i -> Ok i
    | _ ->
        Error
          (`Internal_server_error, Printf.sprintf "state.%s must be int" field)
  with
  | Yojson.Safe.Util.Type_error (msg, _) ->
      Log.Trpg.warn "trpg_read_state_int %s type error: %s" field msg;
      Error (`Internal_server_error, Printf.sprintf "state.%s missing" field)
  | exn ->
      Log.Trpg.warn "trpg_read_state_int %s unexpected: %s" field (Printexc.to_string exn);
      Error (`Internal_server_error, Printf.sprintf "state.%s missing" field)

