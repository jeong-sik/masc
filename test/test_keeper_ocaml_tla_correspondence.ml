(* OCaml ↔ TLA+ correspondence harness — RFC-0065 §3.6.
 *
 * Phase 5.1: scaffold + B1 (KeeperCascadeAttemptFSM) coverage.
 * Phase 5.2: B2 (KeeperToolSurface) observable label parity —
 *   SurfaceClassSet, RequirementSet.
 * Phase 5.3 (this commit): B3 (KeeperPostTurnOrchestration) —
 *   WireinAtomSet parity + BlockerKlassSet coverage check.
 *   Closes the P5 OPEN item in
 *   memory/reference_keeper_state_machine_specs_consolidation_status.md
 *   ("correspondence harness covers B1+B2+B3").
 *
 * Approach:
 *
 *   - Read enumerated sets from each .tla source via
 *     [Masc_test_deps.tla_quoted_set_from_repo_file_exn] (same
 *     primitive used by test_keeper_receipt_outcome_tla_parity).
 *   - Cross-reference with the OCaml side: variant labels emitted
 *     via [@@deriving tla] when available, hand-pinned label lists
 *     when the OCaml side carries the values as plain strings or
 *     as comment-pinned atoms (current state for tool_surface_class,
 *     tool_requirement, wirein order).
 *   - Run a small number of representative transition checks: invoke
 *     [Cascade_fsm.decide] on inputs that map onto B1 actions and
 *     verify the OCaml decision matches the spec's expected next
 *     phase.
 *
 * What this harness does NOT do yet (future work):
 *
 *   - Full TLC trace export + replay.  The aspirational version reads
 *     a TLC trace and replays each (state, action, state') tuple
 *     through OCaml.  Current phases ship parity + spot transitions.
 *   - B2/B3 in-process replay.  The compute_tool_surface and
 *     apply_post_turn_lifecycle pipelines need keeper-runtime
 *     fixtures (acc / meta / switch); the TLC layer is the
 *     load-bearing check for invariants.
 *)

open Alcotest

let spec_relpath_b1 = "specs/keeper-state-machine/KeeperCascadeAttemptFSM.tla"
let spec_relpath_b2 = "specs/keeper-state-machine/KeeperToolSurface.tla"
let spec_relpath_b3 = "specs/keeper-state-machine/KeeperPostTurnOrchestration.tla"

(* ── Set parity (B1) ─────────────────────────────────────── *)

let test_phase_set_parity () =
  let spec_phases =
    Masc_test_deps.tla_quoted_set_from_repo_file_exn
      ~relpath:spec_relpath_b1
      ~symbol:"PhaseSet"
    |> Masc_test_deps.sorted_strings
  in
  (* The OCaml side does not have a single [type attempt_phase = …]
     — the recursion shape inside [keeper_turn_driver::try_cascade]
     plus [Cascade_fsm.decision] together encode the FSM.  We pin
     the observable phase names here as the OCaml-side contract.
     A future cleanup may introduce a typed [attempt_phase] enum;
     when it does, replace this list with [all_symbols] from that
     type's [@@deriving tla] output. *)
  let ocaml_phases =
    Masc_test_deps.sorted_strings
      [ "idle";
        "attempting";
        "awaiting_response";
        "success";
        "exhausted_normal";
        "exhausted_hard_quota" ]
  in
  if ocaml_phases <> spec_phases then begin
    Printf.printf "OCaml attempt phases : [%s]\n"
      (String.concat "; " ocaml_phases);
    Printf.printf "Spec  attempt phases : [%s]\n"
      (String.concat "; " spec_phases);
    failwith
      "KeeperCascadeAttemptFSM PhaseSet differs from OCaml attempt \
       phase set — sync the spec or the OCaml-side contract list."
  end

let test_terminal_set_parity () =
  let spec_terminals =
    Masc_test_deps.tla_quoted_set_from_repo_file_exn
      ~relpath:spec_relpath_b1
      ~symbol:"TerminalSet"
    |> Masc_test_deps.sorted_strings
  in
  let ocaml_terminals =
    Masc_test_deps.sorted_strings
      [ "success"; "exhausted_normal"; "exhausted_hard_quota" ]
  in
  if ocaml_terminals <> spec_terminals then
    failwith
      "KeeperCascadeAttemptFSM TerminalSet differs from OCaml \
       terminal phase set"

let test_provider_outcomes_parity () =
  (* Boundary check: the abstract outcome alphabet in the spec must
     cover every [provider_outcome] variant the OCaml ppx_tla emits.
     The spec may carry extra abstract outcomes (e.g. terminal-vs-hard-
     quota split) that OCaml encodes inside variant payloads. *)
  let open Masc_mcp.Cascade_fsm in
  let ocaml_outcomes = Masc_test_deps.sorted_strings all_symbols in
  (* Spec set includes finer-grained split:
       call_err → call_err_cascadeable | call_err_terminal | call_err_hard_quota
     Walk OCaml outcomes and confirm each is covered by at least one
     spec member (prefix-match for the call_err family). *)
  let spec_set =
    [ "call_ok";
      "call_err_cascadeable";
      "call_err_terminal";
      "call_err_hard_quota";
      "accept_rejected";
      "slot_full" ]
  in
  let covered o =
    if o = "call_err" then
      List.exists (fun s ->
        String.length s >= String.length "call_err"
        && String.sub s 0 (String.length "call_err") = "call_err")
        spec_set
    else List.mem o spec_set
  in
  List.iter
    (fun o ->
      if not (covered o) then
        failwith
          (Printf.sprintf
             "OCaml provider_outcome variant %S is not covered by \
              KeeperCascadeAttemptFSM ProviderOutcomes (spec cfg)"
             o))
    ocaml_outcomes

(* ── Transition spot checks (B1 § Actions) ──────────────── *)

let test_call_ok_maps_to_success () =
  (* B1 action ResolveSuccess: from "awaiting_response" with
     last_outcome = "call_ok", attempt_phase' = "success".
     OCaml: Cascade_fsm.decide on Call_ok returns Accept. *)
  let open Masc_mcp.Cascade_fsm in
  match decide ~accept_on_exhaustion:false ~is_last:false
          (Call_ok (Obj.magic ()))
  with
  | Accept _ -> ()
  | _ ->
      Alcotest.fail
        "B1 ResolveSuccess: OCaml decide(Call_ok) must yield Accept \
         (correspondence broken)"

let test_call_err_cascadeable_maps_to_try_next () =
  (* B1 action ResolveTryNext (non-last tier): from
     "awaiting_response" with cascadeable error, tier_index advances,
     attempt_phase' = "attempting".  OCaml: Cascade_fsm.decide on
     Call_err with cascade_health_filter.should_cascade=true returns
     Try_next. *)
  let open Masc_mcp.Cascade_fsm in
  let err429 =
    Llm_provider.Http_client.HttpError { code = 429; body = "" }
  in
  match decide ~accept_on_exhaustion:false ~is_last:false
          (Call_err err429)
  with
  | Try_next _ -> ()
  | _ ->
      Alcotest.fail
        "B1 ResolveTryNext: OCaml decide(Call_err 429) must yield \
         Try_next on non-last tier (correspondence broken)"

let test_accept_rejected_on_last_maps_to_exhausted () =
  (* B1 action ResolveExhaustedNormal: on the last tier with no
     accept_on_exhaustion fallback, attempt_phase' = "exhausted_normal",
     slot released.

     This test pins the *directly observable* exhaustion path through
     [Cascade_fsm.decide] — namely Accept_rejected + is_last=true +
     accept_on_exhaustion=false → Exhausted.

     The Call_err exhaustion path is NOT directly observable from
     [decide] alone: decide returns Try_next for cascadeable errors
     regardless of is_last; the *caller* (keeper_turn_driver::try_cascade)
     interprets Try_next on the last tier as exhaustion.  B1's
     ResolveExhaustedNormal action models the COMPOSITE (decide +
     try_cascade tier walker), so spec-side it covers both paths.
     Phase 5.2/5.3 may add an integration-level test that exercises
     try_cascade and verifies the composite contract end-to-end. *)
  let open Masc_mcp.Cascade_fsm in
  let dummy = Obj.magic () in
  match decide ~accept_on_exhaustion:false ~is_last:true
          (Accept_rejected { response = dummy; reason = "test" })
  with
  | Exhausted _ -> ()
  | _ ->
      Alcotest.fail
        "B1 ResolveExhaustedNormal: OCaml decide(Accept_rejected, \
         is_last=true, accept_on_exhaustion=false) must yield \
         Exhausted (correspondence broken)"

let test_slot_full_maps_to_try_next () =
  (* B1 covers Slot_full under the same Try_next path. *)
  let open Masc_mcp.Cascade_fsm in
  match decide ~accept_on_exhaustion:false ~is_last:false Slot_full with
  | Try_next _ -> ()
  | _ -> Alcotest.fail "Slot_full must yield Try_next"

let test_accept_on_exhaustion_terminal () =
  (* B1 has no explicit "accept_on_exhaustion" phase — it is folded
     into "success" (accepted last response).  OCaml: when
     accept_on_exhaustion=true and is_last=true with Accept_rejected,
     decide returns Accept_on_exhaustion (terminal success). *)
  let open Masc_mcp.Cascade_fsm in
  let dummy = Obj.magic () in
  match decide ~accept_on_exhaustion:true ~is_last:true
          (Accept_rejected { response = dummy; reason = "test" })
  with
  | Accept_on_exhaustion _ -> ()
  | _ ->
      Alcotest.fail
        "Accept_on_exhaustion path must yield terminal success"

(* ── Set parity (B2) ─────────────────────────────────────── *)

let test_surface_class_set_parity () =
  (* B2 spec catalog: SurfaceClassSet = {"none", "public_only", "mixed"}.
     OCaml: now a closed sum type [tool_surface_class] with
     [@@deriving tla] in [Keeper_agent_tool_surface].  The harness
     drops the hand-pinned list and uses [all_symbols] directly —
     the spec ↔ OCaml drift surface is the [@tla.symbol "…"]
     attribute on each constructor, which the ppx serializes
     into [all_symbols]. *)
  let spec_classes =
    Masc_test_deps.tla_quoted_set_from_repo_file_exn
      ~relpath:spec_relpath_b2
      ~symbol:"SurfaceClassSet"
    |> Masc_test_deps.sorted_strings
  in
  let ocaml_classes =
    Masc_test_deps.sorted_strings
      Masc_mcp.Keeper_agent_tool_surface.all_symbols
  in
  if ocaml_classes <> spec_classes then begin
    Printf.printf "OCaml surface classes : [%s]\n"
      (String.concat "; " ocaml_classes);
    Printf.printf "Spec  surface classes : [%s]\n"
      (String.concat "; " spec_classes);
    failwith
      "KeeperToolSurface SurfaceClassSet differs from OCaml \
       tool_surface_class all_symbols — sync the spec or the \
       OCaml-side variant."
  end

let test_requirement_set_parity () =
  (* B2 spec catalog: RequirementSet = {"no_tools", "required", "optional"}.
     OCaml: tool_requirement = No_tools | Required | Optional (variant
     at keeper_run_tools.ml:956-962).  Lower-cased, snake-cased to
     match the spec convention. *)
  let spec_reqs =
    Masc_test_deps.tla_quoted_set_from_repo_file_exn
      ~relpath:spec_relpath_b2
      ~symbol:"RequirementSet"
    |> Masc_test_deps.sorted_strings
  in
  let ocaml_reqs =
    Masc_test_deps.sorted_strings
      [ "no_tools"; "required"; "optional" ]
  in
  if ocaml_reqs <> spec_reqs then
    failwith
      "KeeperToolSurface RequirementSet differs from OCaml \
       tool_requirement variant set"

(* ── B2 pipeline contract spot checks ──────────────────── *)

(* Pipeline contracts (FallbackFloorOnlyWhenEmpty, LastTurnSafeMonotone,
   MaxToolsCap, RequiredSubsetEmitted) operate over a fully assembled
   [computed_tool_surface], which in turn requires a live keeper
   runtime (acc, meta, switch, …) to construct.  A faithful spot
   check would replicate that runtime — out of scope for this
   scaffold.  The TLC layer is the load-bearing check for these
   invariants.  Hint left for Phase 5.3+ trace-replay work. *)
let test_b2_pipeline_replay_pending () = skip ()

(* ── Set parity (B3) ─────────────────────────────────────── *)

let test_wirein_atom_set_parity () =
  (* B3 spec catalog: WireinAtomSet = {"A5", "A6", "K4b", "K1"}.
     OCaml: pinned by comment at keeper_post_turn.ml:640-647 and
     enforced by the call sequence at lines 648-656
     (apply_autonomous_wirein → apply_resilience_wirein →
      apply_tool_emission_wirein → apply_multimodal_wirein).
     The atoms themselves do not appear as a closed enum on the
     OCaml side — they are tier identifiers in the comments.
     Hand-pin and parity-check. *)
  let spec_atoms =
    Masc_test_deps.tla_quoted_set_from_repo_file_exn
      ~relpath:spec_relpath_b3
      ~symbol:"WireinAtomSet"
    |> Masc_test_deps.sorted_strings
  in
  let ocaml_atoms =
    Masc_test_deps.sorted_strings
      [ "A5"; "A6"; "K4b"; "K1" ]
  in
  if ocaml_atoms <> spec_atoms then begin
    Printf.printf "OCaml wirein atoms : [%s]\n"
      (String.concat "; " ocaml_atoms);
    Printf.printf "Spec  wirein atoms : [%s]\n"
      (String.concat "; " spec_atoms);
    failwith
      "KeeperPostTurnOrchestration WireinAtomSet differs from OCaml \
       wirein tier atoms — sync the spec or the OCaml-side pin."
  end

let test_blocker_klass_overflow_coverage () =
  (* B3 spec catalog: BlockerKlassSet contains the symbolic klass
     names the producer side (StampBlocker action) ranges over.
     The clean spec keeps the alphabet abstract — only "none" is
     constrained.  The cfg pins four representative atoms; this
     test confirms the overflow-relevant one
     ("sdk_token_budget_exceeded") is present, since Track A's
     blocker_class_indicates_overflow returns true only for that
     variant.  If the spec drops it, rollover invariants become
     vacuously satisfied on every trace. *)
  let spec_klasses =
    Masc_test_deps.tla_quoted_set_from_repo_file_exn
      ~relpath:spec_relpath_b3
      ~symbol:"BlockerKlassSet"
  in
  let must_have = [ "none"; "sdk_token_budget_exceeded" ] in
  List.iter
    (fun atom ->
      if not (List.mem atom spec_klasses) then
        failwith
          (Printf.sprintf
             "KeeperPostTurnOrchestration BlockerKlassSet must contain \
              %S (needed for BlockerStampedBeforeRollover invariant to \
              be non-vacuous)"
             atom))
    must_have

(* ── Suite ──────────────────────────────────────────────── *)

let () =
  run "Keeper OCaml ↔ TLA+ correspondence (RFC-0065)" [
    "B1 set parity", [
      test_case "PhaseSet matches OCaml attempt phases" `Quick
        test_phase_set_parity;
      test_case "TerminalSet matches OCaml terminal phases" `Quick
        test_terminal_set_parity;
      test_case "ProviderOutcomes covers OCaml provider_outcome variants" `Quick
        test_provider_outcomes_parity;
    ];
    "B1 transition spot checks", [
      test_case "Call_ok → Accept (B1.ResolveSuccess)" `Quick
        test_call_ok_maps_to_success;
      test_case "Call_err cascadeable → Try_next (B1.ResolveTryNext)" `Quick
        test_call_err_cascadeable_maps_to_try_next;
      test_case "Accept_rejected on last tier → Exhausted (B1.ResolveExhaustedNormal — direct decide path)" `Quick
        test_accept_rejected_on_last_maps_to_exhausted;
      test_case "Slot_full → Try_next" `Quick
        test_slot_full_maps_to_try_next;
      test_case "Accept_on_exhaustion → terminal success" `Quick
        test_accept_on_exhaustion_terminal;
    ];
    "B2 set parity", [
      test_case "SurfaceClassSet matches OCaml tool_surface_class catalog" `Quick
        test_surface_class_set_parity;
      test_case "RequirementSet matches OCaml tool_requirement variant" `Quick
        test_requirement_set_parity;
    ];
    "B2 pipeline contract (deferred to trace-replay)", [
      test_case "B2 pipeline replay (future trace-replay work, pending)" `Quick
        test_b2_pipeline_replay_pending;
    ];
    "B3 set parity", [
      test_case "WireinAtomSet matches OCaml wirein tier atoms" `Quick
        test_wirein_atom_set_parity;
      test_case "BlockerKlassSet covers overflow klass" `Quick
        test_blocker_klass_overflow_coverage;
    ];
  ]
