(* Root-switch-owned maintenance. Scheduling is isolated across Keepers. What
   a step cleans, how it shares the Keeper with its turns and how it runs are
   answered in [Keeper_cleanup_step] and [Keeper_cleanup_attempt]; this loop
   schedules each Keeper, keeps what its steps returned and publishes it.
   Host CLI cancellation alone does not prove that a guest payload has
   terminated. *)
module Keeper_set = Set.Make (String)

type running = Keeper_set.t Atomic.t

let create_running () : running = Atomic.make Keeper_set.empty

let rec reserve running keeper_name =
  let current = Atomic.get running in
  if Keeper_set.mem keeper_name current then false
  else if Atomic.compare_and_set running current (Keeper_set.add keeper_name current)
  then true
  else reserve running keeper_name

let rec release running keeper_name =
  let current = Atomic.get running in
  if not (Atomic.compare_and_set running current (Keeper_set.remove keeper_name current))
  then release running keeper_name

(* Reserve before forking so a second pulse cannot schedule the same Keeper.
   Both cancellation paths release the pure reservation: a refused fork, or
   an entered child whose callback must finish teardown before it leaves.
   [false] means an earlier attempt for this Keeper is still running. *)
let schedule ~sw ~running ~keeper_name run =
  Eio.Switch.check sw;
  if reserve running keeper_name then (
    try
      Eio.Switch.check sw;
      Eio.Fiber.fork ~sw (fun () ->
        Fun.protect
          ~finally:(fun () -> release running keeper_name)
          (fun () -> Eio.Fiber.yield (); run ()));
      true
    with exn ->
      release running keeper_name;
      raise exn)
  else false

let step_label = function
  | Keeper_cleanup_step.Guest_builds -> "Keeper build cleanup"
  | Keeper_cleanup_step.Remote_workspace -> "Keeper workspace cleanup"

(* The name each step has in the pass line. *)
let step_count_label = function
  | Keeper_cleanup_step.Guest_builds -> "builds"
  | Keeper_cleanup_step.Remote_workspace -> "workspaces"

(* The latest result of every Keeper and step, and the latest pass. The loop
   and the fibers it forks for each Keeper all write it, so every write is a
   compare-and-set over the whole immutable value; the dashboard tools
   envelope reads it. A restart starts empty, and the first pass fills it
   again. *)
let status : Keeper_cleanup_status.t Atomic.t = Atomic.make Keeper_cleanup_status.empty

let rec update_status change =
  let current = Atomic.get status in
  if not (Atomic.compare_and_set status current (change current)) then update_status change

let current () = Atomic.get status
let envelope_json () = Keeper_cleanup_status_json.to_json (current ())

