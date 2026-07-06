(** RFC-0035 P4 surface: [keeper_memory_write] validation suite.

    Pins:
    - kind/title/content shape validation taxonomy
      (invalid_memory_kind, title_too_long, content_empty,
      long_term_via_explicit_write_not_yet_supported)
    - field-to-kind mapping in [single_field_snapshot_for_kind]
      (mirrors [Keeper_memory_bank.memory_candidates_from_snapshot])

    Persistence + cap-drop integration is covered by existing keeper
    turn fixtures that already exercise
    [Keeper_memory_bank.append_memory_notes_from_reply] (kind/total
    cap, dedup, JSONL row shape). The new surface inserts no logic
    between snapshot construction and that helper, so the
    pure-validation pin here plus the helper-mapping pin is sufficient
    coverage for the new code paths. *)

module Keeper_tool_memory_runtime = Masc.Keeper_tool_memory_runtime
module Keeper_memory_bank = Masc.Keeper_memory_bank
module Keeper_memory_policy = Masc.Keeper_memory_policy

(* --- helpers ------------------------------------------------------- *)

let make_args ~kind ~title ~content : Yojson.Safe.t =
  `Assoc [ "kind", `String kind; "title", `String title; "content", `String content ]
;;

let validate_memory_write_args_call args =
  Keeper_tool_memory_runtime.validate_memory_write_args args
;;

let assert_invalid ~error_kind result =
  match (result : Keeper_tool_memory_runtime.memory_write_validation) with
  | Memory_write_invalid r ->
    Alcotest.(check string)
      "error_kind"
      error_kind
      (Keeper_tool_memory_runtime.memory_write_error_kind_to_string r.error_kind)
  | Memory_write_ok _ ->
    Alcotest.failf "expected Memory_write_invalid %s, got Memory_write_ok" error_kind
;;

let assert_ok ~kind result =
  match (result : Keeper_tool_memory_runtime.memory_write_validation) with
  | Memory_write_ok r -> Alcotest.(check string) "kind" kind r.kind
  | Memory_write_invalid r ->
    Alcotest.failf
      "expected Memory_write_ok kind=%s, got Memory_write_invalid %s"
      kind
    (Keeper_tool_memory_runtime.memory_write_error_kind_to_string r.error_kind)
;;

let rec remove_tree path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_temp_dir f =
  let dir = Filename.temp_file "keeper-memory-write-" ".tmp" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () -> f dir)
;;

let make_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String name
        ; "trace_id", `String ("trace-" ^ name)
        ; "goal", `String "fallback goal"
        ])
  with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("meta fixture failed: " ^ err)
;;

(* --- snapshot mapping (kind -> populated field) -------------------- *)

let test_snapshot_helper_goal () =
  match Keeper_tool_memory_runtime.single_field_snapshot_for_kind ~kind:"goal" ~text:"x" with
  | Some s ->
    Alcotest.(check (option string)) "goal populated" (Some "x") s.goal;
    Alcotest.(check (list string)) "decisions empty" [] s.decisions
  | None -> Alcotest.fail "expected Some snapshot for kind=goal"
;;

let test_snapshot_helper_progress () =
  match Keeper_tool_memory_runtime.single_field_snapshot_for_kind ~kind:"progress" ~text:"y" with
  | Some s ->
    Alcotest.(check (option string)) "progress populated" (Some "y") s.progress;
    Alcotest.(check (option string)) "goal absent" None s.goal
  | None -> Alcotest.fail "expected Some snapshot for kind=progress"
;;

let test_snapshot_helper_decision () =
  match Keeper_tool_memory_runtime.single_field_snapshot_for_kind ~kind:"decision" ~text:"y" with
  | Some s ->
    Alcotest.(check (option string)) "goal absent" None s.goal;
    Alcotest.(check (list string)) "decisions has y" [ "y" ] s.decisions
  | None -> Alcotest.fail "expected Some snapshot for kind=decision"
;;

let test_snapshot_helper_next () =
  match Keeper_tool_memory_runtime.single_field_snapshot_for_kind ~kind:"next" ~text:"step" with
  | Some s -> Alcotest.(check (list string)) "next_items has step" [ "step" ] s.next_items
  | None -> Alcotest.fail "expected Some snapshot for kind=next"
