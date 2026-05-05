(** Pure-function unit tests for [Briefing_gaps].

    Audit P2 follow-up (2026-04-29 §3.1.2) — second of the four
    briefing_*.ml modules in the "테스트 완전 부재" group.

    [Briefing_gaps] turns sentinel strings ("unassigned",
    "unknown", "not_recorded") in briefing fact JSON into
    structured gap records and buckets them per briefing section
    (Communication / Alignment / Watch).  Properties pinned:

    1. {b Sentinel detection} — each documented sentinel produces
       the right kind of gap record with the right scope_type.
    2. {b Cap on gap count} — collect_metadata_gaps returns at
       most 8 records (mli §22).
    3. {b Section bucketing} — gap kinds map to the right
       section: Communication = {session_communication_mode_missing,
       keeper_last_reply_missing}, Alignment = {session_goal_missing,
       agent_focus_missing}, Watch = {} (empty allow-list).
    4. {b Active-agent guard} — agent_focus_missing only fires
       for agents whose [status] is "active" or "busy"; idle
       agents are skipped.
    5. {b evidence_of_metadata_gaps caps at 2} per section. *)

module G = Masc_mcp.Briefing_gaps

let json_string s = `String s

(* Helpers to construct fixture JSON ---------------------------- *)

let session ?(session_id = "s1") ?(goal = "x") ?(comm = "x") () =
  `Assoc
    [
      ("session_id", json_string session_id);
      ("goal", json_string goal);
      ("communication_mode", json_string comm);
    ]

