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

   Read [ReceiptOutcomeSet] directly out of [KeeperTurnFSM.tla].
   Removes the previous hand-maintained copy (which carried the
   TODO "a future cycle may parse the .tla file directly so this
   list is no longer a second source of truth"). Same parser
   pattern as [test_keeper_state_machine_correspondence] for
   KeeperStateMachine. *)

let rec find_repo_root dir =
  let candidate =
    Filename.concat dir "specs/keeper-turn-fsm/KeeperTurnFSM.tla"
  in
  if Sys.file_exists candidate then dir
  else
    let parent = Filename.dirname dir in
    if String.equal parent dir then
      failwith "could not find repo root for KeeperTurnFSM.tla"
    else find_repo_root parent

let project_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> find_repo_root (Filename.dirname Sys.executable_name)

let read_file path =
  let ic = open_in path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

(** Locate [Name == { "...", "...", ... }] set literal in TLA+ text
    and extract every quoted-string element. Walks from the opening
    brace to the next closing brace, then collects all
    [Str.regexp "\"\\([^\"]*\\)\""] hits. Returns [None] if absent. *)
let find_quoted_set ~symbol content =
  let header = symbol ^ " ==" in
  let len = String.length content in
  let hlen = String.length header in
  let rec idx i =
    if i + hlen > len then None
    else if String.sub content i hlen = header then Some (i + hlen)
    else idx (i + 1)
  in
  match idx 0 with
  | None -> None
  | Some after_header ->
      (match String.index_from_opt content after_header '{' with
       | None -> None
       | Some open_brace ->
           (match String.index_from_opt content open_brace '}' with
            | None -> None
            | Some close_brace ->
                let body =
                  String.sub content open_brace
                    (close_brace - open_brace + 1)
                in
                let re = Str.regexp "\"\\([^\"]*\\)\"" in
                let acc = ref [] in
                let pos = ref 0 in
                let go = ref true in
                while !go do
                  match Str.search_forward re body !pos with
                  | exception Not_found -> go := false
                  | _ ->
                      acc := Str.matched_group 1 body :: !acc;
                      pos := Str.match_end ()
                done;
                Some (List.rev !acc)))

(** Mechanically extract [ReceiptOutcomeSet] from the spec, then drop
    ["receipt_unset"] — initial-state-only marker, not representable
    on a terminal receipt per [EveryTurnHasTerminalReceipt]. *)
let spec_terminal_outcome_set : string list =
  let path =
    Filename.concat
      (project_root ())
      "specs/keeper-turn-fsm/KeeperTurnFSM.tla"
  in
  let content = read_file path in
  match find_quoted_set ~symbol:"ReceiptOutcomeSet" content with
  | None ->
      failwith
        "ReceiptOutcomeSet not found in \
         specs/keeper-turn-fsm/KeeperTurnFSM.tla — set definition may \
         have moved or been renamed."
  | Some outcomes ->
      List.filter
        (fun s -> not (String.equal s "receipt_unset"))
        outcomes

(* The four [outcome_kind] terminal variants prefixed with "receipt_"
   to align with the TLA+ string form. *)
let ocaml_terminal_outcome_set =
  List.map
    (fun k ->
      "receipt_"
      ^ Masc_mcp.Keeper_execution_receipt.outcome_kind_to_string k)
    [ `Ok; `Skipped; `Error; `Cancelled ]

let sort = List.sort String.compare

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
  test_skipped_is_terminal_success ();
  test_unset_is_not_a_terminal_outcome ();
  print_endline "test_keeper_receipt_outcome_tla_parity: OK"
