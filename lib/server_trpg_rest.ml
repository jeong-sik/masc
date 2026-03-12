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
              Printf.eprintf
                "[trpg] read_events failed room=%s after_seq=%d: %s; returning empty list\n%!"
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
                Printf.eprintf
                  "[trpg] derive_state read_events failed room=%s: %s; deriving from empty events\n%!"
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
  with _ -> `Assoc []

let trpg_extract_state_int derived_json field ~default =
  try
    match Yojson.Safe.Util.member field (trpg_state_from_derived derived_json) with
    | `Int i -> i
    | _ -> default
  with _ -> default

let trpg_read_state_int derived_json field =
  try
    match Yojson.Safe.Util.member field (trpg_state_from_derived derived_json) with
    | `Int i -> Ok i
    | _ ->
        Error
          (`Internal_server_error, Printf.sprintf "state.%s must be int" field)
  with _ ->
    Error (`Internal_server_error, Printf.sprintf "state.%s missing" field)

(* ─── Actor state query helpers ─────────────────────────────── *)

type trpg_actor_spawn_cached = {
  fingerprint : string;
  response_json : Yojson.Safe.t;
  seq : int;
}

type trpg_actor_spawn_guard_state = {
  mutex : Mutex.t;
  room_mutexes : (string, Mutex.t) Hashtbl.t;
  idempotency_cache : (string, trpg_actor_spawn_cached) Hashtbl.t;
  mutable next_seq : int;
}

let trpg_actor_spawn_guard : trpg_actor_spawn_guard_state =
  {
    mutex = Mutex.create ();
    room_mutexes = Hashtbl.create 64;
    idempotency_cache = Hashtbl.create 2048;
    next_seq = 0;
  }

let trpg_with_actor_spawn_guard_lock f =
  Mutex.lock trpg_actor_spawn_guard.mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock trpg_actor_spawn_guard.mutex) f

let trpg_with_actor_spawn_room_lock ~room_id f =
  let room_key = String.trim room_id in
  let room_key = if room_key = "" then "default" else room_key in
  let room_mutex =
    trpg_with_actor_spawn_guard_lock (fun () ->
        match Hashtbl.find_opt trpg_actor_spawn_guard.room_mutexes room_key with
        | Some m -> m
        | None ->
            let m = Mutex.create () in
            Hashtbl.replace trpg_actor_spawn_guard.room_mutexes room_key m;
            m)
  in
  Mutex.lock room_mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock room_mutex) f

let trpg_actor_spawn_cache_key ~room_id ~idempotency_key =
  room_id ^ "\x1f" ^ idempotency_key

let trpg_actor_spawn_cache_lookup ~room_id ~idempotency_key =
  let key = trpg_actor_spawn_cache_key ~room_id ~idempotency_key in
  trpg_with_actor_spawn_guard_lock (fun () ->
      Hashtbl.find_opt trpg_actor_spawn_guard.idempotency_cache key)

let trpg_actor_spawn_cache_store ~room_id ~idempotency_key ~fingerprint
    ~response_json =
  let max_cache_entries = 4096 in
  let key = trpg_actor_spawn_cache_key ~room_id ~idempotency_key in
  trpg_with_actor_spawn_guard_lock (fun () ->
      trpg_actor_spawn_guard.next_seq <- trpg_actor_spawn_guard.next_seq + 1;
      Hashtbl.replace trpg_actor_spawn_guard.idempotency_cache key
        { fingerprint; response_json; seq = trpg_actor_spawn_guard.next_seq };
      while Hashtbl.length trpg_actor_spawn_guard.idempotency_cache
            > max_cache_entries
      do
        let oldest =
          Hashtbl.to_seq trpg_actor_spawn_guard.idempotency_cache
          |> Seq.fold_left
               (fun acc (k, v) ->
                 match acc with
                 | None -> Some (k, v.seq)
                 | Some (_old_key, old_seq) ->
                     if v.seq < old_seq then Some (k, v.seq) else acc)
               None
        in
        match oldest with
        | Some (old_key, _) ->
            Hashtbl.remove trpg_actor_spawn_guard.idempotency_cache old_key
        | None -> ()
      done)

let trpg_normalize_keeper_name s = s |> String.trim |> String.lowercase_ascii

let trpg_state_party_fields state =
  match Yojson.Safe.Util.member "party" state with
  | `Assoc fields -> fields
  | _ -> []

let trpg_actor_exists state actor_id =
  trpg_state_party_fields state |> List.mem_assoc actor_id

let trpg_sanitize_actor_id_seed (s : string) =
  let src = String.lowercase_ascii (String.trim s) in
  let out = Buffer.create (String.length src) in
  let prev_dash = ref true in
  String.iter
    (fun c ->
      if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') then (
        Buffer.add_char out c;
        prev_dash := false)
      else if not !prev_dash then (
        Buffer.add_char out '-';
        prev_dash := true))
    src;
  let collapsed = Buffer.contents out in
  let len = String.length collapsed in
  if len > 0 && collapsed.[len - 1] = '-' then
    let trimmed = String.sub collapsed 0 (len - 1) in
    if trimmed = "" then "actor" else trimmed
  else if collapsed = "" then "actor"
  else collapsed

let trpg_next_available_actor_id state base_actor_id =
  if not (trpg_actor_exists state base_actor_id) then base_actor_id
  else
    let rec loop n =
      let candidate = Printf.sprintf "%s-%d" base_actor_id n in
      if trpg_actor_exists state candidate then loop (n + 1) else candidate
    in
    loop 2

let trpg_actor_alive state actor_id =
  match trpg_state_party_fields state |> List.assoc_opt actor_id with
  | Some (`Assoc fields) -> (
      match List.assoc_opt "alive" fields with
      | Some (`Bool b) -> b
      | _ -> true)
  | _ -> true

let trpg_state_actor_control_fields state =
  match Yojson.Safe.Util.member "actor_control" state with
  | `Assoc fields ->
      List.filter_map
        (fun (k, v) ->
          match v with
          | `String s when String.trim s <> "" -> Some (k, String.trim s)
          | _ -> None)
        fields
  | _ -> []

let rec trpg_canonicalize_json (value : Yojson.Safe.t) : Yojson.Safe.t =
  match value with
  | `Assoc fields ->
      `Assoc
        (fields
        |> List.map (fun (k, v) -> (k, trpg_canonicalize_json v))
        |> List.sort (fun (a, _) (b, _) -> String.compare a b))
  | `List items -> `List (List.map trpg_canonicalize_json items)
  | other -> other

let trpg_owner_for_actor state actor_id =
  trpg_state_actor_control_fields state |> List.assoc_opt actor_id

let trpg_actor_for_keeper state keeper =
  let norm = trpg_normalize_keeper_name keeper in
  trpg_state_actor_control_fields state
  |> List.find_opt (fun (_aid, kn) -> trpg_normalize_keeper_name kn = norm)
  |> Option.map fst

let trpg_actor_role state actor_id =
  match trpg_state_party_fields state |> List.assoc_opt actor_id with
  | Some (`Assoc fields) -> (
      match List.assoc_opt "role" fields with
      | Some (`String role) when String.trim role <> "" ->
          String.lowercase_ascii (String.trim role)
      | _ -> "player")
  | _ -> "player"

let trpg_join_gate_phase_open state =
  match Yojson.Safe.Util.member "join_gate" state |> Yojson.Safe.Util.member "phase_open" with
  | `Bool b -> b
  | _ -> true

let trpg_join_gate_min_points state =
  match Yojson.Safe.Util.member "join_gate" state |> Yojson.Safe.Util.member "min_points" with
  | `Int n when n > 0 -> n
  | _ -> 3

let trpg_contribution_for_actor events actor_id =
  let score = ref 0 in
  let reasons = ref [] in
  let add delta reason =
    score := max (-10) (min 50 (!score + delta));
    reasons := !reasons @ [ reason ]
  in
  List.iter
    (fun (ev : Trpg_engine_event.t) ->
      let payload = ev.payload in
      let event_actor_id =
        match payload |> Yojson.Safe.Util.member "actor_id" with
        | `String v when String.trim v <> "" -> Some (String.trim v)
        | _ -> ev.actor_id
      in
      match ev.event_type with
      | Trpg_engine_event.Turn_action_resolved ->
          if event_actor_id = Some actor_id then add 2 "turn.action.resolved +2"
      | Trpg_engine_event.Intervention_applied ->
          let target_actor =
            match payload |> Yojson.Safe.Util.member "target_actor" with
            | `String v when String.trim v <> "" -> Some (String.trim v)
            | _ -> event_actor_id
          in
          if target_actor = Some actor_id then
            add 1 "intervention.applied +1"
      | Trpg_engine_event.Dice_rolled ->
          if event_actor_id = Some actor_id then
            let passed =
              match payload |> Yojson.Safe.Util.member "passed" with
              | `Bool b -> b
              | _ -> false
            in
            if passed then add 1 "dice.rolled(pass) +1"
            else add (-1) "dice.rolled(fail) -1"
      | _ -> ())
    events;
  (!score, !reasons)

let trpg_dice_roll_json ~base_dir ~body_str : trpg_api_result =
  try
    let json = Yojson.Safe.from_string body_str in
    let ( let* ) r f = match r with Ok v -> f v | Error _ as e -> e in
    let* room_id = trpg_parse_required_string "room_id" json in
    let* actor_id = trpg_parse_required_string "actor_id" json in
    let* rule_module_opt = trpg_parse_optional_string "rule_module" json in
    let rule_module = Option.value ~default:"dnd5e-lite" rule_module_opt in
    let* _rule = trpg_rule_by_id rule_module in
    let* action = trpg_parse_required_string "action" json in
    let* stat_value = trpg_parse_required_int "stat_value" json in
    let* dc = trpg_parse_required_int "dc" json in
    let* raw_opt = trpg_parse_optional_int "raw_d20" json in
    let* raw_d20 =
      match raw_opt with
      | Some i ->
          if i < 1 || i > 20 then
            Error (`Bad_request, "raw_d20 must be between 1 and 20")
          else Ok i
      | None -> Ok (1 + Random.int 20)
    in
    let bonus = Trpg_rule_dnd5e_lite.stat_bonus stat_value in
    let total = raw_d20 + bonus in
    let classification =
      Trpg_rule_dnd5e_lite.classify_roll ~raw_d20 ~total
    in
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
          ( "tier",
            `String
              (Trpg_rule_dnd5e_lite.roll_tier_to_string
                 classification.tier) );
          ("label", `String classification.label);
          ("passed", `Bool classification.passed);
        ]
    in
    let* event =
      trpg_append_event
        ~base_dir
        ~room_id
        ~event_type:Trpg_engine_event.Dice_rolled
        ~actor_id
        ~payload
        ()
    in
    let* derived = trpg_derive_state_json ~base_dir ~room_id ~rule_module in
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
                ("passed", `Bool classification.passed);
                ("label", `String classification.label);
              ] );
          ("state", trpg_state_from_derived derived);
        ])
  with Yojson.Json_error e -> Error (`Bad_request, Printf.sprintf "invalid json: %s" e)

