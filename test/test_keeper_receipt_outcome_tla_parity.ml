(* Parity test: [Keeper_execution_receipt.outcome_kind] (terminal subset)
   must match [ReceiptOutcomeSet] from
   [specs/keeper-turn-fsm/KeeperTurnFSM.tla], minus "receipt_unset" which
   is the initial-state-only marker and therefore is not representable
   on a terminal receipt per the [EveryTurnHasTerminalReceipt] safety
   invariant.

   Companion to [test_keeper_turn_fsm_tla_parity]: that test pins the
   state-set, this one pins the outcome-set. Together they make
   spec/implementation drift visible at build time when either side
   changes. *)

(* ── TLA+ spec parsing ───────────────────────────────────────

   Read [ReceiptOutcomeSet] directly out of [KeeperTurnFSM.tla],
   using the shared parser from [Masc_test_deps]. *)

(** Mechanically extract [ReceiptOutcomeSet] from the spec, then drop
    ["receipt_unset"] — initial-state-only marker, not representable
    on a terminal receipt per [EveryTurnHasTerminalReceipt]. *)
let spec_terminal_outcome_set : string list =
  Masc_test_deps.tla_quoted_set_from_repo_file_exn
    ~relpath:"specs/keeper-turn-fsm/KeeperTurnFSM.tla"
    ~symbol:"ReceiptOutcomeSet"
  |> List.filter (fun s -> not (String.equal s "receipt_unset"))

(* The four [outcome_kind] terminal variants mapped to their TLA+
   receipt symbols.  The JSON boundary now emits spec-aligned names
   (["receipt_done"] / ["receipt_failed"] / ["receipt_skipped"] /
   ["receipt_cancelled"]); legacy names (["ok"] / ["error"] / etc.)
   are still accepted on parse for backward compatibility. *)
let ocaml_terminal_outcome_set =
  List.map
    Masc_mcp.Keeper_execution_receipt.outcome_kind_to_tla_receipt
    [ `Ok; `Skipped; `Error; `Cancelled ]

let sort = Masc_test_deps.sorted_strings

let test_terminal_set_parity () =
  let ocaml = sort ocaml_terminal_outcome_set in
  let spec = sort spec_terminal_outcome_set in
  if ocaml <> spec then begin
    Printf.printf "OCaml terminal outcomes : [%s]\n"
      (String.concat "; " ocaml);
    Printf.printf "Spec  terminal outcomes : [%s]\n"
      (String.concat "; " spec);
    let only_ocaml =
      List.filter (fun s -> not (List.mem s spec)) ocaml
    in
    let only_spec =
      List.filter (fun s -> not (List.mem s ocaml)) spec
    in
    Printf.printf "Only in OCaml          : [%s]\n"
      (String.concat "; " only_ocaml);
    Printf.printf "Only in spec           : [%s]\n"
      (String.concat "; " only_spec);
    failwith
      "Keeper_execution_receipt.outcome_kind differs from spec \
       ReceiptOutcomeSet (excluding receipt_unset) — sync the OCaml \
       type or the spec."
  end

let test_string_roundtrip () =
  List.iter
    (fun k ->
      let s =
        Masc_mcp.Keeper_execution_receipt.outcome_kind_to_string k
      in
      match
        Masc_mcp.Keeper_execution_receipt.outcome_kind_of_string s
      with
      | Some k' when k = k' -> ()
      | Some _ | None ->
          failwith
            (Printf.sprintf
               "outcome_kind round-trip failed for %s -> %s -> ?" s s))
    [ `Ok; `Skipped; `Error; `Cancelled ]

let test_tla_name_roundtrip () =
  (* JSON boundary migration (FSM-01): TLA names must parse back to the
     same variant so that spec-aligned emission is reversible. *)
  List.iter
    (fun k ->
      let s =
        Masc_mcp.Keeper_execution_receipt.outcome_kind_to_tla_receipt k
      in
      match
        Masc_mcp.Keeper_execution_receipt.outcome_kind_of_string s
      with
      | Some k' when k = k' -> ()
      | Some _ | None ->
          failwith
            (Printf.sprintf
               "outcome_kind TLA name round-trip failed for %s -> %s -> ?"
               s s))
    [ `Ok; `Skipped; `Error; `Cancelled ]

let test_skipped_is_terminal_success () =
  (* PhaseGateSkip reaches terminal [Done] without dispatching, so the
     receipt outcome must classify as a successful no-op rather than a
     failure. Spec: KeeperTurnFSM.tla [PhaseGateSkip] action sets
     [receipt_outcome' = "receipt_skipped"] and [turn_state' = "done"];
     [ReceiptMatchesState] then accepts {receipt_done, receipt_skipped}
     as the receipt set valid for terminal [Done]. *)
  if not
       (Masc_mcp.Keeper_execution_receipt.outcome_kind_is_terminal_success
          `Skipped)
  then
    failwith
      "outcome_kind_is_terminal_success `Skipped should be true \
       (PhaseGateSkip is a successful no-op, not a failure)"

let test_unset_is_not_a_terminal_outcome () =
  (* receipt_unset is the initial-state marker only; it must NOT parse
     into a terminal outcome_kind. *)
  match
    Masc_mcp.Keeper_execution_receipt.outcome_kind_of_string "unset"
  with
  | None -> ()
  | Some _ ->
      failwith
        "outcome_kind_of_string \"unset\" must return None — \
         receipt_unset is the initial-state marker and is not \
         representable on a terminal receipt per \
         [EveryTurnHasTerminalReceipt]."

let () =
  test_terminal_set_parity ();
  test_string_roundtrip ();
  test_tla_name_roundtrip ();
  test_skipped_is_terminal_success ();
  test_unset_is_not_a_terminal_outcome ();
  print_endline "test_keeper_receipt_outcome_tla_parity: OK"
