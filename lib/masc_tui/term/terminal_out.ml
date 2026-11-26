module Mono = Masc_tui_core.Clock.Mono

let queued : string list Atomic.t = Atomic.make []
let writing = Atomic.make false
let wake = Semaphore.Binary.make false
let started = Atomic.make false
let lost = Atomic.make false
let progress = Atomic.make 0
let stalled_at : int option Atomic.t = Atomic.make None
let shutting_down = Atomic.make false
let on_write_lost : (unit -> unit) Atomic.t = Atomic.make (fun () -> ())

let set_on_write_lost fn = Atomic.set on_write_lost fn

let handled_signals =
  [
    Sys.sigtstp;
    Sys.sigcont;
    Sys.sigint;
    Sys.sigterm;
    Sys.sighup;
    Sys.sigquit;
    Sys.sigwinch;
  ]

let select_slice_s = 0.05
let frame_stall_limit_s = 2.0
let shutdown_stall_limit_s = 0.5

let rec wait_writable ~fd ~deadline =
  let now = Mono.now () in
  let remaining_s = Mono.seconds_since deadline ~since:now in
  if remaining_s <= 0.0 then Error Unix.EAGAIN
  else
    let timeout = Float.min select_slice_s remaining_s in
    match Unix.select [] [ fd ] [] timeout with
    | _, _ :: _, _ -> Ok ()
    | _, [], _ ->
        if Mono.compare (Mono.now ()) deadline >= 0 then Error Unix.EAGAIN
        else wait_writable ~fd ~deadline
    | exception Unix.Unix_error (Unix.EINTR, _, _) ->
        wait_writable ~fd ~deadline
    | exception Unix.Unix_error (err, _, _) -> Error err

let write_all_fd ?(stall_limit_s = frame_stall_limit_s) ?on_progress fd bytes =
  let limit =
    if Float.is_finite stall_limit_s then Float.max 0.01 stall_limit_s
    else frame_stall_limit_s
  in
  let len = String.length bytes in
  let rec loop offset deadline =
    if offset >= len then Ok ()
    else
      match Unix.single_write_substring fd bytes offset (len - offset) with
      | written when written > 0 ->
          (match on_progress with Some fn -> fn () | None -> ());
          let next_deadline = Mono.after_s (Mono.now ()) limit in
          loop (offset + written) next_deadline
      | _ -> (
          (* 0-byte write on non-blocking fd: treat like EAGAIN and wait. *)
          match wait_writable ~fd ~deadline with
          | Ok () -> loop offset deadline
          | Error _ as err -> err)
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop offset deadline
      | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> (
          match wait_writable ~fd ~deadline with
          | Ok () -> loop offset deadline
          | Error _ as err -> err)
      | exception Unix.Unix_error (err, _, _) -> Error err
  in
  loop 0 (Mono.after_s (Mono.now ()) limit)

let notify_write_lost () =
  Atomic.set lost true;
  match (Atomic.get on_write_lost) () with
  | () -> ()
  | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
  | exception Thread.Exit -> raise Thread.Exit
  | exception ex -> ignore ex

let rec writer () =
  Semaphore.Binary.acquire wake;
  (try
     Fun.protect
       ~finally:(fun () -> Atomic.set writing false)
       (fun () ->
         let rec take () =
           Atomic.set writing true;
           match Atomic.exchange queued [] with
           | [] -> Atomic.set writing false
           | chunks ->
               let payload = String.concat "" (List.rev chunks) in
               let stall_limit_s =
                 if Atomic.get shutting_down then shutdown_stall_limit_s
                 else frame_stall_limit_s
               in
               (match
                  write_all_fd ~stall_limit_s
                    ~on_progress:(fun () -> Atomic.incr progress)
                    Unix.stdout payload
                with
                | Ok () -> ()
                | Error _ -> notify_write_lost ());
               take ()
         in
         take ())
   with
   | Eio.Cancel.Cancelled _ as ex -> raise ex
   | Thread.Exit -> raise Thread.Exit
   | ex ->
       ignore ex;
       Atomic.set writing false;
       notify_write_lost ();
       Thread.delay 0.05);
  writer ()

let start () =
  if Atomic.compare_and_set started false true then begin
    let previous = Thread.sigmask Unix.SIG_BLOCK handled_signals in
    Fun.protect
      ~finally:(fun () -> ignore (Thread.sigmask Unix.SIG_SETMASK previous))
      (fun () -> ignore (Thread.create writer ()))
  end

let rec push text =
  let current = Atomic.get queued in
  if not (Atomic.compare_and_set queued current (text :: current)) then
    push text

let write text =
  if String.length text > 0 then begin
    start ();
    push text
  end

let flush () = if Atomic.get started then Semaphore.Binary.release wake
let behind () = Atomic.get queued <> [] || Atomic.get writing
let take_lost () = Atomic.exchange lost false

let drain_poll_s = 0.002

type drained =
  | Drained
  | Abandoned

let handoff_limit_s = 1.0

let abandon () =
  ignore (Atomic.exchange queued []);
  Atomic.set lost true;
  Atomic.set stalled_at (Some (Atomic.get progress));
  Abandoned

let drain ~within_s =
  flush ();
  let still_stuck () =
    Option.equal Int.equal (Atomic.get stalled_at) (Some (Atomic.get progress))
  in
  let rec wait ~seen ~deadline =
    if not (behind ()) then begin
      Atomic.set stalled_at None;
      Drained
    end
    else
      let now = Mono.now () in
      let current = Atomic.get progress in
      if current <> seen then
        wait ~seen:current ~deadline:(Mono.after_s now within_s)
      else if Mono.compare now deadline >= 0 then abandon ()
      else begin
        Thread.delay drain_poll_s;
        wait ~seen ~deadline
      end
  in
  if behind () && still_stuck () then abandon ()
  else wait ~seen:(Atomic.get progress) ~deadline:(Mono.after_s (Mono.now ()) within_s)

type keyboard = Legacy | Kitty | Xterm

let enter_screen_seq ~keyboard ~mouse ~bracketed_paste =
  let buf = Buffer.create 64 in
  Buffer.add_string buf "\x1b[?1049h\x1b[?25l\x1b[?1004h";
  if bracketed_paste then Buffer.add_string buf "\x1b[?2004h";
  if mouse then Buffer.add_string buf "\x1b[?1000h\x1b[?1002h\x1b[?1006h";
  (match keyboard with
  | Legacy -> ()
  | Kitty -> Buffer.add_string buf Input_decoder.enable_kitty_keyboard
  | Xterm -> Buffer.add_string buf "\x1b[>4;2m");
  Buffer.contents buf

let leave_screen_seq ~keyboard =
  let buf = Buffer.create 64 in
  (match keyboard with
  | Legacy -> ()
  | Kitty -> Buffer.add_string buf Input_decoder.disable_kitty_keyboard
  | Xterm -> Buffer.add_string buf "\x1b[>4;0m");
  Buffer.add_string buf
    "\x1b[?1004l\x1b[?2004l\x1b[?1006l\x1b[?1002l\x1b[?1000l\x1b[?7h\x1b[0m\x1b[0 q\x1b[?25h\x1b[?1049l";
  Buffer.contents buf

let install_switch_teardown ~sw ~keyboard ?on_after_drain () =
  Atomic.set shutting_down false;
  Eio.Switch.on_release sw (fun () ->
      Atomic.set shutting_down true;
      write (leave_screen_seq ~keyboard);
      ignore (drain ~within_s:handoff_limit_s : drained);
      Atomic.set shutting_down false;
      match on_after_drain with
      | Some fn -> fn ()
      | None -> ())
