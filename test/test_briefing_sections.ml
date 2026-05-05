(** Pure-function unit tests for [Briefing_sections].

    Audit P2 follow-up (2026-04-29 §3.1.2) — fourth and last of
    the four briefing_*.ml modules in the "테스트 완전 부재"
    group.

    Only [build_briefing_sections] is exposed via .mli; this
    suite black-box exercises the major decision branches of
    the three internal section builders (Communication /
    Alignment / Watch) by varying the inputs.

    Properties pinned:

    1. {b Output shape} — returns [(watch_summary, [c; a; w])]
       where the list always has length 3 with section ids
       [communication / alignment / watch] in that order.
    2. {b Watch branches} — risky room → "risk"; incidents or
       recommended actions → "watch"; otherwise "ok".
    3. {b Communication branches} — positive signal vs
       metadata gaps vs live-session-count vs known mode count.
    4. {b Alignment branches} — active agents vs metadata gaps
       vs bound goals vs assignment status.
    5. {b annotate_section attributes} — every section emits
       [provenance="narrative"], [authoritative=false], and the
       fixed 9-key shape. *)

module S = Masc_mcp.Briefing_sections

(* ── Fixtures ──────────────────────────────────────────────── *)

let s_str s = `String s

let mission ?(room_health = "ok") ?(incidents = 0)
    ?(recommended = 0) ?(top_attention = "") () : Yojson.Safe.t =
  `Assoc
    [
      ("room_health", s_str room_health);
      ("incident_count", `Int incidents);
      ("recommended_action_count", `Int recommended);
      ("top_attention_summary", s_str top_attention);
    ]

let session ?(broadcast = 0) ?(portal = 0) ?(mode = "unknown")
    ?(goal = "unassigned") () =
  `Assoc
    [
      ("broadcast_count", `Int broadcast);
      ("portal_count", `Int portal);
      ("communication_mode", s_str mode);
      ("goal", s_str goal);
    ]

let agent ?(status = "active") ?(assignment = "assigned") () =
  `Assoc
    [
      ("status", s_str status);
      ("assignment_status", s_str assignment);
    ]

let gap ?(kind = "session_goal_missing") ?(summary = "fact") () =
  `Assoc [ ("kind", s_str kind); ("summary", s_str summary) ]

let recent_msg () =
  `Assoc [ ("text", s_str "hi") ]

(* Helpers for assertions ──────────────────────────────────── *)

let section_id j =
  match j with
  | `Assoc kv -> (
      match List.assoc_opt "id" kv with
      | Some (`String s) -> s
      | _ -> "")
  | _ -> ""

let section_status j =
  match j with
  | `Assoc kv -> (
      match List.assoc_opt "status" kv with
      | Some (`String s) -> s
      | _ -> "")
  | _ -> ""

let section_summary j =
  match j with
  | `Assoc kv -> (
      match List.assoc_opt "summary" kv with
      | Some (`String s) -> s
      | _ -> "")
  | _ -> ""

