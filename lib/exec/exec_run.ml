(* Tick 10: foreground / background race for keeper_bash.

   Structure:
   1. Bg_task.spawn  -> a detached pgid-owned child with ring buffers.
   2. Eio.Fiber.first races two sub-fibers:
        (a) poll loop   — Bg_task.read at [poll_interval_ms] cadence,
                          accumulating stdout/stderr.  Exits when
                          Bg_task reports [closed = true] with a
                          terminal [status].  Returns [`Done state].
        (b) budget timer — [Eio.Time.sleep clock budget_sec].
                          Returns [`Budget_expired].
   3. Whichever fiber wins chooses the branch:
        - `Done   -> Completed
        - `Budget_expired -> one final drain, Promoted.

   Invariants:
   - On promotion the task is intentionally NOT killed.  Caller owns
     the handle and is expected to poll via keeper_bash_output or to
     call keeper_bash_kill.
   - Cumulative output is a simple [Buffer.t] append of every
     [read]'s [*_since] slices.  Because [read] is pull-based with
     ring buffers underneath, concatenating every slice yields the
     full observed stream minus whatever Bg_task's ring dropped.
     [bytes_dropped_*] carries that loss forward. *)

(* [Bg_task] is unqualified: [masc_process] is wrapped:false. *)

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

let default_budget_ms () =
  match Sys.getenv_opt "MASC_BLOCKING_BUDGET_MS" with
  | None -> 15_000
  | Some s ->
    (match int_of_string_opt (String.trim s) with
     | Some n -> n
     | None -> 15_000)
;;

(* Drain accumulator tracking cumulative byte offsets into each
   stream.  [since_stdout]/[since_stderr] feed back to Bg_task.read
   so every poll only surfaces fresh bytes. *)
type accum =
  { stdout : Buffer.t
  ; stderr : Buffer.t
  ; mutable since_stdout : int
  ; mutable since_stderr : int
  ; mutable dropped_stdout : int
  ; mutable dropped_stderr : int
  ; mutable status : Unix.process_status option
  ; mutable closed : bool
  }

let mk_accum () =
  { stdout = Buffer.create 1024
  ; stderr = Buffer.create 256
  ; since_stdout = 0
  ; since_stderr = 0
  ; dropped_stdout = 0
  ; dropped_stderr = 0
  ; status = None
  ; closed = false
  }
;;

let drain_once ~task acc =
  match
    Bg_task.read task ~since_stdout:acc.since_stdout ~since_stderr:acc.since_stderr
  with
  | Error _ ->
    (* Unknown / read_failed: treat as a dead task so the race
       settles.  The caller will see the accumulator's current
       state; no partial status recovery here. *)
    acc.closed <- true
  | Ok snap ->
    Buffer.add_string acc.stdout snap.stdout_since;
    Buffer.add_string acc.stderr snap.stderr_since;
    acc.since_stdout <- acc.since_stdout + String.length snap.stdout_since;
    acc.since_stderr <- acc.since_stderr + String.length snap.stderr_since;
    acc.dropped_stdout <- snap.bytes_dropped_stdout;
    acc.dropped_stderr <- snap.bytes_dropped_stderr;
    acc.status <- snap.status;
    acc.closed <- snap.closed
;;

let run_with_auto_bg
      ~clock
      ?(poll_interval_ms = 50)
      ?base_path
      ~budget_ms
      ~keeper
      ~argv
      ~cwd
      ~envp
      ~timeout_sec
      ()
  =
  match Bg_task.spawn ?base_path ~keeper ~argv ~cwd ~envp ~timeout_sec () with
  | Error e -> Spawn_error e
  | Ok task ->
    let acc = mk_accum () in
    let poll_sec = max 0.001 (float_of_int poll_interval_ms /. 1000.) in
    let disabled = budget_ms <= 0 in
    let winner : [ `Done | `Budget_expired ] =
      Eio.Fiber.first
        (fun () ->
           let rec loop () =
             drain_once ~task acc;
             if acc.closed
             then `Done
             else (
               Eio.Time.sleep clock poll_sec;
               loop ())
           in
           loop ())
        (fun () ->
           if disabled
           then (
             (* Unbounded: block forever so the poll fiber wins.
                Using a very large sleep instead of a Promise avoids
                introducing a new synchronisation primitive. *)
             Eio.Time.sleep clock 1.0e9;
             `Budget_expired)
           else (
             Eio.Time.sleep clock (float_of_int budget_ms /. 1000.);
             `Budget_expired))
    in
    (match winner with
     | `Done ->
       let status =
         match acc.status with
         | Some s -> s
         | None -> Unix.WEXITED 0
         (* Drain-after-close without a status is a Bg_task
           bookkeeping slip; default to success so we do not
           invent a failure code. *)
       in
       Completed
         { status
         ; stdout = Buffer.contents acc.stdout
         ; stderr = Buffer.contents acc.stderr
         ; bytes_dropped_stdout = acc.dropped_stdout
         ; bytes_dropped_stderr = acc.dropped_stderr
         }
     | `Budget_expired ->
       (* Final drain so the Promoted snapshot carries every byte
         the child emitted up to budget_expire time. *)
       drain_once ~task acc;
       Promoted
         { task_id = task
         ; partial_stdout = Buffer.contents acc.stdout
         ; partial_stderr = Buffer.contents acc.stderr
         ; bytes_dropped_stdout = acc.dropped_stdout
         ; bytes_dropped_stderr = acc.dropped_stderr
         })
;;