;;

let test_snapshot_helper_open_question () =
  match
    Keeper_tool_memory_runtime.single_field_snapshot_for_kind ~kind:"open_question" ~text:"q?"
  with
  | Some s ->
    Alcotest.(check (list string)) "open_questions has q?" [ "q?" ] s.open_questions
  | None -> Alcotest.fail "expected Some snapshot for kind=open_question"
;;

let test_snapshot_helper_constraints () =
  match
    Keeper_tool_memory_runtime.single_field_snapshot_for_kind ~kind:"constraints" ~text:"c"
  with
  | Some s -> Alcotest.(check (list string)) "constraints has c" [ "c" ] s.constraints
  | None -> Alcotest.fail "expected Some snapshot for kind=constraints"
;;

let test_snapshot_helper_long_term_returns_none () =
  match Keeper_tool_memory_runtime.single_field_snapshot_for_kind ~kind:"long_term" ~text:"z" with
  | Some _ ->
    Alcotest.fail "long_term must not be writable via single_field_snapshot helper"
  | None -> ()
;;

let test_snapshot_helper_unknown_returns_none () =
  match Keeper_tool_memory_runtime.single_field_snapshot_for_kind ~kind:"bogus" ~text:"q" with
  | Some _ -> Alcotest.fail "unknown kind must yield None"
  | None -> ()
;;

(* --- validation taxonomy ------------------------------------------- *)

let test_invalid_memory_kind () =
  validate_memory_write_args_call (make_args ~kind:"bogus_kind" ~title:"t" ~content:"c")
  |> assert_invalid ~error_kind:"invalid_memory_kind"
;;

let test_long_term_rejected () =
  validate_memory_write_args_call (make_args ~kind:"long_term" ~title:"t" ~content:"c")
  |> assert_invalid ~error_kind:"long_term_via_explicit_write_not_yet_supported"
;;

let test_title_too_long_at_121 () =
  let too_long = String.make 121 'a' in
  validate_memory_write_args_call (make_args ~kind:"goal" ~title:too_long ~content:"c")
  |> assert_invalid ~error_kind:"title_too_long"
;;

let test_title_at_120_passes () =
  let at_max = String.make 120 'a' in
  validate_memory_write_args_call (make_args ~kind:"goal" ~title:at_max ~content:"c")
  |> assert_ok ~kind:"goal"
;;

let test_content_empty () =
  validate_memory_write_args_call (make_args ~kind:"goal" ~title:"t" ~content:"")
  |> assert_invalid ~error_kind:"content_empty"
;;

let test_valid_call_constructs_snapshot () =
  match
    validate_memory_write_args_call
      (make_args ~kind:"decision" ~title:"hook" ~content:"body text")
  with
  | Memory_write_ok r ->
    Alcotest.(check string) "kind" "decision" r.kind;
    Alcotest.(check string)
      "body uses **title** content shape"
      "**hook** body text"
      r.body;
    Alcotest.(check (list string))
      "snapshot.decisions populated"
      [ "**hook** body text" ]
      r.snapshot.decisions
  | Memory_write_invalid r ->
    Alcotest.failf
      "expected Memory_write_ok, got invalid %s"
      (Keeper_tool_memory_runtime.memory_write_error_kind_to_string r.error_kind)
;;

let test_valid_call_empty_title_uses_content_alone () =
  match
    validate_memory_write_args_call (make_args ~kind:"goal" ~title:"" ~content:"hello")
  with
  | Memory_write_ok r ->
    Alcotest.(check string) "body is content alone when title empty" "hello" r.body
  | Memory_write_invalid r ->
    Alcotest.failf
      "expected Memory_write_ok, got invalid %s"
      (Keeper_tool_memory_runtime.memory_write_error_kind_to_string r.error_kind)
;;

