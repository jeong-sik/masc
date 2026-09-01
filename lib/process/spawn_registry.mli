(** Processes that outlive the call that started them.

    RFC spawn-a-process-that-outlives-the-call.

    [Process_eio]'s [run_argv_*] all run to completion, which is why none of
    them can carry a dev server or a watcher: their result type is filled in by
    a process that has ended. This holds the ones that have not.

    Nothing here polls. A wait is on the event it is waiting for -- the process
    exiting, or the bytes arriving -- so there is no interval to choose and no
    interval to defend. A timeout is a bound the caller states, never a
    cadence and never a default. *)

type t

val create : run:string -> output_limit_bytes:int -> t option
(** [None] when [run] is empty or the limit is not positive.

    [run] names this registry's issuing epoch and is given by the caller: a
    test fixes it with the same argument production derives once. Handles from
    a registry with a different [run] parse and then match nothing here, rather
    than matching whatever happens to hold their number now.

    [output_limit_bytes] is how much of each stream is kept. A process can
    outrun any reader, so the buffer is bounded; {!read} reports every byte the
    bound cost rather than handing back a string with a hole in it. *)

type stream =
  | Stdout
  | Stderr

type chunk = {
  bytes : string;  (** what the stream holds after the requested offset *)
  next : int;  (** the offset to continue from *)
  dropped_before : int;
      (** bytes between the requested offset and [bytes], discarded by the
          buffer bound before this read asked for them. Zero on a reader
          keeping up. *)
}

type until =
  | Exit
  | Output_contains of {
      stream : stream;
      needle : string;
    }
      (** matched literally against what the stream holds. The needle is the
          caller's own protocol with the program it started; nothing is
          inferred from it. A needle that spanned bytes the bound already
          discarded cannot match -- {!chunk.dropped_before} is how a caller
          sees that happened. *)

type waited =
  | Exited of Unix.process_status
  | Matched of int  (** the offset just past the match *)

val spawn
  :  sw:Eio.Switch.t
  -> t
  -> ?env:string array
  -> ?cwd:string
  -> string list
  -> (Spawn_handle.t, string) result
(** Start [argv] and return while it runs.

    The process is registered with [sw]: when the switch ends, for any reason,
    the process is signalled and reaped. A spawned process cannot outlive its
    switch, which is not a step a caller can forget to take.

    [cwd] resolves through {!Process_eio.cwd_path}: absolute replaces the
    initialized default, relative appends to it. Omitted means the default. *)

val read
  :  t
  -> Spawn_handle.t
  -> stream:stream
  -> from:int
  -> (chunk, [ `Unknown_handle ]) result
(** What [stream] holds after [from]. Reading twice from the returned offsets
    sees each byte once. *)

val wait
  :  t
  -> Spawn_handle.t
  -> until:until
  -> timeout_sec:float
  -> (waited, [ `Timed_out | `Unknown_handle ]) result
(** Wait for [until], for at most [timeout_sec].

    There is no [After of seconds] in {!until} and no default for
    [timeout_sec]. Waiting a fixed time is not synchronisation: it succeeds on
    one machine and reports a state that has not happened on another, which is
    a wrong answer rather than a failure. *)

val stop : t -> Spawn_handle.t -> (unit, [ `Unknown_handle ]) result
(** Signal the process to end. [Ok ()] for one that already has: a caller never
    has to race the process to ask about it. *)

val is_running : t -> Spawn_handle.t -> (bool, [ `Unknown_handle ]) result
