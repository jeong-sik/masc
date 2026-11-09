(* Root-switch-owned maintenance. Scheduling is isolated across Keepers. A
   guest build cleanup is admitted by the Owner mailbox, not a process
   snapshot, and owns its Keeper's atomic Maintenance slot until it returns;
   the guest payload supplies the separate build locks. The Remote_ssh
   workspace step runs beside the Keeper's turns (see [step]). Host CLI
   cancellation alone does not prove that a guest payload has terminated. *)
let read_cleanup_meta ~(config : Workspace.config) ~keeper_name =
  match Keeper_meta_store.read_effective_meta_resolved config keeper_name with
  | Error _ as error -> error
  | Ok None -> Ok None
  | Ok (Some (resolved_name, meta)) ->
    if String.equal resolved_name keeper_name && String.equal meta.name keeper_name
    then Ok (Some meta)
    else Error (Printf.sprintf
      "Keeper cleanup identity mismatch: owner=%s resolved=%s payload=%s"
      keeper_name resolved_name meta.name)

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

(* One cleanup per Keeper per pass, chosen by where its tree lives: an
   Apple microVM guest has stale _build directories, a Remote_ssh endpoint has
   stale workspace entries (RFC-remote-keeper-workspace-entries-are-swept-on-
   their-endpoint). Each step's own switch decides whether it runs.

   Only [Guest_builds] waits for an idle Keeper: its turns and the payload
   share the guest build locks. A workspace entry carries its own keep rules
   on the endpoint (untouched within the retention, no live process inside,
   no unpushed commit or stash), and review Keepers run turns back to back.
   At the first pass on 2026-11-09 (00:08Z) at least five of the seven
   running reviewers were mid-turn, so an idle-only sweep removed nothing
   while a report run found 13,525 stale entries. *)
type step = Guest_builds | Remote_workspace

let step_for ~builds ~remote_workspace = function
  | Keeper_types_profile.Remote_ssh -> if remote_workspace then Some Remote_workspace else None
  | Keeper_types_profile.(Docker | Micro_vm) -> if builds then Some Guest_builds else None

let step_label = function
  | Guest_builds -> "Keeper build cleanup"
  | Remote_workspace -> "Keeper workspace cleanup"

type report =
  | Builds of Keeper_turn_sandbox_runtime.build_cleanup_report
  | Workspace of Keeper_remote_workspace_cleanup.report

let run_step ~config ~meta = function
  | Guest_builds ->
    Keeper_turn_sandbox_runtime.cleanup_attached_builds ~config ~meta
      ~retention_sec:(Runtime_params.get Runtime_settings.keeper_build_cleanup_retention_sec) ()
    |> Result.map (Option.map (fun report -> Builds report))
  | Remote_workspace ->
    Keeper_remote_workspace_cleanup.cleanup ~config ~meta
      ~retention_sec:(Runtime_params.get Runtime_settings.keeper_remote_workspace_cleanup_retention_sec) ()
    |> Result.map (fun report -> Some (Workspace report))

let log_report ~keeper_name = function
  | Builds { Keeper_turn_sandbox_runtime.cleaned; failed } ->
    if cleaned > 0 || failed > 0 then
      Log.Server.info "Keeper build cleanup keeper=%s cleaned=%d failed=%d"
        keeper_name cleaned failed
  (* Every sweep leaves a line, removed=0 included: the passes at 00:08Z and
     03:25Z on 2026-11-09 left none, and nothing showed whether the payload
     had run. *)
  | Workspace { Keeper_remote_workspace_cleanup.removed; skipped; failed; freed_kib; available_kib } ->
    Log.Server.info
      "Keeper workspace cleanup keeper=%s removed=%d skipped=%d failed=%d freed_kib=%d available_kib=%d"
      keeper_name removed skipped failed freed_kib available_kib

(* One line per pass says how many Keepers each step reached, so a step that
   never ran is told apart from one that found nothing. *)
let sweep ~sw ~running ~(config : Workspace.config) ~builds ~remote_workspace () =
  match Keeper_owner_registry.all_projections ~base_path:config.base_path with
  | Error error ->
    Log.Server.warn "Keeper cleanup pass: owner inventory unavailable: %s"
      (Keeper_owner_registry.lookup_error_to_string error)
  | Ok projections ->
    let without_meta = ref 0 and switched_off = ref 0 and still_running = ref 0
    and guest_builds = ref 0 and workspaces = ref 0 in
    List.iter
      (fun (projection : Keeper_owner_reducer.projection) ->
        match projection.meta with
        | None -> incr without_meta
        | Some meta ->
          match step_for ~builds ~remote_workspace meta.sandbox_profile with
          | None -> incr switched_off
          | Some step ->
            let label = step_label step in
            let run () =
              match read_cleanup_meta ~config ~keeper_name:meta.name with
              | Error detail -> Error detail
              | Ok None -> Ok None
              | Ok (Some current) -> run_step ~config ~meta:current step
            in
            let settle = function
              | Error detail -> Log.Server.warn "%s keeper=%s: %s" label meta.name detail
              | Ok (Some report) -> log_report ~keeper_name:meta.name report
              | Ok None ->
                (match step with
                 | Guest_builds -> ()
                 | Remote_workspace ->
                   Log.Server.warn "%s keeper=%s: no stored Keeper meta" label meta.name)
            in
            let attempt () =
              try match step with
              | Guest_builds ->
                (match Keeper_owner_registry.run_maintenance_if_idle ~defer_to_chat:true
                         ~base_path:config.base_path ~keeper_name:meta.name run with
                 | Ok (`Ran result) -> settle result
                 | Error _ | Ok (`Busy _) -> ())
              | Remote_workspace -> settle (run ())
              with
              | Eio.Cancel.Cancelled _ as exn -> raise exn
              | exn -> Log.Server.warn "%s keeper=%s: %s"
                         label meta.name (Printexc.to_string exn)
            in
            if schedule ~sw ~running ~keeper_name:meta.name attempt
            then incr (match step with Guest_builds -> guest_builds | Remote_workspace -> workspaces)
            else incr still_running)
      projections;
    Log.Server.info
      "Keeper cleanup pass owners=%d without_meta=%d switched_off=%d builds=%d workspaces=%d still_running=%d"
      (List.length projections) !without_meta !switched_off !guest_builds !workspaces
      !still_running

let start ~sw ~clock ~config =
  let running = create_running () in
  Server_bootstrap_loops_fiber.fork_logged_fiber ~sw
    ~on_error:(Server_bootstrap_loops_fiber.log_server_fiber_crash "keeper_build_cleanup")
    (fun () ->
      let rec tick () =
        Eio.Time.sleep clock (Runtime_params.get Runtime_settings.keeper_build_cleanup_interval_sec);
        let builds = Runtime_params.get Runtime_settings.keeper_build_cleanup_enabled
        and remote_workspace =
          Runtime_params.get Runtime_settings.keeper_remote_workspace_cleanup_enabled in
        if builds || remote_workspace
        then sweep ~sw ~running ~config ~builds ~remote_workspace ();
        tick ()
      in
      tick ())
