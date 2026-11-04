(** Pure-function unit tests for [Briefing_gaps].

    Audit P2 follow-up (2026-04-29 §3.1.2) — second of the four
    briefing_*.ml modules in the "테스트 완전 부재" group.

    [Briefing_gaps] turns missing or unknown briefing fact JSON into
    structured gap records and buckets them per briefing section
    (Communication / Alignment / Watch).  Properties pinned:

    1. {b Missing-value detection} — an active agent without focus
       produces an agent_focus_missing record with scope_type agent.
    2. {b Cap on gap count} — collect_metadata_gaps returns at
       most 8 records.
    3. {b Section bucketing} — agent_focus_missing counts toward
       Alignment only; Communication and Watch count no gap kind.
    4. {b Active-agent guard} — agent_focus_missing only fires
       for agents whose [status] is "active" or "busy"; idle
       agents are skipped.
    5. {b evidence_of_metadata_gaps caps at 2} per section. *)

module G = Briefing_gaps

let json_string s = `String s

(* Helpers to construct fixture JSON ---------------------------- *)

let agent ?(name = "a1") ?(status = "active") ?(assignment = "x") () =
  `Assoc
    [
      ("name", json_string name);
      ("status", json_string status);
      ("assignment_status", json_string assignment);
    ]

let kind_of j =
  match j with
  | `Assoc kv -> (
      match List.assoc_opt "kind" kv with
      | Some (`String s) -> s
      | _ -> "")
  | _ -> ""

let scope_type_of j =
  match j with
  | `Assoc kv -> (
      match List.assoc_opt "scope_type" kv with
      | Some (`String s) -> s
      | _ -> "")
  | _ -> ""

(* ── (1) Missing-value detection ───────────────────────────── *)

let test_agent_focus_missing_when_active () =
  let a = agent ~status:"active" ~assignment:"unassigned" () in
  let gaps = G.collect_metadata_gaps ~agents:[ a ] in
  assert (List.length gaps = 1);
  let g = List.hd gaps in
  assert (kind_of g = "agent_focus_missing");
  assert (scope_type_of g = "agent")

let test_no_gaps_when_no_missing_values () =
  let a = agent ~status:"active" ~assignment:"task-1" () in
  let gaps = G.collect_metadata_gaps ~agents:[ a ] in
  assert (gaps = [])

(* ── (2) take 8 cap ──────────────────────────────────────── *)

let test_collect_caps_at_eight () =
  (* 10 agent gaps against a cap of 8. *)
  let many_agents =
    List.init 10 (fun i ->
        agent ~name:(Printf.sprintf "a%d" i) ~status:"active"
          ~assignment:"unassigned" ())
  in
  let gaps = G.collect_metadata_gaps ~agents:many_agents in
  assert (List.length gaps = 8)

(* ── (3) Section bucketing ─────────────────────────────────── *)

let make_gap kind =
  `Assoc [ ("kind", `String kind); ("summary", `String "x") ]

let test_count_alignment_section () =
  let gaps = [ make_gap "agent_focus_missing"; make_gap "agent_focus_missing" ] in
  assert (G.count_metadata_gaps_for_section ~section:G.Alignment gaps = 2)

let test_count_communication_and_watch_always_zero () =
  (* Communication and Watch have empty allow-lists — no gap kind
     counts toward them. *)
  let gaps = [ make_gap "agent_focus_missing" ] in
  assert (G.count_metadata_gaps_for_section ~section:G.Communication gaps = 0);
  assert (G.count_metadata_gaps_for_section ~section:G.Watch gaps = 0)

let test_count_unknown_kind_ignored () =
  let gaps = [ make_gap "completely_unknown_kind" ] in
  assert (G.count_metadata_gaps_for_section ~section:G.Communication gaps = 0);
  assert (G.count_metadata_gaps_for_section ~section:G.Alignment gaps = 0)

(* ── (4) Active-agent guard ────────────────────────────────── *)

let test_idle_agent_skipped () =
  (* Idle agent with assignment_status=unassigned must NOT
     produce a focus_missing gap. *)
  let a = agent ~status:"idle" ~assignment:"unassigned" () in
  let gaps = G.collect_metadata_gaps ~agents:[ a ] in
  assert (gaps = [])

let test_busy_agent_triggers () =
  let a = agent ~status:"busy" ~assignment:"unassigned" () in
  let gaps = G.collect_metadata_gaps ~agents:[ a ] in
  assert (List.length gaps = 1)

let test_status_case_insensitive () =
  (* impl uses [String.lowercase_ascii (String.trim ...)] — pin
     case insensitivity. *)
  let a = agent ~status:"ACTIVE" ~assignment:"unassigned" () in
  let gaps = G.collect_metadata_gaps ~agents:[ a ] in
  assert (List.length gaps = 1)

let test_status_with_whitespace () =
  let a = agent ~status:"  active  " ~assignment:"unassigned" () in
  let gaps = G.collect_metadata_gaps ~agents:[ a ] in
  assert (List.length gaps = 1)

let test_active_with_assignment_no_gap () =
  (* Active + assignment != "unassigned" → no gap. *)
  let a = agent ~status:"active" ~assignment:"task-1" () in
  let gaps = G.collect_metadata_gaps ~agents:[ a ] in
  assert (gaps = [])

(* ── (5) evidence_of_metadata_gaps cap at 2 ──────────────── *)

let test_evidence_caps_at_two () =
  let gaps =
    List.init 5 (fun _ -> make_gap "agent_focus_missing")
  in
  let evidence =
    G.evidence_of_metadata_gaps ~section:G.Alignment gaps
  in
  assert (List.length evidence = 2)

let test_evidence_returns_summaries () =
  let gap =
    `Assoc
      [
        ("kind", `String "agent_focus_missing");
        ("summary", `String "specific summary text");
      ]
  in
  let evidence =
    G.evidence_of_metadata_gaps ~section:G.Alignment [ gap ]
  in
  assert (evidence = [ "specific summary text" ])

let test_evidence_filters_by_section () =
  (* An Alignment gap shouldn't appear when section = Communication. *)
  let gap = make_gap "agent_focus_missing" in
  let evidence =
    G.evidence_of_metadata_gaps ~section:G.Communication [ gap ]
  in
  assert (evidence = [])

(* ── runner ──────────────────────────────────────────────── *)

let () =
  test_agent_focus_missing_when_active ();
  test_no_gaps_when_no_missing_values ();
  test_collect_caps_at_eight ();
  test_count_alignment_section ();
  test_count_communication_and_watch_always_zero ();
  test_count_unknown_kind_ignored ();
  test_idle_agent_skipped ();
  test_busy_agent_triggers ();
  test_status_case_insensitive ();
  test_status_with_whitespace ();
  test_active_with_assignment_no_gap ();
  test_evidence_caps_at_two ();
  test_evidence_returns_summaries ();
  test_evidence_filters_by_section ();
  print_endline "test_briefing_gaps: all assertions passed"
