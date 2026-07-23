(* dispatch_state unit tests for PR #22964 *)
open Masc

module Tf = Keeper_chat_consumer.For_testing

let failures = ref 0

let check n c =
  if c
  then Printf.printf "PASS %s\n%!" n
  else (
    incr failures;
    Printf.printf "FAIL %s\n%!" n)
;;

let run () =
  Tf.reset_wake_inbox ();
  Tf.notify_transition ~keeper_name:"wake-a";
  Tf.notify_transition ~keeper_name:"wake-a";
  check
    "duplicate pending wakes coalesce"
    (Tf.take_wake_nonblocking () = Some "wake-a");
  check "coalesced wake is unique" (Tf.take_wake_nonblocking () = None);
  let s = Tf.create_dispatch_state ~base_path:(Sys.getcwd ()) in
  check "fresh" (not (Tf.is_dispatching s "a"));
  check "mark" (Tf.mark_dispatching s "a");
  check "is" (Tf.is_dispatching s "a");
  check "dup" (not (Tf.mark_dispatching s "a"));
  Tf.finish_dispatching_and_reschedule s "a";
  check "clear" (not (Tf.is_dispatching s "a"));
  check
    "wake during dispatch schedules one rerun"
    (Tf.take_wake_nonblocking () = Some "a");
  check "dispatch rerun is unique" (Tf.take_wake_nonblocking () = None);
  check "b_independent" (not (Tf.is_dispatching s "b"));
  ignore (Tf.mark_dispatching s "b");
  check "b_marked" (Tf.is_dispatching s "b");
  Tf.clear_dispatching s "nonexistent";
  check "noop" true;
  Tf.reset_wake_inbox ();
  if !failures > 0 then exit 1 else Printf.printf "All tests passed.\n%!"
;;

let () = Eio_main.run (fun _env -> run ())
