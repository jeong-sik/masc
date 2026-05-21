(* Asynchronous health probe for condition-based auto-resume.
   See [.mli] for TLA+ modeling notes.

   RFC-0041 Phase B2: migrated from per-cascade (string) cache keys to
   per-keeper, per-item (string * string) keys. *)

type health_status =
  | Unknown
  | Healthy
  | Unhealthy of string

type runtime_pressure_class =
  | Client_capacity_full
  | Tier_admission_full
  | Provider_capacity
  | Provider_dns_failure
  | Provider_timeout
  | Provider_error
  | Oas_timeout_budget
  | Turn_stale_timeout
  | Keeper_liveness_failure
  | Tool_contract_failure
  | Runtime_failure

let runtime_pressure_class_to_string = function
  | Client_capacity_full -> "client_capacity_full"
  | Tier_admission_full -> "tier_admission_full"
  | Provider_capacity -> "provider_capacity"
  | Provider_dns_failure -> "provider_dns_failure"
  | Provider_timeout -> "provider_timeout"
  | Provider_error -> "provider_error"
  | Oas_timeout_budget -> "oas_timeout_budget"
  | Turn_stale_timeout -> "turn_stale_timeout"
  | Keeper_liveness_failure -> "keeper_liveness_failure"
  | Tool_contract_failure -> "tool_contract_failure"
  | Runtime_failure -> "runtime_failure"
;;

let runtime_pressure_class_of_label label =
  match String.lowercase_ascii (String.trim label) with
  | "client_capacity_full" | "client_capacity" -> Some Client_capacity_full
  | "tier_admission_full" | "tier_admission" -> Some Tier_admission_full
  | "provider_capacity" | "provider_capacity_full" | "capacity_backpressure" ->
    Some Provider_capacity
  | "provider_dns_failure" | "provider_dns" -> Some Provider_dns_failure
  | "provider_timeout" -> Some Provider_timeout
  | "provider_error" | "provider_runtime_error" -> Some Provider_error
  | "oas_timeout_budget" | "oas_timeout_budget_loop" -> Some Oas_timeout_budget
  | "turn_stale_timeout" | "stale_turn_timeout" -> Some Turn_stale_timeout
  | "keeper_liveness_failure" | "heartbeat_failures" | "turn_failures" ->
    Some Keeper_liveness_failure
  | "tool_contract_failure" | "tool_required_unsatisfied" ->
    Some Tool_contract_failure
  | "runtime_failure" | "fiber_unresolved" | "exception" -> Some Runtime_failure
  | _ -> None
;;

let provider_runtime_pressure_class ~code ~detail ~http_status =
  let contains needle =
    String_util.contains_substring_ci code needle
    || String_util.contains_substring_ci detail needle
  in
  let http_is_any statuses =
    match http_status with
    | Some status -> List.mem status statuses
    | None -> false
  in
  if
    contains "client_capacity"
    || contains "client capacity"
    || contains "client_capacity_full"
  then Client_capacity_full
  else if
    contains "tier_admission"
    || contains "inflight_capacity_full"
    || contains "strict_tool_candidates"
    || contains "tier="
  then Tier_admission_full
  else if
    contains "capacity_backpressure"
    || contains "capacity exhausted"
    || contains "capacity_exhausted"
    || contains "rate limit"
    || contains "rate_limited"
    || contains "overloaded"
    || http_is_any [ 429; 529 ]
  then Provider_capacity
  else if
    contains "getaddrinfo"
    || contains "dns"
    || contains "enotfound"
    || contains "nxdomain"
    || contains "nodename nor servname"
  then Provider_dns_failure
  else if
    contains "timeout"
    || contains "timed out"
    || contains "no_first_token"
    || contains "inter_chunk_idle"
    || contains "max_execution_time"
    || contains "wall-clock timeout"
    || http_is_any [ 408; 504; 524 ]
  then Provider_timeout
  else Provider_error
;;

