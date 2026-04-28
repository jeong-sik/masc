(* Parity test: [Keeper_turn_fsm.all_symbols] (derived by [ppx_tla])
   must match the [TurnStateSet] enumerated in
   [specs/keeper-turn-fsm/KeeperTurnFSM.tla].

   This test makes the spec-implementation drift visible at build time.
   When a constructor is added, removed, or renamed in either side, the
   other side must follow within the same PR or this test fails — which
   is the entire point of [@@deriving tla].

   Cycle 3 of the Kimi keeper FSM review plan; see
   [planning/claude-plans/30m-users-dancer-downloads-kimi-agent-ke-wobbly-shell.md]
   §10 ("formalized incompleteness") for the OCaml ↔ TLA+ identity goal. *)

(* Hardcoded copy of TurnStateSet from the spec. Kept in sync by hand
   for now — Cycle 3+ may parse the .tla file directly so this list is
   no longer a second source of truth. *)
let spec_turn_state_set =
  [
    "idle";
    "phase_gating";
    "cascade_routing";
    "awaiting_provider";
    "streaming";
    "awaiting_tool";
    "completing";
    "done";
    "failed";
    "cancelled";
  ]

let sort = List.sort String.compare

let test_all_symbols_match_spec () =
  let ocaml = sort Masc_mcp.Keeper_turn_fsm.all_symbols in
  let spec = sort spec_turn_state_set in
  if ocaml <> spec then begin
    Printf.printf "OCaml all_symbols  : [%s]\n"
      (String.concat "; " ocaml);
    Printf.printf "Spec  TurnStateSet : [%s]\n"
      (String.concat "; " spec);
    let only_ocaml = List.filter (fun s -> not (List.mem s spec)) ocaml in
    let only_spec = List.filter (fun s -> not (List.mem s ocaml)) spec in
    Printf.printf "Only in OCaml      : [%s]\n"
      (String.concat "; " only_ocaml);
    Printf.printf "Only in spec       : [%s]\n"
      (String.concat "; " only_spec);
    failwith
      "Keeper_turn_fsm.all_symbols differs from spec TurnStateSet — \
       update either the OCaml type, the [@tla.symbol] override, or the \
       spec."
  end

let test_to_tla_symbol_for_each_constructor () =
  (* Sanity: every nullary constructor round-trips through to_tla_symbol
     into the spec set. Parameterised constructors are exercised with a
     dummy payload. *)
  let probe_nullary symbol_should_be ctor =
    assert (Masc_mcp.Keeper_turn_fsm.to_tla_symbol ctor = symbol_should_be)
  in
  probe_nullary "idle" Masc_mcp.Keeper_turn_fsm.Idle;
  probe_nullary "phase_gating" Masc_mcp.Keeper_turn_fsm.Phase_gating;
  probe_nullary "cascade_routing" Masc_mcp.Keeper_turn_fsm.Cascade_routing;
  probe_nullary "awaiting_provider" Masc_mcp.Keeper_turn_fsm.Awaiting_provider;
  probe_nullary "streaming" Masc_mcp.Keeper_turn_fsm.Streaming;
  (* [@tla.symbol "awaiting_tool"] override exercised here. *)
  probe_nullary "awaiting_tool"
    Masc_mcp.Keeper_turn_fsm.Awaiting_tool_result;
  probe_nullary "completing" Masc_mcp.Keeper_turn_fsm.Completing;
  probe_nullary "done" Masc_mcp.Keeper_turn_fsm.Done;
  let dummy_failure =
    Masc_mcp.Keeper_turn_fsm.Failure_runtime_error "probe"
  in
  let dummy_cancel =
    Masc_mcp.Keeper_turn_fsm.Cancelled_supervisor_stop
  in
  assert (
    Masc_mcp.Keeper_turn_fsm.to_tla_symbol
      (Masc_mcp.Keeper_turn_fsm.Failed dummy_failure)
    = "failed");
  assert (
    Masc_mcp.Keeper_turn_fsm.to_tla_symbol
      (Masc_mcp.Keeper_turn_fsm.Cancelled dummy_cancel)
    = "cancelled")

let () =
  test_all_symbols_match_spec ();
  test_to_tla_symbol_for_each_constructor ();
  print_endline "keeper_turn_fsm TLA+ parity test: PASS"
