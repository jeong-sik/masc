(** Pure-function unit tests for [Briefing_compactors].

    Audit P2 follow-up (2026-04-29 §3.1.2) — third of the four
    briefing_*.ml modules in the "테스트 완전 부재" group.

    [Briefing_compactors] reduces raw domain JSON (sessions /
    keepers / agents) into a fixed-shape briefing payload.
    Properties pinned:

    1. {b relevant_sessions_for_briefing filtering}
       - Empty namespace → match all rooms.
       - Project / room_id matching with live-status allow-list
         {running, active, paused, starting, stopping, waiting},
         case-insensitive + whitespace-trimmed.
       - Recent-event window: keep if any recent_events ts_iso is
         within 3600s of [now_ts] (even when status is dead).

    2. {b compact_session_json strict shape} — output assoc has
       exactly 16 keys including [communication_summary] derived
       as ["%s · broadcast %d · portal %d"].

    3. {b compact_session_json fallback contract} — empty
       [recent_events] produces a sentinel last_event with
       event_type = "none" and the documented "unknown" /
       "not_recorded" defaults.

    4. {b compact_keeper_json strict shape} — 13 keys with
       max_len 160 truncation on current_task / last_reply_preview
       and 120 on skill_primary.

    5. {b compact_agent_json}
       - 9-key shape pin.
       - assignment_status logic: blank current_task → "unassigned",
         else "assigned".
       - capabilities list capped at 2 (take 2). *)

module C = Masc_mcp.Briefing_compactors
module T = Masc_domain

(* ── Fixtures ──────────────────────────────────────────────── *)

let json_string s = `String s

let assoc_keys_sorted j =
  match j with
  | `Assoc kv -> List.sort compare (List.map fst kv)
  | _ -> []

(* Session JSON helper — minimal shape that the compactor
   navigates through. *)
