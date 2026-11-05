(** Pure-function unit tests for [Briefing_compactors].

    Audit P2 follow-up (2026-04-29 §3.1.2) — third of the four
    briefing_*.ml modules in the "테스트 완전 부재" group.

    [Briefing_compactors] reduces a workspace agent into a fixed-shape
    briefing row. Properties pinned for [compact_agent_json]:

    - 9-key shape pin.
    - assignment_status logic: blank current_task → "unassigned",
      else "assigned".
    - capabilities list capped at 2 (take 2). *)

module C = Briefing_compactors
module T = Masc_domain

(* ── Fixtures ──────────────────────────────────────────────── *)

let assoc_keys_sorted j =
  match j with
  | `Assoc kv -> List.sort compare (List.map fst kv)
  | _ -> []

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

(* ── compact_agent_json ───────────────────────────────────── *)

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

(* ── runner ───────────────────────────────────────────────── *)

let () =
  test_compact_agent_strict_keys ();
  test_compact_agent_assignment_status_assigned ();
  test_compact_agent_assignment_status_unassigned_when_none ();
  test_compact_agent_assignment_status_unassigned_when_blank ();
  test_compact_agent_capabilities_take_2 ();
  test_compact_agent_status_serialises_lowercase ();
  print_endline "test_briefing_compactors: all assertions passed"