let runtime_pressure_class_of_failure_reason = function
  | Some (Keeper_registry.Oas_timeout_budget_loop _) -> Some Oas_timeout_budget
  | Some (Keeper_registry.Provider_runtime_error { code; detail; http_status; _ }) ->
    Some (provider_runtime_pressure_class ~code ~detail ~http_status)
  | Some (Keeper_registry.Stale_turn_timeout _) -> Some Turn_stale_timeout
  | Some
      ( Keeper_registry.Heartbeat_consecutive_failures _
      | Keeper_registry.Turn_consecutive_failures _ ) ->
    Some Keeper_liveness_failure
  | Some (Keeper_registry.Tool_required_unsatisfied _) -> Some Tool_contract_failure
  | Some
      ( Keeper_registry.Fiber_unresolved
      | Keeper_registry.Exception _
      | Keeper_registry.Stale_termination_storm _
      | Keeper_registry.Stale_fleet_batch _
      | Keeper_registry.Ambiguous_partial_commit _ ) ->
    Some Runtime_failure
  | None -> None
;;

(** Per-keeper, per-item health cache.
    Key: (keeper_name, item_id). Value: (status, timestamp). *)
let health_cache : (string * string, health_status * float) Hashtbl.t = Hashtbl.create 16

let health_cache_mu = Eio.Mutex.create ()

(* ------------------------------------------------------------------ *)
(* Per-item health queries                                            *)
(* ------------------------------------------------------------------ *)

(** [is_item_healthy ~keeper_name ~item_id] returns the cached health
    status for the specific keeper+item pair. *)
let is_item_healthy ~keeper_name ~item_id =
  Eio.Mutex.use_ro health_cache_mu (fun () ->
    match Hashtbl.find_opt health_cache (keeper_name, item_id) with
    | Some (Healthy, _) -> true
    | _ -> false)
;;

(** [set_item_health ~keeper_name ~item_id status] updates the cache
    for a specific keeper+item pair. *)
let set_item_health ~keeper_name ~item_id status =
  Eio.Mutex.use_rw ~protect:true health_cache_mu (fun () ->
    Hashtbl.replace health_cache (keeper_name, item_id) (status, Time_compat.now ()))
;;

(** [record_item_result ~keeper_name ~item_id ~success] updates the
    health state based on turn outcome. Success -> Healthy immediately.
    Failure -> Unhealthy (no Degraded intermediate for now). *)
let record_item_result ~keeper_name ~item_id ~success =
  let status = if success then Healthy else Unhealthy "turn_failure" in
  set_item_health ~keeper_name ~item_id status
;;

let set_cascade_status ~cascade_name status =
  Eio.Mutex.use_rw ~protect:true health_cache_mu (fun () ->
    Hashtbl.replace health_cache (cascade_name, "") (status, Time_compat.now ()))
;;

(** [get_cascade_status ~cascade_name] reads the cascade-level entry
    written by [run_once].  Three-valued:
      - [Healthy]    : last probe saw the cascade at < threshold ratio.
      - [Unhealthy r]: last probe saw the cascade at >= threshold ratio.
      - [Unknown]    : probe never wrote this cascade (e.g. boot before
                       first sweep, or no running keepers in the cascade
                       at the time of the last scan). *)
let get_cascade_status ~cascade_name =
  Eio.Mutex.use_ro health_cache_mu (fun () ->
    match Hashtbl.find_opt health_cache (cascade_name, "") with
    | Some (status, _) -> status
    | None -> Unknown)
;;

(* ------------------------------------------------------------------ *)
(* Cascade health check                                               *)
(* ------------------------------------------------------------------ *)

(** [is_terminal_unhealthy phase] returns true only for phases that
    represent unrecoverable or immediately-actionable failure.
    Dead / Zombie / Crashed are terminal unhealthy states.
    All other phases (including Restarting — a keeper mid-recovery)
    are treated as healthy for cascade ratio purposes.

    Extracted as a named function so tests can exercise the
    exhaustive match directly, and so the compiler catches omissions
    when a new phase variant is added. *)
let is_terminal_unhealthy (phase : Keeper_state_machine.phase) =
  match phase with
  | Dead | Zombie | Crashed -> true
  | Offline | Running | Failing | Overflowed | Compacting
  | HandingOff | Draining | Paused | Stopped | Restarting -> false

(** Threshold semantics: a cascade is healthy iff [failed <= max_failed_allowed]
    where [max_failed_allowed = max 1 (total / 10)]. The single-failure floor
    keeps small cascades (N<10) from tripping on the first transient pause;
    larger cascades retain the original 10% rule.

    The previous formula [ratio < 0.10] meant any cascade with N<10 had a
    de-facto zero tolerance (1/3 = 0.333 ≥ 0.10), so a single auto-paused
    keeper in a 3-member cascade became a permanent admission block in
    [keeper_supervisor.ml]'s auto-resume path. The floor restores the obvious
    invariant ("one keeper down out of N is recoverable") at every N. *)
