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

(* ── TLA+ spec parsing ───────────────────────────────────────

   Read [TurnStateSet] directly out of [KeeperTurnFSM.tla]. Removes
   the previous hand-maintained copy (which carried the TODO
   "Cycle 3+ may parse the .tla file directly so this list is no
   longer a second source of truth"). Same parser pattern as
   [test_keeper_receipt_outcome_tla_parity] for the sibling
   [ReceiptOutcomeSet]. *)

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
    brace to the next closing brace, then collects every
    [Str.regexp "\"\\([^\"]*\\)\""] hit. Returns [None] if absent. *)
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

let spec_turn_state_set : string list =
  let path =
    Filename.concat
      (project_root ())
      "specs/keeper-turn-fsm/KeeperTurnFSM.tla"
  in
  let content = read_file path in
  match find_quoted_set ~symbol:"TurnStateSet" content with
  | None ->
      failwith
        "TurnStateSet not found in \
         specs/keeper-turn-fsm/KeeperTurnFSM.tla — set definition may \
         have moved or been renamed."
  | Some states -> states

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
