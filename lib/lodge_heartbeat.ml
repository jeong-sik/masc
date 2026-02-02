(** Lodge Heartbeat - 세계의 맥박

    The Lodge의 심장박동. 1분마다 세계가 "뛴다".

    기능:
    - 에이전트 깨우기 (매칭 70% + 발견 20% + 랜덤 10%)
    - 인카운터 롤링
    - 시간대 선호 반영

    @since 2.14.0
*)

[@@@warning "-32-69"]

(** {1 Configuration} *)

type config = {
  interval_s: float;           (** Heartbeat interval (default: 60.0 = 1분) *)
  enabled: bool;               (** Enable heartbeat (default: false) *)
  matching_weight: float;      (** Weight for similarity matching (default: 0.7) *)
  discovery_weight: float;     (** Weight for interesting discoveries (default: 0.2) *)
  random_weight: float;        (** Weight for pure random (default: 0.1) *)
  wake_threshold: float;       (** Minimum score to wake agent (default: 0.5) *)
}

let default_config = {
  interval_s = 60.0;
  enabled = false;  (* Opt-in *)
  matching_weight = 0.7;
  discovery_weight = 0.2;
  random_weight = 0.1;
  wake_threshold = 0.5;
}

(** Load config from environment *)
let load_config () =
  let get_float name default =
    match Sys.getenv_opt name with
    | Some v -> (try Float.of_string v with _ -> default)
    | None -> default
  in
  let get_bool name default =
    match Sys.getenv_opt name with
    | Some "1" | Some "true" | Some "yes" -> true
    | Some "0" | Some "false" | Some "no" -> false
    | _ -> default
  in
  {
    interval_s = get_float "LODGE_INTERVAL" 60.0;
    enabled = get_bool "LODGE_ENABLED" false;
    matching_weight = get_float "LODGE_MATCHING_WEIGHT" 0.7;
    discovery_weight = get_float "LODGE_DISCOVERY_WEIGHT" 0.2;
    random_weight = get_float "LODGE_RANDOM_WEIGHT" 0.1;
    wake_threshold = get_float "LODGE_WAKE_THRESHOLD" 0.5;
  }

(** {1 Types} *)

type agent = {
  name: string;
  preferred_hours: int list;
  peak_hour: int option;
  traits: string list;
  activity_level: float;
}

type wake_reason =
  | Matching of { score: float; topic: string }
  | Discovery of { connection: string }
  | Random

type heartbeat_result = {
  timestamp: float;
  current_hour: int;
  agents_checked: int;
  agents_woken: (string * wake_reason) list;
  encounter_rolled: string option;
}

(** {1 Time Utilities} *)

(** Get current hour in KST (UTC+9) *)
let current_hour_kst () =
  let now = Unix.gettimeofday () in
  let tm = Unix.gmtime now in
  (tm.Unix.tm_hour + 9) mod 24

(** Calculate time-based activity modifier *)
let time_modifier agent =
  let hour = current_hour_kst () in
  if List.mem hour agent.preferred_hours then
    match agent.peak_hour with
    | Some peak when peak = hour -> 2.0
    | Some _ -> 1.5
    | None -> 1.5
  else 0.5

(** {1 Agent Loading} *)

(** Default Lodge agents with time preferences *)
let default_agents = [
  { name = "dreamer";
    preferred_hours = [0; 1; 2; 3; 4; 5; 22; 23];
    peak_hour = Some 3;
    traits = ["creative"; "dreamy"];
    activity_level = 0.6 };
  { name = "skeptic";
    preferred_hours = List.init 24 Fun.id;  (* Always active *)
    peak_hour = None;
    traits = ["skeptical"; "analytical"];
    activity_level = 0.7 };
  { name = "historian";
    preferred_hours = [6; 7; 8; 9; 10];
    peak_hour = Some 8;
    traits = ["archival"; "curious"];
    activity_level = 0.5 };
  { name = "pragmatist";
    preferred_hours = [9; 10; 11; 12; 13; 14; 15; 16; 17; 18];
    peak_hour = Some 14;
    traits = ["pragmatic"; "analytical"];
    activity_level = 0.8 };
  { name = "connector";
    preferred_hours = [18; 19; 20; 21; 22; 23];
    peak_hour = Some 20;
    traits = ["connective"; "curious"];
    activity_level = 0.7 };
]

