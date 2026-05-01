(* lib/keeper/keeper_llm_bridge.ml *)
(* OAS Adapter bridging Eio structured concurrency, multi-turn cascade rollbacks,
   and strict global stop preemptions as formally verified in KeeperOASAdvanced.tla. *)

(** Runs a generic Eio execution (usually an OAS Agent.run or Model.call) with a strict
    structural timeout. If the execution is cancelled by a timeout or global stop,
    the exception is caught, OAS-local context mutations are discarded
    (functional rollback), external tool side effects are not reverted.

    Timeout returns [Agent_sdk.Error.Api (Timeout ...)].
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
  try
    do_timeout fn
  with
  | Eio.Time.Timeout ->
    let wall = elapsed () in
    (* #9639/#9662: Eio cancel is cooperative — [with_timeout_exn] fires
       but the fiber must reach a cancel point (single_read, yield, etc.)
       to actually interrupt. Surface overshoot as a structured warn so
       stalls remain observable instead of silently inflating wall time.

       2026-04-27 correction: the original "uncancellable region (native
       HTTP bulk read, syscall, non-yielding loop)" diagnosis was a
       guess and has been *falsified* by four raw-TCP reproducers ported
       to the OAS regression guard (jeong-sik/oas#1210,
       test/test_eio_cancellability.ml).  Buf_read.line + slow drip and
       read_sse + fast stream with trivial / sleeping / CPU-bound on_data
       callbacks all exit Eio.Time.with_timeout_exn within 1-2ms.  The
       layer producing prod hangs (>=1170s) is *not* yet identified;
       remaining suspects are caller on_event handlers, post_sync
       take_all + connection-not-closed, Switch cleanup, or TLS.

       Action: do NOT add yield points to OAS read_sse / Buf_read based
       on the original guess — that wrong-layer fix was almost shipped.
       During the next overshoot, run
       ~/me/scripts/oas-hung-keeper-dump.sh to capture the fiber stack
       and identify the real layer.  Cross-ref:
       jeong-sik/me planning/claude-plans/oas-execution-cancellability.md *)
    let deadline =
      Timeout_policy.Deadline.make
        ~layer:Timeout_policy.Layer.Oas_bridge
        ~origin:"keeper_llm_bridge"
        ~wall_cap_s:timeout_s
        ~now:(t0)
    in
    let _ : bool =
      Timeout_policy.overshoot_warn ~deadline ~actual_wall_s:wall ()
    in
    Log.Keeper.warn
      "keeper_llm_bridge: OAS execution timed out after %.1fs (budget=%.0fs; OAS context rollback only; external tool side effects are not reverted)"
      wall timeout_s;
    Error (Agent_sdk.Error.Api (Timeout { message = Printf.sprintf "Timeout after %.1fs (budget=%.0fs)" wall timeout_s }))
  | Eio.Cancel.Cancelled inner_exn as exn ->
    (* TLA+: FiberHandlesCancellation -> Rollback context.
       Cancelled means a parent fiber (server shutdown, global stop) requested
       cancellation — NOT a timeout. Re-raise so the keeper exits immediately
       instead of entering the retry loop.

       #10716: bimodal distribution observed in production — 21 events in
       [60, 300)s (short-tail, routine cancel: supervisor pause / cascade
       rotation) plus 8 events ≥1800s (long-tail, LLM provider hung). Same
       opaque message for both made root-cause attribution impossible.
       Categorize wall duration into a discrete bucket and surface the
       inner cancel exception so operators can split short_tail / mid_tail
       / long_tail in PromQL and the inner reason ([Eio.Cancel.Cancel_hook]
       payload, parent-fiber Cancelled, etc.) appears in the log. *)
    let bt = Printexc.get_raw_backtrace () in
    let wall = elapsed () in
    let bucket =
      if wall < 60.0 then "fast"
      else if wall < 300.0 then "short_tail"
      else if wall < 600.0 then "mid_tail"
      else if wall < 1800.0 then "long_mid"
      else "long_tail"
    in
    let inner_str =
      match inner_exn with
      | Failure msg -> "Failure(" ^ msg ^ ")"
      | _ -> Printexc.to_string inner_exn
    in
    Log.Keeper.warn
      "keeper_llm_bridge: OAS execution cancelled after %.1fs bucket=%s inner=%s (re-raising; OAS context rollback only; external tool side effects are not reverted)"
      wall bucket inner_str;
    Prometheus.inc_counter "masc_keeper_oas_cancel_total"
      ~labels:[ ("bucket", bucket) ]
      ();
    Printexc.raise_with_backtrace exn bt
  | exn ->
    (* TLA+: HandleError -> Rollback context *)
    let bt = Printexc.get_backtrace () in
    Log.Keeper.error "keeper_llm_bridge: OAS execution error: %s\n%s" (Printexc.to_string exn) bt;
    Error (Agent_sdk.Error.Internal (Printexc.to_string exn))
