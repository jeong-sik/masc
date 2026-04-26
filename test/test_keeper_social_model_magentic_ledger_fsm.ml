open Alcotest
module Fsm = Masc_mcp.Keeper_social_model_magentic_ledger_fsm
module KSM = Masc_mcp.Keeper_social_model

let has_prompt_root path =
  Sys.file_exists (Filename.concat path "config/prompts/keeper.unified.system.md")
;;

let repo_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when has_prompt_root root -> root
  | _ ->
    let rec ascend path =
      if has_prompt_root path
      then path
      else (
        let parent = Filename.dirname path in
        if String.equal parent path then Sys.getcwd () else ascend parent)
    in
    ascend (Sys.getcwd ())
;;

let read_file path = In_channel.with_open_bin path In_channel.input_all

let substring_index haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop i =
    if i + needle_len > hay_len
    then None
    else if String.sub haystack i needle_len = needle
    then Some i
    else loop (i + 1)
  in
  if needle_len = 0 then Some 0 else loop 0
;;

let extract_quoted_set source name =
  let prefix = name ^ " == {" in
  match substring_index source prefix with
  | None -> fail ("missing set definition: " ^ name)
  | Some start ->
    let body_start = start + String.length prefix in
    let rest = String.sub source body_start (String.length source - body_start) in
    let body_end =
      match String.index_opt rest '}' with
      | Some idx -> idx
      | None -> fail ("unterminated set definition: " ^ name)
    in
    String.sub rest 0 body_end
    |> String.split_on_char ','
    |> List.map String.trim
    |> List.filter (fun item -> item <> "")
    |> List.map (fun item ->
      if String.length item >= 2 && item.[0] = '"'
      then String.sub item 1 (String.length item - 2)
      else item)
    |> List.sort String.compare
;;

let phase_strings phases =
  phases |> List.map Fsm.phase_to_string |> List.sort String.compare
;;

let event_strings events =
  events |> List.map Fsm.event_to_string |> List.sort String.compare
;;

let test_progress_evidence_beats_other_signals () =
  let event =
    Fsm.classify_event
      ~previous:(Some { Fsm.phase = Stalled })
      { Fsm.has_progress_evidence = true
      ; has_reactive_signal = true
      ; has_active_goals = true
      ; idle_seconds = 900
      }
  in
  check string "progress event selected" "progress_observed" (Fsm.event_to_string event);
  let snapshot = Fsm.apply_event ~current:{ phase = Stalled } event in
  check string "progress -> advancing" "advancing" (Fsm.phase_to_string snapshot.phase)
;;

let test_reactive_signal_beats_idle_timeout () =
  let event =
    Fsm.classify_event
      ~previous:None
      { Fsm.has_progress_evidence = false
      ; has_reactive_signal = true
      ; has_active_goals = true
      ; idle_seconds = 900
      }
  in
  check string "reactive event selected" "signals_pending" (Fsm.event_to_string event);
  let snapshot = Fsm.apply_event ~current:Fsm.initial event in
  check string "signals -> reactive" "reactive" (Fsm.phase_to_string snapshot.phase)
;;

let test_stalled_state_sticks_until_delta () =
  let previous = Some { Fsm.phase = Stalled } in
  let event =
    Fsm.classify_event
      ~previous
      { Fsm.has_progress_evidence = false
      ; has_reactive_signal = false
      ; has_active_goals = true
      ; idle_seconds = 0
      }
  in
  check
    string
    "stalled carry classifies timeout"
    "goal_idle_timeout"
    (Fsm.event_to_string event);
  let snapshot = Fsm.apply_event ~current:{ phase = Stalled } event in
  check string "stalled stays stalled" "stalled" (Fsm.phase_to_string snapshot.phase)
;;

let test_snapshot_restored_from_social_state () =
  let state =
    { KSM.social_model = "magentic_ledger_v1"
    ; belief_summary = "ledger:phase=stalled; event=goal_idle_timeout"
    ; active_desire = Some "recover_forward_motion"
    ; current_intention = Some "request_replan"
    ; blocker = Some "stalled_without_progress_evidence"
    ; need = Some "fresh_plan_or_external_delta"
    ; speech_act = KSM.Stay_silent
    ; delivery_surface = KSM.Silent
    }
  in
  match Fsm.snapshot_of_social_state state with
  | None -> fail "expected snapshot"
  | Some snapshot ->
    check string "phase restored" "stalled" (Fsm.phase_to_string snapshot.phase)
;;

let test_tla_sets_match_ocaml () =
  let tla_path =
    Filename.concat
      (repo_root ())
      "specs/keeper-state-machine/KeeperSocialModelMagenticLedger.tla"
  in
  let source = read_file tla_path in
  check
    (list string)
    "phase set matches"
    (extract_quoted_set source "PhaseSet")
    (phase_strings Fsm.all_phases);
  check
    (list string)
    "event set matches"
    (extract_quoted_set source "EventSet")
    (event_strings Fsm.all_events)
;;

let () =
  run
    "keeper_social_model_magentic_ledger_fsm"
    [ ( "fsm"
      , [ test_case
            "progress evidence beats other signals"
            `Quick
            test_progress_evidence_beats_other_signals
        ; test_case
            "reactive signal beats idle timeout"
            `Quick
            test_reactive_signal_beats_idle_timeout
        ; test_case
            "stalled state sticks until delta"
            `Quick
            test_stalled_state_sticks_until_delta
        ; test_case
            "snapshot restored from social state"
            `Quick
            test_snapshot_restored_from_social_state
        ; test_case "tla sets match ocaml" `Quick test_tla_sets_match_ocaml
        ] )
    ]
;;
