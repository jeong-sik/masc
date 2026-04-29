(* Cycle 26 / Tier A9 — Crew_council tests. *)

module C = Crew.Crew_council
module P = Crew.Persona_contract
module T = Crew.Crew_types

(* ─── Phase tag mirror ────────────────────────────────────────── *)

let test_all_phase_tags () =
  assert (List.length C.all_phase_tags = 6);
  let strs = List.map C.phase_tag_to_string C.all_phase_tags in
  assert (strs = [ "propose"; "critique"; "research"; "debate"; "vote"; "decide" ])

let test_phase_to_tag_round_trip () =
  assert (C.phase_to_tag C.Propose = C.Tag_propose);
  assert (C.phase_to_tag C.Critique = C.Tag_critique);
  assert (C.phase_to_tag C.Research = C.Tag_research);
  assert (C.phase_to_tag C.Debate = C.Tag_debate);
  assert (C.phase_to_tag C.Vote = C.Tag_vote);
  assert (C.phase_to_tag C.Decide = C.Tag_decide)

let test_any_phase_to_string () =
  assert (C.any_phase_to_string (C.Any_phase C.Propose) = "propose");
  assert (C.any_phase_to_string (C.Any_phase C.Decide) = "decide")

(* ─── Transition GADT ─────────────────────────────────────────── *)

let test_all_transitions_count () =
  assert (List.length C.all_transitions = 5)

let test_transition_to_string () =
  assert (C.transition_to_string C.Propose_to_critique = "propose->critique");
  assert (C.transition_to_string C.Vote_to_decide = "vote->decide")

let test_transition_endpoints () =
  (match C.transition_from C.Propose_to_critique with
   | C.Propose -> ()
   | _ -> assert false);
  match C.transition_to C.Propose_to_critique with
  | C.Critique -> ()
  | _ -> assert false

let test_any_transition_to_string_lists_legal_chain () =
  let strs = List.map C.any_transition_to_string C.all_transitions in
  assert
    (strs
    = [
        "propose->critique";
        "critique->research";
        "research->debate";
        "debate->vote";
        "vote->decide";
      ])

(* ─── Timeout policy ──────────────────────────────────────────── *)

let test_default_timeout () =
  let t = C.default_timeout in
  assert (t.time_cap_per_phase_ms = 30_000);
  assert (t.global_deadline_ms = 180_000);
  (* Vote must not exceed half the global ceiling — 30k * 6 phases
     = 180k matches global, but each phase is well under global/2
     (90k). *)
  assert (t.time_cap_per_phase_ms < t.global_deadline_ms / 2)

(* ─── Council snapshot create + advance ──────────────────────── *)

let make_council () : C.propose C.t =
  let cid = Result.get_ok (T.council_id_of_string "test-council-001") in
  let members =
    [
      P.Any_persona P.analyst_contract;
      P.Any_persona P.executor_contract;
      P.Any_persona P.scholar_contract;
      P.Any_persona P.verifier_contract;
    ]
  in
  C.create ~council_id:cid ~members ~timeout:C.default_timeout ~now:1000.0

let test_create_starts_in_propose () =
  let c = make_council () in
  match C.current_phase c with
  | C.Propose -> ()
  | _ -> assert false

let test_create_preserves_metadata () =
  let c = make_council () in
  assert (T.council_id_to_string (C.council_id c) = "test-council-001");
  assert (List.length (C.members c) = 4);
  assert (Float.abs (C.started_at c -. 1000.0) < 1e-6);
  assert ((C.timeout c).time_cap_per_phase_ms = 30_000)

let test_advance_propose_to_critique () =
  let c0 = make_council () in
  let c1 = C.advance C.Propose_to_critique c0 in
  match C.current_phase c1 with
  | C.Critique -> ()
  | _ -> assert false

let test_advance_full_chain () =
  let c0 = make_council () in
  let c1 = C.advance C.Propose_to_critique c0 in
  let c2 = C.advance C.Critique_to_research c1 in
  let c3 = C.advance C.Research_to_debate c2 in
  let c4 = C.advance C.Debate_to_vote c3 in
  let c5 = C.advance C.Vote_to_decide c4 in
  match C.current_phase c5 with
  | C.Decide -> ()
  | _ -> assert false

let test_advance_preserves_council_id () =
  let c0 = make_council () in
  let c1 = C.advance C.Propose_to_critique c0 in
  assert (T.council_id_equal (C.council_id c0) (C.council_id c1))

(* ─── JSON ────────────────────────────────────────────────────── *)

let test_to_json_shape () =
  let c = make_council () in
  match C.to_json c with
  | `Assoc kv ->
      assert (List.assoc "phase" kv = `String "propose");
      assert (List.mem_assoc "council_id" kv);
      assert (List.mem_assoc "members" kv);
      assert (List.mem_assoc "started_at" kv);
      assert (List.mem_assoc "timeout" kv)
  | _ -> assert false

let test_any_council_to_json () =
  let c = make_council () in
  let any = C.Any_council c in
  let direct = C.to_json c in
  assert (C.any_council_to_json any = direct);
  assert (T.council_id_equal (C.any_council_id any) (C.council_id c))

(* ─── Compile-time discrimination smoke ───────────────────────── *)

let _accept_propose (_c : C.propose C.t) = ()
let _accept_decide (_c : C.decide C.t) = ()

let test_compile_time_phase_discrimination () =
  let c0 = make_council () in
  _accept_propose c0;
  let c5 =
    c0
    |> C.advance C.Propose_to_critique
    |> C.advance C.Critique_to_research
    |> C.advance C.Research_to_debate
    |> C.advance C.Debate_to_vote
    |> C.advance C.Vote_to_decide
  in
  _accept_decide c5

let () =
  test_all_phase_tags ();
  test_phase_to_tag_round_trip ();
  test_any_phase_to_string ();
  test_all_transitions_count ();
  test_transition_to_string ();
  test_transition_endpoints ();
  test_any_transition_to_string_lists_legal_chain ();
  test_default_timeout ();
  test_create_starts_in_propose ();
  test_create_preserves_metadata ();
  test_advance_propose_to_critique ();
  test_advance_full_chain ();
  test_advance_preserves_council_id ();
  test_to_json_shape ();
  test_any_council_to_json ();
  test_compile_time_phase_discrimination ();
  print_endline "test_crew_council: all assertions passed"
