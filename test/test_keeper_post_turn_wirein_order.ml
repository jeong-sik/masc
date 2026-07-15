(* OCaml-side regression guard for RFC-0065 §3.2.3
 * WireinOrderPinned invariant (PR #14632).
 *
 * The post-turn wirein sequence is an implementation ordering contract:
 *
 *   apply_autonomous_wirein     (A5)
 *   apply_resilience_wirein     (A6)
 *   apply_tool_emission_wirein  (K4b)
 *   apply_multimodal_wirein     (K1)
 *
 * This test scans [lib/keeper/keeper_post_turn.ml] and confirms the four
 * wirein calls appear in the correct order inside the body of
 * [apply_post_turn_lifecycle_with_resilience_handles]. An accidental
 * reorder would otherwise compile cleanly and silently violate the
 * pinned invariant.
 *
 * Approach: read the source file as text, locate the function
 * definition by header line, then scan until the next top-level [let]
 * binding. Within that function body, look up the first occurrence of
 * each of the four literal call markers and assert the line numbers are
 * strictly increasing.
 *)

open Alcotest

module Compact_policy = Masc.Keeper_compact_policy
module Post_turn = Masc.Keeper_post_turn

let source_relpath = "lib/keeper/keeper_post_turn.ml"

let function_header = "let apply_post_turn_lifecycle_with_resilience_handles"

(* Literal call markers, in the order they must appear. The order
   here is load-bearing — the test asserts the first-occurrence line
   numbers are strictly increasing in this sequence. *)
let wirein_markers =
  [ "apply_autonomous_wirein";
    "apply_resilience_wirein";
    "apply_tool_emission_wirein";
    "apply_multimodal_wirein" ]

let read_source_lines () =
  let root = Masc_test_deps.find_project_root () in
  let path = Filename.concat root source_relpath in
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let rec loop acc =
        match input_line ic with
        | line -> loop (line :: acc)
        | exception End_of_file -> List.rev acc
      in
      loop [])

let has_prefix ~prefix hay =
  let nlen = String.length prefix in
  String.length hay >= nlen && String.sub hay 0 nlen = prefix

let substring_present ~needle hay =
  let nlen = String.length needle in
  let hlen = String.length hay in
  if nlen > hlen then false
  else
    let rec scan i =
      if i + nlen > hlen then false
      else if String.sub hay i nlen = needle then true
      else scan (i + 1)
    in
    scan 0

(* Find the first line (1-indexed) whose content contains [needle],
   searching only within [lines] in the inclusive 1-indexed range
   [from..to_]. Returns [None] if not found. *)
let find_line_in_range ~lines ~needle ~from ~to_ =
  let arr = Array.of_list lines in
  let n = Array.length arr in
  let lo = max 1 from in
  let hi = min n to_ in
  let rec scan i =
    if i > hi then None
    else if substring_present ~needle arr.(i - 1) then Some i
    else scan (i + 1)
  in
  scan lo

let find_function_header_line ~lines =
  let arr = Array.of_list lines in
  let n = Array.length arr in
  let rec scan i =
    if i > n then None
    else if substring_present ~needle:function_header arr.(i - 1) then Some i
    else scan (i + 1)
  in
  scan 1

let find_next_top_level_let_line ~lines ~from =
  let arr = Array.of_list lines in
  let n = Array.length arr in
  let rec scan i =
    if i > n then None
    else if has_prefix ~prefix:"let " arr.(i - 1) then Some i
    else scan (i + 1)
  in
  scan from

let test_wirein_order_strictly_increasing () =
  let lines = read_source_lines () in
  let header_line =
    match find_function_header_line ~lines with
    | Some i -> i
    | None ->
        failwith
          (Printf.sprintf
             "Could not locate %S in %s — function may have been \
              renamed or removed; sync RFC-0065 WireinOrderPinned \
              guard accordingly."
             function_header source_relpath)
  in
  let from = header_line + 1 in
  let to_ =
    match find_next_top_level_let_line ~lines ~from with
    | Some line -> line - 1
    | None -> List.length lines
  in
  let located =
    List.map
      (fun marker ->
        match find_line_in_range ~lines ~needle:marker ~from ~to_ with
        | Some i -> (marker, i)
        | None ->
            failwith
              (Printf.sprintf
                 "WireinOrderPinned: marker %S not found in body of \
                  %S (lines %d-%d) in %s — RFC-0065 §3.2.3 wirein \
                  call appears to be missing."
                 marker function_header from to_ source_relpath))
      wirein_markers
  in
  let rec check prev_line = function
    | [] -> ()
    | (marker, line) :: rest ->
        if line <= prev_line then
          failwith
            (Printf.sprintf
               "WireinOrderPinned violation: marker %S at line %d is \
                not strictly after the preceding marker at line %d. \
                Expected order: %s. RFC-0065 §3.2.3 pins this \
                sequence; restore it or update the spec and this \
                guard together."
               marker line prev_line
               (String.concat " → " wirein_markers))
        else check line rest
  in
  check 0 located

