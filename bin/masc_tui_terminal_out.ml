(* Every byte the TUI sends to its terminal goes through here, in order. A
   system thread does the blocking write; the UI only appends.

   The UI used to write and flush stdout itself. A terminal that stopped
   reading its pty for a while held that write, and with it the whole UI
   domain: input, async results and the observer queue all waited (a live
   terminal stalled up to 191s, every sampled second spent in write(2),
   2026-11-17).

   No mutex guards the queue. Ctrl-Z runs the suspend handler at the next
   poll point of whatever the UI was doing, and that handler drains this
   queue; a lock the interrupted code held would refuse the handler. Chunks
   go on an atomic list instead, and the writer is woken by a binary
   semaphore.

   The writer thread blocks every signal the TUI handles. A handler runs on
   whichever thread reaches a poll point first; run on the writer, suspend
   would wait in [drain] for the writer itself, and a release inside the
   semaphore's own acquire would lock a mutex its thread already holds. *)

(* Newest first. *)
let queued : string list Atomic.t = Atomic.make []
let writing = Atomic.make false
let wake = Semaphore.Binary.make false
let started = Atomic.make false
let lost = Atomic.make false

(* How many write(2) calls have returned bytes. [drain] reads it to tell a
   terminal that reads slowly from one that reads nothing. *)
let progress = Atomic.make 0

(* [progress] when the last [drain] gave up, if the terminal has taken
   nothing since: it is still not reading. *)
let stalled_at : int option Atomic.t = Atomic.make None

let handled_signals =
  [ Sys.sigtstp; Sys.sigcont; Sys.sigint; Sys.sigterm; Sys.sighup; Sys.sigquit
  ; Sys.sigwinch ]

(* One write(2) per call: [Unix.write_substring] repeats the call inside
   until every byte is written, so a terminal reading a large batch slowly
   would show no progress until the whole batch was through. *)
let rec write_all fd bytes offset =
  if offset < String.length bytes then
    match Unix.single_write_substring fd bytes offset (String.length bytes - offset) with
    | written ->
        Atomic.incr progress;
        write_all fd bytes (offset + written)
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> write_all fd bytes offset

(* [writing] is set before the queue is taken and cleared only once a take
   finds it empty, so [behind] never reads false while bytes are in hand.

   A write that fails drops the rest of its batch and marks the screen lost,
   so the next frame repaints in full rather than diffing against rows the
   terminal never received. Nothing escapes the loop: a writer that died
   would leave [behind] true for good, which skips every frame and hangs
   [drain] at exit. *)
let rec writer () =
  Semaphore.Binary.acquire wake;
  let rec take () =
    Atomic.set writing true;
    match Atomic.exchange queued [] with
    | [] -> Atomic.set writing false
    | chunks ->
        (match write_all Unix.stdout (String.concat "" (List.rev chunks)) 0 with
         | () -> ()
         | exception _ ->
             Atomic.set lost true;
             Masc_tui_wake.(ring loop Terminal_write_lost));
        take ()
  in
  take ();
  writer ()

let start () =
  if Atomic.compare_and_set started false true then
    begin
      (* Set by the creator around [Thread.create], so the writer never
         reaches a poll point with these signals open. *)
      let previous = Thread.sigmask Unix.SIG_BLOCK handled_signals in
      Fun.protect
        ~finally:(fun () -> ignore (Thread.sigmask Unix.SIG_SETMASK previous))
        (fun () -> ignore (Thread.create writer ()))
    end

let rec push text =
  let current = Atomic.get queued in
  if not (Atomic.compare_and_set queued current (text :: current)) then push text

let write text =
  if String.length text > 0 then begin
    start ();
    push text
  end

let flush () =
  if Atomic.get started then Semaphore.Binary.release wake

(* [queued] before [writing]: the writer sets [writing] before it empties
   the queue, so bytes leaving [queued] are always seen in [writing]. *)
let behind () = Atomic.get queued <> [] || Atomic.get writing

let take_lost () = Atomic.exchange lost false

(* Polled rather than waited on: a wait would need the lock the comment
   above keeps out. It runs only when the terminal changes hands. *)
let drain_poll_s = 0.002

type drained =
  | Drained
  | Abandoned

(* A terminal that reads takes a whole frame in milliseconds: the largest
   frame of the 43-screen idle sweep, 17 KB, flushed in 15 ms (2026-11-20).
   One that takes nothing for a second has stopped reading; a TUI that
   waited on it never exited, even on SIGTERM (#52897).

   The limit runs from the terminal's last read, so a slow reader still
   gets everything. Exit drains three times (the main loop's restore, the
   exit restore, the farewell); a terminal still stuck since the last give-up
   is given up on at once, so exit ends within one limit. *)
let handoff_limit_s = 1.0

let abandon () =
  ignore (Atomic.exchange queued []);
  Atomic.set lost true;
  Atomic.set stalled_at (Some (Atomic.get progress));
  Abandoned

let drain ~within_s =
  flush ();
  let still_stuck () = Atomic.get stalled_at = Some (Atomic.get progress) in
  let rec wait ~seen ~deadline =
    if not (behind ()) then begin
      Atomic.set stalled_at None;
      Drained
    end
    else
      let now = Masc_tui_wake.Mono.now () in
      let current = Atomic.get progress in
      if current <> seen then
        wait ~seen:current ~deadline:(Masc_tui_wake.Mono.after now within_s)
      else if Masc_tui_wake.Mono.compare now deadline >= 0 then abandon ()
      else begin
        Thread.delay drain_poll_s;
        wait ~seen ~deadline
      end
  in
  if behind () && still_stuck () then abandon ()
  else
    wait ~seen:(Atomic.get progress)
      ~deadline:Masc_tui_wake.Mono.(after (now ()) within_s)
