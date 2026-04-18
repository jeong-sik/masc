(** Tests for Types module *)

open Types

let test_agent_status_roundtrip () =
  let statuses = [Active; Busy; Listening; Inactive] in
  List.iter (fun status ->
    let json = agent_status_to_yojson status in
    match agent_status_of_yojson json with
    | Ok parsed -> Alcotest.(check string) "roundtrip" (show_agent_status status) (show_agent_status parsed)
    | Error e -> Alcotest.fail e
  ) statuses

let test_task_status_todo () =
  let status = Todo in
  let json = task_status_to_yojson status in
  match task_status_of_yojson json with
  | Ok Todo -> ()  (* Pattern match to verify it's Todo *)
  | Ok _ -> Alcotest.fail "expected Todo"
  | Error e -> Alcotest.fail e

let test_task_status_claimed () =
  let status = Claimed { assignee = "claude"; claimed_at = "2024-01-01T00:00:00Z" } in
  let json = task_status_to_yojson status in
  match task_status_of_yojson json with
  | Ok (Claimed { assignee; _ }) -> Alcotest.(check string) "assignee" "claude" assignee
  | Ok _ -> Alcotest.fail "wrong variant"
  | Error e -> Alcotest.fail e

let test_task_status_done () =
  let status = Done { assignee = "gemini"; completed_at = "2024-01-01T00:00:00Z"; notes = Some "test" } in
  let json = task_status_to_yojson status in
  match task_status_of_yojson json with
  | Ok (Done { notes = Some n; _ }) -> Alcotest.(check string) "notes" "test" n
  | Ok _ -> Alcotest.fail "wrong variant or missing notes"
  | Error e -> Alcotest.fail e

let test_message_roundtrip () =
  let msg = {
    seq = 1;
    from_agent = "claude";
    msg_type = "broadcast";
    content = "Hello @gemini!";
    mention = Some "gemini";
    timestamp = "2024-01-01T00:00:00Z";
    trace_context = None;
  } in
  let json = message_to_yojson msg in
  match message_of_yojson json with
  | Ok parsed ->
      Alcotest.(check int) "seq" 1 parsed.seq;
      Alcotest.(check string) "from" "claude" parsed.from_agent;
      Alcotest.(check (option string)) "mention" (Some "gemini") parsed.mention
  | Error e -> Alcotest.fail e

let test_parse_iso8601_epoch_utc () =
  let parsed = parse_iso8601 "1970-01-01T00:00:00Z" in
  Alcotest.(check (float 0.001)) "utc epoch" 0.0 parsed

(* Issue #8312: lenient parser must accept target-state aliases without
   widening canonical Variant SSOT. *)
let action_to_canonical = function
  | Claim -> "claim"
  | Start -> "start"
  | Done_action -> "done"
  | Cancel -> "cancel"
  | Release -> "release"
  | Submit_for_verification -> "submit_for_verification"
  | Approve_verification -> "approve"
  | Reject_verification -> "reject"

let check_lenient input expected =
  match task_action_of_string_lenient input with
  | Ok a -> Alcotest.(check string) input expected (action_to_canonical a)
  | Error e -> Alcotest.failf "expected %s for %s, got error: %s" expected input e

let test_action_alias_claimed () = check_lenient "claimed" "claim"
let test_action_alias_todo () = check_lenient "todo" "release"
let test_action_alias_in_progress () = check_lenient "in_progress" "start"
let test_action_alias_completed () = check_lenient "completed" "done"
let test_action_alias_cancelled () = check_lenient "cancelled" "cancel"
let test_action_canonical_still_works () = check_lenient "claim" "claim"
let test_action_case_insensitive () = check_lenient "CLAIMED" "claim"

let test_action_unknown_still_rejected () =
  match task_action_of_string_lenient "definitely-not-an-action" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "lenient parser must reject genuine garbage"

(* Strict parser must NOT have grown alias support — preserves SSOT
   for places that document only canonical vocabulary. *)
let test_strict_parser_unchanged () =
  match task_action_of_string "claimed" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "strict parser must reject aliases; lenient owns aliases"

let () =
  Alcotest.run "Types" [
    "agent_status", [
      Alcotest.test_case "roundtrip" `Quick test_agent_status_roundtrip;
    ];
    "task_status", [
      Alcotest.test_case "todo" `Quick test_task_status_todo;
      Alcotest.test_case "claimed" `Quick test_task_status_claimed;
      Alcotest.test_case "done" `Quick test_task_status_done;
    ];
    "message", [
      Alcotest.test_case "roundtrip" `Quick test_message_roundtrip;
    ];
    "timestamp", [
      Alcotest.test_case "parse utc epoch" `Quick test_parse_iso8601_epoch_utc;
    ];
    "task_action_lenient", [
      Alcotest.test_case "alias claimed -> claim" `Quick test_action_alias_claimed;
      Alcotest.test_case "alias todo -> release" `Quick test_action_alias_todo;
      Alcotest.test_case "alias in_progress -> start" `Quick test_action_alias_in_progress;
      Alcotest.test_case "alias completed -> done" `Quick test_action_alias_completed;
      Alcotest.test_case "alias cancelled -> cancel" `Quick test_action_alias_cancelled;
      Alcotest.test_case "canonical claim still works" `Quick test_action_canonical_still_works;
      Alcotest.test_case "case insensitive" `Quick test_action_case_insensitive;
      Alcotest.test_case "garbage still rejected" `Quick test_action_unknown_still_rejected;
      Alcotest.test_case "strict parser ssot preserved" `Quick test_strict_parser_unchanged;
    ];
  ]
