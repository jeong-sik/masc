(* TEL-OK: pure cross-subsystem read-model projection for dashboard tools; it
   joins registry + recurring stores but owns no telemetry and adds no dashboard
   dependency to the lower keeper libraries. *)

let schema = "masc.dashboard.keeper_background.v1"
let source = "server_keeper_background"

let iso_of_ts_opt = function
  | None -> `Null
  | Some ts -> `String (Masc_domain.iso8601_of_unix_seconds ts)
;;

let float_opt_json = function
  | None -> `Null
  | Some value -> `Float value
;;

(* A zeroed unix timestamp means "never happened" (last_run_ts / started_at are
   initialized to 0.0). Surface that as null rather than epoch 0 so the dashboard
   does not render 1970. *)
let ts_opt_of_positive ts = if ts > 0.0 then Some ts else None

(* Exhaustive over Keeper_recurring.action: a new action variant must fail to
   compile here rather than fall through to an unlabeled kind. *)
let action_kind_to_string : Keeper_recurring.action -> string = function
  | Broadcast _ -> "broadcast"
;;

let recurring_task_json (task : Keeper_recurring.recurring_task) =
  let last_run = ts_opt_of_positive task.last_run_ts in
  (* A concrete next tick exists only once the task has run at least once and is
     still enabled; a paused or never-run task has no honest next time, so emit
     null instead of guessing. *)
  let next_run =
    match last_run, task.enabled with
    | Some last, true -> Some (last +. float_of_int task.interval_sec)
    | (Some _ | None), _ -> None
  in
  `Assoc
    [ "id", `String task.id
    ; "label", `String task.label
    ; "action_kind", `String (action_kind_to_string task.action)
    ; "interval_sec", `Int task.interval_sec
    ; "enabled", `Bool task.enabled
    ; "run_count", `Int task.run_count
    ; "failure_count", `Int task.failure_count
    ; "max_failures", `Int task.max_failures
    ; "last_run_at", float_opt_json last_run
    ; "last_run_at_iso", iso_of_ts_opt last_run
    ; "next_run_at", float_opt_json next_run
    ; "next_run_at_iso", iso_of_ts_opt next_run
    ]
;;

let loop_json (entry : Keeper_registry.registry_entry) =
  let started_at = ts_opt_of_positive entry.started_at in
  let last_restart = ts_opt_of_positive entry.last_restart_ts in
  `Assoc
    [ "phase", `String (Keeper_state_machine.phase_to_string entry.phase)
    ; "started_at", float_opt_json started_at
    ; "started_at_iso", iso_of_ts_opt started_at
    ; "restart_count", `Int entry.restart_count
    ; "last_restart_at", float_opt_json last_restart
    ; "last_restart_at_iso", iso_of_ts_opt last_restart
    ; "dead_since", float_opt_json entry.dead_since_ts
    ; "dead_since_iso", iso_of_ts_opt entry.dead_since_ts
    ]
;;

let keeper_json (entry : Keeper_registry.registry_entry) tasks =
  let sorted =
    List.sort
      (fun (a : Keeper_recurring.recurring_task) (b : Keeper_recurring.recurring_task) ->
         String.compare a.id b.id)
      tasks
  in
  `Assoc
    [ "keeper_name", `String entry.name
    ; "loop", loop_json entry
    ; "recurring", `List (List.map recurring_task_json sorted)
    ; "recurring_count", `Int (List.length sorted)
    ]
;;

let dashboard_json (config : Workspace.config) =
  let base_path = config.Workspace.base_path in
  let entries =
    Keeper_registry.all ~base_path ()
    |> List.sort (fun (a : Keeper_registry.registry_entry) (b : Keeper_registry.registry_entry) ->
      String.compare a.name b.name)
  in
  (* Only keepers with recurring tasks appear: loop liveness on its own already
     lives on the fleet surface, so re-listing every keeper here would duplicate
     it. The novel observable is the recurring autonomous work. *)
  let keeper_rows =
    entries
    |> List.filter_map (fun (entry : Keeper_registry.registry_entry) ->
      match Keeper_recurring.list ~keeper_name:entry.name with
      | [] -> None
      | tasks -> Some (keeper_json entry tasks))
  in
  let recurring_total = List.length (Keeper_recurring.list_all ()) in
  `Assoc
    [ "schema", `String schema
    ; "source", `String source
    ; "generated_at", `String (Masc_domain.now_iso ())
    ; "keeper_count", `Int (List.length entries)
    ; "recurring_keeper_count", `Int (List.length keeper_rows)
    ; "recurring_count", `Int recurring_total
    ; "keepers", `List keeper_rows
    ]
;;