let max_failed_allowed_for_cascade ~total =
  max 1 (total / 10)
;;

type cascade_scan_acc =
  { total : int
  ; failed : int
  ; failure_reasons : Keeper_registry.failure_reason option list
  }

let empty_cascade_scan_acc =
  { total = 0; failed = 0; failure_reasons = [] }
;;

let dominant_runtime_pressure_class failure_reasons =
  let counts = Hashtbl.create 8 in
  List.iter
    (fun reason ->
       match runtime_pressure_class_of_failure_reason reason with
       | None -> ()
       | Some cls ->
         let label = runtime_pressure_class_to_string cls in
         let n =
           match Hashtbl.find_opt counts label with
           | Some n -> n
           | None -> 0
         in
         Hashtbl.replace counts label (n + 1))
    failure_reasons;
  let ranked =
    counts
    |> Hashtbl.to_seq
    |> List.of_seq
    |> List.sort (fun (label_a, count_a) (label_b, count_b) ->
      match compare count_b count_a with
      | 0 -> String.compare label_a label_b
      | n -> n)
  in
  match ranked with
  | (label, _) :: _ -> Some label
  | [] -> None
;;

let cascade_failure_reason acc =
  match dominant_runtime_pressure_class acc.failure_reasons with
  | Some label -> "failure_ratio:" ^ label
  | None -> "failure_ratio"
;;

let scan_cascade_health ~base_path =
  let entries = Keeper_registry.all ~base_path () in
  let by_cascade = Hashtbl.create 8 in
  List.iter
    (fun (entry : Keeper_registry.registry_entry) ->
       let cascade = Keeper_types.cascade_name_of_meta entry.meta in
       let acc =
         match Hashtbl.find_opt by_cascade cascade with
         | Some acc -> acc
         | None -> empty_cascade_scan_acc
       in
       let failed = is_terminal_unhealthy entry.phase in
       let acc' =
         { total = acc.total + 1
         ; failed = acc.failed + if failed then 1 else 0
         ; failure_reasons =
             (if failed
              then entry.last_failure_reason :: acc.failure_reasons
              else acc.failure_reasons)
         }
       in
       Hashtbl.replace by_cascade cascade acc')
    entries;
  Hashtbl.fold
    (fun cascade acc rows ->
       let healthy =
         if acc.total <= 0 then true
         else acc.failed <= max_failed_allowed_for_cascade ~total:acc.total
       in
       (cascade, healthy, acc) :: rows)
    by_cascade
    []
;;

(** Compute health per cascade from registry entries.
    Returns (cascade_name, is_healthy).

    A keeper is counted as "failed" only when its phase is a terminal
    unhealthy state (Dead, Zombie, or Crashed).  Past restarts
    (restart_count > 0) do NOT count — a restarted keeper that is now
    Running is healthy.  Prior to this fix, restart_count was used as
    the proxy, causing permanent cascade pollution after any single
    restart since restart_count is monotonic and never resets.

    Per-item health is updated via [record_item_result] after each
    turn. *)
let check_cascade_health ~base_path =
  scan_cascade_health ~base_path
  |> List.map (fun (cascade, healthy, _acc) -> cascade, healthy)
;;

(* ------------------------------------------------------------------ *)
(* Background probe fiber                                             *)
(* ------------------------------------------------------------------ *)

let run_once ~base_path =
  let results = scan_cascade_health ~base_path in
  List.iter
    (fun (cascade, healthy, acc) ->
       let status =
         if healthy then Healthy else Unhealthy (cascade_failure_reason acc)
       in
       set_cascade_status ~cascade_name:cascade status)
    results
;;

let rec probe_loop ~base_path ~interval_sec ~clock () =
  (* Cancel-aware: Safe_ops.protect re-raises Eio.Cancel.Cancelled and swallows
     other exceptions so a transient registry I/O failure cannot kill the fiber
     and leave cascade status stale forever. *)
  Safe_ops.protect ~default:() (fun () -> run_once ~base_path);
  Eio.Time.sleep clock interval_sec;
  probe_loop ~base_path ~interval_sec ~clock ()
;;

let start_probe ~sw ~base_path ~interval_sec ~clock =
  if interval_sec <= 0.0
  then ()
  else
    Eio.Fiber.fork ~sw (fun () ->
      Eio.Switch.run (fun _sw -> probe_loop ~base_path ~interval_sec ~clock ()))
;;
