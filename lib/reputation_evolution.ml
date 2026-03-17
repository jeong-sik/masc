(** Reputation Evolution — Temporal reputation with trend analysis.

    Extends Agent_reputation's snapshot model with:
    - Time-series history (JSONL per agent)
    - Exponential decay (0.95/day)
    - Trend detection (improving / stable / declining)
    - Trust score integration with Hebbian synapses

    Storage: .masc/reputation/{agent}/history.jsonl

    @since 2.90.0 *)

open Printf

(** A single reputation snapshot in time. *)
type reputation_snapshot = {
  timestamp : float;
  overall_score : float;
  tasks_completed : int;
  completion_rate : float;
  response_rate : float;
  board_posts : int;
}

(** Trend direction derived from comparing recent vs historical scores. *)
type trend = Improving | Stable | Declining

let string_of_trend = function
  | Improving -> "improving"
  | Stable -> "stable"
  | Declining -> "declining"

(** Reputation with temporal context. *)
type temporal_reputation = {
  agent_name : string;
  current_score : float;
  trend : trend;
  score_7d : float;       (** Average score over last 7 days *)
  score_30d : float;      (** Average score over last 30 days *)
  history_count : int;    (** Number of snapshots in history *)
}

(* ================================================================ *)
(* Paths                                                            *)
(* ================================================================ *)

let reputation_dir ~agent_name =
  let me_root = Env_config.me_root () in
  sprintf "%s/.masc/reputation/%s" me_root agent_name

let history_path ~agent_name =
  sprintf "%s/history.jsonl" (reputation_dir ~agent_name)

let ensure_dir path =
  Fs_compat.mkdir_p path

(* ================================================================ *)
(* JSON Serialization                                               *)
(* ================================================================ *)

let snapshot_to_json (s : reputation_snapshot) : Yojson.Safe.t =
  `Assoc [
    ("timestamp", `Float s.timestamp);
    ("overall_score", `Float s.overall_score);
    ("tasks_completed", `Int s.tasks_completed);
    ("completion_rate", `Float s.completion_rate);
    ("response_rate", `Float s.response_rate);
    ("board_posts", `Int s.board_posts);
  ]

let snapshot_of_json (json : Yojson.Safe.t) : reputation_snapshot option =
  try
    let open Yojson.Safe.Util in
    Some {
      timestamp = json |> member "timestamp" |> to_float;
      overall_score = json |> member "overall_score" |> to_float;
      tasks_completed =
        (try json |> member "tasks_completed" |> to_int with Type_error _ -> 0);
      completion_rate =
        (try json |> member "completion_rate" |> to_float with Type_error _ -> 0.0);
      response_rate =
        (try json |> member "response_rate" |> to_float with Type_error _ -> 0.0);
      board_posts =
        (try json |> member "board_posts" |> to_int with Type_error _ -> 0);
    }
  with
  | Yojson.Safe.Util.Type_error _ -> None
  | exn ->
      Log.Reputation.warn "snapshot_of_json unexpected: %s" (Printexc.to_string exn);
      None

(* ================================================================ *)
(* File I/O                                                         *)
(* ================================================================ *)

let append_snapshot ~agent_name (s : reputation_snapshot) =
  let dir = reputation_dir ~agent_name in
  ensure_dir dir;
  let path = history_path ~agent_name in
  Fs_compat.append_jsonl path (snapshot_to_json s)

let load_history ~agent_name : reputation_snapshot list =
  let path = history_path ~agent_name in
  Fs_compat.load_jsonl path
  |> List.filter_map snapshot_of_json

(* ================================================================ *)
(* Core Logic                                                       *)
(* ================================================================ *)

(** Exponential decay factor: 0.95 per day. *)
let decay_rate = 0.95

(** Apply decay to a score based on age in days. *)
let decay_score ~score ~age_days =
  score *. (decay_rate ** age_days)

(** Record a new reputation snapshot from Agent_reputation data. *)
let record_snapshot ~agent_name (rep : Agent_reputation.agent_reputation) =
  let snap = {
    timestamp = Time_compat.now ();
    overall_score = rep.overall_score;
    tasks_completed = rep.tasks_completed;
    completion_rate = rep.completion_rate;
    response_rate = rep.response_rate;
    board_posts = rep.board_posts;
  } in
  append_snapshot ~agent_name snap;
  snap

(** Compute average score over a time window (with decay). *)
let windowed_score ~agent_name ~days : float =
  let now = Time_compat.now () in
  let cutoff = now -. (days *. 86400.0) in
  let history = load_history ~agent_name in
  let in_window = List.filter (fun s -> s.timestamp >= cutoff) history in
  if List.length in_window = 0 then 0.0
  else begin
    let sum = List.fold_left (fun acc s ->
      let age_days = (now -. s.timestamp) /. 86400.0 in
      acc +. decay_score ~score:s.overall_score ~age_days
    ) 0.0 in_window in
    sum /. Float.of_int (List.length in_window)
  end

(** Detect trend by comparing 7-day vs 30-day average. *)
let detect_trend ~score_7d ~score_30d : trend =
  let delta = score_7d -. score_30d in
  if delta > 0.05 then Improving
  else if delta < -0.05 then Declining
  else Stable

(** Get full temporal reputation for an agent. *)
let get_temporal_reputation ~agent_name : temporal_reputation =
  let score_7d = windowed_score ~agent_name ~days:7.0 in
  let score_30d = windowed_score ~agent_name ~days:30.0 in
  let trend = detect_trend ~score_7d ~score_30d in
  let current = if score_7d > 0.0 then score_7d else score_30d in
  let history = load_history ~agent_name in
  {
    agent_name;
    current_score = current;
    trend;
    score_7d;
    score_30d;
    history_count = List.length history;
  }

(** {1 Trust Integration with Hebbian Synapses}

    Trust(A,B) = synapse_weight(A,B) × reputation(B)
    This combines collaboration history with individual reputation. *)

let compute_trust ~agent_a:_ ~agent_b ~(synapse_weight : float) : float =
  let rep_b = get_temporal_reputation ~agent_name:agent_b in
  synapse_weight *. rep_b.current_score

(** {1 Reputation-Weighted Voting}

    Reputation-based vote weight: bounded [0.5, 1.5].
    Prevents complete disenfranchisement while rewarding reliability. *)

let vote_weight ~agent_name : float =
  let rep = get_temporal_reputation ~agent_name in
  let raw_weight =
    if rep.current_score >= 0.8 then 1.2
    else if rep.current_score >= 0.6 then 1.0
    else if rep.current_score >= 0.4 then 0.8
    else 0.7
  in
  (* Clamp to [0.5, 1.5] *)
  max 0.5 (min 1.5 raw_weight)

(** Serialize temporal reputation to JSON. *)
let to_json (tr : temporal_reputation) : Yojson.Safe.t =
  `Assoc [
    ("agent_name", `String tr.agent_name);
    ("current_score", `Float tr.current_score);
    ("trend", `String (string_of_trend tr.trend));
    ("score_7d", `Float tr.score_7d);
    ("score_30d", `Float tr.score_30d);
    ("history_count", `Int tr.history_count);
  ]
