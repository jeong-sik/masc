(* dispatch_state unit tests for PR #22964 *)
open Masc
let failures = ref 0
let check n c = if c then Printf.printf "PASS %s\n%!" n else (incr failures; Printf.printf "FAIL %s\n%!" n)
let tf = Keeper_chat_consumer.For_testing
let () =
  let s = tf.create_dispatch_state () in
  check "fresh" (not (tf.is_dispatching s "a"));
  check "mark" (tf.mark_dispatching s "a");
  check "is" (tf.is_dispatching s "a");
  check "dup" (not (tf.mark_dispatching s "a"));
  tf.clear_dispatching s "a";
  check "clear" (not (tf.is_dispatching s "a"));
  check "b_independent" (not (tf.is_dispatching s "b"));
  ignore (tf.mark_dispatching s "b");
  check "b_marked" (tf.is_dispatching s "b");
  tf.clear_dispatching s "nonexistent";
  check "noop" true;
  if !failures > 0 then exit 1 else Printf.printf "All tests passed.\n%!"