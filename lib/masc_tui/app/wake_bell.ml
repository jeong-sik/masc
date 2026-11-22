type source =
  | Ui_bus
  | Resize
  | Interrupt
  | Terminate

let all_sources = [ Ui_bus; Resize; Interrupt; Terminate ]

let equal_source a b =
  match a, b with
  | Ui_bus, Ui_bus
  | Resize, Resize
  | Interrupt, Interrupt
  | Terminate, Terminate ->
      true
  | Ui_bus, (Resize | Interrupt | Terminate)
  | Resize, (Ui_bus | Interrupt | Terminate)
  | Interrupt, (Ui_bus | Resize | Terminate)
  | Terminate, (Ui_bus | Resize | Interrupt) ->
      false

let bit_of_source = function
  | Ui_bus -> 0
  | Resize -> 1
  | Interrupt -> 2
  | Terminate -> 3

let mask_of_source source = 1 lsl bit_of_source source

let sources_of_mask mask =
  if mask = 0 then []
  else List.filter (fun src -> mask land mask_of_source src <> 0) all_sources

(* Pre-allocated 1-byte buffer so POSIX signal handlers perform zero heap
   allocations when nudging the self-pipe. *)
let signal_byte = Bytes.make 1 '\001'

type t = {
  bits : int Atomic.t;
  changed : Eio.Condition.t;
  pipe_w : Unix.file_descr option Atomic.t;
}

let create () =
  {
    bits = Atomic.make 0;
    changed = Eio.Condition.create ();
    pipe_w = Atomic.make None;
  }

let atomic_or cell wanted =
  let rec loop () =
    let before = Atomic.get cell in
    let after = before lor wanted in
    if before = after then ()
    else if not (Atomic.compare_and_set cell before after) then loop ()
  in
  loop ()

let close_quiet fd =
  match Unix.close fd with
  | () -> ()
  | exception Unix.Unix_error _ -> ()

let attach_signal_pipe ~sw t =
  Eio.Switch.check sw;
  match Atomic.get t.pipe_w with
  | Some _ -> ()
  | None -> (
      let r_fd, w_fd = Unix.pipe ~cloexec:true () in
      Unix.set_nonblock r_fd;
      Unix.set_nonblock w_fd;
      if not (Atomic.compare_and_set t.pipe_w None (Some w_fd)) then begin
        close_quiet r_fd;
        close_quiet w_fd
      end
      else begin
        Eio.Switch.on_release sw (fun () ->
            Atomic.set t.pipe_w None;
            close_quiet w_fd;
            close_quiet r_fd);
        let buf = Bytes.create 64 in
        let rec drain_fd () =
          match Unix.read r_fd buf 0 64 with
          | 0 -> `Eof
          | _ -> drain_fd ()
          | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) ->
              `Ok
          | exception Unix.Unix_error (Unix.EINTR, _, _) -> drain_fd ()
          | exception Unix.Unix_error _ -> `Eof
        in
        Eio.Fiber.fork_daemon ~sw (fun () ->
            let rec loop () =
              Eio.Switch.check sw;
              match Eio_unix.await_readable r_fd with
              | () -> (
                  match drain_fd () with
                  | `Eof -> `Stop_daemon
                  | `Ok ->
                      Eio.Condition.broadcast t.changed;
                      loop ())
              | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
              | exception (Unix.Unix_error _ | Eio.Io _) -> `Stop_daemon
            in
            loop ())
      end)

let ring t source =
  atomic_or t.bits (mask_of_source source);
  Eio.Condition.broadcast t.changed

let ring_from_signal t source =
  atomic_or t.bits (mask_of_source source);
  match Atomic.get t.pipe_w with
  | None -> ()
  | Some fd -> (
      match Unix.single_write fd signal_byte 0 1 with
      | _ -> ()
      | exception Unix.Unix_error _ -> ())

let peek_mask t = Atomic.get t.bits
let is_rung t = Atomic.get t.bits <> 0
let drain_mask t = Atomic.exchange t.bits 0
let drain t = sources_of_mask (drain_mask t)

let await t =
  Eio.Condition.loop_no_mutex t.changed (fun () ->
      if Atomic.get t.bits = 0 then None else Some ())

let nanoseconds_per_second = 1e9

let await_until_ns ~clock ~now_ns ~deadline_ns t =
  if is_rung t then `Woken
  else
    match deadline_ns with
    | None ->
        await t;
        `Woken
    | Some target_ns ->
        let remaining_ns = Int64.sub target_ns now_ns in
        if Int64.compare remaining_ns 0L <= 0 then `Timeout
        else
          let delay_s = Int64.to_float remaining_ns /. nanoseconds_per_second in
          Eio.Fiber.first
            (fun () ->
              await t;
              `Woken)
            (fun () ->
              Eio.Time.sleep clock delay_s;
              `Timeout)
