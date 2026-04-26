(** Behavioral regime deriver — pure. See [.mli] for contract. *)

type regime =
  | Crashing
  | Thrashing
  | Healthy

let all_regimes = [ Crashing; Thrashing; Healthy ]

let string_of_regime = function
  | Crashing -> "crashing"
  | Thrashing -> "thrashing"
  | Healthy -> "healthy"
;;

let regime_of_string = function
  | "crashing" -> Some Crashing
  | "thrashing" -> Some Thrashing
  | "healthy" -> Some Healthy
  | _ -> None
;;

type tool_aggregate =
  { count : int
  ; failures : int
  }

type input =
  { turn_consecutive_failures : int
  ; restart_count : int
  ; last_restart_ts : float
  ; tool_aggregates : (string * tool_aggregate) list
  }

type reason =
  { rule_id : string
  ; evidence : string list
  }

type snapshot =
  { regime : regime
  ; reason : reason
  ; updated_at : float
  }

(* ── Thresholds (exposed for tests) ─────────────────────── *)

let turn_fail_streak_threshold = 3
let recent_restart_window_sec = 300.0
let recent_restart_count_threshold = 2
let tool_failure_count_threshold = 3
let tool_failure_ratio_threshold = 0.7

(* ── Rule predicates ────────────────────────────────────── *)

let crashing_rule ~now (i : input) : reason option =
  if
    i.restart_count >= recent_restart_count_threshold
    && now -. i.last_restart_ts <= recent_restart_window_sec
  then
    Some
      { rule_id = "recent_restart_streak"
      ; evidence =
          [ Printf.sprintf "restart_count=%d" i.restart_count
          ; Printf.sprintf "last_restart_age_sec=%.1f" (now -. i.last_restart_ts)
          ]
      }
  else None
;;

let thrashing_turn_streak_rule (i : input) : reason option =
  if i.turn_consecutive_failures >= turn_fail_streak_threshold
  then
    Some
      { rule_id = "turn_fail_streak"
      ; evidence =
          [ Printf.sprintf "turn_consecutive_failures=%d" i.turn_consecutive_failures ]
      }
  else None
;;

let tool_failure_ratio (agg : tool_aggregate) : float =
  if agg.count <= 0 then 0.0 else float_of_int agg.failures /. float_of_int agg.count
;;

let thrashing_tool_saturation_rule (aggs : (string * tool_aggregate) list) : reason option
  =
  let saturated =
    List.filter
      (fun (_name, a) ->
         a.failures >= tool_failure_count_threshold
         && tool_failure_ratio a >= tool_failure_ratio_threshold)
      aggs
  in
  match saturated with
  | [] -> None
  | (name, agg) :: _ ->
    Some
      { rule_id = "tool_failure_saturation"
      ; evidence =
          [ Printf.sprintf "tool=%s" name
          ; Printf.sprintf "failures=%d/%d" agg.failures agg.count
          ; Printf.sprintf "ratio=%.2f" (tool_failure_ratio agg)
          ]
      }
;;

(* ── Deriver ────────────────────────────────────────────── *)

let healthy_reason = { rule_id = "default_healthy"; evidence = [] }

let derive ~now (i : input) : snapshot =
  let regime, reason =
    match crashing_rule ~now i with
    | Some r -> Crashing, r
    | None ->
      (match thrashing_turn_streak_rule i with
       | Some r -> Thrashing, r
       | None ->
         (match thrashing_tool_saturation_rule i.tool_aggregates with
          | Some r -> Thrashing, r
          | None -> Healthy, healthy_reason))
  in
  { regime; reason; updated_at = now }
;;

(* ── JSON projection ────────────────────────────────────── *)

let snapshot_to_json (s : snapshot) : Yojson.Safe.t =
  `Assoc
    [ "regime", `String (string_of_regime s.regime)
    ; "rule_id", `String s.reason.rule_id
    ; "evidence", `List (List.map (fun e -> `String e) s.reason.evidence)
    ; "updated_at", `Float s.updated_at
    ]
;;