(** {1 Wake Logic} *)

(** Calculate matching score (placeholder - integrate with Qdrant later) *)
let matching_score _agent _recent_posts =
  (* TODO: Implement semantic similarity with Qdrant *)
  Random.float 1.0

(** Check for interesting discoveries (placeholder - integrate with Neo4j) *)
let discovery_score _agent =
  (* TODO: Query Neo4j for unexpected connections *)
  if Random.float 1.0 < 0.2 then Some "unexpected pattern" else None

(** Determine if agent should wake *)
let should_wake config agent recent_posts =
  let time_mod = time_modifier agent in
  let base_score =
    (config.matching_weight *. matching_score agent recent_posts) +.
    (config.random_weight *. Random.float 1.0)
  in
  let final_score = base_score *. time_mod *. agent.activity_level in

  (* Check discovery separately *)
  let discovery = discovery_score agent in

  if final_score >= config.wake_threshold then
    Some (Matching { score = final_score; topic = "recent discussion" })
  else match discovery with
    | Some conn -> Some (Discovery { connection = conn })
    | None ->
        if Random.float 1.0 < 0.1 *. time_mod then
          Some Random
        else None

(** {1 Heartbeat Execution} *)

(** Single heartbeat tick *)
let tick ~config ~recent_posts =
  let timestamp = Unix.gettimeofday () in
  let current_hour = current_hour_kst () in

  let woken = default_agents |> List.filter_map (fun agent ->
    match should_wake config agent recent_posts with
    | Some reason -> Some (agent.name, reason)
    | None -> None
  ) in

  (* Roll for encounter *)
  let encounter =
    if Random.int 100 < 10 then  (* 10% chance per tick *)
      Some "MemoryDive"  (* TODO: Proper encounter system *)
    else None
  in

  {
    timestamp;
    current_hour;
    agents_checked = List.length default_agents;
    agents_woken = woken;
    encounter_rolled = encounter;
  }

(** {1 Daemon Loop} *)

(** Start heartbeat daemon fiber *)
let start ~sw ~clock room_config =
  Printf.printf "+Lodge Heartbeat: initializing...\n%!";
  let config = load_config () in
  Printf.printf "+Lodge Heartbeat: enabled=%b\n%!" config.enabled;

  if not config.enabled then begin
    Printf.printf "+💤 Lodge Heartbeat: disabled (set LODGE_ENABLED=1 to enable)\n%!";
    ()
  end else begin
    Eio.traceln "🫀 Lodge Heartbeat: starting (interval=%.0fs)" config.interval_s;

    Eio.Fiber.fork ~sw (fun () ->
      (* Initial delay *)
      Eio.Time.sleep clock 5.0;

      while true do
        let result = tick ~config ~recent_posts:[] in

        (* Log result *)
        Eio.traceln "🫀 [%02d:00 KST] checked=%d woken=%d encounter=%s"
          result.current_hour
          result.agents_checked
          (List.length result.agents_woken)
          (Option.value result.encounter_rolled ~default:"none");

        (* TODO: Actually trigger agent actions via Room/Board *)
        List.iter (fun (name, reason) ->
          let reason_str = match reason with
            | Matching { score; topic } ->
                Printf.sprintf "matching(%.2f, %s)" score topic
            | Discovery { connection } ->
                Printf.sprintf "discovery(%s)" connection
            | Random -> "random"
          in
          Eio.traceln "   🔔 Wake %s: %s" name reason_str;

          (* TODO: Post to board via Room_utils or MCP tool *)
          ignore room_config;  (* Suppress unused warning for now *)
          ()
        ) result.agents_woken;

        Eio.Time.sleep clock config.interval_s
      done
    )
  end

(** {1 Manual Trigger (for MCP tool)} *)

let trigger_heartbeat room_config =
  let config = load_config () in
  let result = tick ~config ~recent_posts:[] in

  (* Log wake events (TODO: Broadcast via proper channel) *)
  List.iter (fun (name, _reason) ->
    Eio.traceln "🔔 %s woke up (manual trigger)" name
  ) result.agents_woken;

  ignore room_config;  (* Suppress unused warning for now *)
  result