(* ─── Actor REST wrappers ───────────────────────────────────── *)

let trpg_actor_spawn_extract_idempotency_key ~(header_key : string option)
    (json : Yojson.Safe.t) : string option =
  let normalize = function
    | None -> None
    | Some raw ->
        let trimmed = String.trim raw in
        if trimmed = "" then None else Some trimmed
  in
  match normalize header_key with
  | Some _ as key -> key
  | None -> (
      match Yojson.Safe.Util.member "idempotency_key" json with
      | `String raw -> normalize (Some raw)
      | _ -> None)

let trpg_actor_spawn_request_fingerprint ~room_id ~rule_module ~actor_id_opt
    ~name_opt ~role ~archetype ~persona ~portrait ~background ~stats_opt ~hp
    ~max_hp ~alive ~traits ~skills ~inventory =
  let fields =
    ref
      [
        ("room_id", `String room_id);
        ("rule_module", `String rule_module);
        ("role", `String role);
        ("hp", `Int hp);
        ("max_hp", `Int max_hp);
        ("alive", `Bool alive);
        ("traits", `List (List.map (fun s -> `String s) traits));
        ("skills", `List (List.map (fun s -> `String s) skills));
        ("inventory", `List (List.map (fun s -> `String s) inventory));
      ]
  in
  let add_opt_string key = function
    | Some value -> fields := (key, `String value) :: !fields
    | None -> ()
  in
  add_opt_string "actor_id" actor_id_opt;
  add_opt_string "name" name_opt;
  add_opt_string "archetype" archetype;
  add_opt_string "persona" persona;
  add_opt_string "portrait" portrait;
  add_opt_string "background" background;
  (match stats_opt with
  | Some stats -> fields := ("stats", trpg_canonicalize_json stats) :: !fields
  | None -> ());
  `Assoc !fields |> trpg_canonicalize_json |> Yojson.Safe.to_string

let trpg_actor_spawn_json ~base_dir ~(idempotency_key : string option) ~body_str
    : trpg_api_result =
  try
    let json = Yojson.Safe.from_string body_str in
    let ( let* ) r f = match r with Ok v -> f v | Error _ as e -> e in
    let* room_id_raw = trpg_parse_required_string "room_id" json in
    let room_id = String.trim room_id_raw in
    let* () =
      if room_id = "" then
        Error (`Bad_request, "room_id is required")
      else Ok ()
    in
    let* rule_module_opt = trpg_parse_optional_string "rule_module" json in
    let rule_module = Option.value ~default:"dnd5e-lite" rule_module_opt in
    let* actor_id_opt = trpg_parse_optional_string "actor_id" json in
    let* name_opt = trpg_parse_optional_string "name" json in
    let* role_opt = trpg_parse_optional_string "role" json in
    let role =
      role_opt |> Option.value ~default:"player" |> String.lowercase_ascii
    in
    let* () = trpg_validate_actor_role role in
    let* archetype = trpg_parse_optional_string "archetype" json in
    let* persona = trpg_parse_optional_string "persona" json in
    let* portrait = trpg_parse_optional_string "portrait" json in
    let* background = trpg_parse_optional_string "background" json in
    let* stats_opt = trpg_parse_optional_object "stats" json in
    let* hp_opt = trpg_parse_optional_int "hp" json in
    let* max_hp_opt = trpg_parse_optional_int "max_hp" json in
    let max_hp = Option.value ~default:10 max_hp_opt in
    let* () =
      if max_hp <= 0 then
        Error (`Bad_request, "max_hp must be > 0")
      else Ok ()
    in
    let hp = Option.value ~default:max_hp hp_opt in
    let* () =
      if hp < 0 then Error (`Bad_request, "hp must be >= 0") else Ok ()
    in
    let hp = min hp max_hp in
    let* alive = trpg_parse_optional_bool "alive" json ~default:true in
    let* traits = trpg_parse_optional_string_list "traits" json in
    let* skills = trpg_parse_optional_string_list "skills" json in
    let* inventory = trpg_parse_optional_string_list "inventory" json in
    let idempotency_key =
      trpg_actor_spawn_extract_idempotency_key ~header_key:idempotency_key json
    in
    let request_fingerprint =
      trpg_actor_spawn_request_fingerprint ~room_id ~rule_module ~actor_id_opt
        ~name_opt ~role ~archetype ~persona ~portrait ~background ~stats_opt ~hp
        ~max_hp ~alive ~traits ~skills ~inventory
    in
    trpg_with_actor_spawn_room_lock ~room_id (fun () ->
      let run_spawn_once () =
        let* derived = trpg_derive_state_json ~base_dir ~room_id ~rule_module in
        let state = trpg_state_from_derived derived in
        let actor_id =
          match actor_id_opt with
          | Some explicit -> explicit
          | None ->
              let seed = name_opt |> Option.value ~default:role in
              let base_actor_id = trpg_sanitize_actor_id_seed seed in
              trpg_next_available_actor_id state base_actor_id
        in
        let name = Option.value ~default:actor_id name_opt in
        if trpg_actor_exists state actor_id then
          Error (`Bad_request, Printf.sprintf "actor '%s' already exists" actor_id)
        else
          let actor_fields = ref [] in
          let add_field key value = actor_fields := (key, value) :: !actor_fields in
          let add_opt_string key = function
            | Some value -> add_field key (`String value)
            | None -> ()
          in
          let add_opt_json key = function
            | Some value -> add_field key value
            | None -> ()
          in
          add_field "inventory" (`List (List.map (fun s -> `String s) inventory));
          add_field "skills" (`List (List.map (fun s -> `String s) skills));
          add_field "traits" (`List (List.map (fun s -> `String s) traits));
          add_field "alive" (`Bool alive);
          add_field "max_hp" (`Int max_hp);
          add_field "hp" (`Int hp);
          add_opt_json "stats" stats_opt;
          add_opt_string "background" background;
          add_opt_string "portrait" portrait;
          add_opt_string "persona" persona;
          add_opt_string "archetype" archetype;
          add_field "role" (`String role);
          add_field "name" (`String name);
          let actor_json = `Assoc (List.rev !actor_fields) in
          let payload_fields =
            [
              ("actor_id", `String actor_id);
              ("name", `String name);
              ("role", `String role);
              ("hp", `Int hp);
              ("max_hp", `Int max_hp);
              ("alive", `Bool alive);
              ("traits", `List (List.map (fun s -> `String s) traits));
              ("skills", `List (List.map (fun s -> `String s) skills));
              ("inventory", `List (List.map (fun s -> `String s) inventory));
              ("actor", actor_json);
            ]
          in
          let payload_fields =
            payload_fields
            @
            (match archetype with
            | Some v -> [ ("archetype", `String v) ]
            | None -> [])
            @
            (match persona with
            | Some v -> [ ("persona", `String v) ]
            | None -> [])
            @
            (match portrait with
            | Some v -> [ ("portrait", `String v) ]
            | None -> [])
            @
            (match background with
            | Some v -> [ ("background", `String v) ]
            | None -> [])
            @ (match stats_opt with Some stats -> [ ("stats", stats) ] | None -> [])
          in
          let payload = `Assoc payload_fields in
          let* _event =
            trpg_append_event ~base_dir ~room_id
              ~event_type:Trpg_engine_event.Actor_spawned ~actor_id
              ~payload ()
          in
          let* derived2 = trpg_derive_state_json ~base_dir ~room_id ~rule_module in
          Ok
            (`Assoc
              [
                ("ok", `Bool true);
                ("actor_id", `String actor_id);
                ("state", trpg_state_from_derived derived2);
              ])
      in
      let run_and_maybe_store () =
        let result = run_spawn_once () in
        (match (result, idempotency_key) with
        | Ok response_json, Some key ->
            trpg_actor_spawn_cache_store ~room_id ~idempotency_key:key
              ~fingerprint:request_fingerprint ~response_json
        | _ -> ());
        result
      in
      match idempotency_key with
      | Some key -> (
          match trpg_actor_spawn_cache_lookup ~room_id ~idempotency_key:key with
          | Some cached when String.equal cached.fingerprint request_fingerprint ->
              Ok cached.response_json
          | Some _ ->
              Error
                ( `Bad_request,
                  "idempotency key reused with different payload: code=idempotency_payload_mismatch"
                )
          | None -> run_and_maybe_store ())
      | None -> run_spawn_once ())
  with Yojson.Json_error e ->
    Error (`Bad_request, Printf.sprintf "invalid json: %s" e)

let trpg_actor_claim_json ~base_dir ~body_str : trpg_api_result =
  try
    let json = Yojson.Safe.from_string body_str in
    let ( let* ) r f = match r with Ok v -> f v | Error _ as e -> e in
    let* room_id = trpg_parse_required_string "room_id" json in
    let* rule_module_opt = trpg_parse_optional_string "rule_module" json in
    let rule_module = Option.value ~default:"dnd5e-lite" rule_module_opt in
    let* actor_id = trpg_parse_required_string "actor_id" json in
    let* keeper = trpg_parse_required_string "keeper" json in
    let* derived = trpg_derive_state_json ~base_dir ~room_id ~rule_module in
    let state = trpg_state_from_derived derived in
    let* events =
      match Trpg_engine_store_sqlite.read_events ~base_dir ~room_id with
      | Ok events -> Ok events
      | Error e ->
          Error
            ( `Internal_server_error,
              Printf.sprintf "failed to read events: %s" e )
    in
    if not (trpg_actor_exists state actor_id) then
      Error (`Bad_request, Printf.sprintf "actor '%s' does not exist" actor_id)
    else if not (trpg_actor_alive state actor_id) then
      Error (`Bad_request, Printf.sprintf "actor '%s' is not alive" actor_id)
    else
      let actor_role = trpg_actor_role state actor_id in
      let phase_name =
        match Yojson.Safe.Util.member "phase" state with
        | `String phase -> String.lowercase_ascii (String.trim phase)
        | _ -> "round"
      in
      let* () =
        if actor_role <> "player" then Ok ()
        else if phase_name <> "round" then
          (* Initial party assignment (lobby/briefing) bypasses contribution gate *)
          Ok ()
        else
          let phase_open = trpg_join_gate_phase_open state in
          let required = trpg_join_gate_min_points state in
          let score, _ = trpg_contribution_for_actor events actor_id in
          if not phase_open then
            Error (`Bad_request, "join gate failed: code=join_window_closed")
          else if score < required then
            Error
              ( `Bad_request,
                Printf.sprintf
                  "join gate failed: code=insufficient_contribution score=%d required=%d"
                  score required )
          else Ok ()
      in
      let norm_keeper = trpg_normalize_keeper_name keeper in
      (* Check current ownership *)
      match trpg_owner_for_actor state actor_id with
      | Some current_keeper
        when trpg_normalize_keeper_name current_keeper = norm_keeper ->
          (* Idempotent re-claim by same keeper *)
          Ok
            (`Assoc
              [
                ("ok", `Bool true);
                ("already_claimed", `Bool true);
                ("actor_id", `String actor_id);
                ("keeper", `String keeper);
              ])
      | Some other_keeper ->
          Error
            ( `Bad_request,
              Printf.sprintf "actor '%s' already claimed by '%s'" actor_id
                other_keeper )
      | None -> (
          (* Check keeper doesn't already control another actor *)
          match trpg_actor_for_keeper state keeper with
          | Some other_actor ->
              Error
                ( `Bad_request,
                  Printf.sprintf "keeper '%s' already controls actor '%s'" keeper
                    other_actor )
          | None ->
              let payload = `Assoc [ ("keeper", `String keeper) ] in
              let* _event =
                trpg_append_event ~base_dir ~room_id
                  ~event_type:Trpg_engine_event.Actor_claimed
                  ~actor_id ~payload ()
              in
              let* derived2 =
                trpg_derive_state_json ~base_dir ~room_id
                  ~rule_module
              in
              Ok
                (`Assoc
                  [
                    ("ok", `Bool true);
                    ("actor_id", `String actor_id);
                    ("keeper", `String keeper);
                    ("state", trpg_state_from_derived derived2);
                  ]))
  with Yojson.Json_error e ->
    Error (`Bad_request, Printf.sprintf "invalid json: %s" e)

let trpg_actor_release_json ~base_dir ~body_str : trpg_api_result =
  try
    let json = Yojson.Safe.from_string body_str in
    let ( let* ) r f = match r with Ok v -> f v | Error _ as e -> e in
    let* room_id = trpg_parse_required_string "room_id" json in
    let* rule_module_opt = trpg_parse_optional_string "rule_module" json in
    let rule_module = Option.value ~default:"dnd5e-lite" rule_module_opt in
    let* actor_id = trpg_parse_required_string "actor_id" json in
    let* keeper = trpg_parse_required_string "keeper" json in
    let* derived = trpg_derive_state_json ~base_dir ~room_id ~rule_module in
    let state = trpg_state_from_derived derived in
    match trpg_owner_for_actor state actor_id with
    | None ->
        Error (`Bad_request, Printf.sprintf "actor '%s' is not claimed" actor_id)
    | Some current_keeper ->
        let norm_keeper = trpg_normalize_keeper_name keeper in
        if trpg_normalize_keeper_name current_keeper <> norm_keeper then
          Error
            ( `Bad_request,
              Printf.sprintf "actor '%s' is claimed by '%s', not '%s'" actor_id
                current_keeper keeper )
        else
          let payload = `Assoc [ ("keeper", `String keeper) ] in
          let* _event =
            trpg_append_event ~base_dir ~room_id
              ~event_type:Trpg_engine_event.Actor_released
              ~actor_id ~payload ()
          in
          let* derived2 =
            trpg_derive_state_json ~base_dir ~room_id ~rule_module
          in
          Ok
            (`Assoc
              [
                ("ok", `Bool true);
                ("actor_id", `String actor_id);
                ("released_by", `String keeper);
                ("state", trpg_state_from_derived derived2);
              ])
  with Yojson.Json_error e ->
    Error (`Bad_request, Printf.sprintf "invalid json: %s" e)

let trpg_turn_advance_json ~base_dir ~body_str : trpg_api_result =
  try
    let json = Yojson.Safe.from_string body_str in
    let ( let* ) r f = match r with Ok v -> f v | Error _ as e -> e in
    let* room_id = trpg_parse_required_string "room_id" json in
    let* rule_module_opt = trpg_parse_optional_string "rule_module" json in
    let rule_module = Option.value ~default:"dnd5e-lite" rule_module_opt in
    let* _rule = trpg_rule_by_id rule_module in
    let* phase_opt_raw = trpg_parse_optional_string "phase" json in
    let* phase_opt =
      match phase_opt_raw with
      | None -> Ok None
      | Some p -> (
          match Trpg_engine_types.phase_of_string p with
          | Ok phase ->
              Ok (Some (Trpg_engine_types.string_of_phase phase))
          | Error e -> Error (`Bad_request, e))
    in
    let* derived = trpg_derive_state_json ~base_dir ~room_id ~rule_module in
    let* current_turn = trpg_read_state_int derived "turn" in
    let next_turn = max 1 (current_turn + 1) in
    let turn_payload = `Assoc [ ("turn", `Int next_turn) ] in
    let* turn_event =
      trpg_append_event
        ~base_dir
        ~room_id
        ~event_type:Trpg_engine_event.Turn_started
        ~payload:turn_payload
        ()
    in
    let* phase_event_opt =
      match phase_opt with
      | None -> Ok None
      | Some phase ->
          let payload = `Assoc [ ("phase", `String phase) ] in
          let* ev =
            trpg_append_event
              ~base_dir
              ~room_id
              ~event_type:Trpg_engine_event.Phase_changed
              ~payload
              ()
          in
          Ok (Some ev)
    in
    let* next_derived = trpg_derive_state_json ~base_dir ~room_id ~rule_module in
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
          ("state", trpg_state_from_derived next_derived);
        ])
  with Yojson.Json_error e -> Error (`Bad_request, Printf.sprintf "invalid json: %s" e)

let trpg_stream_json ~base_dir ~room_id ~after_seq ~event_type_filter : trpg_api_result =
  match trpg_read_events_list ~base_dir ~room_id ~after_seq ~event_type_filter with
  | Error _ as e -> e
  | Ok events ->
      Ok
        (`Assoc
          [
            ("ok", `Bool true);
            ("stream", `Bool true);
            ("room_id", `String (String.trim room_id));
            ("after_seq", `Int after_seq);
            ("count", `Int (List.length events));
            ("events", `List (List.map Trpg_engine_event.to_yojson events));
          ])

