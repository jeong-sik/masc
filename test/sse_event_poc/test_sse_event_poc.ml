(* Phase A0.1 PoC — 3-way byte-equal probe.

   Compares three JSON emit paths for the same agent_started payload:

   1. [baseline] — direct `Assoc construction + Yojson.Safe.to_string.
      This is what [lib/cascade/cascade_event_bridge.ml] emits today
      inside the AgentStarted arm of [native_event_to_json] (lines 556-560).

   2. [manual] — hand-coded variant in [Sse_event_poc.Sse_event_manual],
      structurally identical to the baseline but routed through a named
      module that an Sse_event-style refactor would introduce.

   3. [atdgen] — atdgen-generated [Sse_event_poc.Sse_event_j.string_of_*]
      derived from [lib/sse_event_poc/sse_event.atd].

   The probe answers: does atdgen's default record write produce
   byte-identical output to the hand-coded `Assoc + to_string path?

   If 1 = 2 = 3 → A0.1+A0.2 integration is viable (atd from day 1).
   If 1 = 2 ≠ 3 → byte-diff is reported and atd custom adapter work
   is required before A0.2 can absorb A0.1. *)

let agent_name = "test_agent"
let task_id = "task_42"

let baseline_to_string () : string =
  Yojson.Safe.to_string
    (`Assoc
       [ "agent_name", `String agent_name; "task_id", `String task_id ])
;;

let manual_to_string () : string =
  let p : Sse_event_poc.Sse_event_manual.agent_started_payload =
    { agent_name; task_id }
  in
  Sse_event_poc.Sse_event_manual.agent_started_payload_to_string p
;;

let atdgen_to_string () : string =
  let p : Sse_event_poc.Sse_event_t.agent_started_payload =
    { agent_name; task_id }
  in
  Sse_event_poc.Sse_event_j.string_of_agent_started_payload p
;;

let print_byte_diff (a : string) (b : string) : unit =
  if String.equal a b
  then ()
  else (
    Printf.printf "  byte-diff:\n    a (len=%d): %s\n    b (len=%d): %s\n"
      (String.length a) a (String.length b) b;
    let n = min (String.length a) (String.length b) in
    let rec first_diff i =
      if i >= n then i
      else if Char.equal a.[i] b.[i] then first_diff (i + 1)
      else i
    in
    let i = first_diff 0 in
    Printf.printf "    first divergent index: %d (a=%C, b=%C)\n"
      i
      (if i < String.length a then a.[i] else '?')
      (if i < String.length b then b.[i] else '?'))
;;

let test_three_way_byte_equal () =
  let baseline = baseline_to_string () in
  let manual = manual_to_string () in
  let atdgen = atdgen_to_string () in
  Printf.printf "\n=== Phase A0.1 PoC byte-equal probe ===\n";
  Printf.printf "  baseline (`Assoc + Yojson): %s\n" baseline;
  Printf.printf "  manual   (Sse_event_manual): %s\n" manual;
  Printf.printf "  atdgen   (Sse_event_j):      %s\n" atdgen;
  Printf.printf "  baseline == manual: %b\n" (String.equal baseline manual);
  Printf.printf "  baseline == atdgen: %b\n" (String.equal baseline atdgen);
  Printf.printf "  manual   == atdgen: %b\n" (String.equal manual atdgen);
  print_byte_diff baseline manual;
  print_byte_diff baseline atdgen;
  Alcotest.(check string) "manual == baseline" baseline manual;
  Alcotest.(check string) "atdgen == baseline" baseline atdgen
;;

let () =
  Alcotest.run
    "sse_event_poc"
    [ ( "byte_equal_probe"
      , [ Alcotest.test_case "3-way agent_started" `Quick test_three_way_byte_equal
        ] )
    ]
;;
