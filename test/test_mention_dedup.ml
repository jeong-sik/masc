(** Tests for [Mention_dedup] — RFC-0040.

    Window arithmetic uses the [~now] parameter directly, so the suite
    runs without [Unix.sleep].  Each test calls [reset_for_test ()] in
    its prelude to reset the in-process Hashtbl. *)

let ttl = Mention_dedup.default_ttl_seconds

(* Sanity guard: env override could change defaults; keep the
   integration testable by asserting a positive window. *)
let () =
  if ttl <= 0.0 then
    failwith
      (Printf.sprintf
         "Mention_dedup.default_ttl_seconds must be > 0; got %.3f" ttl)

let hash content = Mention_dedup.content_topic_hash content

let test_dedup_skips_within_window () =
  Mention_dedup.reset_for_test ();
  let h = hash "@nick0cave task-037 is stale" in
  let first =
    Mention_dedup.should_skip
      ~from_agent:"taskmaster" ~target:"nick0cave"
      ~content_hash:h ~now:1000.0
  in
  let second =
    Mention_dedup.should_skip
      ~from_agent:"taskmaster" ~target:"nick0cave"
      ~content_hash:h ~now:1005.0
  in
  Alcotest.(check bool) "first call passes" false first;
  Alcotest.(check bool) "second call within window skips" true second

let test_dedup_clears_after_ttl () =
  Mention_dedup.reset_for_test ();
  let h = hash "@nick0cave please ack" in
  let first =
    Mention_dedup.should_skip
      ~from_agent:"taskmaster" ~target:"nick0cave"
      ~content_hash:h ~now:0.0
  in
  let after_ttl =
    Mention_dedup.should_skip
      ~from_agent:"taskmaster" ~target:"nick0cave"
      ~content_hash:h ~now:(ttl +. 1.0)
  in
  Alcotest.(check bool) "first call passes" false first;
  Alcotest.(check bool) "after ttl passes again" false after_ttl

let test_dedup_distinguishes_targets () =
  Mention_dedup.reset_for_test ();
  let h = hash "shared content" in
  let to_a =
    Mention_dedup.should_skip
      ~from_agent:"taskmaster" ~target:"alice"
      ~content_hash:h ~now:100.0
  in
  let to_b =
    Mention_dedup.should_skip
      ~from_agent:"taskmaster" ~target:"bob"
      ~content_hash:h ~now:101.0
  in
  Alcotest.(check bool) "first to alice passes" false to_a;
  Alcotest.(check bool) "first to bob passes (different target)" false to_b

let test_dedup_distinguishes_content () =
  Mention_dedup.reset_for_test ();
  let from_agent = "taskmaster" in
  let target = "nick0cave" in
  let first =
    Mention_dedup.should_skip
      ~from_agent ~target
      ~content_hash:(hash "@nick0cave task-037 stale") ~now:200.0
  in
  let different =
    Mention_dedup.should_skip
      ~from_agent ~target
      ~content_hash:(hash "@nick0cave task-038 also stale") ~now:201.0
  in
  Alcotest.(check bool) "first content passes" false first;
  Alcotest.(check bool) "different content passes (different hash)"
    false different

let test_bypass_dedup_force () =
  (* The [bypass_dedup] flag is enforced in [Coord_broadcast.broadcast].
     The dedup module itself does not implement bypass — the broadcast
     path skips the [should_skip] call entirely.  This test asserts the
     dedup module remains the "would skip" oracle: with the same
     triple inside the window, [should_skip] still returns true.  A
     bypass caller is expected to NOT invoke [should_skip]. *)
  Mention_dedup.reset_for_test ();
  let h = hash "@alerts critical incident" in
  let first =
    Mention_dedup.should_skip
      ~from_agent:"system" ~target:"alerts"
      ~content_hash:h ~now:300.0
  in
  let would_skip =
    Mention_dedup.should_skip
      ~from_agent:"system" ~target:"alerts"
      ~content_hash:h ~now:301.0
  in
  Alcotest.(check bool) "first call passes" false first;
  Alcotest.(check bool)
    "second call would skip (bypass caller must avoid should_skip)"
    true would_skip

let test_dedup_no_target () =
  (* mention=None must not consume dedup state for any target. *)
  Mention_dedup.reset_for_test ();
  (* Simulate: caller sees mention=None and skips should_skip. State
     remains empty.  A later mention=Some ("foo") should then pass. *)
  let later =
    Mention_dedup.should_skip
      ~from_agent:"taskmaster" ~target:"foo"
      ~content_hash:(hash "first @foo") ~now:400.0
  in
  Alcotest.(check bool)
    "no_target path leaves table empty; first @foo passes"
    false later

let test_content_hash_normalizes () =
  let h1 = Mention_dedup.content_topic_hash "  @Foo Bar  " in
  let h2 = Mention_dedup.content_topic_hash "@foo bar" in
  Alcotest.(check string)
    "trim+lowercase yields stable hash" h1 h2

let () =
  let open Alcotest in
  run "Mention Dedup (RFC-0040)" [
    "window", [
      test_case "skips within window" `Quick test_dedup_skips_within_window;
      test_case "clears after ttl" `Quick test_dedup_clears_after_ttl;
    ];
    "key", [
      test_case "distinguishes targets" `Quick test_dedup_distinguishes_targets;
      test_case "distinguishes content" `Quick test_dedup_distinguishes_content;
    ];
    "policy", [
      test_case "bypass force" `Quick test_bypass_dedup_force;
      test_case "no target" `Quick test_dedup_no_target;
    ];
    "hash", [
      test_case "trim+lowercase" `Quick test_content_hash_normalizes;
    ];
  ]
