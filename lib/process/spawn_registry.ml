(* Read granularity for draining a pipe. Not a policy: it changes how many
   syscalls a drain makes and nothing a caller can observe. The buffer bound
   that *is* a policy is [output_limit_bytes], which the caller states. *)
let read_chunk_bytes = 4096

type stream =
  | Stdout
  | Stderr

type chunk = {
  bytes : string;
  next : int;
  dropped_before : int;
}

type until =
  | Exit
  | Output_contains of {
      stream : stream;
      needle : string;
    }

type waited =
  | Exited of Unix.process_status
  | Matched of int

(* [held] is the tail of the stream this buffer still has; [dropped] counts the
   bytes ahead of it that the bound discarded. An offset is absolute over the
   whole stream, so [dropped + String.length held] is where the stream is now
   and an offset below [dropped] names bytes nobody can produce again. *)
type stream_buffer = {
  mutable held : string;
  mutable dropped : int;
  mutable at_eof : bool;
}

(* Three states, not an option pretending to hold three. [Released] is the one
   an option cannot say: the switch ended, so the process was signalled and
   reaped by the switch, and the fiber that would have recorded a status was
   cancelled before it could. Read as [None] that is indistinguishable from
   [Running], which reported a killed process as still running. *)
type lifecycle =
  | Running
  | Exited_with of Unix.process_status
  | Released

type entry = {
  stdout : stream_buffer;
  stderr : stream_buffer;
  changed : Eio.Condition.t;
  await_status : unit -> Unix.process_status;
  signal_process : int -> unit;
  mutable lifecycle : lifecycle;
}

type t = {
  issuer : Spawn_handle.issuer;
  limit : int;
  entries : (string, entry) Hashtbl.t;
}

let create ~run ~output_limit_bytes =
  if output_limit_bytes <= 0
  then None
  else
    Option.map
      (fun issuer -> { issuer; limit = output_limit_bytes; entries = Hashtbl.create 8 })
      (Spawn_handle.issuer ~run)
;;

let empty_buffer () = { held = ""; dropped = 0; at_eof = false }
let stream_end buffer = buffer.dropped + String.length buffer.held

let append buffer ~limit text =
  buffer.held <- buffer.held ^ text;
  let excess = String.length buffer.held - limit in
  if excess > 0
  then (
    buffer.dropped <- buffer.dropped + excess;
    buffer.held <- String.sub buffer.held excess (String.length buffer.held - excess))
;;

let read_buffer buffer ~from =
  let ending = stream_end buffer in
  let requested = if from < 0 then 0 else from in
  let dropped_before = if requested < buffer.dropped then buffer.dropped - requested else 0 in
  let start = if requested < buffer.dropped then buffer.dropped else requested in
  let start = if start > ending then ending else start in
  let offset_in_held = start - buffer.dropped in
  { bytes = String.sub buffer.held offset_in_held (String.length buffer.held - offset_in_held)
  ; next = ending
  ; dropped_before
  }
;;

(* The match offset is absolute, so a caller can read from it and see what
   followed the needle rather than the needle again. *)
let match_end buffer ~needle =
  let held_length = String.length buffer.held in
  let needle_length = String.length needle in
  if needle_length = 0 || needle_length > held_length
  then None
  else (
    let rec scan at =
      if at + needle_length > held_length
      then None
      else if String.equal (String.sub buffer.held at needle_length) needle
      then Some (buffer.dropped + at + needle_length)
      else scan (at + 1)
    in
    scan 0)
;;

let buffer_of entry = function
  | Stdout -> entry.stdout
  | Stderr -> entry.stderr
;;

let unix_status = function
  | `Exited code -> Unix.WEXITED code
  | `Signaled signal -> Unix.WSIGNALED signal
;;

(* One fiber per stream, appending as bytes arrive and waking whoever is
   waiting. Draining has to be concurrent here: the process does not end, so
   there is no "after it exits" in which to read the pipe.

   These are daemons. [Switch.run] waits for forked fibers before it runs
   release handlers, and a drain is blocked until the pipe reaches EOF, which
   is when the process ends -- so an ordinary fiber makes the switch wait for
   the very process the release handler is there to stop. Measured: 60s for a
   [sleep 60] the switch was supposed to end. A daemon is cancelled when the
   switch's own work finishes, which is what a reader of someone else's output
   should be. *)