let split_csv_nonempty (raw : string) : string list =
  let pieces =
    raw
    |> String.split_on_char ','
    |> List.map String.trim
    |> List.filter (fun s -> s <> "")
  in
  let seen : (string, bool) Hashtbl.t = Hashtbl.create 8 in
  let out_rev =
    List.fold_left
      (fun acc item ->
        if Hashtbl.mem seen item then acc
        else (
          Hashtbl.replace seen item true;
          item :: acc))
      []
      pieces
  in
  List.rev out_rev

let has_nonempty_env name =
  match Sys.getenv_opt name with
  | Some value -> String.trim value <> ""
  | None -> false

let trpg_default_fast_keeper_models () : string list =
  let glm_available = has_nonempty_env "ZAI_API_KEY" in
  let gemini_available = has_nonempty_env "GEMINI_API_KEY" in
  let llama_models =
    match Provider_adapter.explicit_llama_model_label_result () with
    | Ok label -> [ label ]
    | Error _ -> []
  in
  match (glm_available, gemini_available) with
  | true, true -> [ "glm:glm-4.7"; "gemini:gemini-2.5-flash" ] @ llama_models
  | true, false -> [ "glm:glm-4.7" ] @ llama_models
  | false, true -> [ "gemini:gemini-2.5-flash" ] @ llama_models
  | false, false -> llama_models

let trpg_keeper_models_override_csv () : string option =
  match Sys.getenv_opt "MASC_TRPG_KEEPER_MODELS" with
  | Some raw -> Some raw
  | None -> Sys.getenv_opt "KEEPER_MODELS"

let trpg_keeper_models_for_round () : string list =
  let configured_opt =
    match trpg_keeper_models_override_csv () with
    | Some raw ->
        let parsed = split_csv_nonempty raw in
        if parsed = [] then None else Some parsed
    | None -> None
  in
  let chosen =
    match configured_opt with
    | Some models -> models
    | None -> trpg_default_fast_keeper_models ()
  in
  match Keeper_types.model_specs_of_strings chosen with
  | Ok _ -> chosen
  | Error e ->
      if chosen <> [] then
        Printf.eprintf "[trpg] invalid keeper model override ignored: %s\n%!" e;
      []

let trim_trailing_slashes (raw : string) : string =
  let rec loop value =
    let len = String.length value in
    if len > 0 && value.[len - 1] = '/' then
      loop (String.sub value 0 (len - 1))
    else
      value
  in
  loop (String.trim raw)

