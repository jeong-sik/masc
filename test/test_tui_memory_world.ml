(* When the Memory screen's world reading may start a read, and what it holds
   after each answer. The words the world line draws are not compared here. *)

module Wire = Masc.Tui_decode_workspace_memory
module World = Masc_tui_memory_world

let retry_s = 2.0

let world ~claims =
  Wire.Available
    { Wire.generated_at = 1.0
    ; ledger_sha256 = String.make 64 'a'
    ; claim_count = claims
    ; conflict_count = 0
    ; excluded_count = 0
    ; classified_count = 0
    ; briefing = { Wire.status = Wire.Current; building = None }
    ; ordinary_absence = Wire.Absence_complete
        { facts = claims; absent = 0; available_stores = 1; missing_stores = 0 }
    }

let first = world ~claims:1
let second = world ~claims:2

let start_exn ~now t =
  match World.start ~now t with
  | Some started -> started
  | None -> Alcotest.fail "a read was expected to start"

let answer ~now t request result =
  World.complete ~retry_s ~max_retry_s:30.0 ~now t request result

(* What a failed read says it failed of: the text it came with, or that it was
   retired. *)
let cause = function
  | World.Suspended -> "suspended"
  | World.Request_failed text -> text

(* What a reading holds, as a name, so a failure prints both sides. *)
let held t =
  match World.reading t with
  | World.Not_read -> "not read"
  | World.Reading -> "reading"
  | World.Read_failed failure -> "read failed: " ^ cause failure
  | World.Loaded { world; refresh_failure } ->
    let which = if world = first then "first" else if world = second then "second" else "other" in
    (match refresh_failure with
     | None -> which
     | Some failure -> which ^ ", last read failed: " ^ cause failure)

let can_start ~now t = Option.is_some (World.start ~now t)

let test_success_waits_for_a_change () =
  let t1, request = start_exn ~now:0.0 World.initial in
  Alcotest.(check bool) "one read in flight" false (can_start ~now:1.0 t1);
  let settled = answer ~now:5.0 t1 request (Ok first) in
  Alcotest.(check bool) "time alone does not owe another request" false
    (can_start ~now:10000.0 settled);
  Alcotest.(check bool) "a push or revalidation owes one" true
    (can_start ~now:6.0 (World.changed settled))

let test_a_change_in_flight_survives_the_answer () =
  let reading, request = start_exn ~now:0.0 World.initial in
  let changed = World.changed (World.changed reading) in
  Alcotest.(check bool) "a burst cannot overlap the current request" false
    (can_start ~now:1.0 changed);
  let first_answer = answer ~now:1.0 changed request (Ok first) in
  let followup, request = start_exn ~now:1.0 first_answer in
  let settled = answer ~now:2.0 followup request (Ok second) in
  Alcotest.(check string) "the follow-up observes the new inventory" "second" (held settled);
  Alcotest.(check bool) "the burst owes no third read" false
    (can_start ~now:10000.0 settled)

let test_failed_reads_keep_the_shared_retry () =
  let t1, request = start_exn ~now:0.0 World.initial in
  let t2 = answer ~now:0.0 t1 request (Error "boom") in
  Alcotest.(check string) "a failure holds its received cause" "read failed: boom" (held t2);
  Alcotest.(check bool) "the failed read waits" false (can_start ~now:1.0 t2);
  let t3, request = start_exn ~now:retry_s t2 in
  Alcotest.(check string) "retry retains the failure" "read failed: boom" (held t3);
  let t4 = answer ~now:retry_s t3 request (Error "again") in
  Alcotest.(check bool) "consecutive failure backs off" false (can_start ~now:5.0 t4);
  Alcotest.(check bool) "a new change does not wait for the old failure" true
    (can_start ~now:3.0 (World.changed t4));
  let t5, request = start_exn ~now:6.0 t4 in
  let settled = answer ~now:6.0 t5 request (Ok second) in
  Alcotest.(check bool) "success ends retrying" false (can_start ~now:10000.0 settled)

