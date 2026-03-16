(** Lodge Atmosphere — dynamic mood computation for agents.

    Computes an agent's current mood from multiple signals:
    - Recent reaction history (positive/negative ratio)
    - Board activity level (post count in last hour)
    - Time of day (KST-based energy curve)
    - Random jitter (prevents lockstep behavior)

    Output: [Lodge_daemon.mood], consumed by [Lodge_personality.compute_temperature].

    @since 3.0.0 — Rewritten from static float→string mapping. *)

(** {1 Legacy API — backward compatibility} *)

let parse_float_opt s =
  try Some (float_of_string s) with Failure _ -> None

let get_value () =
  match Sys.getenv_opt "MASC_LODGE_ATMOSPHERE" with
  | Some v -> (match parse_float_opt v with Some f -> f | None -> 0.5)
  | None -> 0.5

let get_description () =
  let v = get_value () in
  if v >= 0.8 then "energetic"
  else if v >= 0.6 then "positive"
  else if v >= 0.4 then "neutral"
  else if v >= 0.2 then "low"
  else "quiet"

(** {1 Dynamic mood computation} *)

(** Time-of-day energy factor (KST).
    Peak energy 10-14 KST, low energy 2-6 KST. *)
let time_energy_factor () =
  let now = Unix.gettimeofday () in
  (* KST = UTC + 9 *)
  let kst_hour =
    let tm = Unix.gmtime now in
    (tm.Unix.tm_hour + 9) mod 24
  in
  if kst_hour >= 10 && kst_hour < 14 then 0.8    (* peak *)
  else if kst_hour >= 14 && kst_hour < 20 then 0.6 (* afternoon *)
  else if kst_hour >= 7 && kst_hour < 10 then 0.5  (* morning ramp *)
  else if kst_hour >= 20 && kst_hour < 23 then 0.4 (* evening wind-down *)
  else 0.2                                          (* night *)

(** Random jitter in [-0.1, +0.1]. *)
let jitter () =
  Random.float 0.2 -. 0.1

(** Compute mood from reaction ratio, activity, time, and randomness.

    [positive_ratio]: fraction of positive reactions (0.0-1.0).
    [activity_level]: recent board activity (0.0 = dead, 1.0 = very active).

    The function maps a combined score to a mood variant:
    - >= 0.75: Excited
    - >= 0.55: Curious
    - >= 0.40: Neutral
    - >= 0.25: Satisfied
    - < 0.25: Skeptical *)
let compute_mood ~positive_ratio ~activity_level =
  let time_factor = time_energy_factor () in
  let noise = jitter () in
  (* Weighted combination: reactions 40%, activity 30%, time 20%, noise 10% *)
  let score =
    positive_ratio *. 0.4
    +. activity_level *. 0.3
    +. time_factor *. 0.2
    +. (0.5 +. noise) *. 0.1
  in
  let clamped = Float.max 0.0 (Float.min 1.0 score) in
  if clamped >= 0.75 then Lodge_daemon.Excited
  else if clamped >= 0.55 then Lodge_daemon.Curious
  else if clamped >= 0.40 then Lodge_daemon.Neutral
  else if clamped >= 0.25 then Lodge_daemon.Satisfied
  else Lodge_daemon.Skeptical

(** Compute mood with defaults when signals are unavailable.
    Falls back to time-of-day + jitter only. *)
let compute_mood_default () =
  compute_mood ~positive_ratio:0.5 ~activity_level:0.5
