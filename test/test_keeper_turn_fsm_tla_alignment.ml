(** test_keeper_turn_fsm_tla_alignment

    Pins the OCaml [Keeper_turn_fsm.tla_state_symbol] surface to the
    TLA+ [TurnStateSet] in
    [specs/keeper-turn-fsm/KeeperTurnFSM.tla].

    Why this exists: the runtime label
    ([Awaiting_tool_result -> "awaiting_tool_result"]) deliberately
    differs from the TLA+ symbol
    ([Awaiting_tool_result -> "awaiting_tool"], spec line 32 alias
    table).  Until [tla_state_symbol] was added the alias mapping
    lived only in a TLA+ comment, with no compile-time or test-time
    enforcement that the OCaml side stayed aligned.  A
    constructor rename, a missed addition, or a spec edit could
    drift silently.

    Pattern lifted from [test_keeper_social_model_magentic_ledger_fsm]
    which already cross-checks [PhaseSet]/[EventSet]. *)

open Alcotest
module F = Masc_mcp.Keeper_turn_fsm

let has_prompt_root path =
  Sys.file_exists
    (Filename.concat path "config/prompts/keeper.unified.system.md")

let repo_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when has_prompt_root root -> root
  | _ ->
      let rec ascend path =
        if has_prompt_root path then path
        else
          let parent = Filename.dirname path in
          if String.equal parent path then Sys.getcwd () else ascend parent
      in
      ascend (Sys.getcwd ())

let read_file path = In_channel.with_open_bin path In_channel.input_all

let substring_index haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop i =
    if i + needle_len > hay_len then None
    else if String.sub haystack i needle_len = needle then Some i
    else loop (i + 1)
  in
  if needle_len = 0 then Some 0 else loop 0

let extract_quoted_set source name =
  let prefix = name ^ " ==" in
  match substring_index source prefix with
  | None -> fail ("missing set definition: " ^ name)
  | Some start ->
      let body_start =
        match String.index_from_opt source start '{' with
        | Some idx -> idx + 1
        | None -> fail ("no '{' after " ^ name)
      in
      let rest =
        String.sub source body_start (String.length source - body_start)
      in
      let body_end =
        match String.index_opt rest '}' with
        | Some idx -> idx
        | None -> fail ("unterminated set: " ^ name)
      in
      String.sub rest 0 body_end
      |> String.split_on_char ','
      |> List.map String.trim
      |> List.filter (fun item -> item <> "")
      |> List.map (fun item ->
             if String.length item >= 2 && item.[0] = '"' then
               String.sub item 1 (String.length item - 2)
             else item)
      |> List.sort_uniq String.compare

let tla_path () =
  Filename.concat (repo_root ())
    "specs/keeper-turn-fsm/KeeperTurnFSM.tla"

let test_turn_state_symbols_match_tla () =
  let source = read_file (tla_path ()) in
  check (list string)
    "Keeper_turn_fsm.tla_state_symbol covers TurnStateSet exactly"
    (extract_quoted_set source "TurnStateSet")
    F.all_turn_state_symbols

let test_label_distinct_from_symbol_for_alias () =
  (* Document the deliberate alias: runtime label and TLA symbol
     diverge for [Awaiting_tool_result].  If a future refactor
     accidentally collapses them the test fails here, prompting
     a spec/runtime decision rather than a silent change. *)
  let label = F.turn_state_label F.Awaiting_tool_result in
  let symbol = F.tla_state_symbol F.Awaiting_tool_result in
  check string "runtime label keeps the verbose form"
    "awaiting_tool_result" label;
  check string "TLA+ symbol keeps the spec abbreviation"
    "awaiting_tool" symbol

let () =
  run "keeper_turn_fsm_tla_alignment"
    [
      ( "alignment",
        [
          test_case "tla_state_symbol covers TurnStateSet" `Quick
            test_turn_state_symbols_match_tla;
          test_case "label vs symbol alias documented" `Quick
            test_label_distinct_from_symbol_for_alias;
        ] );
    ]
