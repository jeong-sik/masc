(* A4a exec_gate — production wrappers around Process_eio.

   History: the [run_argv*] wrappers used to route every spawn through
   a typed approval gate ([with_verdict] -> [verdict_for_argv] ->
   [Approval_policy.decide]) whose enforcement was selected by the
   [MASC_EXEC_GATE] env var ([Off] | [Parallel] | [Enforced]).  That
   gate defaulted to [Off] and was never enabled outside its own test
   (`test_exec_gate_runtime.ml`); no deploy/runtime/CI config ever set
   the variable.  The verdict computation (GADT typed capability check,
   overlay rollout config, decision recording) was therefore dead: in
   [Off] mode the verdict was computed and immediately discarded before
   delegating to [Process_eio].  The [run] verdict dispatcher and its
   [error] type had zero production fan-in (only self-referential tests)
   and were removed with the gate.

   The gate machinery has been removed.  The [run_argv*] wrappers now
   delegate directly to [Process_eio].  Their signatures are unchanged
   (~30 callers stay source-compatible); the [~actor]/[~raw_source]/
   [~summary] arguments are retained for signature compatibility but are
   no longer consumed.  See RFC-0005 (typed capability substrate) for
   the original shadow-rollout intent. *)

(* Default subprocess timeout.  Callers should prefer passing
   [~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:... ())]
   so that operators can override via per-caller env vars.  See
   {!Env_config_exec_timeout}; live keeper sandbox callers pass
   caller-scoped values through this gate. *)
let default_exec_timeout_sec = 60.0

let run_argv ~actor:_ ~raw_source:_ ~summary:_
    ?(timeout_sec = default_exec_timeout_sec) ?env argv =
  Process_eio.run_argv ~timeout_sec ?env argv

let run_argv_with_status ~actor:_ ~raw_source:_ ~summary:_
    ?(timeout_sec = default_exec_timeout_sec) ?env ?cwd argv =
  Process_eio.run_argv_with_status ~timeout_sec ?env ?cwd argv

let run_argv_with_status_split ~actor:_ ~raw_source:_ ~summary:_
    ?(timeout_sec = default_exec_timeout_sec) ?env ?cwd argv =
  Process_eio.run_argv_with_status_split ~timeout_sec ?env ?cwd argv

let run_argv_with_stdin_and_status ~actor:_ ~raw_source:_ ~summary:_
    ?(timeout_sec = default_exec_timeout_sec) ?env ?cwd ~stdin_content argv =
  Process_eio.run_argv_with_stdin_and_status ~timeout_sec ?env ?cwd
    ~stdin_content argv

let run_argv_with_stdin_and_status_split ~actor:_ ~raw_source:_ ~summary:_
    ?(timeout_sec = default_exec_timeout_sec) ?env ?cwd ~stdin_content argv =
  Process_eio.run_argv_with_stdin_and_status_split ~timeout_sec ?env ?cwd
    ~stdin_content argv

let run_argv_pipeline_with_status_split ~actor:_ ~raw_source:_ ~summary:_
    ?(timeout_sec = default_exec_timeout_sec) stages =
  Process_eio.run_argv_pipeline_with_status_split ~timeout_sec stages
