(* Cycle 25 / Tier A8 — Persona_contract tests. *)

module P = Crew.Persona_contract
module C = Crew.Crew_types

(* ─── Static contract values ──────────────────────────────────── *)

let test_analyst_contract_kind () =
  assert (P.persona_kind P.analyst_contract = C.Analyst);
  assert (P.name P.analyst_contract = "analyst")

let test_executor_contract_kind () =
  assert (P.persona_kind P.executor_contract = C.Executor);
  assert (P.name P.executor_contract = "executor")

let test_scholar_contract_kind () =
  assert (P.persona_kind P.scholar_contract = C.Scholar);
  assert (P.name P.scholar_contract = "scholar")

let test_verifier_contract_kind () =
  assert (P.persona_kind P.verifier_contract = C.Verifier);
  assert (P.name P.verifier_contract = "verifier")

let test_descriptions_non_empty () =
  List.iter
    (fun any ->
      let d = P.any_description any in
      assert (String.length d > 0))
    P.all_personas

let test_responsibilities_non_empty () =
  let counts =
    List.map
      (fun (P.Any_persona c) -> List.length (P.core_responsibilities c))
      P.all_personas
  in
  List.iter (fun n -> assert (n > 0)) counts

(* ─── Forbidden tools follow design intent ────────────────────── *)

let test_executor_has_no_forbidden_tools () =
  assert (P.forbidden_tools P.executor_contract = [])

let test_scholar_forbids_writes () =
  let forbidden = P.forbidden_tools P.scholar_contract in
  assert (List.mem "shell_write" forbidden);
  assert (List.mem "file_write" forbidden)

let test_verifier_forbids_writes () =
  let forbidden = P.forbidden_tools P.verifier_contract in
  assert (List.mem "shell_write" forbidden);
  assert (List.mem "file_write" forbidden)

let test_analyst_forbids_external_api () =
  assert (List.mem "external_api_call" (P.forbidden_tools P.analyst_contract))

(* ─── Existential capture ────────────────────────────────────── *)

let test_all_personas_count () =
  assert (List.length P.all_personas = 4)

let test_all_personas_kinds_in_order () =
  let kinds = List.map P.any_persona_kind P.all_personas in
  assert (kinds = [ C.Analyst; C.Executor; C.Scholar; C.Verifier ])

let test_any_persona_round_trip_via_kind () =
  let names_via_any = List.map P.any_name P.all_personas in
  let canonical =
    List.map C.persona_kind_to_string
      [ C.Analyst; C.Executor; C.Scholar; C.Verifier ]
  in
  assert (names_via_any = canonical)

(* ─── JSON ────────────────────────────────────────────────────── *)

let test_to_json_shape () =
  let j = P.to_json P.analyst_contract in
  match j with
  | `Assoc kv ->
      assert (List.assoc "name" kv = `String "analyst");
      assert (List.mem_assoc "kind" kv);
      assert (List.mem_assoc "description" kv);
      assert (List.mem_assoc "core_responsibilities" kv);
      assert (List.mem_assoc "forbidden_tools" kv)
  | _ -> assert false

let test_to_json_kind_round_trip () =
  let j = P.to_json P.scholar_contract in
  match j with
  | `Assoc kv -> (
      let k_json = List.assoc "kind" kv in
      match C.persona_kind_of_json k_json with
      | Ok C.Scholar -> ()
      | _ -> assert false)
  | _ -> assert false

let test_any_to_json_matches_to_json () =
  let direct = P.to_json P.executor_contract in
  let via_any = P.any_to_json (P.Any_persona P.executor_contract) in
  assert (direct = via_any)

(* ─── Compile-time discrimination smoke (compiles → passes) ──── *)

(* The following functions exist purely for the compiler to check
   that contract values cannot be cross-applied between personas.
   If P.analyst contract and P.executor contract were the same
   type, the body of [accept_analyst] would compile with
   [P.executor_contract], breaking type discipline. *)

let _accept_analyst (_c : P.analyst P.contract) = ()
let _accept_executor (_c : P.executor P.contract) = ()
let _accept_scholar (_c : P.scholar P.contract) = ()
let _accept_verifier (_c : P.verifier P.contract) = ()

let test_compile_time_discrimination () =
  _accept_analyst P.analyst_contract;
  _accept_executor P.executor_contract;
  _accept_scholar P.scholar_contract;
  _accept_verifier P.verifier_contract

let () =
  test_analyst_contract_kind ();
  test_executor_contract_kind ();
  test_scholar_contract_kind ();
  test_verifier_contract_kind ();
  test_descriptions_non_empty ();
  test_responsibilities_non_empty ();
  test_executor_has_no_forbidden_tools ();
  test_scholar_forbids_writes ();
  test_verifier_forbids_writes ();
  test_analyst_forbids_external_api ();
  test_all_personas_count ();
  test_all_personas_kinds_in_order ();
  test_any_persona_round_trip_via_kind ();
  test_to_json_shape ();
  test_to_json_kind_round_trip ();
  test_any_to_json_matches_to_json ();
  test_compile_time_discrimination ();
  print_endline "test_persona_contract: all assertions passed"