let keeper ?(name = "k1") ?(status = "ok") () =
  `Assoc
    [
      ("name", json_string name);
      ("last_reply_status", json_string status);
    ]

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

(* ── (1) Sentinel detection ────────────────────────────────── *)

let test_session_goal_unassigned () =
  let s = session ~goal:"unassigned" () in
  let gaps = G.collect_metadata_gaps ~sessions:[ s ] ~keepers:[] ~agents:[] in
  assert (List.length gaps = 1);
  let g = List.hd gaps in
  assert (kind_of g = "session_goal_missing");
  assert (scope_type_of g = "session")

let test_session_communication_mode_unknown () =
  let s = session ~comm:"unknown" () in
  let gaps = G.collect_metadata_gaps ~sessions:[ s ] ~keepers:[] ~agents:[] in
  assert (List.length gaps = 1);
  let g = List.hd gaps in
  assert (kind_of g = "session_communication_mode_missing");
  assert (scope_type_of g = "session")

let test_keeper_last_reply_not_recorded () =
  let k = keeper ~status:"not_recorded" () in
  let gaps = G.collect_metadata_gaps ~sessions:[] ~keepers:[ k ] ~agents:[] in
  assert (List.length gaps = 1);
  let g = List.hd gaps in
  assert (kind_of g = "keeper_last_reply_missing");
  assert (scope_type_of g = "keeper")

let test_agent_focus_missing_when_active () =
  let a = agent ~status:"active" ~assignment:"unassigned" () in
  let gaps = G.collect_metadata_gaps ~sessions:[] ~keepers:[] ~agents:[ a ] in
  assert (List.length gaps = 1);
  let g = List.hd gaps in
  assert (kind_of g = "agent_focus_missing");
  assert (scope_type_of g = "agent")

let test_no_gaps_when_no_sentinels () =
  let s = session ~goal:"finished" ~comm:"async" () in
  let k = keeper ~status:"replied" () in
  let a = agent ~status:"active" ~assignment:"task-1" () in
  let gaps =
    G.collect_metadata_gaps ~sessions:[ s ] ~keepers:[ k ]
      ~agents:[ a ]
  in
  assert (gaps = [])

let test_session_id_omitted_when_blank () =
  (* session with empty session_id should still produce gap, but
     scope_id field projects to Null *)
  let s =
    `Assoc
      [
        ("session_id", `String "");
        ("goal", `String "unassigned");
        ("communication_mode", `String "x");
      ]
  in
  let gaps = G.collect_metadata_gaps ~sessions:[ s ] ~keepers:[] ~agents:[] in
  assert (List.length gaps = 1);
  match List.hd gaps with
  | `Assoc kv -> (
      match List.assoc_opt "scope_id" kv with
      | Some `Null -> ()
      | _ -> assert false)
  | _ -> assert false

(* ── (2) take 8 cap ──────────────────────────────────────── *)

let test_collect_caps_at_eight () =
  (* Build > 8 sessions, each with 2 sentinel gaps (goal +
     comm).  collect should cap at 8. *)
  let many_sessions =
    List.init 6 (fun i ->
        session
          ~session_id:(Printf.sprintf "s%d" i)
          ~goal:"unassigned" ~comm:"unknown" ())
  in
  let gaps =
    G.collect_metadata_gaps ~sessions:many_sessions ~keepers:[]
      ~agents:[]
  in
  assert (List.length gaps = 8)

let test_collect_caps_with_mixed_sources () =
  (* Cap is global across sessions+keepers+agents.  Build 6
     sessions × 2 sentinels = 12 candidates, plus keeper + agent
     gaps that should still bring total to 8 (not 12+2). *)
  let many_sessions =
    List.init 6 (fun i ->
        session
          ~session_id:(Printf.sprintf "s%d" i)
          ~goal:"unassigned" ~comm:"unknown" ())
  in
  let many_keepers =
    List.init 3 (fun i ->
        keeper
          ~name:(Printf.sprintf "k%d" i)
          ~status:"not_recorded" ())
  in
  let many_agents =
    List.init 3 (fun i ->
        agent
          ~name:(Printf.sprintf "a%d" i)
          ~status:"active" ~assignment:"unassigned" ())
  in
  let gaps =
    G.collect_metadata_gaps ~sessions:many_sessions
      ~keepers:many_keepers ~agents:many_agents
  in
  assert (List.length gaps = 8)

(* ── (3) Section bucketing ─────────────────────────────────── *)

let make_gap kind =
  `Assoc [ ("kind", `String kind); ("summary", `String "x") ]

let test_count_communication_section () =
  let gaps =
    [
      make_gap "session_communication_mode_missing";
      make_gap "keeper_last_reply_missing";
      make_gap "session_goal_missing";  (* Alignment, not counted *)
    ]
  in
  assert (G.count_metadata_gaps_for_section ~section:G.Communication gaps = 2)

let test_count_alignment_section () =
  let gaps =
    [
      make_gap "session_goal_missing";
      make_gap "agent_focus_missing";
      make_gap "keeper_last_reply_missing";  (* Communication *)
    ]
  in
  assert (G.count_metadata_gaps_for_section ~section:G.Alignment gaps = 2)

let test_count_watch_section_always_zero () =
  (* Watch's allow-list is empty per impl line 79 — no gap kind
     ever counts toward Watch. *)
  let gaps =
    [
      make_gap "session_goal_missing";
      make_gap "agent_focus_missing";
      make_gap "session_communication_mode_missing";
      make_gap "keeper_last_reply_missing";
    ]
  in
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
  let gaps = G.collect_metadata_gaps ~sessions:[] ~keepers:[] ~agents:[ a ] in
  assert (gaps = [])

let test_busy_agent_triggers () =
  let a = agent ~status:"busy" ~assignment:"unassigned" () in
  let gaps = G.collect_metadata_gaps ~sessions:[] ~keepers:[] ~agents:[ a ] in
  assert (List.length gaps = 1)

let test_status_case_insensitive () =
  (* impl uses [String.lowercase_ascii (String.trim ...)] — pin
     case insensitivity. *)
  let a = agent ~status:"ACTIVE" ~assignment:"unassigned" () in
  let gaps = G.collect_metadata_gaps ~sessions:[] ~keepers:[] ~agents:[ a ] in
  assert (List.length gaps = 1)

let test_status_with_whitespace () =
  let a = agent ~status:"  active  " ~assignment:"unassigned" () in
  let gaps = G.collect_metadata_gaps ~sessions:[] ~keepers:[] ~agents:[ a ] in
  assert (List.length gaps = 1)

let test_active_with_assignment_no_gap () =
  (* Active + assignment != "unassigned" → no gap. *)
  let a = agent ~status:"active" ~assignment:"task-1" () in
  let gaps = G.collect_metadata_gaps ~sessions:[] ~keepers:[] ~agents:[ a ] in
  assert (gaps = [])

(* ── (5) evidence_of_metadata_gaps cap at 2 ──────────────── *)

let test_evidence_caps_at_two () =
  let gaps =
    List.init 5 (fun _ -> make_gap "session_goal_missing")
    @ [ make_gap "agent_focus_missing" ]
  in
  let evidence =
    G.evidence_of_metadata_gaps ~section:G.Alignment gaps
  in
  assert (List.length evidence = 2)

let test_evidence_returns_summaries () =
  let gap =
    `Assoc
      [
        ("kind", `String "session_goal_missing");
        ("summary", `String "specific summary text");
      ]
  in
  let evidence =
    G.evidence_of_metadata_gaps ~section:G.Alignment [ gap ]
  in
  assert (evidence = [ "specific summary text" ])

let test_evidence_filters_by_section () =
  (* Communication-only gap shouldn't appear when section =
     Alignment. *)
  let gap = make_gap "keeper_last_reply_missing" in
  let evidence =
    G.evidence_of_metadata_gaps ~section:G.Alignment [ gap ]
  in
  assert (evidence = [])

(* ── runner ──────────────────────────────────────────────── *)

let () =
  test_session_goal_unassigned ();
  test_session_communication_mode_unknown ();
  test_keeper_last_reply_not_recorded ();
  test_agent_focus_missing_when_active ();
  test_no_gaps_when_no_sentinels ();
  test_session_id_omitted_when_blank ();
  test_collect_caps_at_eight ();
  test_collect_caps_with_mixed_sources ();
  test_count_communication_section ();
  test_count_alignment_section ();
  test_count_watch_section_always_zero ();
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