let drain ~flow ~buffer ~limit ~changed =
  let scratch = Cstruct.create read_chunk_bytes in
  let rec loop () =
    match Eio.Flow.single_read flow scratch with
    | count ->
      append buffer ~limit (Cstruct.to_string (Cstruct.sub scratch 0 count));
      Eio.Condition.broadcast changed;
      loop ()
    | exception End_of_file ->
      buffer.at_eof <- true;
      Eio.Condition.broadcast changed
    | exception (Eio.Cancel.Cancelled _ as cancelled) ->
      (* Mark the stream done so a waiter is not left expecting more, then let
         the cancellation through. Swallowing it returns a fiber that the
         switch is still waiting to see finish cancelling, which is a hang. *)
      buffer.at_eof <- true;
      Eio.Condition.broadcast changed;
      raise cancelled
  in
  loop ();
  `Stop_daemon
;;

(* [cwd] is a string rather than a path because that is what a caller has: the
   spawn tool takes it off the wire, and [Process_eio] already owns the rule
   for turning one into the other. Taking [Eio.Fs.dir_ty Eio.Path.t] here left
   the tool with no way to pass what it was given, so it passed nothing and
   the parameter it advertised was discarded. *)
let spawn ~sw registry ?env ?cwd argv =
  match Process_eio.get_proc_mgr (), Process_eio.cwd_path cwd with
  | Error message, _ | _, Error message -> Error message
  | Ok manager, Ok cwd ->
    (match argv with
     | [] -> Error "spawn needs a program to run"
     | _ :: _ ->
       let stdout_r, stdout_w = Eio.Process.pipe ~sw manager in
       let stderr_r, stderr_w = Eio.Process.pipe ~sw manager in
       let process =
         Eio.Process.spawn ~sw manager ~cwd ?env ~stdout:stdout_w ~stderr:stderr_w argv
       in
       Eio.Flow.close stdout_w;
       Eio.Flow.close stderr_w;
       let entry =
         { stdout = empty_buffer ()
         ; stderr = empty_buffer ()
         ; changed = Eio.Condition.create ()
         ; await_status = (fun () -> unix_status (Eio.Process.await process))
         ; signal_process = (fun signal -> Eio.Process.signal process signal)
         ; lifecycle = Running
         }
       in
       (* Teardown is the switch, not a call the caller has to remember. A
          process that is still running when the switch ends is signalled and
          reaped here, which is where a cancelled turn stops leaving one
          behind. *)
       (* Signal only. The reaper daemon owns the await, and awaiting the same
          process from here as well deadlocked the two against each other --
          the switch waiting on a release handler waiting on a process the
          daemon was already waiting on. Reaping is [Eio.Process.spawn ~sw]'s
          own switch hook; this just makes sure there is something to reap. *)
       Eio.Switch.on_release sw (fun () ->
         match entry.lifecycle with
         | Exited_with _ | Released -> ()
         | Running ->
           (try entry.signal_process Sys.sigterm with
            | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
            | _ -> ());
           entry.lifecycle <- Released);
       (* One waiting mechanism, not two. A reaper daemon turns the process
          ending into the same condition broadcast that arriving bytes are, so
          [wait] never calls [Eio.Process.await] on the caller's fiber -- which
          is what made a 0.05s bound take 60s: the await was not interrupted by
          the timeout around it. *)
       Eio.Fiber.fork_daemon ~sw (fun () ->
         (match entry.await_status () with
          | status ->
            (match entry.lifecycle with
             | Running -> entry.lifecycle <- Exited_with status
             | Exited_with _ | Released -> ())
          (* Cancellation is how this daemon is meant to end. Swallowing it
             leaves the switch waiting on a fiber that has already agreed to
             stop, which is a hang rather than a slow teardown. *)
          | exception (Eio.Cancel.Cancelled _ as cancelled) -> raise cancelled
          | exception _ -> ());
         Eio.Condition.broadcast entry.changed;
         `Stop_daemon);
       Eio.Fiber.fork_daemon ~sw (fun () ->
         drain ~flow:stdout_r ~buffer:entry.stdout ~limit:registry.limit
           ~changed:entry.changed);
       Eio.Fiber.fork_daemon ~sw (fun () ->
         drain ~flow:stderr_r ~buffer:entry.stderr ~limit:registry.limit
           ~changed:entry.changed);
       let handle = Spawn_handle.issue registry.issuer in
       Hashtbl.replace registry.entries (Spawn_handle.to_string handle) entry;
       Ok handle)
;;

let entry_of registry handle = Hashtbl.find_opt registry.entries (Spawn_handle.to_string handle)

let with_entry registry handle f =
  match entry_of registry handle with
  | None -> Error `Unknown_handle
  | Some entry -> Ok (f entry)
;;

let read registry handle ~stream ~from =
  with_entry registry handle (fun entry -> read_buffer (buffer_of entry stream) ~from)
;;

let stop registry handle =
  with_entry registry handle (fun entry ->
    match entry.lifecycle with
    | Exited_with _ | Released -> ()
    | Running ->
      (try entry.signal_process Sys.sigterm with
       | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
       | _ -> ()))
;;

let is_running registry handle =
  with_entry registry handle (fun entry ->
    match entry.lifecycle with
    | Running -> true
    | Exited_with _ | Released -> false)
;;

let wait registry handle ~until ~timeout_sec =
  match entry_of registry handle with
  | None -> Error `Unknown_handle
  | Some entry ->
    (match Process_eio.get_clock () with
     | Error _ -> Error `Timed_out
     | Ok clock ->
       let awaited () =
         match until with
         | Exit ->
           (* The process ending does not mean its pipes are read, so this
              waits for the status *and* for both drains to reach EOF. A caller
              handed a status that says "complete" beside a truncated tail
              would have no way to tell. *)
           Eio.Condition.loop_no_mutex entry.changed (fun () ->
             match entry.lifecycle with
             | Exited_with status when entry.stdout.at_eof && entry.stderr.at_eof ->
               Some (Exited status)
             (* Signalled by the switch: that is what ended it, and saying so
                is more honest than reporting a status nobody observed. *)
             | Released -> Some (Exited (Unix.WSIGNALED Sys.sigterm))
             | Exited_with _ | Running -> None)
         | Output_contains { stream; needle } ->
           let buffer = buffer_of entry stream in
           Eio.Condition.loop_no_mutex entry.changed (fun () ->
             match match_end buffer ~needle with
             | Some offset -> Some (Matched offset)
             | None -> if buffer.at_eof then Some (Matched (stream_end buffer)) else None)
       in
       (try Ok (Eio.Time.with_timeout_exn clock timeout_sec awaited) with
        | Eio.Time.Timeout -> Error `Timed_out))
;;