let test_a_refresh_keeps_the_value () =
  let t1, request = start_exn ~now:0.0 World.initial in
  Alcotest.(check string) "the first read is unknown" "reading" (held t1);
  let t2 = answer ~now:0.0 t1 request (Ok first) in
  let t3, refresh = start_exn ~now:retry_s (World.changed t2) in
  Alcotest.(check string) "the held inventory stays while the refresh runs" "first" (held t3);
  let t4 = answer ~now:retry_s t3 refresh (Error "boom") in
  Alcotest.(check string) "a failed refresh keeps it and says so, with its cause"
    "first, last read failed: boom" (held t4);
  let t5, again = start_exn ~now:(2.0 *. retry_s) t4 in
  let t6 = answer ~now:(2.0 *. retry_s) t5 again (Ok second) in
  Alcotest.(check string) "the next answer replaces it" "second" (held t6)

let test_clear_drops_what_was_read_and_the_old_reply () =
  let t1, old_request = start_exn ~now:0.0 World.initial in
  let t2 = World.clear t1 in
  Alcotest.(check string) "cleared" "not read" (held t2);
  let t3, request = start_exn ~now:0.0 t2 in
  let t4 = answer ~now:0.0 t3 old_request (Ok first) in
  Alcotest.(check string) "the old answer is dropped" "reading" (held t4);
  let t5 = answer ~now:0.0 t4 request (Ok second) in
  Alcotest.(check string) "the new one lands" "second" (held t5)

let test_clear_allows_a_read_at_once () =
  let t1, request = start_exn ~now:0.0 World.initial in
  let t2 = answer ~now:0.0 t1 request (Ok first) in
  Alcotest.(check bool) "settled" false (can_start ~now:1.0 t2);
  Alcotest.(check bool) "another workspace is read at once" true (can_start ~now:1.0 (World.clear t2))

let test_suspend_retires_the_read () =
  let t1, retired = start_exn ~now:0.0 World.initial in
  let t2 = World.suspend t1 in
  Alcotest.(check string) "a first read cut short holds nothing, and says it was retired"
    "read failed: suspended" (held t2);
  Alcotest.(check bool) "it never answered, so the next read need not wait" true
    (can_start ~now:1.0 t2);
  let late = answer ~now:1.0 t2 retired (Ok first) in
  Alcotest.(check string) "its late answer is dropped" "read failed: suspended" (held late);
  Alcotest.(check bool) "and cannot settle the owed read" true (can_start ~now:1.5 late);
  let t3, request = start_exn ~now:2.0 World.initial in
  let t4 = answer ~now:2.0 t3 request (Ok first) in
  let t5, refresh = start_exn ~now:(2.0 +. retry_s) (World.changed t4) in
  let t6 = World.suspend t5 in
  Alcotest.(check string) "a refresh cut short keeps the inventory, marked failed"
    "first, last read failed: suspended" (held t6);
  Alcotest.(check string) "and its late answer is dropped" "first, last read failed: suspended"
    (held (answer ~now:(2.0 +. retry_s) t6 refresh (Ok second)));
  let t7, failed = start_exn ~now:4.0 World.initial in
  let t8 = answer ~now:4.0 t7 failed (Error "boom") in
  let t9, _ = start_exn ~now:(4.0 +. retry_s) t8 in
  Alcotest.(check string) "a retry cut short keeps the failure it was retrying"
    "read failed: boom" (held (World.suspend t9))

let () =
  Alcotest.run "tui_memory_world"
    [ ( "read schedule"
      , [ Alcotest.test_case "success waits for a change" `Quick test_success_waits_for_a_change
        ; Alcotest.test_case "changes during a read owe one follow-up" `Quick
            test_a_change_in_flight_survives_the_answer
        ; Alcotest.test_case "failed reads keep the shared retry" `Quick
            test_failed_reads_keep_the_shared_retry
        ] )
    ; ( "what the reading holds"
      , [ Alcotest.test_case "a refresh keeps the value" `Quick test_a_refresh_keeps_the_value
        ; Alcotest.test_case "clear drops what was read and the old reply" `Quick
            test_clear_drops_what_was_read_and_the_old_reply
        ; Alcotest.test_case "clear allows a read at once" `Quick
            test_clear_allows_a_read_at_once
        ; Alcotest.test_case "suspend retires the read" `Quick test_suspend_retires_the_read
        ] )
    ]