let trpg_json_assoc_find (key : string) = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let trpg_json_string_fields (keys : string list) (json : Yojson.Safe.t) : string option =
  let rec pick = function
    | [] -> None
    | key :: rest -> (
        match trpg_json_assoc_find key json with
        | Some (`String value) ->
            let trimmed = String.trim value in
            if trimmed = "" then pick rest else Some trimmed
        | _ -> pick rest)
  in
  pick keys

let trpg_json_string_list_field (key : string) = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`List rows) ->
          rows
          |> List.filter_map (function
               | `String value ->
                   let trimmed = String.trim value in
                   if trimmed = "" then None else Some trimmed
               | _ -> None)
      | _ -> [])
  | _ -> []

let trpg_http_get_json_via_curl ?(timeout_sec = 2) (url : string) :
    (Yojson.Safe.t, string) result =
  let argv = ["curl"; "-sS"; "--max-time"; string_of_int timeout_sec; url] in
  try
    let status, raw =
      Process_eio.run_argv_with_status
        ~timeout_sec:(Float.of_int timeout_sec +. 1.0)
        argv
    in
    match status with
    | Unix.WEXITED 0 -> (
        if String.trim raw = "" then Error "empty response"
        else
          try Ok (Yojson.Safe.from_string raw)
          with Yojson.Json_error msg ->
            Error (Printf.sprintf "invalid json: %s" msg))
    | Unix.WEXITED 7 -> Error "connection refused"
    | Unix.WEXITED 28 -> Error "request timed out"
    | Unix.WEXITED code -> Error (Printf.sprintf "curl exit %d" code)
    | Unix.WSIGNALED sig_num ->
        Error (Printf.sprintf "curl killed by signal %d" sig_num)
    | Unix.WSTOPPED _ -> Error "curl stopped unexpectedly"
  with exn ->
    Error (Printf.sprintf "http error: %s" (Printexc.to_string exn))

let trpg_custom_endpoint_urls_from_specs (specs : string list) : string list =
  specs
  |> List.filter_map (fun spec ->
         let spec = String.trim spec in
         if not (String.starts_with ~prefix:"custom:" spec) then None
         else
           match String.index_opt spec '@' with
           | Some at_idx when at_idx + 1 < String.length spec ->
               let url =
                 String.sub spec (at_idx + 1) (String.length spec - at_idx - 1)
                 |> trim_trailing_slashes
               in
               if url = "" then None else Some url
           | _ -> None)
  |> String.concat ","
  |> split_csv_nonempty

let trpg_string_contains ~(needle : string) (haystack : string) : bool =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  let rec loop idx =
    if needle_len = 0 then true
    else if idx + needle_len > haystack_len then false
    else if String.sub haystack idx needle_len = needle then true
    else loop (idx + 1)
  in
  loop 0

let trpg_parse_flag_value ~(flag : string) (command : string) : string option =
  let trimmed = String.trim command in
  let with_equals = flag ^ "=" in
  let len = String.length trimmed in
  let rec find_equals idx =
    if idx >= len then None
    else if
      idx + String.length with_equals <= len
      && String.sub trimmed idx (String.length with_equals) = with_equals
    then
      let start = idx + String.length with_equals in
      let rec stop j =
        if j >= len then j
        else
          match trimmed.[j] with
          | ' ' | '\t' | '\n' | '\r' -> j
          | _ -> stop (j + 1)
      in
      let value = String.sub trimmed start (stop start - start) |> String.trim in
      if value = "" then None else Some value
    else find_equals (idx + 1)
  in
  match find_equals 0 with
  | Some _ as value -> value
  | None ->
      let with_space = flag ^ " " in
      let rec find_space idx =
        if idx >= len then None
        else if
          idx + String.length with_space <= len
          && String.sub trimmed idx (String.length with_space) = with_space
        then
          let start = idx + String.length with_space in
          let rec skip_spaces j =
            if j < len && (trimmed.[j] = ' ' || trimmed.[j] = '\t') then
              skip_spaces (j + 1)
            else
              j
          in
          let start = skip_spaces start in
          let rec stop j =
            if j >= len then j
            else
              match trimmed.[j] with
              | ' ' | '\t' | '\n' | '\r' -> j
              | _ -> stop (j + 1)
          in
          let value = String.sub trimmed start (stop start - start) |> String.trim in
          if value = "" then None else Some value
        else find_space (idx + 1)
      in
      find_space 0

let trpg_running_llama_cpp_urls () : string list =
  try
    let status, raw =
      Process_eio.run_argv_with_status ~timeout_sec:2.5 ["ps"; "ax"; "-o"; "command="]
    in
    match status with
    | Unix.WEXITED 0 ->
        raw
        |> String.split_on_char '\n'
        |> List.filter_map (fun line ->
               let trimmed = String.trim line in
               if trimmed = "" || not (trpg_string_contains ~needle:"llama-server" trimmed)
               then None
               else
                 match trpg_parse_flag_value ~flag:"--port" trimmed with
                 | Some port when String.for_all (function '0' .. '9' -> true | _ -> false) port
                   ->
                     Some (Printf.sprintf "http://127.0.0.1:%s" port)
                 | _ -> None
               )
        |> String.concat ","
        |> split_csv_nonempty
    | _ -> []
  with _ -> []

let trpg_openai_compatible_urls () : string list =
  let env_urls =
    match Sys.getenv_opt "MASC_TRPG_CUSTOM_MODEL_ENDPOINTS" with
    | Some raw -> split_csv_nonempty raw |> List.map trim_trailing_slashes
    | None -> []
  in
  let spec_urls =
    trpg_keeper_models_for_round () |> trpg_custom_endpoint_urls_from_specs
  in
  let llama_cpp_urls = trpg_running_llama_cpp_urls () in
  env_urls @ spec_urls @ llama_cpp_urls
  |> List.map trim_trailing_slashes
  |> String.concat ","
  |> split_csv_nonempty

let trpg_discover_openai_compatible_models (base_url : string) :
    (string list, string) result =
  let base_url = trim_trailing_slashes base_url in
  let url = base_url ^ "/v1/models" in
  match trpg_http_get_json_via_curl url with
  | Error err -> Error err
  | Ok json ->
      let named_rows =
        let gather key =
          match trpg_json_assoc_find key json with
          | Some (`List entries) ->
              entries
              |> List.filter_map (fun entry ->
                     trpg_json_string_fields ["id"; "name"; "model"] entry)
          | _ -> []
        in
        gather "data" @ gather "models"
      in
      let names = split_csv_nonempty (String.concat "," named_rows) in
      if names = [] then Error "model ids not found in /v1/models"
      else
        Ok
          (List.map
             (fun model_id -> Printf.sprintf "custom:%s@%s" model_id base_url)
             names)

let trpg_discover_local_llama_models () : (string list, string) result =
  match trpg_discover_openai_compatible_models Env_config.Llama.server_url with
  | Ok specs ->
      Ok
        (specs
        |> List.map (fun spec ->
               match String.index_opt spec ':' with
               | Some idx when idx + 1 < String.length spec ->
                   let tail =
                     String.sub spec (idx + 1) (String.length spec - idx - 1)
                   in
                   (match String.index_opt tail '@' with
                   | Some at_idx when at_idx > 0 ->
                       "llama:" ^ String.sub tail 0 at_idx
                   | _ -> spec)
               | _ -> spec))
  | Error err -> Error err

let trpg_available_models_json_collect
    ?(warnings : string list = [])
    ?(include_live = true)
    () : Yojson.Safe.t =
  let seen : (string, bool) Hashtbl.t = Hashtbl.create 64 in
  let models_rev = ref [] in
  let warnings_rev = ref [] in
  let add_warning message =
    let trimmed = String.trim message in
    if trimmed <> "" then warnings_rev := trimmed :: !warnings_rev
  in
  let add_model ~spec ~source ~status ?detail () =
    let spec = String.trim spec in
    if spec = "" || Hashtbl.mem seen spec then ()
    else (
      Hashtbl.replace seen spec true;
      let fields =
        [
          ("spec", `String spec);
          ("source", `String source);
          ("status", `String status);
        ]
      in
      let fields =
        match detail with
        | Some detail when String.trim detail <> "" ->
            ("detail", `String (String.trim detail)) :: fields
        | _ -> fields
      in
      models_rev := `Assoc (List.rev fields) :: !models_rev)
  in
  let configured_override =
    match trpg_keeper_models_override_csv () with
    | Some raw -> split_csv_nonempty raw
    | None -> []
  in
  let default_models = trpg_default_fast_keeper_models () in
  let effective_models = trpg_keeper_models_for_round () in
  List.iter
    (fun spec -> add_model ~spec ~source:"runtime-default" ~status:"default" ())
    default_models;
  List.iter
    (fun spec -> add_model ~spec ~source:"env-override" ~status:"override" ())
    configured_override;
  List.iter
    (fun spec -> add_model ~spec ~source:"runtime-effective" ~status:"selected" ())
    effective_models;
  List.iter add_warning warnings;
  if include_live then (
    List.iter
      (fun base_url ->
        match trpg_discover_openai_compatible_models base_url with
        | Ok specs ->
            List.iter
              (fun spec ->
                add_model ~spec ~source:"openai-compatible" ~status:"live"
                  ~detail:base_url ())
              specs
        | Error err ->
            add_warning
              (Printf.sprintf "openai-compatible %s 조회 실패: %s" base_url err))
      (trpg_openai_compatible_urls ());
    match trpg_discover_local_llama_models () with
    | Ok specs ->
        List.iter
          (fun spec ->
            add_model ~spec ~source:"llama" ~status:"live"
              ~detail:Env_config.Llama.server_url ())
          specs
    | Error err ->
        add_warning
          (Printf.sprintf "llama %s 조회 실패: %s" Env_config.Llama.server_url err));
  `Assoc
    [
      ("ok", `Bool true);
      ( "effective_models",
        `List (List.map (fun spec -> `String spec) effective_models) );
      ( "configured_override",
        `List (List.map (fun spec -> `String spec) configured_override) );
      ("models", `List (List.rev !models_rev));
      ("warnings", `List (List.rev_map (fun item -> `String item) !warnings_rev));
    ]

let trpg_available_models_json_uncached () : Yojson.Safe.t =
  trpg_available_models_json_collect ()

let trpg_available_models_json_base ?(warnings : string list = []) () : Yojson.Safe.t =
  trpg_available_models_json_collect ~warnings ~include_live:false ()

type trpg_model_catalog_cache = {
  mutex : Mutex.t;
  mutable cached_at : float;
  mutable cached_json : Yojson.Safe.t option;
  mutable refresh_in_flight : bool;
}

let trpg_model_catalog_cache_ttl_sec = 15.0

let trpg_model_catalog_cache : trpg_model_catalog_cache =
  {
    mutex = Mutex.create ();
    cached_at = 0.0;
    cached_json = None;
    refresh_in_flight = false;
  }

let trpg_available_models_json () : Yojson.Safe.t =
  let now = Unix.gettimeofday () in
  let cached, should_refresh =
    Mutex.lock trpg_model_catalog_cache.mutex;
    let snapshot = trpg_model_catalog_cache.cached_json in
    let fresh_snapshot =
      match trpg_model_catalog_cache.cached_json with
      | Some json
        when now -. trpg_model_catalog_cache.cached_at
             < trpg_model_catalog_cache_ttl_sec ->
          Some json
      | _ -> None
    in
    let should_refresh =
      match fresh_snapshot with
      | Some _ -> false
      | None when trpg_model_catalog_cache.refresh_in_flight -> false
      | None ->
          trpg_model_catalog_cache.refresh_in_flight <- true;
          true
    in
    Mutex.unlock trpg_model_catalog_cache.mutex;
    ((match fresh_snapshot with Some json -> Some json | None -> snapshot), should_refresh)
  in
  match (cached, should_refresh) with
  | Some json, false -> json
  | None, false ->
      trpg_available_models_json_base
        ~warnings:["가용 모델 조회 중입니다. 잠시 후 다시 시도하세요."] ()
  | cached_snapshot, true ->
      let fallback_json =
        Fun.protect
          ~finally:(fun () ->
            Mutex.lock trpg_model_catalog_cache.mutex;
            trpg_model_catalog_cache.refresh_in_flight <- false;
            Mutex.unlock trpg_model_catalog_cache.mutex)
          (fun () ->
            let outcome =
              try Ok (trpg_available_models_json_uncached ())
              with
              | Eio.Cancel.Cancelled _ as exn -> raise exn
              | exn -> Error (Printexc.to_string exn)
            in
            match outcome with
            | Ok fresh -> fresh
            | Error err -> (
                match cached_snapshot with
                | Some stale ->
                    stale
                | None ->
                    trpg_available_models_json_base
                      ~warnings:[Printf.sprintf "가용 모델 조회 실패: %s" err] ()))
      in
      Mutex.lock trpg_model_catalog_cache.mutex;
      trpg_model_catalog_cache.cached_json <- Some fallback_json;
      trpg_model_catalog_cache.cached_at <- Unix.gettimeofday ();
      Mutex.unlock trpg_model_catalog_cache.mutex;
      fallback_json

let trpg_json_string_opt_field (json : Yojson.Safe.t) (key : string) : string option =
  match Yojson.Safe.Util.member key json with
  | `String value ->
      let trimmed = String.trim value in
      if trimmed = "" then None else Some trimmed
  | _ -> None

let trpg_json_int_field (json : Yojson.Safe.t) (key : string) ~(default : int) : int =
  match Yojson.Safe.Util.member key json with
  | `Int value -> value
  | _ -> default

let trpg_json_bool_field (json : Yojson.Safe.t) (key : string) ~(default : bool) : bool =
  match Yojson.Safe.Util.member key json with
  | `Bool value -> value
  | _ -> default

let trpg_take_right n lst =
  lst |> List.rev |> take n |> List.rev

let trpg_recent_events ~base_dir ~room_id ~limit =
  match Trpg_engine_store_sqlite.read_events ~base_dir ~room_id with
  | Ok events -> trpg_take_right limit events
  | Error _ -> []

let trpg_party_member_rows (state : Yojson.Safe.t) =
  trpg_state_party_fields state
  |> List.map (fun (actor_id, row) ->
         match row with
         | `Assoc _ ->
             let name =
               trpg_json_string_opt_field row "name" |> Option.value ~default:actor_id
             in
             let role =
               trpg_json_string_opt_field row "role" |> Option.value ~default:"player"
             in
             let alive = trpg_json_bool_field row "alive" ~default:true in
             let hp = trpg_json_int_field row "hp" ~default:0 in
             let max_hp = trpg_json_int_field row "max_hp" ~default:hp in
             let keeper =
               trpg_owner_for_actor state actor_id |> Option.value ~default:""
             in
             `Assoc
               [
                 ("actor_id", `String actor_id);
                 ("name", `String name);
                 ("role", `String role);
                 ("alive", `Bool alive);
                 ("hp", `Int hp);
                 ("max_hp", `Int max_hp);
                 ("keeper", `String keeper);
                 ("claimed", `Bool (String.trim keeper <> ""));
               ]
         | _ ->
             `Assoc
               [
                 ("actor_id", `String actor_id);
                 ("name", `String actor_id);
                 ("role", `String "player");
                 ("alive", `Bool true);
                 ("hp", `Int 0);
                 ("max_hp", `Int 0);
                 ("keeper", `String "");
                 ("claimed", `Bool false);
               ])

let trpg_actor_control_rows (state : Yojson.Safe.t) =
  trpg_party_member_rows state
  |> List.filter_map (fun row ->
         let role = trpg_json_string_opt_field row "role" |> Option.value ~default:"player" in
         let claimed = trpg_json_bool_field row "claimed" ~default:false in
         if String.equal role "dm" || claimed then Some row else None)

let trpg_keeper_summary_rows (config : Room.config) =
  let dir = Keeper_types.keeper_dir config in
  if not (Sys.file_exists dir) then []
  else
    Sys.readdir dir
    |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f ".json")
    |> List.map Filename.remove_extension
    |> List.filter Keeper_types.validate_name
    |> List.sort String.compare
    |> List.filter_map (fun name ->
           match Keeper_types.read_meta config name with
           | Error _ -> None
           | Ok None -> None
           | Ok (Some (m : Keeper_types.keeper_meta)) ->
               let agent = Keeper_exec_status.parse_agent_status config ~agent_name:m.agent_name in
               let agent_exists = trpg_json_bool_field agent "exists" ~default:false in
               let agent_status =
                 trpg_json_string_opt_field agent "status"
                 |> Option.value ~default:"unknown"
               in
               let is_zombie = trpg_json_bool_field agent "is_zombie" ~default:false in
               let keepalive_running = Keeper_keepalive.keeper_keepalive_running m.name in
               Some
                 (`Assoc
                   [
                     ("name", `String m.name);
                     ("agent_name", `String m.agent_name);
                     ("models", `List (List.map (fun item -> `String item) m.models));
                     ("goal", `String m.goal);
                     ("agent_exists", `Bool agent_exists);
                     ("agent_status", `String agent_status);
                     ("is_zombie", `Bool is_zombie);
                     ("keepalive_running", `Bool keepalive_running);
                   ]))

let trpg_lobby_catalog_json ~base_dir ~(config : Room.config) ~room_id ~rule_module :
    trpg_api_result =
  let ( let* ) r f = match r with Ok v -> f v | Error _ as e -> e in
  let* derived = trpg_derive_state_json ~base_dir ~room_id ~rule_module in
  let state = trpg_state_from_derived derived in
  let preset_catalog =
    match Trpg_preset_store.load_catalog ~base_dir with
    | Ok catalog -> catalog
    | Error _ -> Trpg_preset_store.default_catalog
  in
  let keepers = trpg_keeper_summary_rows config in
  let keeper_names =
    keepers
    |> List.filter_map (fun row -> trpg_json_string_opt_field row "name")
  in
  let current_status =
    trpg_json_string_opt_field state "status" |> Option.value ~default:"lobby"
  in
  let current_phase =
    trpg_json_string_opt_field state "phase"
    |> Option.value ~default:"dm_narration"
  in
  let current_turn = trpg_json_int_field state "turn" ~default:0 in
  Ok
    (`Assoc
      [
        ("ok", `Bool true);
        ("room_id", `String room_id);
        ("rule_module", `String rule_module);
        ("keepers", `List (List.map (fun name -> `String name) keeper_names));
        ("keeper_rows", `List keepers);
        ( "world_presets",
          `List
            (List.map Trpg_preset_store.world_preset_to_yojson
               preset_catalog.world_presets) );
        ( "dm_presets",
          `List
            (List.map Trpg_preset_store.dm_preset_to_yojson
               preset_catalog.dm_presets) );
        ("model_catalog", trpg_available_models_json ());
        ("occupancy", `List (trpg_actor_control_rows state));
        ( "current_room",
          `Assoc
            [
              ("status", `String current_status);
              ("phase", `String current_phase);
              ("turn", `Int current_turn);
            ] );
      ])

