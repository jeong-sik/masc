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


include Trpg_types_canon

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
