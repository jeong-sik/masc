module Periodic = Keeper_volume_gc_periodic

let report_interval_sec = 6.0 *. Masc_time_constants.hour

(* The loop below is the only writer; the dashboard tools envelope reads it.
   A restart starts empty, and the first pass fills it again. *)
type observed_pass = { base_path : string; value : Periodic.t }
let last : observed_pass option Atomic.t = Atomic.make None

let envelope_json ~base_path () =
  match Atomic.get last with
  | None -> `Null
  | Some pass -> if String.equal pass.base_path base_path then
      Periodic.to_json pass.value else `Null
;;

let log_pass (pass : Periodic.t) =
  match pass.Periodic.outcome with
  | Periodic.Reported answer ->
    let candidates = Keeper_volume_gc_answer.reclaim_candidates answer in
    Log.Server.info
      "sandbox volume gc report: keepers=%d reclaim_candidates=%d names=[%s]"
      (List.length answer.Keeper_volume_gc_answer.keepers)
      (List.length candidates)
      (String.concat ", " candidates)
  | Periodic.Skipped reason -> Log.Server.info "sandbox volume gc report skipped: %s" reason
  | Periodic.Failed reason -> Log.Server.warn "sandbox volume gc report failed: %s" reason
;;

let pass ~base_path =
  let timeout_sec = Keeper_volume_gc_host.default_timeout_sec () in
  Periodic.observe
    ~now:Time_compat.now
    ~ready:Keeper_volume_gc_host.apple_container_ready
    ~resolve_claims_image:(fun () ->
      Keeper_volume_gc_host.resolve_claims_image ~base_path Keeper_volume_gc_host.claims_image)
    ~judge:(fun ready ~claims_image ~request ->
      Keeper_volume_gc_host.run ready ~base_path ~claims_image ~timeout_sec ~request)
;;

let start ~sw ~clock ~(config : Workspace.config) =
  let base_path = config.base_path in
  Server_bootstrap_loops_fiber.fork_logged_fiber
    ~sw
    ~on_error:(Server_bootstrap_loops_fiber.log_server_fiber_crash "sandbox_volume_gc_report")
    (fun () ->
       (* The first pass waits one maintenance pulse, so its container
          commands do not start while the server is still starting. *)
       Eio.Time.sleep clock Env_config_runtime_services.Timeouts.maintenance_pulse_interval_sec;
       let rec tick () =
         let observed = pass ~base_path in
         log_pass observed;
         Atomic.set last (Some {base_path; value = observed});
         Dashboard_observation_commit.written ~base_path ~scope:`Workspace `Tools;
         Eio.Time.sleep clock report_interval_sec;
         tick ()
       in
       tick ())
;;