let trpg_preflight_row ~id ~label ~ok ?hint detail =
  let status = if ok then "ok" else "fail" in
  let fields =
    [
      ("id", `String id);
      ("label", `String label);
      ("ok", `Bool ok);
      ("status", `String status);
      ("detail", `String detail);
    ]
  in
  match hint with
  | Some value when String.trim value <> "" ->
      `Assoc (fields @ [("hint", `String (String.trim value))])
  | _ -> `Assoc fields

let trpg_lobby_preflight_json ~base_dir ~(config : Room.config) ~room_id ~rule_module
    ~(dm_keeper : string option) ~(player_keepers : string list) ~(models : string list) :
    trpg_api_result =
  let selected_dm = Option.value ~default:"" dm_keeper |> String.trim in
  let players = player_keepers |> List.map String.trim |> List.filter (( <> ) "") in
  let selected_keepers =
    split_csv_nonempty (String.concat "," (selected_dm :: players))
  in
  let keepers = trpg_keeper_summary_rows config in
  let keeper_names =
    keepers
    |> List.filter_map (fun row -> trpg_json_string_opt_field row "name")
  in
  let keeper_lookup : (string, Yojson.Safe.t) Hashtbl.t = Hashtbl.create 32 in
  List.iter
    (fun row ->
      match trpg_json_string_opt_field row "name" with
      | Some name -> Hashtbl.replace keeper_lookup name row
      | None -> ())
    keepers;
  let preset_catalog_result = Trpg_preset_store.load_catalog ~base_dir in
  let preset_ok = Result.is_ok preset_catalog_result in
  let derived =
    match trpg_derive_state_json ~base_dir ~room_id ~rule_module with
    | Ok json -> Some json
    | Error _ -> None
  in
  let state = derived |> Option.map trpg_state_from_derived |> Option.value ~default:(`Assoc []) in
  let room_status =
    trpg_json_string_opt_field state "status" |> Option.value ~default:"lobby"
  in
  let blocking_rev = ref [] in
  let warnings_rev = ref [] in
  let actions_rev = ref [] in
  let add_blocking message =
    let trimmed = String.trim message in
    if trimmed <> "" then blocking_rev := trimmed :: !blocking_rev
  in
  let add_warning message =
    let trimmed = String.trim message in
    if trimmed <> "" then warnings_rev := trimmed :: !warnings_rev
  in
  let add_action message =
    let trimmed = String.trim message in
    if trimmed <> "" then actions_rev := trimmed :: !actions_rev
  in
  let selection_ok =
    selected_dm <> "" && players <> [] && not (List.mem selected_dm players)
  in
  if selected_dm = "" then add_blocking "DM keeper를 선택하세요.";
  if players = [] then add_blocking "플레이어 keeper를 1명 이상 선택하세요.";
  if List.mem selected_dm players then
    add_blocking "DM keeper와 플레이어 keeper를 중복 선택할 수 없습니다.";
  if models = [] then add_blocking "AI 모델을 하나 이상 입력하세요.";
  let missing_keepers =
    selected_keepers
    |> List.filter (fun name -> not (List.mem name keeper_names))
  in
  if missing_keepers <> [] then
    add_blocking
      (Printf.sprintf "keeper pool 없음: %s"
         (String.concat ", " missing_keepers));
  let boot_required =
    selected_keepers
    |> List.filter_map (fun name ->
           match Hashtbl.find_opt keeper_lookup name with
           | None -> None
           | Some row ->
               let agent_exists = trpg_json_bool_field row "agent_exists" ~default:false in
               let agent_status =
                 trpg_json_string_opt_field row "agent_status"
                 |> Option.value ~default:"unknown"
               in
               let is_zombie = trpg_json_bool_field row "is_zombie" ~default:false in
               let keepalive_running =
                 trpg_json_bool_field row "keepalive_running" ~default:false
               in
               if (not agent_exists) || is_zombie then Some (Printf.sprintf "%s: boot 필요" name)
               else if not (List.mem agent_status [ "active"; "busy"; "listening" ]) then
                 Some (Printf.sprintf "%s: status=%s" name agent_status)
               else if not keepalive_running then
                 Some (Printf.sprintf "%s: keepalive off" name)
               else None)
  in
  if boot_required <> [] then
    add_warning
      (Printf.sprintf "선택 keeper 준비 필요: %s"
         (String.concat ", " boot_required));
  let occupied =
    trpg_actor_control_rows state
    |> List.filter_map (fun row ->
           let keeper = trpg_json_string_opt_field row "keeper" |> Option.value ~default:"" in
           let actor_id =
             trpg_json_string_opt_field row "actor_id" |> Option.value ~default:""
           in
           if List.mem keeper selected_keepers then
             Some (Printf.sprintf "%s→%s" keeper actor_id)
           else None)
  in
  if occupied <> [] then (
    add_blocking
      (Printf.sprintf "이미 점유 중: %s" (String.concat ", " occupied));
    add_action "새 room id로 바꾸거나 기존 actor 점유를 해제하세요.");
  if not preset_ok then add_blocking "프리셋 catalog를 불러오지 못했습니다.";
  if not selection_ok then add_action "Lobby에서 DM 1명과 플레이어를 다시 선택하세요.";
  if models = [] then add_action "Lobby에서 AI 모델을 입력하거나 칩에서 선택하세요.";
  if room_status = "ended" then
    add_warning "현재 room은 종료 상태입니다. 새 room id 사용을 권장합니다.";
  let checks =
    [
      trpg_preflight_row ~id:"server" ~label:"서버 연결" ~ok:true "MASC 서버 응답 정상";
      trpg_preflight_row ~id:"presets" ~label:"프리셋" ~ok:preset_ok
        (if preset_ok then "월드/DM 프리셋 로드 가능" else "프리셋 catalog를 불러오지 못했습니다.");
      trpg_preflight_row ~id:"keeper-pool" ~label:"키퍼 풀"
        ~ok:(keeper_names <> [])
        (Printf.sprintf "%d명 사용 가능" (List.length keeper_names));
      trpg_preflight_row ~id:"selection" ~label:"선택 키퍼"
        ~ok:(selected_keepers <> [] && missing_keepers = [] && selection_ok)
        (if selected_keepers = [] then "DM/플레이어 keeper를 선택하세요."
         else
           Printf.sprintf "DM %s · 플레이어 %d명"
             (if selected_dm = "" then "-" else selected_dm)
             (List.length players));
      trpg_preflight_row ~id:"models" ~label:"AI 모델" ~ok:(models <> [])
        (if models = [] then "입력된 모델이 없습니다."
         else Printf.sprintf "%d개 선택" (List.length models));
      trpg_preflight_row ~id:"occupancy" ~label:"점유 충돌" ~ok:(occupied = [])
        (if occupied = [] then "선택 keeper 모두 비점유"
         else Printf.sprintf "충돌 %s" (String.concat ", " occupied));
      trpg_preflight_row ~id:"room" ~label:"룸 상태" ~ok:true
        (Printf.sprintf "room %s · %s" room_id room_status);
    ]
  in
  let dedupe_list items = String.concat "," items |> split_csv_nonempty in
  let blocking = List.rev !blocking_rev |> dedupe_list in
  let warnings = List.rev !warnings_rev |> dedupe_list in
  let recommended_actions = List.rev !actions_rev |> dedupe_list in
  Ok
    (`Assoc
      [
        ("ok", `Bool true);
        ("room_id", `String room_id);
        ("ready", `Bool (blocking = []));
        ("checks", `List checks);
        ("blocking", `List (List.map (fun item -> `String item) blocking));
        ("warnings", `List (List.map (fun item -> `String item) warnings));
        ( "recommended_actions",
          `List (List.map (fun item -> `String item) recommended_actions) );
      ])

