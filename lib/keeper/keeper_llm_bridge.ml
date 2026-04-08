(* lib/keeper/keeper_llm_bridge.ml *)
(* OAS Adapter bridging Eio structured concurrency, multi-turn cascade rollbacks,
   and strict global stop preemptions as formally verified in KeeperOASAdvanced.tla. *)

(** Runs a generic Eio execution (usually an OAS Agent.run or Model.call) with a strict
    structural timeout. If the execution is cancelled by a timeout or global stop,
    the exception is caught, OAS-local context mutations are discarded
    (functional rollback), external tool side effects are not reverted,
    and an OAS timeout error is returned. *)
let run_with_timeout_and_fallback ~timeout_s fn =
  let do_timeout fn =
    match (Masc_eio_env.get ()).clock with
    | Some clock -> Eio.Time.with_timeout_exn clock timeout_s fn
    | None -> fn ()
  in
  try
    do_timeout fn
  with
  | Eio.Time.Timeout ->
    Log.Keeper.warn
      "keeper_llm_bridge: OAS execution timed out after %.1fs (OAS context rollback only; external tool side effects are not reverted)"
      timeout_s;
    Error (Oas.Error.Api (Timeout { message = Printf.sprintf "Execution cancelled after %.1fs" timeout_s }))
  | Eio.Cancel.Cancelled _ ->
    (* TLA+: FiberHandlesCancellation -> Rollback context.
       Since Oas_worker_exec returns the new context functionally inside the run_result,
       we inherently discard intermediate state when cancelled here. *)
    Log.Keeper.warn
      "keeper_llm_bridge: OAS execution cancelled (OAS context rollback only; external tool side effects are not reverted)";
    Error (Oas.Error.Api (Timeout { message = Printf.sprintf "Execution cancelled after %.1fs" timeout_s }))
  | exn ->
    (* TLA+: HandleError -> Rollback context *)
    let bt = Printexc.get_backtrace () in
    Log.Keeper.error "keeper_llm_bridge: OAS execution error: %s\n%s" (Printexc.to_string exn) bt;
    Error (Oas.Error.Internal (Printexc.to_string exn))
