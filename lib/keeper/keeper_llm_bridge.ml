(* lib/keeper/keeper_llm_bridge.ml *)
(* OAS Adapter bridging Eio structured concurrency, multi-turn cascade rollbacks,
   and strict global stop preemptions as formally verified in KeeperOASAdvanced.tla. *)

(** Runs a generic Eio execution (usually an OAS Agent.run or Model.call) with a strict
    structural timeout. If the execution is cancelled by a timeout or global stop,
    the exception is caught, OAS-local context mutations are discarded
    (functional rollback), external tool side effects are not reverted.

    Timeout returns [Oas.Error.Api (Timeout ...)].
    Cancellation (server shutdown / parent fiber cancel) re-raises so the caller
    exits immediately instead of retrying. *)
let run_with_timeout_and_fallback ~timeout_s fn =
  let clock_opt = (Masc_eio_env.get ()).clock in
  let t0 =
    match clock_opt with
    | Some clock -> Eio.Time.now clock
    | None -> Unix.gettimeofday ()
  in
  let elapsed () =
    match clock_opt with
    | Some clock -> Eio.Time.now clock -. t0
    | None -> Unix.gettimeofday () -. t0
  in
  let do_timeout fn =
    match clock_opt with
    | Some clock -> Eio.Time.with_timeout_exn clock timeout_s fn
    | None -> fn ()
  in
  try do_timeout fn with
  | Eio.Time.Timeout ->
    let wall = elapsed () in
    (* #9639/#9662: Eio cancel is cooperative. When the fiber blocks inside
       an uncancellable region (native HTTP bulk read, syscall, non-yielding
       loop), [with_timeout_exn] fires but the fiber continues until the
       next yield. Surface that overshoot as a structured warn so the
       condition is observable instead of silently inflating wall time. *)
    let deadline =
      Timeout_policy.Deadline.make
        ~layer:Timeout_policy.Layer.Oas_bridge
        ~origin:"keeper_llm_bridge"
        ~wall_cap_s:timeout_s
        ~now:t0
    in
    let _ : bool = Timeout_policy.overshoot_warn ~deadline ~actual_wall_s:wall () in
    Log.Keeper.warn
      "keeper_llm_bridge: OAS execution timed out after %.1fs (budget=%.0fs; OAS context \
       rollback only; external tool side effects are not reverted)"
      wall
      timeout_s;
    Error
      (Oas.Error.Api
         (Timeout
            { message = Printf.sprintf "Timeout after %.1fs (budget=%.0fs)" wall timeout_s
            }))
  | Eio.Cancel.Cancelled _ as exn ->
    (* TLA+: FiberHandlesCancellation -> Rollback context.
       Cancelled means a parent fiber (server shutdown, global stop) requested
       cancellation — NOT a timeout. Re-raise so the keeper exits immediately
       instead of entering the retry loop. *)
    let bt = Printexc.get_raw_backtrace () in
    let wall = elapsed () in
    Log.Keeper.warn
      "keeper_llm_bridge: OAS execution cancelled after %.1fs (re-raising; OAS context \
       rollback only; external tool side effects are not reverted)"
      wall;
    Printexc.raise_with_backtrace exn bt
  | exn ->
    (* TLA+: HandleError -> Rollback context *)
    let bt = Printexc.get_backtrace () in
    Log.Keeper.error
      "keeper_llm_bridge: OAS execution error: %s\n%s"
      (Printexc.to_string exn)
      bt;
    Error (Oas.Error.Internal (Printexc.to_string exn))
;;