let section_evidence j =
  match j with
  | `Assoc kv -> (
      match List.assoc_opt "evidence" kv with
      | Some (`List items) ->
          List.filter_map
            (function `String s -> Some s | _ -> None)
            items
      | _ -> [])
  | _ -> []

let assoc_keys_sorted j =
  match j with
  | `Assoc kv -> List.sort compare (List.map fst kv)
  | _ -> []

(* Convenience: pull section by id from build result. *)
let by_id sections id =
  List.find (fun s -> section_id s = id) sections

(* ── (1) Output shape ──────────────────────────────────────── *)

let test_output_shape_three_sections () =
  let _ws, sections =
    S.build_briefing_sections
      ~mission_summary_json:(mission ()) ~sessions:[] ~agents:[]
      ~recent_messages:[] ~metadata_gaps:[]
  in
  assert (List.length sections = 3);
  let ids = List.map section_id sections in
  assert (ids = [ "communication"; "alignment"; "watch" ])

let test_output_shape_section_attribute_keys () =
  let _ws, sections =
    S.build_briefing_sections
      ~mission_summary_json:(mission ()) ~sessions:[] ~agents:[]
      ~recent_messages:[] ~metadata_gaps:[]
  in
  let expected_keys =
    List.sort compare
      [
        "id"; "label"; "status"; "summary"; "evidence";
        "signal_class"; "evidence_quality"; "provenance";
        "authoritative";
      ]
  in
  List.iter
    (fun s -> assert (assoc_keys_sorted s = expected_keys))
    sections

let test_provenance_and_authoritative_pinned () =
  let _ws, sections =
    S.build_briefing_sections
      ~mission_summary_json:(mission ()) ~sessions:[] ~agents:[]
      ~recent_messages:[] ~metadata_gaps:[]
  in
  List.iter
    (fun s ->
      match s with
      | `Assoc kv ->
          assert (
            List.assoc_opt "provenance" kv
            = Some (`String "narrative"));
          assert (
            List.assoc_opt "authoritative" kv = Some (`Bool false))
      | _ -> assert false)
    sections

let test_watch_summary_matches_watch_section () =
  let ws, sections =
    S.build_briefing_sections
      ~mission_summary_json:(mission ()) ~sessions:[] ~agents:[]
      ~recent_messages:[] ~metadata_gaps:[]
  in
  let watch = by_id sections "watch" in
  assert (section_summary watch = ws)

(* ── (2) Watch section branches ────────────────────────────── *)

let test_watch_risky_room () =
  let _ws, sections =
    S.build_briefing_sections
      ~mission_summary_json:(mission ~room_health:"critical" ())
      ~sessions:[] ~agents:[] ~recent_messages:[]
      ~metadata_gaps:[]
  in
  let w = by_id sections "watch" in
  assert (section_status w = "risk")

let test_watch_incidents_only () =
  let _ws, sections =
    S.build_briefing_sections
      ~mission_summary_json:(mission ~incidents:2 ()) ~sessions:[]
      ~agents:[] ~recent_messages:[] ~metadata_gaps:[]
  in
  let w = by_id sections "watch" in
  assert (section_status w = "watch")

let test_watch_recommended_actions_only () =
  let _ws, sections =
    S.build_briefing_sections
      ~mission_summary_json:(mission ~recommended:3 ())
      ~sessions:[] ~agents:[] ~recent_messages:[]
      ~metadata_gaps:[]
  in
  let w = by_id sections "watch" in
  assert (section_status w = "watch")

let test_watch_clean_state_ok () =
  let _ws, sections =
    S.build_briefing_sections
      ~mission_summary_json:(mission ()) ~sessions:[] ~agents:[]
      ~recent_messages:[] ~metadata_gaps:[]
  in
  let w = by_id sections "watch" in
  assert (section_status w = "ok")

(* ── (3) Communication section branches ────────────────────── *)

let test_communication_positive_signal_no_gaps_healthy () =
  (* recent_messages > 0, no metadata gaps in communication
     allow-list → "healthy". *)
  let _ws, sections =
    S.build_briefing_sections
      ~mission_summary_json:(mission ())
      ~sessions:[ session ~mode:"async" () ]
      ~agents:[] ~recent_messages:[ recent_msg () ]
      ~metadata_gaps:[]
  in
  let c = by_id sections "communication" in
  assert (section_status c = "healthy")

let test_communication_positive_signal_with_gaps_watch () =
  (* recent_messages > 0 AND a Communication gap → "watch". *)
  let _ws, sections =
    S.build_briefing_sections
      ~mission_summary_json:(mission ())
      ~sessions:[ session () ]
      ~agents:[]
      ~recent_messages:[ recent_msg () ]
      ~metadata_gaps:[ gap ~kind:"keeper_last_reply_missing" () ]
  in
  let c = by_id sections "communication" in
  assert (section_status c = "watch")

let test_communication_no_sessions_unclear () =
  let _ws, sections =
    S.build_briefing_sections
      ~mission_summary_json:(mission ()) ~sessions:[] ~agents:[]
      ~recent_messages:[] ~metadata_gaps:[]
  in
  let c = by_id sections "communication" in
  assert (section_status c = "unclear")

let test_communication_unknown_mode_unclear () =
  (* Live session present, but mode is "unknown" → "unclear". *)
  let _ws, sections =
    S.build_briefing_sections
      ~mission_summary_json:(mission ())
      ~sessions:[ session ~mode:"unknown" () ]
      ~agents:[] ~recent_messages:[] ~metadata_gaps:[]
  in
  let c = by_id sections "communication" in
  assert (section_status c = "unclear")

let test_communication_metadata_gap_unclear () =
  let _ws, sections =
    S.build_briefing_sections
      ~mission_summary_json:(mission ())
      ~sessions:[ session ~mode:"async" () ]
      ~agents:[]
      ~recent_messages:[]
      ~metadata_gaps:
        [ gap ~kind:"session_communication_mode_missing" () ]
  in
  let c = by_id sections "communication" in
  assert (section_status c = "unclear")

(* ── (4) Alignment section branches ────────────────────────── *)

let test_alignment_no_active_agents_unclear () =
  let _ws, sections =
    S.build_briefing_sections
      ~mission_summary_json:(mission ())
      ~sessions:[ session ~goal:"ship" () ]
      ~agents:[ agent ~status:"inactive" () ]
      ~recent_messages:[] ~metadata_gaps:[]
  in
  let a = by_id sections "alignment" in
  assert (section_status a = "unclear")

let test_alignment_metadata_gap_unclear () =
  let _ws, sections =
    S.build_briefing_sections
      ~mission_summary_json:(mission ())
      ~sessions:[ session ~goal:"ship" () ]
      ~agents:[ agent ~status:"active" ~assignment:"assigned" () ]
      ~recent_messages:[]
      ~metadata_gaps:[ gap ~kind:"agent_focus_missing" () ]
  in
  let a = by_id sections "alignment" in
  assert (section_status a = "unclear")

let test_alignment_no_bound_goal_unclear () =
  (* Active agents but every session goal is "unassigned" →
     bound_goal_count=0 → "unclear". *)
  let _ws, sections =
    S.build_briefing_sections
      ~mission_summary_json:(mission ())
      ~sessions:[ session ~goal:"unassigned" () ]
      ~agents:[ agent ~status:"active" ~assignment:"assigned" () ]
      ~recent_messages:[] ~metadata_gaps:[]
  in
  let a = by_id sections "alignment" in
  assert (section_status a = "unclear")

let test_alignment_all_assigned_aligned () =
  let _ws, sections =
    S.build_briefing_sections
      ~mission_summary_json:(mission ())
      ~sessions:[ session ~goal:"ship feature" () ]
      ~agents:
        [
          agent ~status:"active" ~assignment:"assigned" ();
          agent ~status:"busy" ~assignment:"assigned" ();
        ]
      ~recent_messages:[] ~metadata_gaps:[]
  in
  let a = by_id sections "alignment" in
  assert (section_status a = "aligned")

let test_alignment_some_unassigned_watch () =
  let _ws, sections =
    S.build_briefing_sections
      ~mission_summary_json:(mission ())
      ~sessions:[ session ~goal:"ship feature" () ]
      ~agents:
        [
          agent ~status:"active" ~assignment:"assigned" ();
          agent ~status:"active" ~assignment:"unassigned" ();
        ]
      ~recent_messages:[] ~metadata_gaps:[]
  in
  let a = by_id sections "alignment" in
  assert (section_status a = "watch")

(* ── (5) Evidence cap ─────────────────────────────────────── *)

let test_evidence_capped_at_two () =
  (* Construct inputs that produce > 2 candidate evidence
     entries — output should still be capped at 2. *)
  let many_messages =
    List.init 5 (fun _ -> recent_msg ())
  in
  let s_with_signals =
    session ~broadcast:5 ~portal:7 ~mode:"async" ()
  in
  let _ws, sections =
    S.build_briefing_sections
      ~mission_summary_json:(mission ())
      ~sessions:[ s_with_signals ]
      ~agents:[ agent ~status:"active" ~assignment:"assigned" () ]
      ~recent_messages:many_messages ~metadata_gaps:[]
  in
  List.iter
    (fun s ->
      let ev = section_evidence s in
      assert (List.length ev <= 2))
    sections

(* ── runner ───────────────────────────────────────────────── *)

let () =
  test_output_shape_three_sections ();
  test_output_shape_section_attribute_keys ();
  test_provenance_and_authoritative_pinned ();
  test_watch_summary_matches_watch_section ();
  test_watch_risky_room ();
  test_watch_incidents_only ();
  test_watch_recommended_actions_only ();
  test_watch_clean_state_ok ();
  test_communication_positive_signal_no_gaps_healthy ();
  test_communication_positive_signal_with_gaps_watch ();
  test_communication_no_sessions_unclear ();
  test_communication_unknown_mode_unclear ();
  test_communication_metadata_gap_unclear ();
  test_alignment_no_active_agents_unclear ();
  test_alignment_metadata_gap_unclear ();
  test_alignment_no_bound_goal_unclear ();
  test_alignment_all_assigned_aligned ();
  test_alignment_some_unassigned_watch ();
  test_evidence_capped_at_two ();
  print_endline "test_briefing_sections: all assertions passed"