let trpg_build_alarm ~level ~code ~message =
  `Assoc
    [
      ("level", `String level);
      ("code", `String code);
      ("message", `String message);
    ]

let trpg_overview_json ~base_dir ~room_id ~rule_module : trpg_api_result =
  let ( let* ) r f = match r with Ok v -> f v | Error _ as e -> e in
  let* derived = trpg_derive_state_json ~base_dir ~room_id ~rule_module in
  let state = trpg_state_from_derived derived in
  let recent_events = trpg_recent_events ~base_dir ~room_id ~limit:12 in
  let party = trpg_party_member_rows state in
  let players =
    party
    |> List.filter (fun row ->
           trpg_json_string_opt_field row "role" |> Option.value ~default:"player"
           |> String.lowercase_ascii = "player")
  in
  let player_count = List.length players in
  let alive_players =
    players |> List.filter (fun row -> trpg_json_bool_field row "alive" ~default:true)
    |> List.length
  in
  let claimed_players =
    players |> List.filter (fun row -> trpg_json_bool_field row "claimed" ~default:false)
    |> List.length
  in
  let unclaimed_players = max 0 (player_count - claimed_players) in
  let active_keepers =
    trpg_state_actor_control_fields state
    |> List.map snd |> String.concat "," |> split_csv_nonempty |> List.length
  in
  let status =
    trpg_json_string_opt_field state "status" |> Option.value ~default:"lobby"
  in
  let phase =
    trpg_json_string_opt_field state "phase"
    |> Option.value ~default:"dm_narration"
  in
  let scenario =
    trpg_json_string_fields [ "current_scenario"; "scenario"; "world" ] state
    |> Option.value ~default:""
  in
  let node =
    trpg_json_string_fields
      [ "current_node"; "node"; "current_area"; "area"; "scene" ]
      state
    |> Option.value ~default:""
  in
  let alarms_rev = ref [] in
  let add_alarm level code message =
    alarms_rev := trpg_build_alarm ~level ~code ~message :: !alarms_rev
  in
  if status = "unavailable" then
    add_alarm "error" "room_unavailable" "TRPG 엔진 상태를 읽지 못했습니다.";
  if status = "ended" then
    add_alarm "warn" "room_ended" "이 room은 종료 상태입니다.";
  if unclaimed_players > 0 && status <> "lobby" then
    add_alarm "warn" "unclaimed_players"
      (Printf.sprintf "player actor %d명이 아직 keeper와 연결되지 않았습니다."
         unclaimed_players);
  List.iter
    (fun ev ->
      match ev.Trpg_engine_event.event_type with
      | Trpg_engine_event.Turn_timeout ->
          add_alarm "warn" "turn_timeout" "최근 턴 timeout 이벤트가 기록되었습니다."
      | Trpg_engine_event.Keeper_unavailable ->
          add_alarm "warn" "keeper_unavailable" "최근 keeper unavailable 이벤트가 기록되었습니다."
      | _ -> ())
    recent_events;
  let next_actions =
    let items = ref [] in
    let add item =
      let trimmed = String.trim item in
      if trimmed <> "" then items := trimmed :: !items
    in
    if status = "lobby" then add "Lobby에서 세션을 시작하세요.";
    if unclaimed_players > 0 then add "Control에서 actor 점유 상태를 확인하세요.";
    if status = "stopped" then add "세션 재개 또는 라운드 실행 여부를 결정하세요.";
    if !items = [] then add "Timeline에서 최근 이벤트를 확인하세요.";
    String.concat "," (List.rev !items) |> split_csv_nonempty
  in
  Ok
    (`Assoc
      [
        ("ok", `Bool true);
        ("room_id", `String room_id);
        ( "summary",
          `Assoc
            [
              ("status", `String status);
              ("turn", `Int (trpg_json_int_field state "turn" ~default:0));
              ("phase", `String phase);
              ("scenario", `String scenario);
              ("node", `String node);
              ("player_count", `Int player_count);
              ("alive_players", `Int alive_players);
              ("claimed_players", `Int claimed_players);
              ("unclaimed_players", `Int unclaimed_players);
              ("active_keepers", `Int active_keepers);
            ] );
        ("alarms", `List (List.rev !alarms_rev));
        ( "next_actions",
          `List (List.map (fun item -> `String item) next_actions) );
        ("party", `List party);
        ( "recent_events",
          `List
            (List.map Trpg_engine_event.to_yojson recent_events) );
      ])

let trpg_control_state_json ~base_dir ~room_id ~rule_module : trpg_api_result =
  let ( let* ) r f = match r with Ok v -> f v | Error _ as e -> e in
  let* derived = trpg_derive_state_json ~base_dir ~room_id ~rule_module in
  let state = trpg_state_from_derived derived in
  let status =
    trpg_json_string_opt_field state "status" |> Option.value ~default:"lobby"
  in
  let phase =
    trpg_json_string_opt_field state "phase"
    |> Option.value ~default:"dm_narration"
  in
  let actor_control = trpg_actor_control_rows state in
  let player_rows =
    trpg_party_member_rows state
    |> List.filter (fun row ->
           trpg_json_string_opt_field row "role" |> Option.value ~default:"player"
           |> String.lowercase_ascii = "player")
  in
  let unclaimed_players =
    player_rows
    |> List.filter (fun row -> not (trpg_json_bool_field row "claimed" ~default:false))
  in
  let recent_interventions =
    trpg_recent_events ~base_dir ~room_id ~limit:20
    |> List.filter (fun ev ->
           match ev.Trpg_engine_event.event_type with
           | Trpg_engine_event.Intervention_submitted
           | Trpg_engine_event.Intervention_applied -> true
           | _ -> false)
  in
  let allowed_actions =
    [
      `Assoc
        [
          ("id", `String "run-round");
          ("label", `String "라운드 실행");
          ("enabled", `Bool (status <> "ended" && status <> "unavailable"));
          ( "reason",
            `String
              (if status = "ended" then "종료된 세션입니다."
               else if status = "unavailable" then "엔진 상태를 읽지 못했습니다."
               else "라운드 실행 가능") );
        ];
      `Assoc
        [
          ("id", `String "pause-session");
          ("label", `String "세션 멈춤");
          ("enabled", `Bool (status = "running"));
          ( "reason",
            `String (if status = "running" then "진행 중 세션입니다." else "running 상태에서만 사용") );
        ];
      `Assoc
        [
          ("id", `String "resume-session");
          ("label", `String "세션 재개");
          ("enabled", `Bool (status = "stopped"));
          ( "reason",
            `String (if status = "stopped" then "중단된 세션입니다." else "stopped 상태에서만 사용") );
        ];
    ]
  in
  let warnings =
    [
      (if unclaimed_players = [] then None
       else
         Some
           (Printf.sprintf "미점유 player actor %d명"
              (List.length unclaimed_players)));
      (if recent_interventions = [] then None
       else Some "최근 intervention 이벤트가 있습니다.");
    ]
    |> List.filter_map (fun item -> item)
  in
  Ok
    (`Assoc
      [
        ("ok", `Bool true);
        ("room_id", `String room_id);
        ( "summary",
          `Assoc
            [
              ("status", `String status);
              ("turn", `Int (trpg_json_int_field state "turn" ~default:0));
              ("phase", `String phase);
              ( "join_window_open",
                `Bool (trpg_join_gate_phase_open state) );
              ("join_gate_min_points", `Int (trpg_join_gate_min_points state));
            ] );
        ("actor_control", `List actor_control);
        ("unclaimed_players", `List unclaimed_players);
        ( "recent_interventions",
          `List
            (List.map Trpg_engine_event.to_yojson recent_interventions) );
        ("allowed_actions", `List allowed_actions);
        ("warnings", `List (List.map (fun item -> `String item) warnings));
      ])

let trpg_event_phase_matches (phase_filter : string option)
    (event : Trpg_engine_event.t) =
  match phase_filter with
  | None -> true
  | Some phase_filter ->
      let normalized = String.lowercase_ascii (String.trim phase_filter) in
      if normalized = "" then true
      else
        match
          trpg_json_string_fields
            [ "phase"; "phase_name"; "phase_after"; "phase_before" ]
            event.payload
        with
        | Some phase ->
            String.equal (String.lowercase_ascii (String.trim phase)) normalized
        | None -> false

let trpg_timeline_json ~base_dir ~room_id ~after_seq ~event_type_filter ~actor_filter
    ~phase_filter ~limit : trpg_api_result =
  match trpg_stream_json ~base_dir ~room_id ~after_seq ~event_type_filter with
  | Error _ as err -> err
  | Ok raw ->
      let normalized = trpg_normalize_events_json ~default_room_id:room_id raw in
      let events =
        match trpg_json_assoc_find "events" normalized with
        | Some (`List entries) ->
            entries
            |> List.filter_map (fun item ->
                   match Trpg_engine_event.of_yojson item with
                   | Ok event -> Some event
                   | Error _ -> None)
            |> List.filter (fun (event : Trpg_engine_event.t) ->
                   let actor_ok =
                     match actor_filter with
                     | Some actor when String.trim actor <> "" -> (
                         match event.actor_id with
                         | Some actor_id -> String.equal actor_id (String.trim actor)
                         | None -> false)
                     | _ -> true
                   in
                   actor_ok && trpg_event_phase_matches phase_filter event)
            |> take limit
        | _ -> []
      in
      let last_seq =
        events
        |> List.rev
        |> List.find_map (fun event -> Some event.Trpg_engine_event.seq)
        |> Option.value ~default:after_seq
      in
      Ok
        (`Assoc
          [
            ("ok", `Bool true);
            ("room_id", `String room_id);
            ( "filters",
              `Assoc
                [
                  ("after_seq", `Int after_seq);
                  ( "event_type",
                    match event_type_filter with
                    | Some value -> `String value
                    | None -> `Null );
                  ( "actor",
                    match actor_filter with
                    | Some value -> `String value
                    | None -> `Null );
                  ( "phase",
                    match phase_filter with
                    | Some value -> `String value
                    | None -> `Null );
                  ("limit", `Int limit);
                ] );
            ("count", `Int (List.length events));
            ("last_seq", `Int last_seq);
            ( "events",
              `List (List.map Trpg_engine_event.to_yojson events) );
          ])

let trpg_keeper_call_with_runtime
    ~(config : Room.config)
    ~(sw : Eio.Switch.t)
    ~(clock : float Eio.Time.clock_ty Eio.Resource.t)
    ~name:keeper_name
    ~message
    ~timeout_sec
  : Tool_trpg.keeper_call_result =
  let keeper_ctx : _ Tool_keeper.context = { config; sw; clock } in
  let forced_models = trpg_keeper_models_for_round () in
  let forced_models_field =
    if forced_models = [] then []
    else [ ("models", `List (List.map (fun m -> `String m) forced_models)) ]
  in
  let inline_goal =
    Printf.sprintf
      "TRPG runtime keeper for %s. You are an in-world keeper of this setting; avoid out-of-world meta narration, stay in character, keep continuity, answer concisely, and never output SKILL/STATE tags, prompt recalls, or raw visible_state_json."
      keeper_name
  in
  let turn_instructions =
    Tool_trpg.trpg_structured_action_system_instructions
  in
  let keeper_args =
    `Assoc
      (forced_models_field
      @ [
          ("name", `String keeper_name);
          ("message", `String message);
          ("goal", `String inline_goal);
          ("require_existing", `Bool true);
          ("timeout_sec", `Float timeout_sec);
          ("turn_instructions", `String turn_instructions);
        ])
  in
  try
    Eio.Time.with_timeout_exn clock timeout_sec (fun () ->
      match
        Tool_keeper.dispatch keeper_ctx ~name:"masc_keeper_msg" ~args:keeper_args
      with
      | None -> `Error "masc_keeper_msg dispatch unavailable"
      | Some (true, body) -> (
          try `Ok (Yojson.Safe.from_string body)
          with Yojson.Json_error e ->
            `Error (Printf.sprintf "keeper returned invalid json: %s" e))
      | Some (false, msg) -> `Error msg)
  with
  | Eio.Time.Timeout -> `Timeout
  | exn -> `Error (Printexc.to_string exn)

type trpg_round_run_guard_state = {
  mutex : Mutex.t;
  inflight_rooms : (string, unit) Hashtbl.t;
  idempotency_cache : (string, Yojson.Safe.t) Hashtbl.t;
  mutable cache_writes : int;
}

let trpg_round_run_guard : trpg_round_run_guard_state =
  {
    mutex = Mutex.create ();
    inflight_rooms = Hashtbl.create 64;
    idempotency_cache = Hashtbl.create 512;
    cache_writes = 0;
  }
let trpg_keeper_probe_with_runtime
    ~(config : Room.config)
    ~(sw : Eio.Switch.t)
    ~(clock : float Eio.Time.clock_ty Eio.Resource.t)
    ~name:keeper_name
  : Tool_trpg.keeper_probe_result =
  let keeper_ctx : _ Tool_keeper.context = { config; sw; clock } in
  let keeper_args =
    `Assoc [ ("name", `String keeper_name); ("fast", `Bool true) ]
  in
  try
    Eio.Time.with_timeout_exn clock 5.0 (fun () ->
      match
        Tool_keeper.dispatch keeper_ctx ~name:"masc_keeper_status"
          ~args:keeper_args
      with
      | None -> `Error "masc_keeper_status dispatch unavailable"
      | Some (true, _body) -> `Ok
      | Some (false, msg) -> `Error msg)
  with
  | Eio.Time.Timeout -> `Error "timeout"
  | exn -> `Error (Printexc.to_string exn)
let trpg_round_run_json
    ~(state : Mcp_server.server_state)
    ~(agent_name : string)
    ~(sw : Eio.Switch.t)
    ~(clock : float Eio.Time.clock_ty Eio.Resource.t)
    ~(idempotency_key : string option)
    ~body_str
  : trpg_api_result =
  let with_round_run_guard_lock f =
    Mutex.lock trpg_round_run_guard.mutex;
    Fun.protect ~finally:(fun () -> Mutex.unlock trpg_round_run_guard.mutex) f
  in
  let trpg_round_run_extract_room_id (args : Yojson.Safe.t) : string =
    let pick key =
      match Yojson.Safe.Util.member key args with
      | `String raw ->
          let trimmed = String.trim raw in
          if trimmed = "" then None else Some trimmed
      | _ -> None
    in
    match pick "room_id" with
    | Some room_id -> room_id
    | None -> (
        match pick "room" with
        | Some room_id -> room_id
        | None -> "default")
  in
  let trpg_round_run_extract_idempotency_key
      ~(header_key : string option)
      (args : Yojson.Safe.t) : string option =
    let normalize = function
      | None -> None
      | Some raw ->
          let trimmed = String.trim raw in
          if trimmed = "" then None else Some trimmed
    in
    match normalize header_key with
    | Some _ as key -> key
    | None -> (
        match Yojson.Safe.Util.member "idempotency_key" args with
        | `String raw -> normalize (Some raw)
        | _ -> None)
  in
  let trpg_round_run_cache_key ~room_id ~idempotency_key =
    room_id ^ "\x1f" ^ idempotency_key
  in
  let trpg_round_run_cache_lookup ~room_id ~idempotency_key =
    let key = trpg_round_run_cache_key ~room_id ~idempotency_key in
    with_round_run_guard_lock (fun () ->
      Hashtbl.find_opt trpg_round_run_guard.idempotency_cache key)
  in
  let trpg_round_run_cache_store ~room_id ~idempotency_key ~result_json =
    let key = trpg_round_run_cache_key ~room_id ~idempotency_key in
    with_round_run_guard_lock (fun () ->
      Hashtbl.replace trpg_round_run_guard.idempotency_cache key result_json;
      trpg_round_run_guard.cache_writes <- trpg_round_run_guard.cache_writes + 1;
      if trpg_round_run_guard.cache_writes >= 1024
         && Hashtbl.length trpg_round_run_guard.idempotency_cache > 4096
      then (
        Hashtbl.reset trpg_round_run_guard.idempotency_cache;
        trpg_round_run_guard.cache_writes <- 0))
  in
  let trpg_round_run_try_acquire ~room_id =
    with_round_run_guard_lock (fun () ->
      if Hashtbl.mem trpg_round_run_guard.inflight_rooms room_id then false
      else (
        Hashtbl.replace trpg_round_run_guard.inflight_rooms room_id ();
        true))
  in
  let trpg_round_run_release ~room_id =
    with_round_run_guard_lock (fun () ->
      Hashtbl.remove trpg_round_run_guard.inflight_rooms room_id)
  in
  try
    let args = Yojson.Safe.from_string body_str in
    let room_id = trpg_round_run_extract_room_id args in
    let idempotency_key =
      trpg_round_run_extract_idempotency_key ~header_key:idempotency_key args
    in
    let run_once () =
      let keeper_call =
        trpg_keeper_call_with_runtime
          ~config:state.Mcp_server.room_config
          ~sw
          ~clock
      in
      let keeper_probe =
        trpg_keeper_probe_with_runtime
          ~config:state.Mcp_server.room_config
          ~sw
          ~clock
      in
      let trpg_ctx : Tool_trpg.context =
        {
          store = Trpg_store.make_sqlite ~base_dir:state.Mcp_server.room_config.base_path;
          agent_name;
          keeper_call = Some keeper_call;
          keeper_probe = Some keeper_probe;
          dm_voice_emit = None;
        }
      in
      match Tool_trpg.dispatch trpg_ctx ~name:"masc_trpg_round_run" ~args with
      | None ->
          Error (`Internal_server_error, "masc_trpg_round_run dispatch unavailable")
      | Some (false, msg) -> Error (`Bad_request, msg)
      | Some (true, body) -> (
          try Ok (Yojson.Safe.from_string body)
          with Yojson.Json_error e ->
            Error (`Internal_server_error, Printf.sprintf "invalid tool json: %s" e))
    in
    let run_with_single_flight () =
      if not (trpg_round_run_try_acquire ~room_id) then
        Error
          ( `Bad_request,
            Printf.sprintf
              "round run already in progress for room_id=%s (single-flight)"
              room_id )
      else
        Fun.protect
          ~finally:(fun () -> trpg_round_run_release ~room_id)
          (fun () ->
            let result = run_once () in
            (match (result, idempotency_key) with
            | Ok json, Some idem_key ->
                trpg_round_run_cache_store
                  ~room_id
                  ~idempotency_key:idem_key
                  ~result_json:json
            | _ -> ());
            result)
    in
    match idempotency_key with
    | Some idem_key -> (
        match trpg_round_run_cache_lookup ~room_id ~idempotency_key:idem_key with
        | Some json -> Ok json
        | None -> run_with_single_flight ())
    | None -> run_with_single_flight ()
  with
  | Yojson.Json_error e -> Error (`Bad_request, Printf.sprintf "invalid json: %s" e)
  | exn -> Error (`Internal_server_error, Printexc.to_string exn)


(* ============================================ *)
(* TRPG SSE Streaming                           *)
(* ============================================ *)

let trpg_sse_poll_interval_s = 2.0

(** TRPG SSE keepalive interval in seconds *)
let trpg_sse_keepalive_s = 30.0

(** Format a single TRPG event as an SSE frame.
    Uses the event's seq as the SSE id, and the event_type string as the SSE event field. *)
let trpg_event_to_sse (ev : Trpg_engine_event.t) : string =
  let data = Yojson.Safe.to_string (Trpg_engine_event.to_yojson ev) in
  let event_type_str = Trpg_engine_event.string_of_event_type ev.event_type in
  Printf.sprintf "id: %d\nevent: %s\ndata: %s\n\n" ev.seq event_type_str data

(** Handle TRPG SSE streaming endpoint (HTTP/1.1).
    Opens a long-lived text/event-stream connection, replays events after Last-Event-ID,
    then polls SQLite every 2s for new events. Sends keepalive comments every 30s. *)
let handle_trpg_sse ~base_dir ~room_id ~event_type_filter request reqd =
  let room_id = String.trim room_id in
  if room_id = "" then begin
    let origin = get_origin request in
    Http_server_eio.Response.json ~status:`Bad_request
      ~extra_headers:(cors_headers origin)
      (Yojson.Safe.to_string (trpg_error_json "room_id is required")) reqd
  end else
    let origin = get_origin request in
    match trpg_parse_event_type_filter event_type_filter with
    | Error (`Bad_request, msg) ->
        Http_server_eio.Response.json ~status:`Bad_request
          ~extra_headers:(cors_headers origin)
          (Yojson.Safe.to_string (trpg_error_json msg)) reqd
    | Ok event_type_opt ->
        let last_event_id =
          match Httpun.Headers.get request.Httpun.Request.headers "last-event-id" with
          | Some id -> (try int_of_string id with Failure _ -> 0)
          | None -> 0
        in
        let headers = Httpun.Headers.of_list ([
          ("content-type", "text/event-stream");
          ("cache-control", "no-cache");
          ("connection", "keep-alive");
        ] @ cors_headers origin) in
        let response = Httpun.Response.create ~headers `OK in
        let writer = Httpun.Reqd.respond_with_streaming reqd response in
        let mutex = Eio.Mutex.create () in
        let closed = ref false in
        let last_seq = ref last_event_id in

        let send_raw_data data =
          if !closed || Httpun.Body.Writer.is_closed writer then begin
            closed := true; false
          end else
            try
              Eio.Mutex.use_rw ~protect:true mutex (fun () ->
                Httpun.Body.Writer.write_string writer data;
                Httpun.Body.Writer.flush writer (fun _ -> ()));
              true
            with _exn ->
              closed := true; false
        in

        (* Send initial comment to confirm connection *)
        ignore (send_raw_data
          (Printf.sprintf ": TRPG SSE stream for room %s (after_seq=%d)\nretry: 3000\n\n"
             room_id !last_seq));

        (* Replay existing events newer than last_seq *)
        (match
           (if !last_seq > 0 then
              Trpg_engine_store_sqlite.read_events_after
                ~base_dir ~room_id ~after_seq:!last_seq
            else
              Trpg_engine_store_sqlite.read_events ~base_dir ~room_id)
         with
         | Ok events ->
             let events = match event_type_opt with
               | None -> events
               | Some et ->
                   List.filter
                     (fun (ev : Trpg_engine_event.t) -> ev.event_type = et)
                     events
             in
             List.iter (fun ev ->
               if not !closed then begin
                 ignore (send_raw_data (trpg_event_to_sse ev));
                 last_seq := max !last_seq ev.Trpg_engine_event.seq
               end) events
         | Error _ -> ());

        (* Start polling fiber for new events + keepalive *)
        (match Eio_context.get_switch_opt (), Eio_context.get_clock_opt () with
         | Some sw, Some clock ->
             Eio.Fiber.fork ~sw (fun () ->
               let is_cancelled = function
                 | Eio.Cancel.Cancelled _ -> true | _ -> false
               in
               let keepalive_counter = ref 0 in
               let polls_per_keepalive =
                 max 1 (int_of_float (trpg_sse_keepalive_s /. trpg_sse_poll_interval_s))
               in
               let rec loop () =
                 if not !closed then begin
                   (try Eio.Time.sleep clock trpg_sse_poll_interval_s
                    with exn -> if is_cancelled exn then raise exn);
                   if not !closed then begin
                     (match
                        Trpg_engine_store_sqlite.read_events_after
                          ~base_dir ~room_id ~after_seq:!last_seq
                      with
                      | Ok events ->
                          let events = match event_type_opt with
                            | None -> events
                            | Some et ->
                                List.filter
                                  (fun (ev : Trpg_engine_event.t) ->
                                    ev.event_type = et)
                                  events
                          in
                          List.iter (fun ev ->
                            if not !closed then begin
                              if not (send_raw_data (trpg_event_to_sse ev)) then
                                closed := true
                              else
                                last_seq := max !last_seq
                                  ev.Trpg_engine_event.seq
                            end) events
                      | Error _ -> ());
                     incr keepalive_counter;
                     if !keepalive_counter >= polls_per_keepalive then begin
                       keepalive_counter := 0;
                       if not !closed then
                         ignore (send_raw_data ": keepalive\n\n")
                     end
                   end;
                   loop ()
                 end
               in
               try loop () with exn ->
                 if not (is_cancelled exn) then
                   Printf.eprintf "[TRPG-SSE] poll loop error for room %s: %s\n%!"
                     room_id (Printexc.to_string exn))
         | _ ->
             ignore (send_raw_data
               "event: error\ndata: {\"error\":\"server not ready\"}\n\n"))
