(** Terminal input effect boundary. The byte decoder remains pure and separate. *)

module Render_schedule = Masc_tui_render_schedule

let nanoseconds_per_second = 1_000_000_000.0

(* Bytes the terminal has delivered that the reader has not served yet.

   One [Unix.read] per byte is one syscall per character, which is invisible
   while a person types and expensive the moment they do not: a paste is
   thousands of bytes arriving at once, and the terminal hands them over in
   one read whether or not this asks for them one at a time.

   The unserved tail is also the pushback: an invalid UTF-8 continuation has
   to leave the byte it rejected for the next key. [last_source] steps back
   either the terminal probe's replay or [position], with no second reader for
   a byte to hide in. *)
type input_source =
  | Probe_replay
  | Terminal_buffer

(* When the paste the decoder holds last received a byte, and whether one
   Ctrl-C already asked it to wait. Whether a paste is active at all is the
   decoder's state; this is only the clock the Ctrl-C recovery reads. *)
type paste_clock = {
  mutable last_byte_ns : int64;
  mutable cancel_armed : bool;
}

(* A paste can only be active or draining its quarantined tail. Derived from
   the decoder on every read, never stored. *)
type paste_phase =
  | No_paste
  | Pasting of paste_clock
  | Draining_tail of paste_clock

type input_reader = {
  bytes : Bytes.t;
  mutable filled : int;
  mutable position : int;
  mutable terminal_probe : Masc_tui_terminal_probe.decoder option;
  mutable late_palette_publisher :
    (Masc_tui_terminal_palette.t -> unit) option;
  mutable last_source : input_source option;
  decoder : Masc_tui_input_decoder.t;
  queued : Masc_tui_input_decoder.event Queue.t;
      (** Events one byte produced beyond the first; served before any read. *)
  paste_clock : paste_clock;
}

(* One terminal read. Bigger than any escape sequence and big enough that a
   pasted screenful arrives whole; a paste larger than this is read in as many
   passes as it takes, which is the same loop either way. *)
let input_buffer_bytes = 8192

let create_input_reader () =
  {
    bytes = Bytes.create input_buffer_bytes;
    filled = 0;
    position = 0;
    terminal_probe = None;
    late_palette_publisher = None;
    last_source = None;
    decoder = Masc_tui_input_decoder.create ();
    queued = Queue.create ();
    paste_clock = { last_byte_ns = 0L; cancel_armed = false };
  }

let paste_phase reader =
  match Masc_tui_input_decoder.pending reader.decoder with
  | Some Masc_tui_input_decoder.Pasting -> Pasting reader.paste_clock
  | Some Masc_tui_input_decoder.Draining -> Draining_tail reader.paste_clock
  | Some
      ( Masc_tui_input_decoder.Prefix | Masc_tui_input_decoder.Sequence
      | Masc_tui_input_decoder.Character )
  | None ->
      No_paste

(* Both sources can hold bytes already read from the terminal. A character
   the decoder holds is awaiting more input, so it must not defer a frame. *)
let input_reader_has_pending_bytes reader =
  (not (Queue.is_empty reader.queued))
  || reader.position < reader.filled
  || match reader.terminal_probe with
     | None -> false
     | Some decoder -> Masc_tui_terminal_probe.has_replay decoder

(* Whether the terminal has bytes for us, waited for inside Eio rather than
   in the kernel.

   [Unix.select] blocks the whole domain, not one fiber. Every fiber waiting
   on a socket then advances only when this loop comes back round, so a reply
   costs the number of steps it takes times what one pass of the loop costs.
   That is how a request the server answers in milliseconds reached the
   ten-second timeout: measured with masc-http-probe, the same 1.8 MB read
   takes 5.5 seconds beside a loop that waits this way and 26 ms beside one
   that waits through Eio (RFC-0429 §3.0). Waiting through Eio takes this
   fiber out of the run queue, and those fibers run until they block in turn.

   Only the readiness wait races the deadline. The read below is never
   cancelled, so no keystroke is taken from the terminal and then dropped
   with the losing fiber -- which is what racing the read itself would risk.

   A wait with no time left has nothing to register: asking Eio for one would
   cancel it in the same breath, and the kernel answers that question without
   blocking anyway. *)
let terminal_has_bytes ~remaining =
  let kernel_wait seconds =
    match Unix.select [ Unix.stdin ] [] [] seconds with
    | ready, _, _ -> ready <> []
  in
  if remaining <= 0.0 then kernel_wait 0.0
  else
    match (Eio_guard.is_eio_fiber (), Eio_context.get_clock_opt ()) with
    | true, Some clock ->
        Eio.Fiber.first
          (fun () ->
            Eio_unix.await_readable Unix.stdin;
            true)
          (fun () ->
            Eio.Time.sleep clock remaining;
            false)
    | true, None | false, _ ->
        (* The startup terminal probe reads through this same reader from
           inside [Eio_guard.run_in_systhread], where an Eio effect has no
           handler. The kernel wait is the right one there for the same
           reason the probe runs on a thread at all: blocking a system
           thread does not stop the domain. *)
        kernel_wait remaining

(* A read buffer can end while the next chunk already waits in the kernel.
   Include readiness without consuming input, so a long burst is coalesced
   across buffer boundaries too. EINTR means readiness was not observed;
   defer at most to the existing frame deadline and let the reader retry. *)
let input_reader_has_ready_input reader =
  input_reader_has_pending_bytes reader
  || try terminal_has_bytes ~remaining:0.0 with
     | Unix.Unix_error (Unix.EINTR, _, _) -> true

let refill_input_reader reader ~timeout =
  let timeout_ns =
    Int64.of_float (max 0.0 timeout *. nanoseconds_per_second)
  in
  let poll remaining =
    match terminal_has_bytes ~remaining with
    | true -> (
        match
          Unix.read Unix.stdin reader.bytes 0 (Bytes.length reader.bytes)
        with
        | count when count > 0 -> Render_schedule.Input_wait.Ready count
        | _ -> Render_schedule.Input_wait.Timed_out
        | exception Unix.Unix_error (Unix.EINTR, _, _) ->
            Render_schedule.Input_wait.Interrupted)
    | false -> Render_schedule.Input_wait.Timed_out
    | exception Unix.Unix_error (Unix.EINTR, _, _) ->
        Render_schedule.Input_wait.Interrupted
  in
  match
    Render_schedule.Input_wait.await ~now_ns:Mtime_clock.elapsed_ns ~timeout_ns
      ~poll
  with
  | Some count ->
      reader.filled <- count;
      reader.position <- 0;
      true
  | None -> false

let take_terminal_buffer_byte reader ~timeout =
  if
    reader.position >= reader.filled && not (refill_input_reader reader ~timeout)
  then None
  else begin
    let byte = Bytes.get reader.bytes reader.position in
    reader.position <- reader.position + 1;
    Some byte
  end

let take_late_palette_publisher reader =
  match reader.late_palette_publisher with
  | None -> None
  | Some publish ->
    reader.late_palette_publisher <- None;
    Some publish
;;

let publish_late_terminal_palette reader decoder =
  (* The page the terminal reports is not the palette and does not wait on
     it: a multiplexer answers DECSET 996 and no OSC colour query, so this is
     the only thing that ever arrives there. Published on its own so a colour
     that has to know which way to move can still be told. *)
  (match Masc_tui_terminal_probe.theme_mode decoder with
   | None -> ()
   | Some _ as theme_mode ->
     if
       Masc_tui_terminal_palette.snapshot_theme_mode
         (Masc_tui_terminal_palette.snapshot ())
       <> theme_mode
     then Masc_tui_terminal_palette.set_theme_mode theme_mode);
  match reader.late_palette_publisher with
  | None -> ()
  | Some _ ->
    (match Masc_tui_terminal_probe.palette decoder with
     | None -> ()
     | Some palette ->
       (match take_late_palette_publisher reader with
        | None -> ()
        | Some publish -> publish palette))
;;

let install_late_palette_publisher reader ~request_full_repaint =
  reader.late_palette_publisher <-
    Some
      (fun palette ->
        Masc_tui_terminal_palette.set_current (Some palette);
        request_full_repaint 0)
;;

let take_input_byte reader ~timeout =
  let timeout_ns =
    Int64.of_float (max 0.0 timeout *. nanoseconds_per_second)
  in
  let deadline_ns = Int64.add (Mtime_clock.elapsed_ns ()) timeout_ns in
  let terminal_byte () =
    let remaining_ns =
      Int64.sub deadline_ns (Mtime_clock.elapsed_ns ())
    in
    take_terminal_buffer_byte reader
      ~timeout:
        (if Int64.compare remaining_ns 0L <= 0 then 0.0
         else Int64.to_float remaining_ns /. nanoseconds_per_second)
  in
  match reader.terminal_probe with
  | None ->
    (match terminal_byte () with
     | None ->
       reader.last_source <- None;
       None
     | Some byte ->
       reader.last_source <- Some Terminal_buffer;
       Some byte)
  | Some decoder
    when (not (Masc_tui_terminal_probe.has_replay decoder))
         && Masc_tui_terminal_probe.complete decoder ->
    publish_late_terminal_palette reader decoder;
    reader.terminal_probe <- None;
    (match terminal_byte () with
     | None ->
       reader.last_source <- None;
       None
     | Some byte ->
       reader.last_source <- Some Terminal_buffer;
       Some byte)
  | Some decoder ->
    let next = Masc_tui_terminal_probe.next decoder ~next_raw:terminal_byte in
    publish_late_terminal_palette reader decoder;
    (match next with
     | Some byte ->
       reader.last_source <- Some Probe_replay;
       Some byte
     | None ->
       if
         (not (Masc_tui_terminal_probe.has_replay decoder))
         && Masc_tui_terminal_probe.complete decoder
       then begin
         publish_late_terminal_palette reader decoder;
         reader.terminal_probe <- None
       end;
       reader.last_source <- None;
       None)

(* Give back the byte just taken. Probe replay and the terminal buffer are two
   sources inside this reader, not two readers. The source marker puts an
   invalid UTF-8 continuation back where it came from. *)
let return_input_byte reader =
  (match reader.last_source with
   | Some Probe_replay ->
     Option.iter Masc_tui_terminal_probe.return_replay reader.terminal_probe
   | Some Terminal_buffer -> reader.position <- max 0 (reader.position - 1)
   | None -> ());
  reader.last_source <- None
;;

(* A sequence begun but not finished, wherever this reader holds it: the
   decoder, or the startup probe still in front of it. The probe completes only
   once its replies arrive, so on a terminal without them it stays in front of
   every byte and keeps an [ESC \[ 2 0 0] head in its own buffer as a possible
   paste start. The decoder then never sees the head, and a check of the
   decoder alone showed no notice and let Ctrl-C fall through to the quit
   prompt. Both are asked until the probe becomes a reply consumer (RFC
   tui-single-input-decoder, step 3). *)
let input_holds_incomplete_sequence reader =
  Masc_tui_input_decoder.pending reader.decoder
  = Some Masc_tui_input_decoder.Sequence
  || (match reader.terminal_probe with
      | Some decoder -> Masc_tui_terminal_probe.holds_incomplete_sequence decoder
      | None -> false)

let cancel_incomplete_sequence reader =
  Masc_tui_input_decoder.cancel_pending reader.decoder;
  Option.iter Masc_tui_terminal_probe.discard_incomplete_sequence
    reader.terminal_probe

(* Ctrl-C recovery only snapshots a paste after this much quiet since its
   last byte. Reading itself uses the caller's short render-loop deadline;
   this is a recovery observation, not a blocking terminal read. *)
let paste_quiet_seconds = 0.5
let paste_quiet_ns =
  Int64.of_float (paste_quiet_seconds *. nanoseconds_per_second)

let paste_is_quiet last_byte_ns =
  Int64.compare
    (Int64.sub (Mtime_clock.elapsed_ns ()) last_byte_ns)
    paste_quiet_ns >= 0

(* Check every input source without consuming its next byte. A terminal read
   can already be buffered, and the startup probe can still have replay; a
   clock alone cannot prove that a paused paste has no unread tail. *)
let input_byte_ready reader =
  match take_input_byte reader ~timeout:0.0 with
  | None -> false
  | Some _ ->
      return_input_byte reader;
      true

let paste_can_recover reader clock =
  paste_is_quiet clock.last_byte_ns && not (input_byte_ready reader)

(* A paste is not a key and does not become one. Encoding the payload into
   the key channel would put a second meaning on a string every surface reads
   as a key name, and the caller would have to tell the two apart by looking
   at the text -- the classifier this codebase spent RFC-0042 removing. The
   two kinds travel as two constructors instead, and only the paste path can
   carry text. *)
type input_event =
  | Key of string
  | Pasted of Masc_tui_paste.t
  | Graphics_reply of string
      (** The body of an APC the terminal sent back, between [ESC _ G] and
          [ESC \\]. Only the graphics capability query asks for one -- every
          placement says q=2 -- but a reply that is never read is not silent:
          stdin here is the key stream, so its bytes are typed into whatever
          the operator was writing. Reading it is what keeps that from
          happening, whether or not anyone is waiting for it. *)
  | Mouse_left_press of int * int
  | Mouse_left_release of int * int
      (** [(row, column)] of an unmodified left-button press, 1-based as the
          terminal reported it. Only surfaces that map frame rows to their own
          rows consume one; everywhere else it is inert, like a wheel notch on
          a surface with nothing to scroll. *)
  | Mouse_wheel of Masc.Tui_decode.wheel_direction * int * int
      (** A wheel notch and the [(row, column)] it happened at. The loop
          gives a notch over the Activity pane to the pane and turns every
          other one into the [wheel-up] / [wheel-down] key the surfaces bind,
          so no surface learned a new key when the pane appeared. *)

(* How long a started sequence or character waits for its next byte inside
   one read. A lone ESC is the Escape key once this passes; anything longer
   stays held in the decoder and the next read resumes it. *)
let sequence_byte_wait_seconds = 0.05

let input_event_of_decoded = function
  | Masc_tui_input_decoder.Key name -> Some (Key name)
  | Masc_tui_input_decoder.Paste paste -> Some (Pasted paste)
  | Masc_tui_input_decoder.Mouse_wheel (direction, row, column) ->
      Some (Mouse_wheel (direction, row, column))
  | Masc_tui_input_decoder.Mouse_left_press (row, column) ->
      Some (Mouse_left_press (row, column))
  | Masc_tui_input_decoder.Mouse_left_release (row, column) ->
      Some (Mouse_left_release (row, column))
  | Masc_tui_input_decoder.Reply (Masc_tui_input_decoder.Graphics body) ->
      Some (Graphics_reply body)
  (* The startup probe still reads these while it stands in front. One that
     arrives after it finished was not asked for by anything running now;
     reading it keeps it out of the composer, and step 3 of the RFC gives it a
     consumer. *)
  | Masc_tui_input_decoder.Reply
      ( Masc_tui_input_decoder.Palette _ | Masc_tui_input_decoder.Theme_mode _
      | Masc_tui_input_decoder.Cell_pixels _ ) ->
      None

let in_paste reader =
  match paste_phase reader with
  | Pasting _ | Draining_tail _ -> true
  | No_paste -> false

(** Read one key, one paste, or one thing the terminal said back. *)
let read_input ?(timeout = 0.1) reader () : input_event option =
  (* The reader belongs to this fiber. Keeping it here lets readiness use
     [await_readable] and the Eio timer; moving the whole decoder to a system
     thread also moves buffered keys and every frame-deadline poll there.
     Only readiness races the timer: the consuming Unix.read stays after it. *)
  Eio_guard.with_named_switch "tui-read-key" (fun () ->
      let enqueue decoded =
        List.iter
          (fun event -> Queue.add event reader.queued)
          decoded
      in
      (* Queued events only; an empty queue is the answer, not a reason to
         read again. *)
      let rec drain () =
        match Queue.take_opt reader.queued with
        | None -> None
        | Some decoded -> (
            match input_event_of_decoded decoded with
            | Some event -> Some event
            | None -> drain ())
      in
      let rec serve () =
        match Queue.take_opt reader.queued with
        | Some decoded -> (
            match input_event_of_decoded decoded with
            | Some event -> Some event
            | None -> serve ())
        | None -> read ()
      and read () =
        let wait =
          match Masc_tui_input_decoder.pending reader.decoder with
          (* Not bounded by [timeout]: a frame due now passes 0, and a prefix
             given no time ends as Escape, splitting an arrow into three keys. *)
          | Some Masc_tui_input_decoder.Prefix -> sequence_byte_wait_seconds
          | Some (Masc_tui_input_decoder.Sequence | Masc_tui_input_decoder.Character) ->
              Float.min timeout sequence_byte_wait_seconds
          | Some (Masc_tui_input_decoder.Pasting | Masc_tui_input_decoder.Draining)
          | None ->
              timeout
        in
        match take_input_byte reader ~timeout:wait with
        | None ->
            enqueue (Masc_tui_input_decoder.idle reader.decoder);
            drain ()
        | Some byte ->
            let was_in_paste = in_paste reader in
            let was_pasting =
              Masc_tui_input_decoder.pending reader.decoder
              = Some Masc_tui_input_decoder.Pasting
            in
            enqueue (Masc_tui_input_decoder.feed reader.decoder byte);
            (match paste_phase reader with
             | Pasting clock when not was_pasting ->
                 clock.last_byte_ns <- Mtime_clock.elapsed_ns ();
                 clock.cancel_armed <- false
             | Pasting clock | Draining_tail clock ->
                 clock.last_byte_ns <- Mtime_clock.elapsed_ns ()
             | No_paste -> ());
            if not (Queue.is_empty reader.queued) then serve ()
            else if was_in_paste && not (in_paste reader) then
              (* The end marker of a drained tail: nothing to hand on, and the
                 caller notices the guard lifting. *)
              None
            else if in_paste reader && reader.position >= reader.filled then
              (* Return to the main loop after each terminal read buffer. A
                 sender that never pauses must not hold Ctrl-C or other queued
                 work behind this loop. *)
              None
            else read ()
      in
      serve ())

(* How long to wait for the combined palette and graphics answers. A terminal
   replies as soon as it has parsed a supported query; an unsupported query
   says nothing, and this is the whole cost of finding that out, paid once at
   startup. *)
let terminal_probe_wait_seconds = 0.2

let read_terminal_probe reader ~palette_requested =
  Eio_guard.run_in_systhread ~label:"tui-terminal-probe" (fun () ->
      let decoder =
        Masc_tui_terminal_probe.create ~palette_requested
      in
      let timeout_ns =
        Int64.of_float
          (terminal_probe_wait_seconds *. nanoseconds_per_second)
      in
      let deadline_ns = Int64.add (Mtime_clock.elapsed_ns ()) timeout_ns in
      let bytes_read = ref 0 in
      let finished = ref false in
      while
        (not !finished)
        && !bytes_read < Masc_tui_terminal_probe.max_bytes
        && not (Masc_tui_terminal_probe.complete decoder)
      do
        let remaining_ns =
          Int64.sub deadline_ns (Mtime_clock.elapsed_ns ())
        in
        if Int64.compare remaining_ns 0L <= 0 then finished := true
        else
          match
            take_terminal_buffer_byte reader
              ~timeout:(Int64.to_float remaining_ns /. nanoseconds_per_second)
          with
          | None -> finished := true
          | Some byte ->
            incr bytes_read;
            Masc_tui_terminal_probe.feed decoder byte
      done;
      decoder, Masc_tui_terminal_probe.snapshot decoder)
;;

let install_terminal_probe reader decoder =
  reader.terminal_probe <- Some decoder

let abandon_draining reader =
  Masc_tui_input_decoder.abandon_draining reader.decoder

let recover_paste reader =
  let recovered = Masc_tui_input_decoder.recover_paste reader.decoder in
  reader.paste_clock.last_byte_ns <- Mtime_clock.elapsed_ns ();
  recovered

let cancel_armed clock = clock.cancel_armed

let arm_cancel clock = clock.cancel_armed <- true
