(** Trpg_types — shared types, config, utilities, world contracts,
    session outcome, canon checks, and stagnation detection. *)

(** Tool_trpg - Strict TRPG action tools for AI agents.

    Exposes:
    - masc_trpg_dice_roll
    - masc_trpg_turn_advance
    - masc_trpg_stream
    - masc_trpg_round_run
    - masc_trpg_preset_list
    - masc_trpg_pool_generate
    - masc_trpg_party_select
    - masc_trpg_session_start
    - masc_trpg_actor_spawn
    - masc_trpg_actor_update
    - masc_trpg_actor_delete
    - masc_trpg_actor_claim
    - masc_trpg_actor_release
    - masc_trpg_intervention_submit
*)

open Yojson.Safe.Util

type result = bool * string

type keeper_call_result = [ `Ok of Yojson.Safe.t | `Timeout | `Error of string ]
type keeper_probe_result = [ `Ok | `Error of string ]
type dm_voice_emit_result = (Yojson.Safe.t, string) Stdlib.result

type context = {
  store : Trpg_store.t;
  agent_name : string;
  keeper_call :
    (name:string -> message:string -> timeout_sec:float -> keeper_call_result)
    option;
  keeper_probe : (name:string -> keeper_probe_result) option;
  dm_voice_emit :
    (agent_id:string ->
     message:string ->
     provider:string option ->
     dm_voice_emit_result)
    option;
}

type trpg_role = [ `Dm | `Player ]

let role_to_string = function `Dm -> "dm" | `Player -> "player"

let normalize_keeper_name (s : string) : string =
  s |> String.trim |> String.lowercase_ascii

let clamp_int low high value =
  if value < low then low
  else if value > high then high
  else value

let trpg_keeper_timeout_sec_default = 0.0
let trpg_keeper_timeout_sec_env = "MASC_TRPG_KEEPER_TIMEOUT_SEC"
let trpg_keeper_call_retries_default = 1
let trpg_keeper_call_retries_env = "MASC_TRPG_KEEPER_CALL_RETRIES"
let trpg_keeper_reprompt_retries_default = 2
let trpg_keeper_reprompt_retries_env = "MASC_TRPG_KEEPER_REPROMPT_RETRIES"
let trpg_strict_unique_player_reply_default = false
let trpg_strict_unique_player_reply_env = "MASC_TRPG_STRICT_UNIQUE_PLAYER_REPLY"

let trpg_keeper_timeout_sec () =
  match Sys.getenv_opt trpg_keeper_timeout_sec_env with
  | Some raw -> (
      match float_of_string_opt (String.trim raw) with
      | Some value when value > 0.0 -> value
      | _ -> trpg_keeper_timeout_sec_default)
  | None -> trpg_keeper_timeout_sec_default

let env_int ~default ~guard env_name =
  match Sys.getenv_opt env_name with
  | Some raw -> (
      match int_of_string_opt (String.trim raw) with
      | Some v when guard v -> v
      | _ -> default)
  | None -> default

let trpg_keeper_call_retries () =
  env_int ~default:trpg_keeper_call_retries_default
    ~guard:(fun v -> v >= 0) trpg_keeper_call_retries_env

let env_bool ~default name =
  match Sys.getenv_opt name with
  | Some raw -> (
      match String.lowercase_ascii (String.trim raw) with
      | "1" | "true" | "yes" | "on" -> true
      | "0" | "false" | "no" | "off" -> false
      | _ -> default)
  | None -> default

let trpg_keeper_reprompt_retries () =
  env_int ~default:trpg_keeper_reprompt_retries_default
    ~guard:(fun v -> v >= 0) trpg_keeper_reprompt_retries_env

let trpg_strict_unique_player_reply () =
  env_bool ~default:trpg_strict_unique_player_reply_default
    trpg_strict_unique_player_reply_env

let resolve_keeper_timeout_sec ~keeper_timeout_override_sec ~timeout_sec
    ~participant_count : float =
  let participant_count = max 1 participant_count in
  let per_actor_budget = timeout_sec /. float_of_int participant_count in
  let base = min timeout_sec per_actor_budget in
  let base =
    match keeper_timeout_override_sec with
    | Some override_sec when override_sec > 0.0 ->
        min timeout_sec (max 0.001 override_sec)
    | _ -> base
  in
  let floor_sec = trpg_keeper_timeout_sec () in
  if floor_sec <= 0.0 then base else min timeout_sec (max floor_sec base)

let unique_nonempty_keepers (keepers : string list) : string list =
  keepers
  |> List.map String.trim
  |> List.filter (fun k -> k <> "")
  |> List.sort_uniq String.compare

let validate_unique_keeper_assignments ~dm_keeper
    ~(player_keepers : (string * string) list) : (unit, string) Stdlib.result =
  let dm_keeper = String.trim dm_keeper in
  if dm_keeper = "" then Error "dm_keeper cannot be empty"
  else
    let seen : (string, string) Hashtbl.t = Hashtbl.create 16 in
    Hashtbl.replace seen (normalize_keeper_name dm_keeper) "dm";
    let rec loop = function
      | [] -> Ok ()
      | (actor_id, keeper_name) :: tl ->
          let actor_id = String.trim actor_id in
          let keeper_name = String.trim keeper_name in
          if actor_id = "" then Error "player actor_id cannot be empty"
          else if keeper_name = "" then
            Error (Printf.sprintf "keeper for actor %s cannot be empty" actor_id)
          else
            let key = normalize_keeper_name keeper_name in
            (match Hashtbl.find_opt seen key with
            | Some previous_owner ->
                Error
                  (Printf.sprintf
                     "keeper assignments must be unique: keeper '%s' is reused by %s and %s"
                     keeper_name previous_owner actor_id)
            | None ->
                Hashtbl.replace seen key actor_id;
                loop tl)
    in
    loop player_keepers

let keeper_preflight ctx ~(keepers : string list) : (unit, string) Stdlib.result =
  match ctx.keeper_probe with
  | None -> Ok ()
  | Some probe ->
      let failures =
        unique_nonempty_keepers keepers
        |> List.filter_map (fun keeper_name ->
               match probe ~name:keeper_name with
               | `Ok -> None
               | `Error raw_reason ->
                   let reason =
                     let trimmed = String.trim raw_reason in
                     if trimmed = "" then "unavailable" else trimmed
                   in
                   Some (Printf.sprintf "%s=%s" keeper_name reason))
      in
      if failures = [] then Ok ()
      else
        Error
          (Printf.sprintf "keeper preflight failed: %s"
             (String.concat "; " failures))

let keeper_busy_mutex = Mutex.create ()
let keeper_busy_counts : (string, int) Hashtbl.t = Hashtbl.create 128

let with_keeper_reservation ~(keepers : string list)
    (f : unit -> ('a, string) Stdlib.result) : ('a, string) Stdlib.result =
  let keeper_keys =
    keepers |> List.map normalize_keeper_name
    |> List.filter (fun k -> k <> "")
    |> List.sort_uniq String.compare
  in
  let reserve () =
    Mutex.lock keeper_busy_mutex;
    Fun.protect
      ~finally:(fun () -> Mutex.unlock keeper_busy_mutex)
      (fun () ->
        let busy =
          List.filter
            (fun key ->
              let cnt = Hashtbl.find_opt keeper_busy_counts key |> Option.value ~default:0 in
              cnt > 0)
            keeper_keys
        in
        if busy <> [] then
          Error
            (Printf.sprintf
               "keeper busy: %s (each spawned keeper can handle only one round at a time)"
               (String.concat ", " busy))
        else (
          List.iter
            (fun key ->
              let cnt = Hashtbl.find_opt keeper_busy_counts key |> Option.value ~default:0 in
              Hashtbl.replace keeper_busy_counts key (cnt + 1))
            keeper_keys;
          Ok ()))
  in
  let release () =
    Mutex.lock keeper_busy_mutex;
    Fun.protect
      ~finally:(fun () -> Mutex.unlock keeper_busy_mutex)
      (fun () ->
        List.iter
          (fun key ->
            let cnt = Hashtbl.find_opt keeper_busy_counts key |> Option.value ~default:0 in
            if cnt <= 1 then Hashtbl.remove keeper_busy_counts key
            else Hashtbl.replace keeper_busy_counts key (cnt - 1))
          keeper_keys)
  in
  match reserve () with
  | Error _ as e -> e
  | Ok () -> Fun.protect ~finally:release f

type pool_member = {
  actor_id : string;
  name : string;
  archetype : string;
  persona : string;
  traits : string list;
  skill_ids : string list;
  keeper_name : string option;
  source_preset_id : string;
}

let pool_member_to_yojson (m : pool_member) : Yojson.Safe.t =
  `Assoc
    [
      ("actor_id", `String m.actor_id);
      ("name", `String m.name);
      ("archetype", `String m.archetype);
      ("persona", `String m.persona);
      ("traits", `List (List.map (fun s -> `String s) m.traits));
      ("skill_ids", `List (List.map (fun s -> `String s) m.skill_ids));
      ( "keeper_name",
        Option.fold ~none:`Null ~some:(fun s -> `String s) m.keeper_name );
      ("source_preset_id", `String m.source_preset_id);
    ]

let schemas = Trpg_schema.schemas

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
      with Failure _ -> Error (Printf.sprintf "%s must be int" key))
  | `Null -> Error (Printf.sprintf "%s is required" key)
  | _ -> Error (Printf.sprintf "%s must be int" key)

let get_optional_int args key =
  match args |> member key with
  | `Int i -> Ok (Some i)
  | `Intlit s -> (
      try Ok (Some (int_of_string s))
      with Failure _ -> Error (Printf.sprintf "%s must be int" key))
  | `Null -> Ok None
  | _ -> Error (Printf.sprintf "%s must be int" key)

let get_optional_float args key ~default =
  match args |> member key with
  | `Float f -> Ok f
  | `Int i -> Ok (float_of_int i)
  | `Intlit s -> (
      try Ok (float_of_string s)
      with Failure _ -> Error (Printf.sprintf "%s must be number" key))
  | `Null -> Ok default
  | _ -> Error (Printf.sprintf "%s must be number" key)

let get_required_assoc args key =
  match args |> member key with
  | `Assoc fields -> Ok fields
  | `Null -> Error (Printf.sprintf "%s is required" key)
  | _ -> Error (Printf.sprintf "%s must be object" key)

let get_required_list args key =
  match args |> member key with
  | `List xs -> Ok xs
  | `Null -> Error (Printf.sprintf "%s is required" key)
  | _ -> Error (Printf.sprintf "%s must be array" key)

let get_optional_bool args key ~default =
  match args |> member key with
  | `Bool b -> Ok b
  | `Null -> Ok default
  | _ -> Error (Printf.sprintf "%s must be boolean" key)

let get_optional_object args key =
  match args |> member key with
  | `Assoc _ as obj -> Ok (Some obj)
  | `Null -> Ok None
  | _ -> Error (Printf.sprintf "%s must be object" key)

let get_string_list_from_json = function
  | `List xs ->
      Ok
        (List.filter_map
           (function
             | `String s ->
                 let s = String.trim s in
                 if s = "" then None else Some s
             | _ -> None)
           xs)
  | _ -> Error "value must be string array"

let get_optional_string_list args key =
  match args |> member key with
  | `Null -> Ok []
  | `List _ as list_json -> get_string_list_from_json list_json
  | _ -> Error (Printf.sprintf "%s must be string array" key)

let get_optional_string_list_option args key =
  match args |> member key with
  | `Null -> Ok None
  | `List _ as list_json ->
      let ( let* ) = Result.bind in
      let* xs = get_string_list_from_json list_json in
      Ok (Some xs)
  | _ -> Error (Printf.sprintf "%s must be string array" key)

let dedupe_keep_order xs =
  let rec loop seen acc = function
    | [] -> List.rev acc
    | x :: tl ->
        if List.mem x seen then loop seen acc tl
        else loop (x :: seen) (x :: acc) tl
  in
  loop [] [] xs

let sanitize_room_id (s : string) =
  let s = String.trim s in
  let b = Bytes.of_string s in
  for i = 0 to Bytes.length b - 1 do
    let c = Bytes.get b i in
    let valid =
      (c >= 'a' && c <= 'z')
      || (c >= 'A' && c <= 'Z')
      || (c >= '0' && c <= '9')
      || c = '.' || c = '_' || c = '-'
    in
    if not valid then Bytes.set b i '-'
  done;
  let out = Bytes.to_string b in
  if out = "" then "session-default" else out

let validate_rule_module = function
  | "" | "dnd5e-lite" -> Ok ()
  | other -> Error (Printf.sprintf "unsupported rule_module: %s" other)

let validate_actor_role = function
  | "player" | "npc" | "dm" -> Ok ()
  | other -> Error (Printf.sprintf "role must be one of: player, npc, dm (got %s)" other)

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

let next_seq ~store ~room_id =
  match store.Trpg_store.read_events ~room_id with
  | Error e -> Error e
  | Ok events ->
      Ok
        (1
        + List.fold_left
            (fun acc (ev : Trpg_engine_event.t) -> max acc ev.seq)
            0 events)

let append_event ~store ~room_id ~event_type ?actor_id ?ts ?seq ~payload () =
  let room_id = String.trim room_id in
  if room_id = "" then Error "room_id is required"
  else
    let seq_result =
      match seq with
      | Some s when s <= 0 -> Error "seq must be positive"
      | Some s -> Ok s
      | None -> next_seq ~store ~room_id
    in
    match seq_result with
    | Error e -> Error e
    | Ok seq ->
        let ts = Option.value ~default:(Types.now_iso ()) ts in
        let event =
          Trpg_engine_event.make
            ~seq ~room_id ~ts ~event_type ?actor_id ~payload ()
        in
        (match store.Trpg_store.append_event ~event with
        | Ok () -> Ok event
        | Error e -> Error e)

let derive_state ~store ~room_id ~rule_module =
  match validate_rule_module rule_module with
  | Error e -> Error e
  | Ok () -> (
      match store.Trpg_store.read_events ~room_id with
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

let state_party_fields state =
  match state |> member "party" with
  | `Assoc fields -> fields
  | _ -> []

let actor_exists_in_state state actor_id =
  state_party_fields state |> List.mem_assoc actor_id

let sanitize_actor_id_seed (s : string) =
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

let next_available_actor_id state base_actor_id =
  if not (actor_exists_in_state state base_actor_id) then base_actor_id
  else
    let rec loop n =
      let candidate = Printf.sprintf "%s-%d" base_actor_id n in
      if actor_exists_in_state state candidate then loop (n + 1) else candidate
    in
    loop 2

let actor_alive_in_state state actor_id =
  match state_party_fields state |> List.assoc_opt actor_id with
  | Some actor_json ->
      actor_json |> member "alive" |> to_bool_option |> Option.value ~default:true
  | None -> false

let state_actor_control_fields state =
  match state |> member "actor_control" with
  | `Assoc fields ->
      fields
      |> List.filter_map (function
           | actor_id, `String keeper_name ->
               let actor_id = String.trim actor_id in
               let keeper_name = String.trim keeper_name in
               if actor_id = "" || keeper_name = "" then None
               else Some (actor_id, keeper_name)
           | _ -> None)
  | _ -> []

let owner_for_actor state actor_id =
  state_actor_control_fields state |> List.assoc_opt actor_id

let actor_for_keeper state keeper_name =
  let keeper_key = normalize_keeper_name keeper_name in
  state_actor_control_fields state
  |> List.find_map (fun (actor_id, owner) ->
         if normalize_keeper_name owner = keeper_key then Some actor_id else None)

let read_state_turn derived =
  match state_of_derived derived |> member "turn" with
  | `Int i -> Ok i
  | _ -> Error "state.turn must be int"

let mid_join_min_score_default = 3
let mid_join_min_score_env = "TRPG_MID_JOIN_MIN_SCORE"

let mid_join_min_score () =
  env_int ~default:mid_join_min_score_default
    ~guard:(fun v -> v > 0) mid_join_min_score_env

type join_gate_state = {
  phase_open : bool;
  min_points : int;
  window : string;
}

let join_gate_of_state state =
  let gate = state |> member "join_gate" in
  let phase_open =
    match gate |> member "phase_open" with
    | `Bool v -> v
    | _ -> true
  in
  let min_points =
    match gate |> member "min_points" with
    | `Int v when v > 0 -> v
    | _ -> mid_join_min_score ()
  in
  let window =
    match gate |> member "window" with
    | `String v when String.trim v <> "" -> String.trim v
    | _ -> "round_boundary_only"
  in
  { phase_open; min_points; window }

let actor_role_in_state state actor_id =
  match state_party_fields state |> List.assoc_opt actor_id with
  | Some actor_json -> (
      match actor_json |> member "role" with
      | `String role when String.trim role <> "" ->
          String.lowercase_ascii (String.trim role)
      | _ -> "player")
  | None -> "player"

let contribution_score_in_state state actor_id =
  match state |> member "contribution_ledger" |> member actor_id |> member "score" with
  | `Int v -> v
  | _ -> 0

type keeper_bonus_eval = {
  bonus : int;
  source : string;
  reason : string option;
  warning : string option;
}

let parse_keeper_bonus json =
  let raw =
    match json |> member "bonus" with
    | `Int i -> Some i
    | `Float f -> Some (int_of_float f)
    | _ -> None
  in
  let reason =
    match json |> member "reason" with
    | `String s when String.trim s <> "" -> Some (String.trim s)
    | _ -> None
  in
  match raw with
  | Some v -> Some (clamp_int (-1) 1 v, reason)
  | None -> None

let evaluate_keeper_bonus ctx ~keeper_name ~room_id ~actor_id ~server_score
    ~required_points =
  match ctx.keeper_call with
  | None ->
      {
        bonus = 0;
        source = "deterministic_fallback";
        reason = None;
        warning = Some "keeper runtime unavailable";
      }
  | Some keeper_call -> (
      let message =
        Printf.sprintf
          "You are evaluating a TRPG mid-join request.\n\
           Return strict JSON: {\"bonus\": -1|0|1, \"reason\": \"short\"}.\n\
           room_id=%s actor_id=%s server_score=%d required_points=%d\n\
           Rules: +1 only if strong positive contribution trend; -1 if disruptive risk; else 0."
          room_id actor_id server_score required_points
      in
      match keeper_call ~name:keeper_name ~message ~timeout_sec:(trpg_keeper_timeout_sec ()) with
      | `Ok payload -> (
          match parse_keeper_bonus payload with
          | Some (bonus, reason) ->
              { bonus; source = "keeper_judge"; reason; warning = None }
          | None ->
              {
                bonus = 0;
                source = "deterministic_fallback";
                reason = None;
                warning = Some "keeper returned unparsable bonus";
              })
      | `Timeout ->
          {
            bonus = 0;
            source = "deterministic_fallback";
            reason = None;
            warning = Some "keeper judge timeout";
          }
      | `Error err ->
          {
            bonus = 0;
            source = "deterministic_fallback";
            reason = None;
            warning = Some (Printf.sprintf "keeper judge error: %s" err);
          })

let contribution_actor_id_of_event (event : Trpg_engine_event.t) =
  let payload = event.payload in
  let from_payload =
    match payload |> member "actor_id" with
    | `String v when String.trim v <> "" -> Some (String.trim v)
    | _ -> None
  in
  match from_payload with
  | Some actor_id -> Some actor_id
  | None ->
      Option.bind event.actor_id (fun v ->
          let trimmed = String.trim v in
          if trimmed = "" then None else Some trimmed)

let contribution_add score_tbl reasons_tbl ~actor_id ~delta ~reason =
  let prev = Hashtbl.find_opt score_tbl actor_id |> Option.value ~default:0 in
  let next = clamp_int (-10) 50 (prev + delta) in
  Hashtbl.replace score_tbl actor_id next;
  let reasons = Hashtbl.find_opt reasons_tbl actor_id |> Option.value ~default:[] in
  let next_reasons =
    if String.trim reason = "" then reasons else
      let appended = reasons @ [ reason ] in
      let len = List.length appended in
      if len <= 8 then appended else
        let rec drop n xs =
          if n <= 0 then xs
          else
            match xs with
            | [] -> []
            | _ :: tl -> drop (n - 1) tl
        in
        drop (len - 8) appended
  in
  Hashtbl.replace reasons_tbl actor_id next_reasons

let contribution_snapshot_from_events events =
  let score_tbl = Hashtbl.create 32 in
  let reasons_tbl = Hashtbl.create 32 in
  List.iter
    (fun (event : Trpg_engine_event.t) ->
      let payload = event.payload in
      match event.event_type with
      | Trpg_engine_event.Turn_action_resolved -> (
          match contribution_actor_id_of_event event with
          | Some actor_id ->
              contribution_add score_tbl reasons_tbl ~actor_id ~delta:2
                ~reason:"turn.action.resolved +2"
          | None -> ())
      | Trpg_engine_event.Intervention_applied -> (
          let actor_id =
            match payload |> member "target_actor" with
            | `String v when String.trim v <> "" -> Some (String.trim v)
            | _ -> contribution_actor_id_of_event event
          in
          match actor_id with
          | Some id ->
              contribution_add score_tbl reasons_tbl ~actor_id:id ~delta:1
                ~reason:"intervention.applied +1"
          | None -> ())
      | Trpg_engine_event.Dice_rolled -> (
          match contribution_actor_id_of_event event with
          | Some actor_id ->
              let passed =
                match payload |> member "passed" with
                | `Bool b -> b
                | _ -> false
              in
              let delta = if passed then 1 else -1 in
              let reason =
                if passed then "dice.rolled(pass) +1"
                else "dice.rolled(fail) -1"
              in
              contribution_add score_tbl reasons_tbl ~actor_id ~delta ~reason
          | None -> ())
      | _ -> ())
    events;
  (score_tbl, reasons_tbl)

let contribution_for_actor_from_events events actor_id =
  let score_tbl, reasons_tbl = contribution_snapshot_from_events events in
  let score = Hashtbl.find_opt score_tbl actor_id |> Option.value ~default:0 in
  let reasons = Hashtbl.find_opt reasons_tbl actor_id |> Option.value ~default:[] in
  (score, reasons)

let append_memory_signal_event ~store ~room_id ~event_tier ~importance_score
    ~summary_ko ~summary_en ~entity_refs =
  let payload =
    `Assoc
      [
        ("event_tier", `String event_tier);
        ("importance_score", `Int (clamp_int 0 100 importance_score));
        ("summary_ko", `String summary_ko);
        ("summary_en", `String summary_en);
        ("entity_refs", `Assoc entity_refs);
      ]
  in
  append_event ~store ~room_id
    ~event_type:Trpg_engine_event.Memory_signal
    ~payload ()

let parse_player_keepers args =
  let ( let* ) = Result.bind in
  let* fields = get_required_assoc args "player_keepers" in
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | (actor_id, `String keeper_name) :: tl ->
        let actor_id = String.trim actor_id in
        let keeper_name = String.trim keeper_name in
        if actor_id = "" then Error "player_keepers contains empty actor_id"
        else if keeper_name = "" then
          Error (Printf.sprintf "player_keepers.%s cannot be empty" actor_id)
        else loop ((actor_id, keeper_name) :: acc) tl
    | (actor_id, _) :: _ ->
        Error (Printf.sprintf "player_keepers.%s must be string" actor_id)
  in
  loop [] fields

let starts_with s prefix =
  let ls = String.length s and lp = String.length prefix in
  ls >= lp && String.sub s 0 lp = prefix

let find_substring s sub =
  let ls = String.length s and lp = String.length sub in
  if lp = 0 then Some 0
  else
    let rec loop i =
      if i + lp > ls then None
      else if String.sub s i lp = sub then Some i
      else loop (i + 1)
    in
    loop 0

let contains_substring s sub = Option.is_some (find_substring s sub)

type session_outcome =
  | Victory
  | Defeat
  | Draw

type outcome_source =
  | Outcome_source_flag
  | Outcome_source_dm_signal
  | Outcome_source_all_players_dead
  | Outcome_source_max_turn
  | Outcome_source_stagnation
  | Outcome_source_unknown

let string_of_session_outcome = function
  | Victory -> "victory"
  | Defeat -> "defeat"
  | Draw -> "draw"

let summary_of_session_outcome = function
  | Victory -> "Victory condition met."
  | Defeat -> "Defeat condition met."
  | Draw -> "Draw condition met."

let string_of_outcome_source = function
  | Outcome_source_flag -> "flag"
  | Outcome_source_dm_signal -> "dm_signal"
  | Outcome_source_all_players_dead -> "all_players_dead"
  | Outcome_source_max_turn -> "max_turn"
  | Outcome_source_stagnation -> "stagnation"
  | Outcome_source_unknown -> "unknown"

let outcome_source_of_reason reason =
  let trimmed = String.trim reason in
  if starts_with trimmed "flag:" then Outcome_source_flag
  else if starts_with trimmed "dm_signal:" then Outcome_source_dm_signal
  else if trimmed = "all_players_dead" then Outcome_source_all_players_dead
  else if trimmed = "max_turn_reached" then Outcome_source_max_turn
  else if trimmed = "stagnation" then Outcome_source_stagnation
  else Outcome_source_unknown

let outcome_source_from_payload_opt (payload : Yojson.Safe.t) : string option =
  match payload |> member "outcome_source" with
  | `String raw ->
      let source = String.trim raw in
      if source = "" then None else Some source
  | _ -> None

let outcome_source_from_payload (payload : Yojson.Safe.t) : string =
  match outcome_source_from_payload_opt payload with
  | Some source -> source
  | None ->
      let reason =
        match payload |> member "reason" with
        | `String raw -> raw
        | _ -> ""
      in
      string_of_outcome_source (outcome_source_of_reason reason)

let ensure_outcome_payload_source (payload : Yojson.Safe.t) : Yojson.Safe.t =
  let source = outcome_source_from_payload payload in
  match payload with
  | `Assoc fields ->
      `Assoc
        (("outcome_source", `String source)
        :: List.remove_assoc "outcome_source" fields)
  | _ -> payload

let stagnation_level_from_payload (payload : Yojson.Safe.t) : int =
  match payload |> member "stagnation_level" with
  | `Int n when n > 0 -> n
  | _ -> 0

let default_end_rules_local : Trpg_preset_store.end_rules =
  {
    max_turn = 40;
    defeat_if_all_players_dead = true;
    victory_flags = [ "outcome.victory"; "quest.main.completed"; "ending.victory" ];
    defeat_flags = [ "outcome.defeat"; "party.wiped"; "ending.defeat" ];
    draw_flags = [ "outcome.draw"; "ending.draw" ];
    allow_dm_end_signal = true;
  }

type world_contract = {
  id : string;
  title : string;
  description : string;
  required_flags : string list;
  forbidden_flags : string list;
  required_event_types : string list;
  required_event_types_any_of : string list list;
  banned_terms : string list;
}

type world_contract_catalog = {
  default_contract_id : string option;
  contracts : world_contract list;
}

let default_world_contract_catalog : world_contract_catalog =
  {
    default_contract_id = Some "open-runtime-v1";
    contracts =
      [
        {
          id = "open-runtime-v1";
          title = "Open Runtime Contract";
          description =
            "Baseline canon contract that keeps guardrails lightweight for sandbox runs.";
          required_flags = [];
          forbidden_flags = [];
          required_event_types = [];
          required_event_types_any_of =
            [ [ "scene.transition"; "quest.update"; "flag.set" ] ];
          banned_terms = [];
        };
        {
          id = "grimland-chronicle";
          title = "Grimland Chronicle Canon";
          description =
            "Keeps scarcity/political tone coherent for Grimland sessions.";
          required_flags = [ "scarcity.high"; "trust.public-low" ];
          forbidden_flags = [ "outcome.invalid"; "world.magic_unlimited" ];
          required_event_types = [];
          required_event_types_any_of =
            [
              [ "scene.transition"; "quest.update"; "flag.set" ];
              [ "combat.attack"; "combat.defense"; "dice.rolled" ];
            ];
          banned_terms =
            [ "spaceship"; "laser rifle"; "cyber implant"; "quantum drive" ];
        };
        {
          id = "emberfall-siege";
          title = "Emberfall Siege Canon";
          description =
            "Keeps siege pressure active for Emberfall sessions.";
          required_flags = [ "siege.active"; "morale.volatile" ];
          forbidden_flags = [ "peace.treaty.signed"; "outcome.invalid" ];
          required_event_types = [];
          required_event_types_any_of =
            [
              [ "scene.transition"; "quest.update"; "flag.set" ];
              [ "combat.attack"; "combat.defense"; "dice.rolled" ];
            ];
          banned_terms =
            [ "vacation"; "tourism festival"; "beach party"; "peace parade" ];
        };
      ];
  }

let world_contracts_path ~base_dir =
  Filename.concat base_dir "config/trpg/world_contracts.json"

let parse_world_contract_json (json : Yojson.Safe.t) :
    (world_contract, string) Stdlib.result =
  let ( let* ) = Result.bind in
  let string_field key =
    match json |> member key with
    | `String raw ->
        let value = String.trim raw in
        if value = "" then Error (Printf.sprintf "world contract %s is empty" key)
        else Ok value
    | _ -> Error (Printf.sprintf "world contract %s is required" key)
  in
  let string_list_field key =
    match json |> member key with
    | `List xs ->
        Ok
          (xs
          |> List.filter_map (function
               | `String raw ->
                   let value = String.trim raw in
                   if value = "" then None else Some value
               | _ -> None))
    | `Null -> Ok []
    | _ -> Error (Printf.sprintf "world contract %s must be string array" key)
  in
  let string_matrix_field key =
    match json |> member key with
    | `Null -> Ok []
    | `List rows ->
        let parse_row idx = function
          | `List xs ->
              let values =
                xs
                |> List.filter_map (function
                     | `String raw ->
                         let value = String.trim raw in
                         if value = "" then None else Some value
                     | _ -> None)
              in
              if values = [] then
                Error
                  (Printf.sprintf
                     "world contract %s[%d] must contain at least one string"
                     key idx)
              else Ok values
          | _ ->
              Error
                (Printf.sprintf
                   "world contract %s[%d] must be string array"
                   key idx)
        in
        let rec loop idx acc = function
          | [] -> Ok (List.rev acc)
          | row :: tl ->
              let* parsed = parse_row idx row in
              loop (idx + 1) (parsed :: acc) tl
        in
        loop 0 [] rows
    | _ -> Error (Printf.sprintf "world contract %s must be string[][]" key)
  in
  let* id = string_field "id" in
  let* title = string_field "title" in
  let description =
    match json |> member "description" with
    | `String raw -> String.trim raw
    | _ -> ""
  in
  let* required_flags = string_list_field "required_flags" in
  let* forbidden_flags = string_list_field "forbidden_flags" in
  let* required_event_types = string_list_field "required_event_types" in
  let* required_event_types_any_of =
    string_matrix_field "required_event_types_any_of"
  in
  let* banned_terms = string_list_field "banned_terms" in
  Ok
    {
      id;
      title;
      description;
      required_flags;
      forbidden_flags;
      required_event_types;
      required_event_types_any_of;
      banned_terms;
    }

let parse_world_contract_catalog_json (json : Yojson.Safe.t) :
    (world_contract_catalog, string) Stdlib.result =
  match json with
  | `Null -> Error "world contracts file not found"
  | _ ->
  let ( let* ) = Result.bind in
  let default_contract_id =
    match json |> member "default_contract_id" with
    | `String raw ->
        let value = String.trim raw in
        if value = "" then None else Some value
    | _ -> None
  in
  let* contracts =
    match json |> member "contracts" with
    | `List xs ->
        let rec loop acc = function
          | [] -> Ok (List.rev acc)
          | item :: tl ->
              let* parsed = parse_world_contract_json item in
              loop (parsed :: acc) tl
        in
        loop [] xs
    | _ -> Error "world contracts file must contain contracts[]"
  in
  if contracts = [] then Error "world contracts file has empty contracts[]"
  else Ok { default_contract_id; contracts }

let load_world_contract_catalog ~(store : Trpg_store.t) : world_contract_catalog =
  match store.load_world_contracts () |> parse_world_contract_catalog_json with
  | Ok catalog -> catalog
  | Error _ -> default_world_contract_catalog

let find_world_contract (catalog : world_contract_catalog) ~id =
  catalog.contracts
  |> List.find_opt (fun (contract : world_contract) ->
         String.equal contract.id id)

let resolve_world_contract_for_session ~store ~world_preset_id
    ~world_contract_id_opt :
    (world_contract, string) Stdlib.result =
  let catalog = load_world_contract_catalog ~store in
  let requested_id =
    match world_contract_id_opt with
    | Some raw when String.trim raw <> "" -> Some (String.trim raw)
    | _ -> None
  in
  let default_id =
    match find_world_contract catalog ~id:world_preset_id with
    | Some _ -> Some world_preset_id
    | None -> (
        match catalog.default_contract_id with
        | Some raw when String.trim raw <> "" -> Some (String.trim raw)
        | _ -> (
            match catalog.contracts with
            | (first : world_contract) :: _ -> Some first.id
            | [] -> None))
  in
  let selected_id =
    match requested_id with Some _ -> requested_id | None -> default_id
  in
  match selected_id with
  | None -> Error "no world contract is available"
  | Some id -> (
      match find_world_contract catalog ~id with
      | Some contract -> Ok contract
      | None -> Error (Printf.sprintf "unknown world_contract_id: %s" id))

let world_contract_ref_to_yojson ~(contract : world_contract) ~strict :
    Yojson.Safe.t =
  `Assoc
    [
      ("id", `String contract.id);
      ("title", `String contract.title);
      ("description", `String contract.description);
      ("strict", `Bool strict);
    ]

let string_list_member_or_default json key default =
  match json |> member key with
  | `List xs ->
      let parsed =
        xs
        |> List.filter_map (function
             | `String s ->
                 let trimmed = String.trim s in
                 if trimmed = "" then None else Some trimmed
             | _ -> None)
      in
      if parsed = [] then default else parsed
  | _ -> default

let parse_end_rules_json (json : Yojson.Safe.t) : Trpg_preset_store.end_rules =
  {
    max_turn =
      (match json |> member "max_turn" with
      | `Int n when n > 0 -> n
      | _ -> default_end_rules_local.max_turn);
    defeat_if_all_players_dead =
      (match json |> member "defeat_if_all_players_dead" with
      | `Bool b -> b
      | _ -> default_end_rules_local.defeat_if_all_players_dead);
    victory_flags =
      string_list_member_or_default json "victory_flags"
        default_end_rules_local.victory_flags;
    defeat_flags =
      string_list_member_or_default json "defeat_flags"
        default_end_rules_local.defeat_flags;
    draw_flags =
      string_list_member_or_default json "draw_flags"
        default_end_rules_local.draw_flags;
    allow_dm_end_signal =
      (match json |> member "allow_dm_end_signal" with
      | `Bool b -> b
      | _ -> default_end_rules_local.allow_dm_end_signal);
  }

let extract_end_rules_from_room_created_payload (payload : Yojson.Safe.t) :
    Trpg_preset_store.end_rules option =
  match payload |> member "config" |> member "world" |> member "end_rules" with
  | `Assoc _ as end_rules_json -> Some (parse_end_rules_json end_rules_json)
  | _ -> None

let extract_world_preset_id_from_room_created_payload (payload : Yojson.Safe.t) :
    string option =
  match payload |> member "world_preset_id" with
  | `String s ->
      let trimmed = String.trim s in
      if trimmed = "" then None else Some trimmed
  | _ -> None

let resolve_end_rules_for_room ~store ~(events : Trpg_engine_event.t list) :
    Trpg_preset_store.end_rules =
  match
    events
    |> List.fold_left
         (fun acc (ev : Trpg_engine_event.t) ->
           if ev.event_type = Trpg_engine_event.Room_created then Some ev else acc)
         None
  with
  | None -> default_end_rules_local
  | Some room_created -> (
      match extract_end_rules_from_room_created_payload room_created.payload with
      | Some rules -> rules
      | None -> (
          match
            extract_world_preset_id_from_room_created_payload room_created.payload
          with
          | Some world_preset_id -> (
              match store.Trpg_store.load_catalog () with
              | Ok catalog -> (
                  match
                    Trpg_preset_store.find_world_preset catalog ~id:world_preset_id
                  with
                  | Some preset -> preset.Trpg_preset_store.end_rules
                  | None -> default_end_rules_local)
              | Error _ -> default_end_rules_local)
          | None -> default_end_rules_local))

let story_flags_from_state (state : Yojson.Safe.t) : string list =
  match state |> member "world" |> member "story_flags" with
  | `List xs ->
      xs
      |> List.filter_map (function
           | `String s ->
               let trimmed = String.trim s in
               if trimmed = "" then None else Some trimmed
           | _ -> None)
  | _ -> []

let actor_is_player actor_id actor_json =
  if String.equal (String.trim actor_id) "dm" then false
  else
    let role =
      match actor_json |> member "role" with
      | `String s -> String.lowercase_ascii (String.trim s)
      | _ -> "player"
    in
    role <> "npc" && role <> "dm"

let actor_is_alive actor_json =
  match actor_json |> member "alive" with
  | `Bool b -> b
  | _ -> (
      match actor_json |> member "hp" with
      | `Int hp -> hp > 0
      | _ -> true)

let all_players_dead_in_state (state : Yojson.Safe.t) : bool =
  match state |> member "party" with
  | `Assoc actors ->
      let players = List.filter (fun (actor_id, actor_json) -> actor_is_player actor_id actor_json) actors in
      players <> [] && List.for_all (fun (_, actor_json) -> not (actor_is_alive actor_json)) players
  | _ -> false

let first_matching_flag ~story_flags candidates =
  candidates
  |> List.find_opt (fun candidate ->
         List.exists (fun flag -> String.equal (String.trim flag) (String.trim candidate)) story_flags)

let dm_signal_outcome reply_text =
  let upper = String.uppercase_ascii reply_text in
  if contains_substring upper "[VICTORY]" then Some (Victory, "dm_signal:[VICTORY]")
  else if contains_substring upper "[DEFEAT]" then
    Some (Defeat, "dm_signal:[DEFEAT]")
  else if contains_substring upper "[DRAW]" then Some (Draw, "dm_signal:[DRAW]")
  else if contains_substring upper "[END]" then Some (Draw, "dm_signal:[END]")
  else None

let evaluate_session_outcome ~end_rules ~max_turn_override
    ~(state : Yojson.Safe.t) ~dm_reply :
    (session_outcome * string) option =
  let story_flags = story_flags_from_state state in
  let draw_flag =
    first_matching_flag ~story_flags end_rules.Trpg_preset_store.draw_flags
  in
  let defeat_flag =
    first_matching_flag ~story_flags end_rules.Trpg_preset_store.defeat_flags
  in
  let victory_flag =
    first_matching_flag ~story_flags end_rules.Trpg_preset_store.victory_flags
  in
  let all_players_dead =
    end_rules.Trpg_preset_store.defeat_if_all_players_dead
    && all_players_dead_in_state state
  in
  let effective_max_turn =
    match max_turn_override with
    | Some n when n > 0 -> min end_rules.Trpg_preset_store.max_turn n
    | _ -> end_rules.Trpg_preset_store.max_turn
  in
  let max_turn_reached =
    let turn =
      match state |> member "turn" with
      | `Int n -> n
      | _ -> 0
    in
    turn >= effective_max_turn
  in
  match draw_flag with
  | Some flag -> Some (Draw, "flag:" ^ flag)
  | None -> (
      match defeat_flag with
      | Some flag -> Some (Defeat, "flag:" ^ flag)
      | None -> (
          match victory_flag with
          | Some flag -> Some (Victory, "flag:" ^ flag)
          | None ->
              if all_players_dead then
                Some (Defeat, "all_players_dead")
              else (
                match (end_rules.Trpg_preset_store.allow_dm_end_signal, dm_reply) with
                | true, Some reply -> (
                    match dm_signal_outcome reply with
                    | Some outcome -> Some outcome
                    | None ->
                        if max_turn_reached then Some (Draw, "max_turn_reached")
                        else None)
                | _ ->
                    if max_turn_reached then Some (Draw, "max_turn_reached")
                    else None)))

type canon_check = {
  enabled : bool;
  contract_id : string option;
  strict : bool;
  status : string;
  violations : string list;
  warnings : string list;
  required_flags_missing : string list;
  forbidden_flags_hit : string list;
  required_event_types_missing : string list;
  required_event_types_any_of_missing : string list;
  banned_terms_hit : string list;
}

let canon_check_to_yojson (check : canon_check) : Yojson.Safe.t =
  let strings_json xs = `List (List.map (fun value -> `String value) xs) in
  `Assoc
    [
      ("enabled", `Bool check.enabled);
      ( "contract_id",
        match check.contract_id with
        | Some id -> `String id
        | None -> `Null );
      ("strict", `Bool check.strict);
      ("status", `String check.status);
      ("violations", strings_json check.violations);
      ("warnings", strings_json check.warnings);
      ("required_flags_missing", strings_json check.required_flags_missing);
      ("forbidden_flags_hit", strings_json check.forbidden_flags_hit);
      ( "required_event_types_missing",
        strings_json check.required_event_types_missing );
      ( "required_event_types_any_of_missing",
        strings_json check.required_event_types_any_of_missing );
      ("banned_terms_hit", strings_json check.banned_terms_hit);
    ]

let canon_check_disabled : canon_check =
  {
    enabled = false;
    contract_id = None;
    strict = false;
    status = "disabled";
    violations = [];
    warnings = [];
    required_flags_missing = [];
    forbidden_flags_hit = [];
    required_event_types_missing = [];
    required_event_types_any_of_missing = [];
    banned_terms_hit = [];
  }

let canon_contract_ref_from_state (state : Yojson.Safe.t) :
    (string * bool) option =
  match state |> member "world" with
  | `Assoc world_fields -> (
      match List.assoc_opt "canon_contract" world_fields with
      | Some (`Assoc canon_fields) ->
          let canon_json = `Assoc canon_fields in
          let id_opt =
            match List.assoc_opt "id" canon_fields with
            | Some (`String raw) ->
                let id = String.trim raw in
                if id = "" then None else Some id
            | _ -> None
          in
          (match id_opt with
          | None -> None
          | Some id ->
              let strict =
                canon_json |> member "strict" |> to_bool_option
                |> Option.value ~default:false
              in
              Some (id, strict))
      | _ -> None)
  | _ -> None

let evaluate_canon_check ~store ~state ~events ~dm_reply : canon_check =
  match canon_contract_ref_from_state state with
  | None -> canon_check_disabled
  | Some (contract_id, strict) -> (
      let catalog = load_world_contract_catalog ~store in
      match find_world_contract catalog ~id:contract_id with
      | None ->
          {
            enabled = true;
            contract_id = Some contract_id;
            strict;
            status = "warn";
            violations = [];
            warnings =
              [ Printf.sprintf "contract_not_found:%s" contract_id ];
            required_flags_missing = [];
            forbidden_flags_hit = [];
            required_event_types_missing = [];
            required_event_types_any_of_missing = [];
            banned_terms_hit = [];
          }
      | Some contract ->
          let story_flags = story_flags_from_state state in
          let has_story_flag candidate =
            story_flags
            |> List.exists (fun flag ->
                   String.equal
                     (String.lowercase_ascii (String.trim flag))
                     (String.lowercase_ascii (String.trim candidate)))
          in
          let required_flags_missing =
            contract.required_flags
            |> List.filter (fun flag -> not (has_story_flag flag))
          in
          let forbidden_flags_hit =
            contract.forbidden_flags
            |> List.filter has_story_flag
          in
          let event_types_seen =
            events
            |> List.map (fun (event : Trpg_engine_event.t) ->
                   Trpg_engine_event.string_of_event_type event.event_type)
            |> dedupe_keep_order
          in
          let required_event_types_missing =
            contract.required_event_types
            |> List.filter (fun required ->
                   not (List.mem required event_types_seen))
          in
          let required_event_types_any_of_missing =
            contract.required_event_types_any_of
            |> List.filter_map (fun choices ->
                   let satisfied =
                     choices
                     |> List.exists (fun event_type ->
                            List.mem event_type event_types_seen)
                   in
                   if satisfied then None
                   else Some (String.concat "|" choices))
          in
          let dm_reply_lower =
            dm_reply
            |> Option.value ~default:""
            |> String.lowercase_ascii
          in
          let banned_terms_hit =
            contract.banned_terms
            |> List.filter (fun term ->
                   let token =
                     term |> String.trim |> String.lowercase_ascii
                   in
                   token <> "" && contains_substring dm_reply_lower token)
          in
          let violations =
            []
            |> (fun acc ->
                 acc
                 @ List.map
                     (fun flag ->
                       Printf.sprintf "required_flag_missing:%s" flag)
                     required_flags_missing)
            |> (fun acc ->
                 acc
                 @ List.map
                     (fun flag ->
                       Printf.sprintf "forbidden_flag_present:%s" flag)
                     forbidden_flags_hit)
            |> (fun acc ->
                 acc
                 @ List.map
                     (fun term ->
                       Printf.sprintf "banned_term_detected:%s" term)
                     banned_terms_hit)
          in
          let warnings =
            (List.map
               (fun ev ->
                 Printf.sprintf "required_event_type_missing:%s" ev)
               required_event_types_missing)
            @
            (List.map
               (fun choices ->
                 Printf.sprintf "required_event_type_any_of_missing:%s"
                   choices)
               required_event_types_any_of_missing)
          in
          let status =
            if violations <> [] then if strict then "fail" else "warn"
            else if warnings <> [] then "warn"
            else "pass"
          in
          {
            enabled = true;
            contract_id = Some contract.id;
            strict;
            status;
            violations;
            warnings;
            required_flags_missing;
            forbidden_flags_hit;
            required_event_types_missing;
            required_event_types_any_of_missing;
            banned_terms_hit;
          })

let append_canon_check_observability_events ~store ~room_id ~turn ~phase
    ~(check : canon_check) =
  let ( let* ) = Result.bind in
  if not check.enabled || check.status = "pass" then Ok []
  else
    let severity = if check.status = "fail" then "major" else "minor" in
    let contract_id = check.contract_id |> Option.value ~default:"unknown" in
    let description =
      Printf.sprintf "Canon check %s for contract=%s (violations=%d warnings=%d)"
        check.status contract_id
        (List.length check.violations)
        (List.length check.warnings)
    in
    let payload =
      let strings_json xs = `List (List.map (fun value -> `String value) xs) in
      `Assoc
        [
          ("event_type", `String "canon.check");
          ("description", `String description);
          ("severity", `String severity);
          ("turn", `Int turn);
          ("phase", `String phase);
          ("contract_id", `String contract_id);
          ("strict", `Bool check.strict);
          ("status", `String check.status);
          ("violations", strings_json check.violations);
          ("warnings", strings_json check.warnings);
        ]
    in
    let* world_event =
      append_event ~store ~room_id
        ~event_type:Trpg_engine_event.World_event
        ~actor_id:"dm" ~payload ()
    in
    let importance_score = if check.status = "fail" then 84 else 61 in
    let memory_tier = if check.status = "fail" then "long" else "mid" in
    let* memory_event =
      append_memory_signal_event ~store ~room_id ~event_tier:memory_tier
        ~importance_score
        ~summary_ko:
          (Printf.sprintf "캐논 검사 %s: %s" check.status contract_id)
        ~summary_en:
          (Printf.sprintf "Canon check %s: %s" check.status contract_id)
        ~entity_refs:
          [
            ("source", `String "canon_check");
            ("contract_id", `String contract_id);
            ("status", `String check.status);
            ("strict", `Bool check.strict);
            ("turn", `Int turn);
            ("phase", `String phase);
            ("violation_count", `Int (List.length check.violations));
            ("warning_count", `Int (List.length check.warnings));
          ]
    in
    Ok [ world_event; memory_event ]

let is_meaningful_event_type = function
  | Trpg_engine_event.Flag_set
  | Trpg_engine_event.Combat_attack
  | Trpg_engine_event.Combat_defense
  | Trpg_engine_event.Scene_transition
  | Trpg_engine_event.Quest_update
  | Trpg_engine_event.Hp_changed
  | Trpg_engine_event.Inventory_changed ->
      true
  | _ -> false

let detect_stagnation ~(events : Trpg_engine_event.t list) ~threshold =
  let turn_events =
    events
    |> List.filter (fun (ev : Trpg_engine_event.t) ->
           ev.event_type = Trpg_engine_event.Turn_started)
    |> List.length
  in
  if turn_events < threshold then false
  else
    let recent_events =
      let rev = List.rev events in
      let rec take_until_n_turns n acc = function
        | [] -> acc
        | (ev : Trpg_engine_event.t) :: rest ->
            if n <= 0 then acc
            else
              let n' =
                if ev.event_type = Trpg_engine_event.Turn_started then n - 1
                else n
              in
              take_until_n_turns n' (ev :: acc) rest
      in
      take_until_n_turns threshold [] rev
    in
    not (List.exists (fun (ev : Trpg_engine_event.t) ->
             is_meaningful_event_type ev.event_type) recent_events)

let stagnation_detection_turn_threshold = 5
let stagnation_escalation_threshold = 3

let latest_stagnation_pressure_level ~(events : Trpg_engine_event.t list) : int =
  let latest_meaningful_seq =
    events
    |> List.fold_left
         (fun acc (ev : Trpg_engine_event.t) ->
           if is_meaningful_event_type ev.event_type then max acc ev.seq else acc)
         0
  in
  let latest_pressure_seq, latest_pressure_level =
    events
    |> List.fold_left
         (fun (best_seq, best_level) (ev : Trpg_engine_event.t) ->
           if ev.event_type <> Trpg_engine_event.World_event then
             (best_seq, best_level)
           else
             let event_type =
               match ev.payload |> member "event_type" with
               | `String raw -> String.lowercase_ascii (String.trim raw)
               | _ -> ""
             in
             if event_type <> "stagnation_pressure" then
               (best_seq, best_level)
             else
               let level =
                 match ev.payload |> member "stagnation_level" with
                 | `Int n when n > 0 -> n
                 | _ -> 1
               in
               if ev.seq >= best_seq then (ev.seq, level)
               else (best_seq, best_level))
         (0, 0)
  in
  if latest_pressure_seq = 0 || latest_meaningful_seq > latest_pressure_seq then 0
  else latest_pressure_level

let has_event_type (events : Trpg_engine_event.t list) event_type =
  List.exists
    (fun (ev : Trpg_engine_event.t) -> ev.event_type = event_type)
    events

let is_session_marker_event = function
  | Trpg_engine_event.Room_started
  | Trpg_engine_event.Session_started
  | Trpg_engine_event.Room_created ->
      true
  | _ -> false

let events_since_last_session_marker (events : Trpg_engine_event.t list) :
    Trpg_engine_event.t list =
  let rec collect acc = function
    | [] -> acc
    | (ev : Trpg_engine_event.t) :: tl ->
        let acc' = ev :: acc in
        if is_session_marker_event ev.event_type then acc' else collect acc' tl
  in
  collect [] (List.rev events)

let latest_session_outcome_payload (events : Trpg_engine_event.t list) :
    Yojson.Safe.t option =
  events
  |> List.fold_left
       (fun acc (ev : Trpg_engine_event.t) ->
         if ev.event_type = Trpg_engine_event.Session_outcome then
           Some (ensure_outcome_payload_source ev.payload)
         else acc)
       None

type combat_semantic =
  | Combat_attack_intent
  | Combat_defense_intent

type action_type =
  | Attack
  | Defend
  | Heal
  | Investigate
  | Social
  | Explore
  | Magic
  | UseItem
  | SetFlag
  | SceneTransition
  | QuestUpdate

type memory_tier =
  | Memory_short
  | Memory_mid
  | Memory_long

type structured_memory_hint = {
  requested_tier : memory_tier;
  importance_score : int option;
  reason : string option;
}

type structured_action = {
  sa_type : action_type;
  target_id : string option;
  description : string;
  flag_key : string option;
  scene : string option;
  quest_info : string option;
  memory_hint : structured_memory_hint option;
  raw_payload : Yojson.Safe.t;
}

let first_nonempty_string_field keys (json : Yojson.Safe.t) =
  keys
  |> List.find_map (fun key ->
         match json |> member key with
         | `String s when String.trim s <> "" -> Some (String.trim s)
         | _ -> None)