let session_fixture ?(session_id = "s-1") ?(project = "room-A")
    ?(room_id = "room-A") ?(goal = "ship feature") ?(status = "active")
    ?(summary_status = "active") ?(comm_mode = "async")
    ?(broadcast = 3) ?(portal = 5) ?(recent = []) () =
  `Assoc
    [
      ("session_id", json_string session_id);
      ( "status",
        `Assoc
          [
            ( "session",
              `Assoc
                [
                  ("project", json_string project);
                  ("room_id", json_string room_id);
                  ("goal", json_string goal);
                  ("status", json_string status);
                  ("agent_names", `List [ json_string "a1" ]);
                ] );
            ( "summary",
              `Assoc
                [
                  ("status", json_string summary_status);
                  ("elapsed_sec", `Int 120);
                  ("progress_pct", `Float 0.42);
                  ("done_delta_total", `Int 7);
                ] );
            ( "team_health",
              `Assoc
                [
                  ("status", json_string "healthy");
                  ("active_agents_count", `Int 2);
                  ("required_agents", `Int 3);
                ] );
            ( "communication_metrics",
              `Assoc
                [
                  ("mode", json_string comm_mode);
                  ("broadcast_count", `Int broadcast);
                  ("portal_count", `Int portal);
                ] );
          ] );
      ("recent_events", `List recent);
    ]

let recent_event ?(event_type = "task_done") ?(ts_iso = "2026-05-05T03:00:00Z")
    ?(actor = "alice") ?(task_title = "do thing")
    ?(result = "ok") ?(reason = "") () =
  `Assoc
    [
      ("event_type", json_string event_type);
      ("ts_iso", json_string ts_iso);
      ( "detail",
        `Assoc
          [
            ("actor", json_string actor);
            ("task_title", json_string task_title);
            ("result", json_string result);
            ("reason", json_string reason);
          ] );
    ]

let keeper_fixture ?(name = "k-1") ?(status = "active")
    ?(agent_name = "claude-1") ?(generation = 2) ?(context_ratio = 0.42)
    ?(current_task = "do thing") ?(last_reply_status = "replied")
    ?(last_reply_preview = "preview text") ?(skill_primary = "ocaml")
    () =
  `Assoc
    [
      ("name", json_string name);
      ("status", json_string status);
      ("agent_name", json_string agent_name);
      ("generation", `Int generation);
      ("context_ratio", `Float context_ratio);
      ("last_turn_ago_s", `Float 30.0);
      ("compaction_count", `Int 1);
      ("handoff_count_total", `Int 0);
      ("active_goal_ids", `List [ json_string "g1"; json_string "g2" ]);
      ("skill_primary", json_string skill_primary);
      ( "diagnostic",
        `Assoc
          [
            ("last_reply_status", json_string last_reply_status);
            ("last_reply_preview", json_string last_reply_preview);
          ] );
      ("agent", `Assoc [ ("current_task", json_string current_task) ]);
    ]

let agent_fixture ?(name = "a-1") ?(agent_type = "claude")
    ?(status = T.Active) ?(capabilities = [ "ocaml"; "python"; "rust" ])
    ?(current_task = Some "implement X")
    ?(joined_at = "2026-05-05T00:00:00Z")
    ?(last_seen = "2026-05-05T03:00:00Z") () : T.agent =
  {
    id = None;
    name;
    agent_type;
    status;
    capabilities;
    current_task;
    joined_at;
    last_seen;
    meta = None;
  }

let string_of j =
  match j with `String s -> s | _ -> "<non-string>"

let int_of j = match j with `Int n -> n | _ -> -1

(* ── (1) relevant_sessions_for_briefing ────────────────────── *)

let test_relevant_empty_namespace_matches_all () =
  (* When current_namespace is "" (or whitespace), trim_to_option
     returns None, and room_matches always returns true. *)
  let s = session_fixture ~project:"any-room" () in
  let result =
    C.relevant_sessions_for_briefing ~current_namespace:""
      ~now_ts:0.0 [ s ]
  in
  assert (List.length result = 1)

let test_relevant_namespace_matching_keeps () =
  let s = session_fixture ~project:"room-X" ~status:"active"
              ~summary_status:"active" () in
  let result =
    C.relevant_sessions_for_briefing ~current_namespace:"room-X"
      ~now_ts:0.0 [ s ]
  in
  assert (List.length result = 1)

let test_relevant_namespace_mismatch_drops () =
  let s = session_fixture ~project:"room-X" ~status:"active" () in
  let result =
    C.relevant_sessions_for_briefing ~current_namespace:"room-Y"
      ~now_ts:0.0 [ s ]
  in
  assert (result = [])

let test_relevant_room_id_fallback_when_project_blank () =
  (* If project is blank, fall back to room_id for matching. *)
  let s =
    session_fixture ~project:"" ~room_id:"room-Z"
      ~status:"active" ~summary_status:"active" ()
  in
  let result =
    C.relevant_sessions_for_briefing ~current_namespace:"room-Z"
      ~now_ts:0.0 [ s ]
  in
  assert (List.length result = 1)

let test_relevant_dead_status_drops () =
  let s =
    session_fixture ~project:"room-A" ~status:"failed"
      ~summary_status:"failed" ~recent:[] ()
  in
  let result =
    C.relevant_sessions_for_briefing ~current_namespace:"room-A"
      ~now_ts:0.0 [ s ]
  in
  assert (result = [])

let test_relevant_live_status_case_insensitive_trim () =
  let s =
    session_fixture ~project:"room-A"
      ~summary_status:"  RUNNING  " ~status:"  RUNNING  " ()
  in
  let result =
    C.relevant_sessions_for_briefing ~current_namespace:"room-A"
      ~now_ts:0.0 [ s ]
  in
  assert (List.length result = 1)

let test_relevant_recent_event_within_hour_keeps_dead_session () =
  (* Session is dead, but a recent_event ts is within 3600s of
     now_ts → still kept. *)
  let now_ts = 1_714_953_600.0 in (* 2026-05-05 ish *)
  let recent_ts_iso =
    let tm = Unix.gmtime (now_ts -. 1800.0) in
    Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
      (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
      tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec
  in
  let s =
    session_fixture ~project:"room-A" ~status:"failed"
      ~summary_status:"failed"
      ~recent:[ recent_event ~ts_iso:recent_ts_iso () ] ()
  in
  let result =
    C.relevant_sessions_for_briefing ~current_namespace:"room-A"
      ~now_ts [ s ]
  in
  assert (List.length result = 1)

let test_relevant_recent_event_outside_hour_drops_dead_session () =
  let now_ts = 1_714_953_600.0 in
  let stale_ts_iso =
    let tm = Unix.gmtime (now_ts -. 7200.0) in
    Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
      (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
      tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec
  in
  let s =
    session_fixture ~project:"room-A" ~status:"failed"
      ~summary_status:"failed"
      ~recent:[ recent_event ~ts_iso:stale_ts_iso () ] ()
  in
  let result =
    C.relevant_sessions_for_briefing ~current_namespace:"room-A"
      ~now_ts [ s ]
  in
  assert (result = [])

(* ── (2) compact_session_json strict shape ─────────────────── *)

let test_compact_session_strict_keys () =
  let s = session_fixture () in
  let out = C.compact_session_json s in
  let expected_keys =
    List.sort compare
      [
        "session_id"; "goal"; "project"; "status"; "agent_names";
        "elapsed_sec"; "progress_pct"; "done_delta_total";
        "team_health"; "active_agents_count"; "required_agents";
        "communication_mode"; "broadcast_count"; "portal_count";
        "communication_summary"; "last_event";
      ]
  in
  assert (assoc_keys_sorted out = expected_keys)

let test_compact_session_communication_summary_format () =
  (* "%s · broadcast %d · portal %d" *)
  let s =
    session_fixture ~comm_mode:"async" ~broadcast:7 ~portal:11 ()
  in
  let out = C.compact_session_json s in
  match out with
  | `Assoc kv ->
      let summary =
        match List.assoc_opt "communication_summary" kv with
        | Some (`String s) -> s
        | _ -> ""
      in
      assert (summary = "async \xc2\xb7 broadcast 7 \xc2\xb7 portal 11")
  | _ -> assert false

(* ── (3) last_event sentinel when recent_events empty ─────── *)

let test_compact_session_last_event_empty_uses_sentinel () =
  let s = session_fixture ~recent:[] () in
  let out = C.compact_session_json s in
  match out with
  | `Assoc kv -> (
      match List.assoc_opt "last_event" kv with
      | Some (`Assoc le) ->
          let get k =
            match List.assoc_opt k le with
            | Some (`String s) -> s
            | _ -> "<missing>"
          in
          assert (get "event_type" = "none");
          assert (get "ts_iso" = "unknown");
          assert (get "actor" = "unknown");
          assert (get "task_title" = "no recent session events");
          assert (get "result" = "not_recorded");
          assert (get "reason" = "not_recorded")
      | _ -> assert false)
  | _ -> assert false

let test_compact_session_last_event_uses_latest () =
  (* When multiple recent_events present, last_event mirrors the
     LAST element of the list (List.rev pattern in impl). *)
  let s =
    session_fixture
      ~recent:
        [
          recent_event ~event_type:"first" ~actor:"alice"
            ~task_title:"first task" ();
          recent_event ~event_type:"latest" ~actor:"bob"
            ~task_title:"latest task" ();
        ]
      ()
  in
  let out = C.compact_session_json s in
  match out with
  | `Assoc kv -> (
      match List.assoc_opt "last_event" kv with
      | Some (`Assoc le) ->
          assert (
            (List.assoc_opt "event_type" le = Some (`String "latest")));
          assert (
            (List.assoc_opt "actor" le = Some (`String "bob")))
      | _ -> assert false)
  | _ -> assert false

let test_compact_session_goal_default_when_blank () =
  (* Goal field default = "unassigned" when JSON is blank/Null. *)
  let s =
    `Assoc
      [
        ("session_id", `String "s1");
        ( "status",
          `Assoc
            [
              ( "session",
                `Assoc
                  [
                    ("project", `String "room-A");
                    ("status", `String "active");
                    ("goal", `String "");
                    ("agent_names", `List []);
                  ] );
              ("summary", `Assoc [ ("status", `String "active") ]);
              ("team_health", `Assoc []);
              ("communication_metrics", `Assoc []);
            ] );
        ("recent_events", `List []);
      ]
  in
  let out = C.compact_session_json s in
  match out with
  | `Assoc kv ->
      assert (
        List.assoc_opt "goal" kv = Some (`String "unassigned"))
  | _ -> assert false

(* ── (4) compact_keeper_json strict shape ─────────────────── *)

let test_compact_keeper_strict_keys () =
  let k = keeper_fixture () in
  let out = C.compact_keeper_json k in
  let expected_keys =
    List.sort compare
      [
        "name"; "status"; "agent_name"; "generation"; "context_ratio";
        "last_turn_ago_s"; "compaction_count"; "handoff_count_total";
        "current_task"; "last_reply_status"; "last_reply_preview";
        "active_goal_ids"; "skill_primary";
      ]
  in
  assert (assoc_keys_sorted out = expected_keys)

let test_compact_keeper_max_len_truncation () =
  (* current_task / last_reply_preview should be capped at 160. *)
  let long_text = String.make 300 'x' in
  let k =
    keeper_fixture ~current_task:long_text
      ~last_reply_preview:long_text ()
  in
  let out = C.compact_keeper_json k in
  match out with
  | `Assoc kv ->
      let ct =
        match List.assoc_opt "current_task" kv with
        | Some (`String s) -> s
        | _ -> ""
      in
      let lp =
        match List.assoc_opt "last_reply_preview" kv with
        | Some (`String s) -> s
        | _ -> ""
      in
      (* compact_text uses [max_bytes:(max_len-1)+3], which with
         a 3-byte UTF-8 ellipsis suffix tops out at 162 bytes for
         max_len=160. *)
      assert (String.length ct <= 162);
      assert (String.length lp <= 162);
      (* But truncation must have occurred (input was 300 'x'). *)
      assert (String.length ct < 300);
      assert (String.length lp < 300)
  | _ -> assert false

let test_compact_keeper_default_unknown_when_missing_keys () =
  (* Keeper JSON missing diagnostic block → defaults applied. *)
  let k = `Assoc [ ("name", `String "k") ] in
  let out = C.compact_keeper_json k in
  match out with
  | `Assoc kv ->
      let get k =
        match List.assoc_opt k kv with
        | Some (`String s) -> s
        | _ -> ""
      in
      assert (get "status" = "unknown");
      assert (get "agent_name" = "unknown");
      assert (get "current_task" = "unassigned");
      assert (get "last_reply_status" = "not_recorded");
      assert (get "last_reply_preview" = "not_recorded")
  | _ -> assert false

(* ── (5) compact_agent_json ───────────────────────────────── *)

let test_compact_agent_strict_keys () =
  let a = agent_fixture () in
  let out = C.compact_agent_json a in
  let expected_keys =
    List.sort compare
      [
        "name"; "agent_type"; "status"; "assignment_status";
        "current_focus"; "goal_hint"; "joined_at"; "last_seen";
        "capabilities";
      ]
  in
  assert (assoc_keys_sorted out = expected_keys)

let test_compact_agent_assignment_status_assigned () =
  let a = agent_fixture ~current_task:(Some "real task") () in
  let out = C.compact_agent_json a in
  match out with
  | `Assoc kv ->
      assert (
        List.assoc_opt "assignment_status" kv
        = Some (`String "assigned"));
      assert (
        List.assoc_opt "current_focus" kv
        = Some (`String "real task"))
  | _ -> assert false

let test_compact_agent_assignment_status_unassigned_when_none () =
  let a = agent_fixture ~current_task:None () in
  let out = C.compact_agent_json a in
  match out with
  | `Assoc kv ->
      assert (
        List.assoc_opt "assignment_status" kv
        = Some (`String "unassigned"));
      assert (
        List.assoc_opt "current_focus" kv
        = Some (`String "unassigned"))
  | _ -> assert false

let test_compact_agent_assignment_status_unassigned_when_blank () =
  let a = agent_fixture ~current_task:(Some "  ") () in
  let out = C.compact_agent_json a in
  match out with
  | `Assoc kv ->
      assert (
        List.assoc_opt "assignment_status" kv
        = Some (`String "unassigned"))
  | _ -> assert false

let test_compact_agent_capabilities_take_2 () =
  let a =
    agent_fixture ~capabilities:[ "a"; "b"; "c"; "d"; "e" ] ()
  in
  let out = C.compact_agent_json a in
  match out with
  | `Assoc kv -> (
      match List.assoc_opt "capabilities" kv with
      | Some (`List items) ->
          assert (List.length items = 2);
          let strs =
            List.map
              (function `String s -> s | _ -> "")
              items
          in
          assert (strs = [ "a"; "b" ])
      | _ -> assert false)
  | _ -> assert false

let test_compact_agent_status_serialises_lowercase () =
  (* T.string_of_agent_status returns lowercase strings. *)
  List.iter
    (fun (status, expected) ->
      let a = agent_fixture ~status () in
      let out = C.compact_agent_json a in
      match out with
      | `Assoc kv ->
          assert (
            List.assoc_opt "status" kv = Some (`String expected))
      | _ -> assert false)
    [
      (T.Active, "active");
      (T.Busy, "busy");
      (T.Listening, "listening");
      (T.Inactive, "inactive");
    ]

(* Avoid dead-let warnings from the helpers. *)
let _ = string_of
let _ = int_of

(* ── runner ───────────────────────────────────────────────── *)

let () =
  test_relevant_empty_namespace_matches_all ();
  test_relevant_namespace_matching_keeps ();
  test_relevant_namespace_mismatch_drops ();
  test_relevant_room_id_fallback_when_project_blank ();
  test_relevant_dead_status_drops ();
  test_relevant_live_status_case_insensitive_trim ();
  test_relevant_recent_event_within_hour_keeps_dead_session ();
  test_relevant_recent_event_outside_hour_drops_dead_session ();
  test_compact_session_strict_keys ();
  test_compact_session_communication_summary_format ();
  test_compact_session_last_event_empty_uses_sentinel ();
  test_compact_session_last_event_uses_latest ();
  test_compact_session_goal_default_when_blank ();
  test_compact_keeper_strict_keys ();
  test_compact_keeper_max_len_truncation ();
  test_compact_keeper_default_unknown_when_missing_keys ();
  test_compact_agent_strict_keys ();
  test_compact_agent_assignment_status_assigned ();
  test_compact_agent_assignment_status_unassigned_when_none ();
  test_compact_agent_assignment_status_unassigned_when_blank ();
  test_compact_agent_capabilities_take_2 ();
  test_compact_agent_status_serialises_lowercase ();
  print_endline "test_briefing_compactors: all assertions passed"