let test_wirein_all_present () =
  (* Independent presence check: each of the four markers must be
     present anywhere in the file at least once. Catches an accidental
     deletion of one of the wirein passes even if the function header
     scan logic regresses. *)
  let lines = read_source_lines () in
  let n = List.length lines in
  List.iter
    (fun marker ->
      match find_line_in_range ~lines ~needle:marker ~from:1 ~to_:n with
      | Some _ -> ()
      | None ->
          failwith
            (Printf.sprintf
               "WireinOrderPinned all-present: marker %S not found \
                anywhere in %s — RFC-0065 §3.2.3 wirein pass appears \
                to be deleted."
               marker source_relpath))
    wirein_markers

let test_prepared_becomes_applied_only_after_save () =
  let trigger = Compaction_trigger.Manual in
  check bool "Prepared is not Applied" false
    (Compact_policy.compaction_decision_applied
       (Compact_policy.Prepared trigger));
  (match
     Post_turn.For_testing.commit_prepared_after_save
       ~trigger
       ~save:(fun () -> Error "checkpoint unavailable")
   with
   | Error detail -> check string "save failure preserved" "checkpoint unavailable" detail
   | Ok _ -> fail "failed checkpoint save promoted Prepared to Applied");
  match
    Post_turn.For_testing.commit_prepared_after_save
      ~trigger
      ~save:(fun () -> Ok "durable-checkpoint")
  with
  | Error detail -> failf "successful checkpoint save failed: %s" detail
  | Ok (checkpoint, Compact_policy.Applied Compaction_trigger.Manual) ->
    check string "saved checkpoint returned" "durable-checkpoint" checkpoint
  | Ok _ -> fail "successful checkpoint save did not produce Applied Manual"

let make_meta
      ?(name = "post-turn-no-auto-compact")
      ?(trace_id = "trace-post-turn-no-auto-compact")
      ()
  : Masc.Keeper_meta_contract.keeper_meta
  =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String name
        ; "trace_id", `String trace_id
        ; "compaction_mode", `String "llm"
        ])
  with
  | Ok meta -> meta
  | Error detail -> failf "keeper meta fixture failed: %s" detail

let make_checkpoint () =
  Agent_sdk.Checkpoint.
    { version = checkpoint_version
    ; session_id = "trace-post-turn-no-auto-compact"
    ; agent_name = "post-turn-no-auto-compact"
    ; model = "test-model"
    ; system_prompt = None
    ; messages =
        [ Agent_sdk.Types.text_message Agent_sdk.Types.User "keep"
        ; Agent_sdk.Types.text_message Agent_sdk.Types.Assistant (String.make 2048 'x')
        ; Agent_sdk.Types.text_message Agent_sdk.Types.User (String.make 2048 'y')
        ]
    ; usage = Agent_sdk.Types.empty_usage
    ; turn_count = 7
    ; created_at = 1_700_000_000.0
    ; tools = []
    ; tool_choice = None
    ; disable_parallel_tool_use = false
    ; temperature = None
    ; top_p = None
    ; top_k = None
    ; min_p = None
    ; enable_thinking = None
    ; preserve_thinking = None
    ; response_format = Agent_sdk.Types.Off
    ; thinking_budget = None
    ; reasoning_effort = None
    ; cache_system_prompt = false
    ; context = Agent_sdk.Context.create_sync ()
    ; mcp_sessions = []
    ; working_context = None
    }

let test_regular_post_turn_does_not_auto_compact () =
  Eio_main.run @@ fun _env ->
  let meta = make_meta () in
  let checkpoint = make_checkpoint () in
  let unexpected_callback () = fail "regular post-turn invoked a compaction callback" in
  let result =
    Post_turn.apply_post_turn_lifecycle_with_resilience_handles
      ~resilience_audit_store:None
      ~resilience_strategy_executor:None
      ~on_compaction_started:unexpected_callback
      ~on_handoff_started:unexpected_callback
      ~base_dir:"unused"
      ~meta
      ~model:"test-model"
      ~primary_model_max_tokens:8192
      ~current_turn_blocker_info:None
      ~checkpoint:(Some checkpoint)
  in
  check bool "compaction not attempted" false result.compaction.attempted;
  check bool "compaction not applied" false result.compaction.applied;
  (match result.compaction.decision with
   | Compact_policy.Not_requested -> ()
   | _ -> fail "regular post-turn returned a compaction decision");
  match result.checkpoint with
  | None -> fail "regular post-turn discarded the checkpoint"
  | Some retained ->
    check int "checkpoint turn retained" checkpoint.turn_count retained.turn_count;
    check bool "checkpoint messages retained exactly" true
      (retained.messages = checkpoint.messages)

let () =
  run "RFC-0065 §3.2.3 WireinOrderPinned (OCaml-side guard)" [
    "WireinOrderPinned", [
      test_case "ordering: A5 → A6 → K4b → K1 strictly increasing"
        `Quick test_wirein_order_strictly_increasing;
      test_case "all-present: four wirein calls present in source"
        `Quick test_wirein_all_present;
    ];
    "durable compaction", [
      test_case "Prepared requires a successful checkpoint save"
        `Quick test_prepared_becomes_applied_only_after_save;
      test_case "regular post-turn does not auto-compact"
        `Quick test_regular_post_turn_does_not_auto_compact;
    ];
  ]
