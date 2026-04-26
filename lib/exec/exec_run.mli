(** Auto-background race — Phase 4 of the Legendary Bash roadmap.

    Mirrors claude-code's foreground-shell auto-promotion: run a
    command in the foreground, but if it outruns a blocking budget,
    hand it off to the background-task registry and return a
    [Promoted] ref so the caller can continue polling.

    Design (Tick 10): {e bg-first with early settlement}.  Every
    invocation spawns a {!Bg_task} (from [masc_process]) from the start so
    tree-kill, PID-file persistence, and ring-buffered drains are
    always available.  A short-lived poll fiber drains the task
    while racing a budget timer via {!Eio.Fiber.first}.  Whichever
    fiber wins picks the outcome:
    - exit before budget -> [Completed] (caller cleans up; bg_task
      auto-closes on read-after-exit in a future tick)
    - budget expires first -> [Promoted] (task keeps running, caller
      gets partial output + a handle)

    This sidesteps the "switch hand-off" problem suggested by the
    plan: because we never start a foreground-only process, there is
    no fiber to transplant.  The pgid-owned child in Bg_task was
    already the right unit of ownership. *)

type completed =
  { status : Unix.process_status
  ; stdout : string
  ; stderr : string
  ; bytes_dropped_stdout : int
  ; bytes_dropped_stderr : int
  }

type promoted =
  { task_id : Bg_task.task_id
  ; partial_stdout : string
  ; partial_stderr : string
  ; bytes_dropped_stdout : int
  ; bytes_dropped_stderr : int
  }

type outcome =
  | Completed of completed
  | Promoted of promoted
  | Spawn_error of Bg_task.spawn_error

(** Reads [MASC_BLOCKING_BUDGET_MS].  Defaults to [15_000] to match
    claude-code's foreground timeout.  A value of [0] or negative
    disables the race (behaves as unbounded foreground). *)
val default_budget_ms : unit -> int

(** Spawn [argv] as a Bg_task, then race its completion against
    [budget_ms].  [poll_interval_ms] defaults to [50] — tight enough
    to catch a fast-exiting command inside the budget without burning
    CPU on idle polls.  [timeout_sec] is the upper-bound wall clock
    that Bg_task enforces even after promotion (pass [0.0] to
    disable). *)
val run_with_auto_bg
  :  clock:_ Eio.Time.clock
  -> ?poll_interval_ms:int
  -> ?base_path:string
  -> budget_ms:int
  -> keeper:string
  -> argv:string list
  -> cwd:string
  -> envp:string array
  -> timeout_sec:float
  -> unit
  -> outcome
