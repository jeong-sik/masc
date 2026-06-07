(* Keeper health helpers.

   RFC-0041 Phase B2: migrated from per-runtime (string) cache keys to
   per-keeper, per-item (string * string) keys. *)

type health_status =
  | Unknown
  | Healthy
  | Unhealthy of string

type runtime_pressure_class =
  | Client_capacity_full
  | Runtime_admission_full
  | Provider_capacity
  | Provider_dns_failure
  | Provider_timeout
  | Provider_error
  | Turn_stale_timeout
  | Keeper_liveness_failure
  | Completion_contract_failure
  | Runtime_failure

let runtime_pressure_class_to_string = function
  | Client_capacity_full -> "client_capacity_full"
  | Runtime_admission_full -> "admission_full"
  | Provider_capacity -> "provider_capacity"
  | Provider_dns_failure -> "provider_dns_failure"
  | Provider_timeout -> "provider_timeout"
  | Provider_error -> "provider_error"
  | Turn_stale_timeout -> "turn_stale_timeout"
  | Keeper_liveness_failure -> "keeper_liveness_failure"
  | Completion_contract_failure -> "completion_contract_failure"
  | Runtime_failure -> "runtime_failure"
;;

let runtime_pressure_class_of_label label =
  match label |> String.trim |> String.lowercase_ascii with
  | "client_capacity_full" | "client_capacity" -> Some Client_capacity_full
  | "admission_full" | "admission_capacity" -> Some Runtime_admission_full
  | "provider_capacity" | "provider_capacity_full" | "capacity_backpressure" ->
    Some Provider_capacity
  | "provider_dns_failure" | "provider_dns" -> Some Provider_dns_failure
  | "provider_timeout" -> Some Provider_timeout
  | "provider_error" | "provider_runtime_error" -> Some Provider_error
  | "turn_stale_timeout" | "stale_turn_timeout" -> Some Turn_stale_timeout
  | "keeper_liveness_failure" | "heartbeat_failures" | "turn_failures" ->
    Some Keeper_liveness_failure
  | "completion_contract_failure" ->
    Some Completion_contract_failure
  | "runtime_failure" | "fiber_unresolved" | "exception" -> Some Runtime_failure
  | _ -> None
;;

let provider_runtime_pressure_class ~code ~detail ~http_status ~runtime_id =
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
    contains "admission_capacity"
    || contains "inflight_capacity_full"
    || Option.is_some runtime_id
    || contains "admission="
  then Runtime_admission_full
  else if
    contains "capacity_backpressure"
    || contains "capacity exhausted"
    || contains "capacity backpressure"
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
  | Some (Keeper_registry.Provider_timeout_loop _) -> Some Provider_timeout
  | Some (Keeper_registry.Provider_runtime_error { code; detail; http_status; runtime_id }) ->
    Some (provider_runtime_pressure_class ~code ~detail ~http_status ~runtime_id)
  | Some (Keeper_registry.Stale_turn_timeout _) -> Some Turn_stale_timeout
  | Some
      ( Keeper_registry.Heartbeat_consecutive_failures _
      | Keeper_registry.Turn_consecutive_failures _ ) ->
    Some Keeper_liveness_failure
  | Some
      ( Keeper_registry.Fiber_unresolved _
      | Keeper_registry.Exception _
      | Keeper_registry.Turn_overflow_pause
      | Keeper_registry.Turn_livelock_pause
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

(* ------------------------------------------------------------------ *)
(* Runtime health check                                               *)
(* ------------------------------------------------------------------ *)

(** [is_terminal_unhealthy phase] returns true only for phases that
    represent unrecoverable or immediately-actionable failure.
    Dead / Zombie / Crashed are terminal unhealthy states.
    All other phases (including Restarting — a keeper mid-recovery)
    are treated as healthy for runtime ratio purposes.

    Extracted as a named function so tests can exercise the
    exhaustive match directly, and so the compiler catches omissions
    when a new phase variant is added. *)
let is_terminal_unhealthy (phase : Keeper_state_machine.phase) =
  match phase with
  | Dead | Zombie | Crashed -> true
  | Offline | Running | Failing | Overflowed | Compacting
  | HandingOff | Draining | Paused | Stopped | Restarting -> false

(** Threshold semantics: a runtime is healthy iff [failed <= max_failed_allowed]
    where [max_failed_allowed = max 1 (total / 10)]. The single-failure floor
    keeps small runtimes (N<10) from tripping on the first transient pause;
    larger runtimes retain the original 10% rule.

    The previous formula [ratio < 0.10] meant any runtime with N<10 had a
    de-facto zero tolerance (1/3 = 0.333 ≥ 0.10), so a single auto-paused
    keeper in a 3-member runtime became a permanent admission block in
    [keeper_supervisor.ml]'s auto-resume path. The floor restores the obvious
    invariant ("one keeper down out of N is recoverable") at every N. *)
let max_failed_allowed_for_runtime ~total =
  max 1 (total / 10)
;;

type runtime_scan_acc =
  { total : int
  ; failed : int
  }

let empty_runtime_scan_acc =
  { total = 0; failed = 0 }
;;

let scan_runtime_health ~base_path =
  let entries = Keeper_registry.all ~base_path () in
  let by_runtime = Hashtbl.create 8 in
  List.iter
    (fun (entry : Keeper_registry.registry_entry) ->
       let runtime_id = Keeper_meta_contract.runtime_id_of_meta entry.meta in
       let acc =
         match Hashtbl.find_opt by_runtime runtime_id with
         | Some acc -> acc
         | None -> empty_runtime_scan_acc
       in
       let failed = is_terminal_unhealthy entry.phase in
       let acc' =
         { total = acc.total + 1
         ; failed = acc.failed + if failed then 1 else 0
         }
       in
       Hashtbl.replace by_runtime runtime_id acc')
    entries;
  Hashtbl.fold
    (fun runtime_id acc rows ->
       let healthy =
         if acc.total <= 0 then true
         else acc.failed <= max_failed_allowed_for_runtime ~total:acc.total
       in
       (runtime_id, healthy, acc) :: rows)
    by_runtime
    []
;;

(** Compute health per runtime from registry entries.
    Returns (runtime_id, is_healthy).

    A keeper is counted as "failed" only when its phase is a terminal
    unhealthy state (Dead, Zombie, or Crashed).  Past restarts
    (restart_count > 0) do NOT count — a restarted keeper that is now
    Running is healthy.  Prior to this fix, restart_count was used as
    the proxy, causing permanent runtime pollution after any single
    restart since restart_count is monotonic and never resets.

    Per-item health is updated via [record_item_result] after each
    turn. *)
let check_runtime_health ~base_path =
  scan_runtime_health ~base_path
  |> List.map (fun (runtime_id, healthy, _acc) -> runtime_id, healthy)
;;
