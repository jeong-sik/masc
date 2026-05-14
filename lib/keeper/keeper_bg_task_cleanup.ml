(** Implementation of Keeper_bg_task_cleanup. See .mli for contract. *)

let drain_for_keeper ~keeper_id ~grace_sec : int =
  let grace_sec =
    if grace_sec < 0.0 then 0.0
    else if grace_sec > 30.0 then 30.0
    else grace_sec
  in
  let task_ids =
    try Bg_task.list ~keeper:keeper_id
    with exn ->
      Log.Keeper.warn
        "[BgTaskCleanup] Bg_task.list raised on keeper=%s: %s"
        keeper_id (Printexc.to_string exn);
      []
  in
  let inspected = ref 0 in
  let kill_failed = ref 0 in
  List.iter (fun tid ->
    incr inspected;
    match
      try Bg_task.kill tid ~signal:Sys.sigterm ~grace_sec
      with exn ->
        Log.Keeper.warn
          "[BgTaskCleanup] Bg_task.kill raised on keeper=%s task=%s: %s"
          keeper_id (Bg_task.task_id_to_string tid)
          (Printexc.to_string exn);
        Error (Bg_task.Kill_failed (Printexc.to_string exn))
    with
    | Ok () -> ()
    | Error (Bg_task.Unknown_task_kill _) -> () (* already gone *)
    | Error (Bg_task.Kill_failed msg) ->
      incr kill_failed;
      Log.Keeper.warn
        "[BgTaskCleanup] kill failed keeper=%s task=%s: %s"
        keeper_id (Bg_task.task_id_to_string tid) msg
  ) task_ids;
  if !inspected > 0 then
    Log.Keeper.info
      "[BgTaskCleanup] keeper=%s inspected=%d kill_failed=%d grace=%.1fs"
      keeper_id !inspected !kill_failed grace_sec;
  !inspected

let default_hook : Keeper_lifecycle_hooks.hook =
 fun ~keeper_id ev ->
  match ev with
  | Keeper_lifecycle_hooks.Tombstone_reaped ->
    let _n = drain_for_keeper ~keeper_id ~grace_sec:5.0 in
    ()
  | Keeper_lifecycle_hooks.Phase_transition _ -> ()

(* Idempotency guard. *)
let registered = Atomic.make false

let register_default_cleanup_hook () : unit =
  if Atomic.compare_and_set registered false true then
    Keeper_lifecycle_hooks.register default_hook

let reset_for_testing () : unit = Atomic.set registered false