(* Every attempt that ran its payload leaves an info line, zero removals
   included: the passes at 00:08Z and 03:25Z on 2026-11-09 left none, and
   nothing showed whether the payload had run. A busy Keeper and a stopped
   guest are every pass's ordinary case; their rows carry them. *)
let log_attempt ~keeper_name (attempt : Keeper_cleanup_status.attempt) =
  let label = step_label (Keeper_cleanup_status.step attempt) in
  match attempt with
  | Keeper_cleanup_status.Guest_builds
      (Keeper_cleanup_status.Reclaimed { Keeper_cleanup_status.cleaned; failed }) ->
    Log.Server.info "%s keeper=%s cleaned=%d failed=%d" label keeper_name cleaned failed
  | Keeper_cleanup_status.Remote_workspace
      (Keeper_cleanup_status.Reclaimed
        { Keeper_cleanup_status.removed; skipped; failed; freed_kib; available_kib }) ->
    Log.Server.info
      "%s keeper=%s removed=%d skipped=%d failed=%d freed_kib=%d available_kib=%d"
      label keeper_name removed skipped failed freed_kib available_kib
  | Keeper_cleanup_status.Guest_builds (Keeper_cleanup_status.Failed detail)
  | Keeper_cleanup_status.Remote_workspace (Keeper_cleanup_status.Failed detail) ->
    Log.Server.warn "%s keeper=%s: %s" label keeper_name detail
  | Keeper_cleanup_status.Guest_builds (Keeper_cleanup_status.Deferred reason)
  | Keeper_cleanup_status.Remote_workspace (Keeper_cleanup_status.Deferred reason) ->
    Log.Server.debug "%s keeper=%s deferred: %s" label keeper_name reason
  | Keeper_cleanup_status.Guest_builds Keeper_cleanup_status.Not_running
  | Keeper_cleanup_status.Remote_workspace Keeper_cleanup_status.Not_running ->
    Log.Server.debug "%s keeper=%s: no running guest" label keeper_name

(* One Keeper's steps, in list order. A step does not wait on the one before
   it: a deferred or failed step leaves its row and the next one still runs. *)
let attempt_steps ~config ~keeper_name steps () =
  List.iter
    (fun step ->
      let attempt = Keeper_cleanup_attempt.run ~config ~keeper_name step in
      log_attempt ~keeper_name attempt;
      update_status
        (Keeper_cleanup_status.record_attempt ~keeper:keeper_name
           ~finished_at:(Time_compat.now ()) attempt))
    steps

(* One line per pass says how many Keepers each step reached, so a step that
   never ran is told apart from one that found nothing. *)
let log_pass (pass : Keeper_cleanup_status.pass) =
  List.iter
    (fun ({ keeper; reason } : Keeper_cleanup_status.unreadable) ->
      Log.Server.warn "Keeper cleanup keeper=%s: %s" keeper reason)
    pass.unreadable;
  Log.Server.info
    "Keeper cleanup pass owners=%d without_meta=%d unreadable=%d no_step=%d switched_off=%d %s scheduled=%d still_running=%d"
    pass.owners pass.without_meta (List.length pass.unreadable) pass.no_step
    pass.switched_off
    (String.concat " "
       (List.map
          (fun ({ step; selected; enabled = _ } : Keeper_cleanup_status.step_pass) ->
            Printf.sprintf "%s=%d" (step_count_label step) selected)
          pass.steps))
    pass.scheduled (List.length pass.still_running)

let sweep ~sw ~running ~(config : Workspace.config) ~enabled ~interval_sec () =
  let started_at = Time_compat.now () in
  match Keeper_owner_registry.all_projections ~base_path:config.base_path with
  | Error error ->
    Log.Server.warn "Keeper cleanup pass: owner inventory unavailable: %s"
      (Keeper_owner_registry.lookup_error_to_string error)
  | Ok projections ->
    let owner (projection : Keeper_owner_reducer.projection) =
      match projection.meta with
      | None -> Keeper_cleanup_status.Unnamed
      | Some meta ->
        let keeper_name = meta.name in
        Keeper_cleanup_status.Named
          ( keeper_name
          , match Keeper_cleanup_attempt.select ~config ~enabled ~keeper_name with
            | Error exclusion -> Keeper_cleanup_status.Excluded exclusion
            | Ok steps ->
              if schedule ~sw ~running ~keeper_name (attempt_steps ~config ~keeper_name steps)
              then Keeper_cleanup_status.Scheduled steps
              else Keeper_cleanup_status.Still_running steps )
    in
    let pass, record =
      Keeper_cleanup_status.conclude_pass ~started_at ~interval_sec ~enabled
        (List.map owner projections)
    in
    update_status record;
    log_pass pass

(* When passes run. [pass] returns the interval to wait before the next one.
   The first pass does not wait an interval: a server restarted within the
   interval would never pass, and the published result would stay empty for
   that long after every start. Of the 15 server runs between 2026-11-09
   10:00Z and 2026-11-11 07:33Z, 4 ended before their first pass, and 13.1
   of the 36.7 uptime hours came before one. *)
let run_passes ~clock ~first_delay_sec pass =
  Eio.Time.sleep clock first_delay_sec;
  let rec tick () =
    let interval_sec = pass () in
    Eio.Time.sleep clock interval_sec;
    tick ()
  in
  tick ()

let start ~sw ~clock ~config =
  let running = create_running () in
  Server_bootstrap_loops_fiber.fork_logged_fiber ~sw
    ~on_error:(Server_bootstrap_loops_fiber.log_server_fiber_crash "keeper_build_cleanup")
    (fun () ->
      (* One maintenance pulse, as the volume report waits, so the payloads
         do not start while the server is still starting. *)
      run_passes ~clock
        ~first_delay_sec:Env_config_runtime_services.Timeouts.maintenance_pulse_interval_sec
        (fun () ->
          let interval_sec =
            Runtime_params.get Runtime_settings.keeper_build_cleanup_interval_sec
          in
          (* One reading of the switches serves the whole pass, so its summary
             and its selection cannot disagree. A pass with every step off
             still runs: it is what tells "switched off" from "never ran". *)
          let switches =
            List.map
              (fun step -> step, Keeper_cleanup_attempt.enabled step)
              Keeper_cleanup_step.all
          in
          let enabled step =
            List.exists
              (fun (candidate, on) -> on && Keeper_cleanup_step.equal candidate step)
              switches
          in
          sweep ~sw ~running ~config ~enabled ~interval_sec ();
          interval_sec))
