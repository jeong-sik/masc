#!/usr/bin/env python3
"""Compile only the verbatim private writer with real Eio; no Dune/full linkage."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
source = (root / 'lib/backend/backend.ml').read_text()
writer = source.split('  let save_payload path content =', 1)[1].split('\n  (** Get value', 1)[0]
header = r'''
let write_hook = Atomic.make (fun () -> ())
let write_count = Atomic.make 0
let write_limit = Atomic.make None
let interrupt_once = Atomic.make false
let fail_write = Atomic.make None
module Unix = struct
  include Unix
  let write_substring fd bytes offset length =
    Atomic.incr write_count;
    (Atomic.get write_hook) ();
    if Atomic.exchange interrupt_once false then raise (Unix_error (EINTR, "write", "probe"));
    match Atomic.get fail_write with
    | Some error -> raise (Unix_error (error, "write", "probe"))
    | None ->
      match Atomic.get write_limit with
      | Some 0 -> 0
      | limit ->
        let length = match limit with None -> length | Some n -> min n length in
        Unix.write_substring fd bytes offset length
end
module Payload = struct
  let save_payload path content =
'''
footer = r'''
end
let check label value = if not value then failwith label
let reset () =
  Atomic.set write_hook (fun () -> ()); Atomic.set write_limit None;
  Atomic.set write_count 0; Atomic.set interrupt_once false; Atomic.set fail_write None
let count = ref 0
let case label fn = reset (); fn (); incr count; Printf.printf "PASS %s\n%!" label
let () =
  Eio_main.run @@ fun env ->
  let root = Sys.argv.(1) in
  let path = Eio.Path.(Eio.Stdenv.fs env / root / "payload") in
  let native_path = Filename.concat root "payload" in
  let main_thread = Thread.id (Thread.self ()) in
  let write bytes = Payload.save_payload path bytes in
  let read () = Eio.Path.load path in
  case "empty bytes and zero write syscalls" (fun () ->
    write ""; check "empty read" (read () = ""); check "no writes" (Atomic.get write_count = 0));
  case "UTF-8 and binary bytes round trip" (fun () ->
    let bytes = "\000한글🙂\255\000" in write bytes; check "bytes" (read () = bytes));
  case "multi-megabyte bytes round trip" (fun () ->
    let bytes = String.init (2 * 1024 * 1024 + 13) (fun n -> Char.chr (n mod 256)) in
    write bytes; check "bytes" (read () = bytes));
  case "short writes and EINTR preserve every byte" (fun () ->
    Atomic.set write_limit (Some 3); Atomic.set interrupt_once true;
    let bytes = "short writes and interruption" in write bytes;
    check "bytes" (read () = bytes); check "multiple calls" (Atomic.get write_count > 2));
  case "zero write fails once with EIO" (fun () ->
    Atomic.set write_limit (Some 0);
    (match write "data" with
    | () -> failwith "accepted zero write"
    | exception Unix.Unix_error (Unix.EIO, _, _) -> ());
    check "no retry" (Atomic.get write_count = 1));
  case "ENOSPC propagates once" (fun () ->
    Atomic.set fail_write (Some Unix.ENOSPC);
    (match write "data" with
    | () -> failwith "accepted ENOSPC"
    | exception Unix.Unix_error (Unix.ENOSPC, _, _) -> ());
    check "no retry" (Atomic.get write_count = 1));
  case "scheduler runs while payload syscall is held" (fun () ->
    let entered, enter = Eio.Promise.create () in
    let gate = Mutex.create () and condition = Condition.create () in
    let released = ref false in
    let release () = Mutex.protect gate (fun () -> released := true; Condition.broadcast condition) in
    Atomic.set write_hook (fun () ->
      check "writer stayed on main scheduler" (Thread.id (Thread.self ()) <> main_thread);
      Eio.Promise.resolve enter ();
      Mutex.protect gate (fun () -> while not !released do Condition.wait condition gate done));
    let returned = ref false in
    Eio.Fiber.both
      (fun () -> write "held payload"; returned := true)
      (fun () ->
        Eio.Promise.await entered;
        Fun.protect ~finally:release (fun () ->
          check "writer returned before syscall" (not !returned);
          Eio.Fiber.yield ();
          check "writer still held" (not !returned)));
    check "completed after release" !returned;
    check "bytes" (read () = "held payload"));
  case "caller cancellation joins the active write" (fun () ->
    let entered, enter = Eio.Promise.create () in
    let context, give_context = Eio.Promise.create () in
    let gate = Mutex.create () and condition = Condition.create () in
    let released = ref false in
    let finished = Atomic.make false in
    let release () = Mutex.protect gate (fun () -> released := true; Condition.broadcast condition) in
    Atomic.set write_hook (fun () ->
      Eio.Promise.resolve enter ();
      Mutex.protect gate (fun () -> while not !released do Condition.wait condition gate done);
      Atomic.set finished true);
    let cancelled = ref false in
    (Eio.Switch.run @@ fun sw ->
    Eio.Fiber.fork ~sw (fun () ->
      try Eio.Cancel.sub (fun cc ->
        Eio.Promise.resolve give_context cc;
        write "cancelled payload";
        check "returned before worker finished" (Atomic.get finished);
        Eio.Fiber.check ())
      with Eio.Cancel.Cancelled _ ->
        check "cancel observed before worker finished" (Atomic.get finished);
        cancelled := true);
    Eio.Promise.await entered;
    Fun.protect ~finally:release (fun () ->
      Eio.Cancel.cancel (Eio.Promise.await context) Exit;
      Eio.Fiber.yield ();
      check "returned before release" (not !cancelled));
    Eio.Fiber.yield ());
    check "caller observed cancellation" !cancelled;
    check "completed payload before cancellation" (read () = "cancelled payload"));
  reset ();
  Unix.unlink native_path;
  Printf.printf "TOTAL %d PASS; source extraction, not full Backend linkage\n%!" !count
'''
with tempfile.TemporaryDirectory(prefix='masc-backend-payload-') as directory:
    scratch = Path(directory)
    unit = scratch / 'probe.ml'
    unit.write_text(header + writer + footer)
    command = ['opam', 'exec', '--switch=5.5.1', '--', 'ocamlfind', 'ocamlopt', '-thread',
               '-package', 'eio_main,eio.unix', '-linkpkg', '-o', str(scratch / 'probe'), str(unit)]
    subprocess.run(command, check=True)
    result = subprocess.run([str(scratch / 'probe'), directory], text=True, capture_output=True)
    print(result.stdout, end='')
    print(result.stderr, end='')
    result.check_returncode()
