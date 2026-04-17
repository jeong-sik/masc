(** Behavioral regime deriver — pure. See [.mli] for contract. *)

(* Use [Keeper_registry.StringMap] so [registry_entry.tool_usage]
   typechecks directly without coercion. A fresh [Map.Make(String)]
   here would be a distinct nominal type even though structurally
   identical. *)
module StringMap = Keeper_registry.StringMap

type regime =
  | Crashing
  | Thrashing
  | Healthy

let all_regimes = [ Crashing; Thrashing; Healthy ]

let string_of_regime = function
  | Crashing -> "crashing"
  | Thrashing -> "thrashing"
  | Healthy -> "healthy"

let regime_of_string = function
  | "crashing" -> Some Crashing
  | "thrashing" -> Some Thrashing
  | "healthy" -> Some Healthy
  | _ -> None

type reason = {
  rule_id : string;
  evidence : string list;
}

type snapshot = {
  regime : regime;
  reason : reason;
  updated_at : float;
}

(* ── Thresholds (exposed for tests) ─────────────────────── *)

let turn_fail_streak_threshold = 3
let recent_restart_window_sec = 300.0
let recent_restart_count_threshold = 2
let tool_failure_count_threshold = 3
let tool_failure_ratio_threshold = 0.7

(* ── Rule predicates ────────────────────────────────────── *)

(* Crashing: keeper has restarted repeatedly in a recent window. We
   look at [restart_count] together with [last_restart_ts] so a
   long-lived keeper that restarted once at t=0 does not linger in
   Crashing forever. *)
let crashing_rule ~now (e : Keeper_registry.registry_entry) : reason option =
  if e.restart_count >= recent_restart_count_threshold
     && now -. e.last_restart_ts <= recent_restart_window_sec
  then
    Some {
      rule_id = "recent_restart_streak";
      evidence = [
        Printf.sprintf "restart_count=%d" e.restart_count;
        Printf.sprintf "last_restart_age_sec=%.1f" (now -. e.last_restart_ts);
      ];
    }
  else None

(* Thrashing rule A: the runtime's own turn failure counter is at or
   above threshold. Coarser than per-tool-args hashing (the plan's
   original signal) but uses a field [registry_entry] actually carries. *)
let thrashing_turn_streak_rule (e : Keeper_registry.registry_entry) : reason option =
  if e.turn_consecutive_failures >= turn_fail_streak_threshold
  then
    Some {
      rule_id = "turn_fail_streak";
      evidence = [
        Printf.sprintf "turn_consecutive_failures=%d" e.turn_consecutive_failures;
      ];
    }
  else None

(* Thrashing rule B: any single tool has accumulated a failure-dominant
   usage profile. [tool_call_entry] is per-tool aggregate (not per-args),
   so this catches "a keeper keeps calling a tool that keeps failing" —
   the same structural pathology as the plan's "same args ≥3 fails" but
   at lower resolution. *)
let tool_failure_ratio (entry : Keeper_types.tool_call_entry) : float =
  if entry.count <= 0 then 0.0
  else float_of_int entry.failures /. float_of_int entry.count

let thrashing_tool_saturation_rule
    (tool_usage : Keeper_types.tool_call_entry StringMap.t) : reason option =
  let offenders =
    StringMap.fold
      (fun name entry acc ->
         if entry.Keeper_types.failures >= tool_failure_count_threshold
            && tool_failure_ratio entry >= tool_failure_ratio_threshold
         then (name, entry) :: acc
         else acc)
      tool_usage
      []
  in
  match offenders with
  | [] -> None
  | (name, entry) :: _ ->
      Some {
        rule_id = "tool_failure_saturation";
        evidence = [
          Printf.sprintf "tool=%s" name;
          Printf.sprintf "failures=%d/%d" entry.failures entry.count;
          Printf.sprintf "ratio=%.2f" (tool_failure_ratio entry);
        ];
      }

(* ── Deriver ────────────────────────────────────────────── *)

let healthy_reason = {
  rule_id = "default_healthy";
  evidence = [];
}

let derive ~now (entry : Keeper_registry.registry_entry) : snapshot =
  let regime, reason =
    match crashing_rule ~now entry with
    | Some r -> Crashing, r
    | None ->
        match thrashing_turn_streak_rule entry with
        | Some r -> Thrashing, r
        | None ->
            match thrashing_tool_saturation_rule entry.tool_usage with
            | Some r -> Thrashing, r
            | None -> Healthy, healthy_reason
  in
  { regime; reason; updated_at = now }

(* ── JSON projection ────────────────────────────────────── *)

let snapshot_to_json (s : snapshot) : Yojson.Safe.t =
  `Assoc [
    "regime", `String (string_of_regime s.regime);
    "rule_id", `String s.reason.rule_id;
    "evidence", `List (List.map (fun e -> `String e) s.reason.evidence);
    "updated_at", `Float s.updated_at;
  ]
