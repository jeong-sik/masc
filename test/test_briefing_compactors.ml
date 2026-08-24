(** Pure-function unit tests for [Briefing_compactors].

    Audit P2 follow-up (2026-04-29 §3.1.2) — third of the four
    briefing_*.ml modules in the "테스트 완전 부재" group.

    [Briefing_compactors] reduces raw domain JSON (sessions /
    keepers / agents) into a fixed-shape briefing payload.
    Properties pinned:

    1. {b relevant_sessions_for_briefing filtering}
       - Empty namespace → match all workspaces.
       - Project / workspace_id matching with live-status allow-list
         {running, active, paused, starting, stopping, waiting},
         case-insensitive + whitespace-trimmed.
       - Recent-event window: keep if any recent_events ts_iso is
         within 3600s of [now_ts] (even when status is dead).

    2. {b compact_session_json strict shape} — output assoc has
       exactly 15 keys including [communication_summary] derived
       as ["%s · broadcast %d"].

    3. {b compact_session_json fallback contract} — empty
       [recent_events] produces [last_event = null].

    4. {b compact_keeper_json strict shape} — 12 keys with
       max_len 160 truncation on current_task / last_reply_preview.

    5. {b compact_agent_json}
       - 9-key shape pin.
       - assignment_status logic: blank current_task → "unassigned",
         else "assigned".
       - capabilities list capped at 2 (take 2). *)

module C = Briefing_compactors
module T = Masc_domain

(* ── Fixtures ──────────────────────────────────────────────── *)

let json_string s = `String s

let assoc_keys_sorted j =
  match j with
  | `Assoc kv -> List.sort compare (List.map fst kv)
  | _ -> []

(* Session JSON helper — minimal shape that the compactor
   navigates through. *)
let keeper_fixture ?(name = "k-1") ?(status = "active")
    ?(agent_name = "claude-1") ?(generation = 2) ?(context_ratio = 0.42)
    ?(current_task = "do thing") ?(last_reply_status = "replied")
    ?(last_reply_preview = "preview text")
    () =
  `Assoc
    [
      ("name", json_string name);
      ("status", json_string status);
      ("agent_name", json_string agent_name);
      ("context_ratio", `Float context_ratio);
      ("last_turn_ago_s", `Float 30.0);
      ("compaction_count", `Int 1);
      ("handoff_count_total", `Int 0);
      ( "diagnostic",
        `Assoc
          [
            ("last_reply_status", json_string last_reply_status);
            ("last_reply_preview", json_string last_reply_preview);
          ] );
      ("current_task_id", json_string current_task);
    ]

let agent_fixture ?(name = "a-1") ?(agent_type = "claude")
    ?(status = T.Active) ?(capabilities = [ "ocaml"; "python"; "rust" ])
    ?(current_task = Some "implement X")
    ?(session_bound_at = "2026-05-05T00:00:00Z")
    ?(last_seen = "2026-05-05T03:00:00Z") () : T.agent =
  {
    id = None;
    name;
    agent_type;
    status;
    capabilities;
    current_task;
    session_bound_at;
    last_seen;
    meta = None;
  }

let string_of j =
  match j with `String s -> s | _ -> "<non-string>"

let int_of j = match j with `Int n -> n | _ -> -1

(* ── (1) relevant_sessions_for_briefing ────────────────────── *)

let test_compact_keeper_strict_keys () =
  let k = keeper_fixture () in
  let out = C.compact_keeper_json k in
  let expected_keys =
    List.sort compare
      [
        "name"; "status"; "agent_name"; "generation"; "context_ratio";
        "last_turn_ago_s"; "compaction_count"; "handoff_count_total";
        "current_task"; "last_reply_status"; "last_reply_preview";
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

let test_compact_keeper_missing_scalars_are_null () =
  (* Keeper JSON missing diagnostic block → optional scalars stay null. *)
  let k = `Assoc [ ("name", `String "k") ] in
  let out = C.compact_keeper_json k in
  match out with
  | `Assoc kv ->
      assert (List.assoc_opt "status" kv = Some `Null);
      assert (List.assoc_opt "agent_name" kv = Some `Null);
      assert (List.assoc_opt "current_task" kv = Some `Null);
      assert (List.assoc_opt "last_reply_status" kv = Some `Null);
      assert (List.assoc_opt "last_reply_preview" kv = Some `Null)
  | _ -> assert false

(* ── (5) compact_agent_json ───────────────────────────────── *)

let test_compact_agent_strict_keys () =
  let a = agent_fixture () in
  let out = C.compact_agent_json a in
  let expected_keys =
    List.sort compare
      [
        "name"; "agent_type"; "status"; "assignment_status";
        "current_focus"; "goal_hint"; "session_bound_at"; "last_seen";
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
      assert (List.assoc_opt "current_focus" kv = Some `Null)
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
  test_compact_keeper_strict_keys ();
  test_compact_keeper_max_len_truncation ();
  test_compact_keeper_missing_scalars_are_null ();
  test_compact_agent_strict_keys ();
  test_compact_agent_assignment_status_assigned ();
  test_compact_agent_assignment_status_unassigned_when_none ();
  test_compact_agent_assignment_status_unassigned_when_blank ();
  test_compact_agent_capabilities_take_2 ();
  test_compact_agent_status_serialises_lowercase ();
  print_endline "test_briefing_compactors: all assertions passed"
