[@@@warning "-32-33-69"]

include Server_trpg_rest_core

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