let test_synthetic_snapshot_source_drops_memory_candidates () =
  let snapshot =
    Keeper_memory_policy.synthesize_state_from_run_result
      ~goal:"Fix task"
      ~tools_used:["tool_execute"; "tool_read_file"]
      ~stop_reason:"budget_exhausted"
      ~response_text:"Continuation checkpoint saved; keeper remains scheduled"
  in
  let selection =
    Keeper_memory_bank.memory_candidates_from_snapshot_gated
      ~is_synthetic:true
      snapshot
  in
  Alcotest.(check int)
    "synthetic source writes no durable memory candidates"
    0
    (List.length selection.Keeper_memory_bank.selected);
  Alcotest.(check bool)
    "synthetic suppression is observable"
    true
    (selection.Keeper_memory_bank.suppressed_synthetic_candidates > 0)

let test_meta_goal_fallback_writes_no_durable_memory_candidates () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "meta-goal-fallback" in
  let count, kinds =
    Keeper_memory_bank.append_memory_notes_from_reply
      config
      meta
      ~turn:1
      ~reply:"plain response without a state block"
      ()
  in
  Alcotest.(check int)
    "meta_goal_fallback is synthetic and writes no durable notes"
    0
    count;
  Alcotest.(check (list string)) "no fallback kinds" [] kinds;
  let fallback_selection =
    Keeper_memory_bank.memory_candidates_from_snapshot_gated
      ~is_synthetic:true
      { Keeper_memory_policy.empty_keeper_state_snapshot with goal = Some meta.goal }
  in
  Alcotest.(check int)
    "meta_goal_fallback suppression count"
    1
    fallback_selection.Keeper_memory_bank.suppressed_synthetic_candidates;
  let path = Masc.Keeper_types_support.keeper_memory_bank_path config meta.name in
  Alcotest.(check bool)
    "memory bank file is not created for meta_goal_fallback"
    false
    (Sys.file_exists path)
;;

(* --- constants ----------------------------------------------------- *)

let test_max_title_chars_constant () =
  Alcotest.(check int)
    "RFC-0035 §3 declared limit"
    120
    Keeper_tool_memory_runtime.keeper_memory_write_max_title_chars
;;

let () =
  Alcotest.run
    "keeper_memory_write"
    [ ( "snapshot_helper"
      , [ Alcotest.test_case "goal -> snapshot.goal" `Quick test_snapshot_helper_goal
        ; Alcotest.test_case
            "progress -> snapshot.progress"
            `Quick
            test_snapshot_helper_progress
        ; Alcotest.test_case
            "decision -> snapshot.decisions"
            `Quick
            test_snapshot_helper_decision
        ; Alcotest.test_case
            "next -> snapshot.next_items"
            `Quick
            test_snapshot_helper_next
        ; Alcotest.test_case
            "open_question -> snapshot.open_questions"
            `Quick
            test_snapshot_helper_open_question
        ; Alcotest.test_case
            "constraints -> snapshot.constraints"
            `Quick
            test_snapshot_helper_constraints
        ; Alcotest.test_case
            "long_term not writable here"
            `Quick
            test_snapshot_helper_long_term_returns_none
        ; Alcotest.test_case
            "unknown kind -> None"
            `Quick
            test_snapshot_helper_unknown_returns_none
        ] )
    ; ( "validation"
      , [ Alcotest.test_case "invalid_memory_kind" `Quick test_invalid_memory_kind
        ; Alcotest.test_case "long_term explicit rejected" `Quick test_long_term_rejected
        ; Alcotest.test_case
            "title_too_long at 121 chars"
            `Quick
            test_title_too_long_at_121
        ; Alcotest.test_case "title at 120 chars passes" `Quick test_title_at_120_passes
        ; Alcotest.test_case "content_empty" `Quick test_content_empty
        ; Alcotest.test_case
            "valid call -> snapshot + body shape"
            `Quick
            test_valid_call_constructs_snapshot
        ; Alcotest.test_case
            "empty title -> content alone as body"
            `Quick
            test_valid_call_empty_title_uses_content_alone
        ; Alcotest.test_case
            "synthetic snapshot source drops candidates"
            `Quick
            test_synthetic_snapshot_source_drops_memory_candidates
        ; Alcotest.test_case
            "meta_goal_fallback writes no durable memory candidates"
            `Quick
            test_meta_goal_fallback_writes_no_durable_memory_candidates
        ] )
    ; ( "constants"
      , [ Alcotest.test_case "max_title_chars = 120" `Quick test_max_title_chars_constant
        ] )
    ]
;;
