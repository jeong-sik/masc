(** Tests for Keeper_tool_call_log — truncation, redaction, and read_recent. *)

open Masc

let eio_test name fn =
  Alcotest.test_case name `Quick (fun () ->
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    fn ())

let eio_env_test name fn =
  Alcotest.test_case name `Quick (fun () ->
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    fn env)

let artifact_ref_exn ~sha256 ~bytes ~preview ~mime =
  match Tool_output.make_artifact_ref ~sha256 ~bytes ~preview ~mime with
  | Ok r -> r
  | Error e -> Alcotest.fail (Tool_output.make_error_to_string e)

let counter = ref 0

let invocation ~tool_use_id ~turn ~planned_index =
  Agent_core.Tool_contract.Invocation.create
    ~tool_use_id
    ~turn
    ~completion:Agent_core.Tool_contract.Continue_after_success
    ~schedule:
      { planned_index
      ; batch_index = 0
      ; batch_size = 2
      ; execution_mode = Agent_core.Tool_contract.Concurrent
      }
;;

let test_pending_observations_are_occurrence_scoped () =
  Keeper_tool_call_log.reset_for_testing ();
  let first = invocation ~tool_use_id:"" ~turn:7 ~planned_index:0 in
  let sibling_with_same_blank_id =
    invocation ~tool_use_id:"" ~turn:7 ~planned_index:1
  in
  let later_with_repeated_id =
    invocation ~tool_use_id:"repeated" ~turn:8 ~planned_index:0
  in
  let earlier_with_repeated_id =
    invocation ~tool_use_id:"repeated" ~turn:7 ~planned_index:2
  in
  List.iter
    (fun (invocation, original_bytes) ->
       Keeper_tool_call_log.set_truncation_info
         ~invocation
         ~original_bytes
         ())
    [ first, 11
    ; sibling_with_same_blank_id, 22
    ; earlier_with_repeated_id, 33
    ; later_with_repeated_id, 44
    ];
  let consume invocation =
    Keeper_tool_call_log.consume_truncation_info
      ~invocation
      ()
  in
  Alcotest.(check (pair int (option int)))
    "blank-id sibling keeps its own observation"
    (22, None)
    (consume sibling_with_same_blank_id);
  Alcotest.(check (pair int (option int)))
    "first blank-id occurrence remains available"
    (11, None)
    (consume first);
  Alcotest.(check (pair int (option int)))
    "later repeated-id occurrence keeps its own observation"
    (44, None)
    (consume later_with_repeated_id);
  Alcotest.(check (pair int (option int)))
    "earlier repeated-id occurrence remains available"
    (33, None)
    (consume earlier_with_repeated_id);
  Alcotest.(check (pair int (option int)))
    "consumed occurrence is absent"
    (0, None)
    (consume first)
;;

let test_pending_file_change_evidence_is_occurrence_scoped () =
  Keeper_tool_call_log.reset_for_testing ();
  let first = invocation ~tool_use_id:"repeated" ~turn:7 ~planned_index:0 in
  let second = invocation ~tool_use_id:"repeated" ~turn:7 ~planned_index:1 in
  let first_evidence = Keeper_file_change_evidence.written "one\n" in
  let second_evidence = Keeper_file_change_evidence.written "one\ntwo\n" in
  Keeper_tool_call_log.set_file_change_evidence
    ~invocation:first
    ~evidence:first_evidence;
  Keeper_tool_call_log.set_file_change_evidence
    ~invocation:second
    ~evidence:second_evidence;
  let consume invocation =
    Keeper_tool_call_log.consume_file_change_evidence ~invocation ()
    |> Option.map (fun evidence ->
      Keeper_file_change_evidence.to_yojson evidence
      |> Yojson.Safe.to_string)
  in
  let encoded evidence =
    Keeper_file_change_evidence.to_yojson evidence |> Yojson.Safe.to_string
  in
  Alcotest.(check (option string))
    "peek leaves evidence pending until commit acknowledgement"
    (Some (encoded second_evidence))
    (Keeper_tool_call_log.peek_file_change_evidence ~invocation:second ()
     |> Option.map encoded);
  Alcotest.(check (option string))
    "same provider id keeps the second physical occurrence"
    (Some (encoded second_evidence))
    (consume second);
  Alcotest.(check (option string))
    "same provider id keeps the first physical occurrence"
    (Some (encoded first_evidence))
    (consume first);
  Alcotest.(check (option string))
    "evidence is consumed once"
    None
    (consume first)
;;

let test_abandoned_observation_is_released_with_invocation () =
  Keeper_tool_call_log.reset_for_testing ();
  let record_abandoned () =
    let abandoned = invocation ~tool_use_id:"cancelled" ~turn:9 ~planned_index:0 in
    Keeper_tool_call_log.set_truncation_info
      ~invocation:abandoned
      ~original_bytes:99
      ()
  in
  record_abandoned ();
  Gc.full_major ();
  Gc.full_major ();
  Alcotest.(check int)
    "settlement-skip observation is weakly released"
    0
    (Keeper_tool_call_log.pending_truncation_count_for_testing ())
;;

let test_abandoned_file_change_evidence_is_released_with_invocation () =
  Keeper_tool_call_log.reset_for_testing ();
  let record_abandoned () =
    let abandoned = invocation ~tool_use_id:"cancelled" ~turn:9 ~planned_index:0 in
    Keeper_tool_call_log.set_file_change_evidence
      ~invocation:abandoned
      ~evidence:(Keeper_file_change_evidence.written "orphaned\n")
  in
  record_abandoned ();
  Gc.full_major ();
  Gc.full_major ();
  Alcotest.(check int)
    "cancelled invocation weakly releases file change evidence"
    0
    (Keeper_tool_call_log.pending_file_change_evidence_count_for_testing ())
;;

let with_tmp_log f =
  incr counter;
  let dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "test-keeper-tool-call-log-%d-%d-%d"
       (Unix.getpid ()) !counter
       (int_of_float (Unix.gettimeofday () *. 1000.0))) in
  Fs_compat.mkdir_p dir;
  Keeper_tool_call_log.reset_for_testing ();
  Keeper_tool_call_log.init ~base_path:dir ();
  Fun.protect
    ~finally:(fun () ->
      Keeper_tool_call_log.reset_for_testing ();
      Fs_compat.remove_tree dir)
    (fun () -> f ())

let with_tmp_log_dir f =
  incr counter;
  let dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "test-keeper-tool-call-log-%d-%d-%d"
       (Unix.getpid ()) !counter
       (int_of_float (Unix.gettimeofday () *. 1000.0))) in
  Fs_compat.mkdir_p dir;
  Keeper_tool_call_log.reset_for_testing ();
  Keeper_tool_call_log.init ~base_path:dir ();
  Fun.protect
    ~finally:(fun () ->
      Keeper_tool_call_log.reset_for_testing ();
      Fs_compat.remove_tree dir)
    (fun () -> f dir)

let with_tmp_corrupt_tool_call_store f =
  incr counter;
  let dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "test-keeper-tool-call-log-corrupt-%d-%d-%d"
       (Unix.getpid ()) !counter
       (int_of_float (Unix.gettimeofday () *. 1000.0))) in
  let masc_root = Filename.concat dir ".masc" in
  Fs_compat.mkdir_p masc_root;
  Fs_compat.save_file (Filename.concat masc_root "tool_calls") "not a directory";
  Keeper_tool_call_log.reset_for_testing ();
  Keeper_tool_call_log.init ~base_path:dir ();
  Fun.protect
    ~finally:(fun () ->
      Keeper_tool_call_log.reset_for_testing ();
      Fs_compat.remove_tree dir)
    (fun () -> f ~dir ~masc_root)

(* ── read_window ─────────────────────────── *)

(* [read_window] filters as it reads rather than building the day range and
   filtering after. What it keeps, and in what order, is the contract; the
   store held 40,268 rows in a 24h window on 2026-09-06 and a keeper-scoped
   caller kept 7-19% of them, so what the other 80% cost is the reason the
   read changed and not part of the contract. *)
let test_read_window_keeps_the_keepers_rows_in_order () =
  with_tmp_log (fun () ->
    let log keeper tool =
      Keeper_tool_call_log.log_call
        ~keeper_name:keeper ~tool_name:tool
        ~input:(`Assoc []) ~output_text:"out"
        ~success:true ~duration_ms:1.0 ()
    in
    log "alice" "first";
    log "bob" "between";
    log "alice" "second";
    log "carol" "other";
    log "alice" "third";
    let tools rows =
      List.filter_map (fun row -> Safe_ops.json_string_opt "tool" row) rows
    in
    let alice = Keeper_tool_call_log.read_window ~keeper_name:"alice" ~window_hours:1.0 () in
    Alcotest.(check (list string))
      "the keeper's rows, in the order they were written"
      [ "first"; "second"; "third" ]
      (tools alice);
    let all = Keeper_tool_call_log.read_window ~window_hours:1.0 () in
    Alcotest.(check (list string))
      "no keeper filter keeps every row"
      [ "first"; "between"; "second"; "other"; "third" ]
      (tools all);
    Alcotest.(check int)
      "a keeper that wrote nothing has nothing"
      0
      (List.length
         (Keeper_tool_call_log.read_window ~keeper_name:"dave" ~window_hours:1.0 ()));
    Alcotest.(check int)
      "a non-positive window is empty"
      0
      (List.length (Keeper_tool_call_log.read_window ~window_hours:0.0 ())))
;;

(* ── file_change_tally carries its answer ─────────────── *)

(* The tally is folded from what the store gained since the last call. Two
   things have to hold for that to be safe: the answer must equal what a whole
   read produces, and a row appended between calls must appear. The counts are
   what this checks — a keeper's rows are not file changes in this fixture, so
   [rows_counted] is where they land, and it is the field the endpoint reports
   as "of m calls". *)
let test_file_change_tally_matches_a_whole_read () =
  with_tmp_log (fun () ->
    let module Change = Keeper_tool_call_file_change in
    let log keeper tool =
      Keeper_tool_call_log.log_call
        ~keeper_name:keeper ~tool_name:tool
        ~input:(`Assoc []) ~output_text:"out"
        ~success:true ~duration_ms:1.0 ()
    in
    log "alice" "first";
    log "bob" "other";
    log "alice" "second";
    let whole_read keeper =
      Change.classify_all
        (Keeper_tool_call_log.read_window ~keeper_name:keeper ~window_hours:1.0 ())
    in
    let carried = Keeper_tool_call_log.file_change_tally ~keeper_name:"alice" ~window_hours:1.0 () in
    Alcotest.(check int)
      "a first fold equals a whole read"
      (Change.rows_counted (whole_read "alice"))
      (Change.rows_counted carried);
    Alcotest.(check int) "and it saw alice's two rows" 2 (Change.rows_counted carried);
    (* Called again with nothing appended, the carried tally must not double. *)
    let again = Keeper_tool_call_log.file_change_tally ~keeper_name:"alice" ~window_hours:1.0 () in
    Alcotest.(check int) "a repeat call does not re-count" 2 (Change.rows_counted again);
    log "alice" "third";
    let after = Keeper_tool_call_log.file_change_tally ~keeper_name:"alice" ~window_hours:1.0 () in
    Alcotest.(check int) "a row appended between calls appears" 3 (Change.rows_counted after);
    Alcotest.(check int)
      "and still equals a whole read"
      (Change.rows_counted (whole_read "alice"))
      (Change.rows_counted after);
    (* A different keeper and an unfiltered read are separate carried answers. *)
    Alcotest.(check int)
      "bob's own answer"
      1
      (Change.rows_counted
         (Keeper_tool_call_log.file_change_tally ~keeper_name:"bob" ~window_hours:1.0 ()));
    Alcotest.(check int)
      "no keeper filter sees every row"
      4
      (Change.rows_counted (Keeper_tool_call_log.file_change_tally ~window_hours:1.0 ()));
    Alcotest.(check int)
      "a non-positive window is empty"
      0
      (Change.rows_counted (Keeper_tool_call_log.file_change_tally ~window_hours:0.0 ())))
;;

(* ── read_recent edge cases ─────────────────────────── *)

let test_read_recent_n_zero () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"k" ~tool_name:"tool_a"
      ~input:(`Assoc []) ~output_text:"ok"
      ~success:true ~duration_ms:1.0 ();
    let result = Keeper_tool_call_log.read_recent ~n:0 () in
    Alcotest.(check int) "n=0 returns empty" 0 (List.length result))

let test_read_recent_n_negative () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"k" ~tool_name:"tool_a"
      ~input:(`Assoc []) ~output_text:"ok"
      ~success:true ~duration_ms:1.0 ();
    let result = Keeper_tool_call_log.read_recent ~n:(-1) () in
    Alcotest.(check int) "n<0 returns empty" 0 (List.length result))

let test_read_recent_keeper_filter () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"alice" ~tool_name:"tool_x"
      ~input:(`Assoc []) ~output_text:"out"
      ~success:true ~duration_ms:5.0 ();
    Keeper_tool_call_log.log_call
      ~keeper_name:"bob" ~tool_name:"tool_y"
      ~input:(`Assoc []) ~output_text:"out"
      ~success:true ~duration_ms:5.0 ();
    let alice_entries = Keeper_tool_call_log.read_recent ~keeper_name:"alice" () in
    let bob_entries = Keeper_tool_call_log.read_recent ~keeper_name:"bob" () in
    let all_entries = Keeper_tool_call_log.read_recent () in
    Alcotest.(check int) "alice gets 1 entry" 1 (List.length alice_entries);
    Alcotest.(check int) "bob gets 1 entry" 1 (List.length bob_entries);
    Alcotest.(check int) "all gets 2 entries" 2 (List.length all_entries))

(* The dashboard /tool-calls handler derives each keeper's slice from one
   shared fleet read instead of per-keeper [read_recent] calls. The
   derivation must be observationally equal to [read_recent]. *)
(* The unfiltered read stops at [n]; the keeper-filtered one still scans past
   it to find [n] matches. Both have to hold at once — dropping the over-scan
   everywhere would silently shorten per-keeper answers, and keeping it
   everywhere reads five times the store for a fleet answer that cannot
   change. *)
let test_unfiltered_read_is_exactly_n_and_filtered_still_finds_n () =
  with_tmp_log (fun () ->
    List.iter
      (fun (keeper, tool) ->
        Keeper_tool_call_log.log_call
          ~keeper_name:keeper ~tool_name:tool
          ~input:(`Assoc []) ~output_text:"out"
          ~success:true ~duration_ms:1.0 ())
      [ ("alice", "t1"); ("bob", "t2"); ("bob", "t3"); ("bob", "t4")
      ; ("bob", "t5"); ("bob", "t6"); ("bob", "t7"); ("bob", "t8")
      ; ("bob", "t9"); ("alice", "t10")
      ];
    let tools rows =
      List.map
        (fun json ->
          match Safe_ops.json_string_opt "tool" json with
          | Some tool -> tool
          | None -> "?")
        rows
    in
    Alcotest.(check (list string))
      "unfiltered read returns exactly the newest n"
      [ "t9"; "t10" ]
      (tools (Keeper_tool_call_log.read_recent ~n:2 ()));
    (* alice's two rows sit at opposite ends of the store, so finding both
       requires reading well past n — this is what the over-scan buys. *)
    Alcotest.(check (list string))
      "keeper-filtered read still scans past n to find n matches"
      [ "t1"; "t10" ]
      (tools (Keeper_tool_call_log.read_recent ~keeper_name:"alice" ~n:2 ())))
;;

let test_fleet_rows_derivation_matches_read_recent () =
  with_tmp_log (fun () ->
    List.iter
      (fun (keeper, tool) ->
        Keeper_tool_call_log.log_call
          ~keeper_name:keeper ~tool_name:tool
          ~input:(`Assoc []) ~output_text:"out"
          ~success:true ~duration_ms:1.0 ())
      [ ("alice", "t1"); ("bob", "t2"); ("alice", "t3");
        ("carol", "t4"); ("alice", "t5"); ("bob", "t6") ];
    let n = 2 in
    let fleet =
      Keeper_tool_call_log.read_recent_rows
        ~n:(n * Keeper_tool_call_log.read_over_scan_factor) ()
    in
    List.iter
      (fun keeper ->
        let direct =
          Keeper_tool_call_log.read_recent ~keeper_name:keeper ~n ()
        in
        let derived =
          Keeper_tool_call_log.filter_rows_for_keeper
            ~keeper_name:keeper ~n fleet
        in
        Alcotest.(check (list string))
          (Printf.sprintf "derived slice equals read_recent for %s" keeper)
          (List.map Yojson.Safe.to_string direct)
          (List.map Yojson.Safe.to_string derived))
      [ "alice"; "bob"; "carol"; "absent-keeper" ])

let test_exact_agent_core_occurrence_persisted () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"k"
      ~tool_name:"tool_a"
      ~input:(`Assoc [])
      ~output_text:"ok"
      ~success:true
      ~duration_ms:1.0
      ~tool_use_id:""
      ~turn:9
      ~planned_index:4
      ~batch_index:2
      ~batch_size:3
      ~execution_mode:Agent_core.Tool_contract.Concurrent
      ();
    match Keeper_tool_call_log.read_recent ~n:1 () with
    | [ entry ] ->
      Alcotest.(check (option string))
        "blank provider id persisted"
        (Some "")
        (Safe_ops.json_string_opt "tool_use_id" entry);
      Alcotest.(check int)
        "turn persisted"
        9
        (Safe_ops.json_int ~default:(-1) "turn" entry);
      Alcotest.(check int)
        "planned index persisted"
        4
        (Safe_ops.json_int ~default:(-1) "planned_index" entry);
      Alcotest.(check int)
        "batch index persisted"
        2
        (Safe_ops.json_int ~default:(-1) "batch_index" entry);
      Alcotest.(check int)
        "batch size persisted"
        3
        (Safe_ops.json_int ~default:(-1) "batch_size" entry);
      Alcotest.(check (option string))
        "execution mode persisted"
        (Some "concurrent")
        (Safe_ops.json_string_opt "execution_mode" entry)
    | _ -> Alcotest.fail "expected exactly one entry")

(* The ordinary path knows the disposition but not the payload, so it cannot
   supply [typed_result]. Before this it supplied nothing and the row carried
   only [success], which cannot tell a policy rejection from a runtime failure
   and cannot represent [Deferred] at all. *)
let test_ordinary_path_disposition_persisted () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"epsilon"
      ~tool_name:"keeper_fs_read"
      ~input:(`Assoc [ "path", `String "lib/runtime.ml" ])
      ~output_text:"refused"
      ~success:false
      ~duration_ms:3.0
      ~disposition:(Tool_result.Failed Tool_result.Policy_rejection)
      ();
    match Keeper_tool_call_log.read_recent ~n:1 () with
    | [ entry ] ->
      Alcotest.(check (option string))
        "the row says which kind of failure"
        (Some "failed")
        (Safe_ops.json_string_opt "disposition" entry)
    | _ -> Alcotest.fail "expected exactly one entry")

let test_file_change_evidence_persists_with_execution_identity () =
  with_tmp_log (fun () ->
    let occurrence =
      Keeper_file_change_evidence.edit_occurrence
        ~old_start_line:2
        ~new_start_line:2
        ~old_string:"old a\nold b"
        ~new_string:"new a\nnew b\nnew c"
    in
    let evidence = Keeper_file_change_evidence.edited [ occurrence ] in
    let execution_id = Ids.Execution_id.of_string "exec-file-change-evidence" in
    Keeper_tool_call_log.log_call
      ~keeper_name:"epsilon"
      ~tool_name:"keeper_fs_edit"
      ~input:(`Assoc [ "path", `String "lib/runtime.ml" ])
      ~output_text:(String.make 5000 'x')
      ~success:true
      ~duration_ms:3.0
      ~execution_id
      ~file_change_evidence:evidence
      ();
    match Keeper_tool_call_log.read_recent ~n:1 () with
    | [ entry ] ->
      Alcotest.(check (option string))
        "same row keeps canonical execution id"
        (Some "exec-file-change-evidence")
        (Safe_ops.json_string_opt "execution_id" entry);
      let expected =
        Keeper_file_change_evidence.to_yojson evidence |> Yojson.Safe.to_string
      in
      let actual =
        Yojson.Safe.Util.member "file_change_evidence" entry
        |> Yojson.Safe.to_string
      in
      Alcotest.(check string)
        "typed evidence bypasses the truncated output preview"
        expected
        actual
    | _ -> Alcotest.fail "expected exactly one file change entry")
;;

(* A row with neither says so by omission rather than by guessing. *)
let test_row_without_a_typed_outcome_omits_the_field () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"epsilon"
      ~tool_name:"keeper_fs_read"
      ~input:(`Assoc [])
      ~output_text:"ok"
      ~success:true
      ~duration_ms:1.0
      ();
    match Keeper_tool_call_log.read_recent ~n:1 () with
    | [ entry ] ->
      Alcotest.(check (option string))
        "no disposition is written when none was known"
        None
        (Safe_ops.json_string_opt "disposition" entry)
    | _ -> Alcotest.fail "expected exactly one entry")

let test_composition_action_context_persisted () =
  with_tmp_log (fun () ->
    let source_id =
      Skill_source_config.source_id_of_string "workspace" |> Result.get_ok
    in
    let package_id = Skill_reference.package_id_of_directory "research" |> Result.get_ok in
    let skill_reference =
      Skill_reference.make
        ~identity:
          (Skill_reference.make_identity
             ~source_id
             ~package_id
             ~name:"research")
        ~content_revision:
          (Skill_reference.content_revision_of_string (String.make 64 'a')
           |> Result.get_ok)
    in
    let typed_result =
      Tool_result.Completed
        { Tool_result.tool_name = "keeper_fs_read"
        ; data = `Assoc [ "content", `String "typed output" ]
        ; metadata = None
        ; duration_ms = 12.5
        }
    in
    Keeper_tool_call_log.log_call
      ~keeper_name:"delta"
      ~tool_name:"keeper_fs_read"
      ~input:(`Assoc [ "path", `String "lib/runtime.ml" ])
      ~output_text:"typed output"
      ~success:true
      ~duration_ms:12.5
      ~typed_result
      ~composition_tool:"keeper_research_pipeline"
      ~skill_reference
      ~composition_run_id:"run-42"
      ~composition_node_id:"fetch_sources"
      ~composition_execution:Keeper_tool_composition_catalog.Async
      ~parent_tool_use_id:"outer-7"
      ();
    match Keeper_tool_call_log.read_recent ~n:1 () with
    | [ entry ] ->
      List.iter
        (fun (label, key, expected) ->
           Alcotest.(check (option string))
             label
             (Some expected)
             (Safe_ops.json_string_opt key entry))
        [ "typed disposition", "disposition", "completed"
        ; "composition tool", "composition_tool", "keeper_research_pipeline"
        ; "composition run", "composition_run_id", "run-42"
        ; "composition node", "composition_node_id", "fetch_sources"
        ; "composition execution", "composition_execution", "async"
        ; "outer provider call", "parent_tool_use_id", "outer-7"
        ]
      ; Alcotest.(check string)
          "exact Skill reference"
          (Skill_reference.to_yojson skill_reference |> Yojson.Safe.to_string)
          (match Safe_ops.json_member_opt "skill_reference" entry with
           | Some json -> Yojson.Safe.to_string json
           | None -> "missing")
    | _ -> Alcotest.fail "expected exactly one composition action entry")

(* One keeper, one trace: a submitted turn and the keeper's own autonomous
   cycle each run the same composition tool. Rows of both carry the same
   keeper, trace_id and composition tool, so a reader asking which run
   belongs to the submission had nothing to separate them and fell back to
   the submission's wall clock — which the autonomous run overlaps
   (masc#28977 RW17: builder-b's autonomous compose runs were read as
   exactly-once violations of the submitted mission).

   The rows are written the way both production writers do it: context into
   a per-run cell, read back as a record, passed explicitly to log_call. *)
let test_composition_rows_separate_submitted_from_autonomous_turn () =
  with_tmp_log (fun () ->
    let node_ids = [ "clock"; "board"; "board-peer"; "memory" ] in
    let log_composition_run ~turn_kind ~keeper_turn_id ~run_id =
      let cell = Keeper_tool_call_log.create_turn_ctx_cell () in
      Keeper_tool_call_log.set_turn_context
        ~cell
        ~agent_name:"keeper-build-b-agent"
        ~turn_kind
        ~lane:"tool_optional"
        ~trace_id:"trace-shared"
        ~session_id:"trace-shared"
        ~keeper_turn_id
        ();
      let context : Keeper_tool_call_log_context.turn_context =
        Keeper_tool_call_log_context.get_turn_context_record ~cell ()
      in
      List.iter
        (fun node_id ->
           Keeper_tool_call_log.log_call
             ~keeper_name:"build-b"
             ~tool_name:"masc_board_stats"
             ~input:(`Assoc [])
             ~output_text:"ok"
             ~success:true
             ~duration_ms:1.0
             ?agent_name:context.agent_name
             ?turn_kind:context.turn_kind
             ?lane:context.lane
             ?trace_id:context.trace_id
             ?session_id:context.session_id
             ?keeper_turn_id:context.keeper_turn_id
             ~composition_tool:"keeper_compose_mission-snapshot"
             ~composition_run_id:run_id
             ~composition_node_id:node_id
             ~composition_execution:Keeper_tool_composition_catalog.Inline
             ~parent_tool_use_id:("call-" ^ run_id)
             ())
        node_ids
    in
    log_composition_run
      ~turn_kind:Turn_record.Direct
      ~keeper_turn_id:2
      ~run_id:"run-submitted";
    log_composition_run
      ~turn_kind:Turn_record.Autonomous
      ~keeper_turn_id:3
      ~run_id:"run-autonomous";
    let entries = Keeper_tool_call_log.read_recent ~n:16 () in
    Alcotest.(check int) "every node row of both runs persisted" 8
      (List.length entries);
    let run_ids_for kind =
      List.filter_map
        (fun entry ->
           match Safe_ops.json_string_opt "turn_kind" entry with
           | Some value when String.equal value kind ->
             Safe_ops.json_string_opt "composition_run_id" entry
           | Some _ | None -> None)
        entries
      |> List.sort_uniq String.compare
    in
    Alcotest.(check (list string)) "submitted turn owns exactly its run"
      [ "run-submitted" ]
      (run_ids_for "direct");
    Alcotest.(check (list string)) "autonomous cycle owns exactly its run"
      [ "run-autonomous" ]
      (run_ids_for "autonomous");
    let submitted_node_rows =
      List.filter
        (fun entry ->
           match Safe_ops.json_string_opt "turn_kind" entry with
           | Some value -> String.equal value "direct"
           | None -> false)
        entries
    in
    Alcotest.(check int) "submitted run keeps all four node rows" 4
      (List.length submitted_node_rows);
    Alcotest.(check (list string)) "every node of the submitted run is named"
      (List.sort String.compare node_ids)
      (List.filter_map
         (Safe_ops.json_string_opt "composition_node_id")
         submitted_node_rows
       |> List.sort String.compare))

(* ── Redaction: tool names do not suppress evidence ────────────── *)

let test_sensitive_named_tool_logged_with_redaction () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"k" ~tool_name:"mcp_auth_create"
      ~input:(`Assoc [("token", `String "secret123")]) ~output_text:"done"
      ~success:true ~duration_ms:1.0 ();
    let result = Keeper_tool_call_log.read_recent () in
    Alcotest.(check int) "tool call logged" 1 (List.length result);
    let encoded = Yojson.Safe.to_string (List.hd result) in
    Alcotest.(check bool)
      "sensitive value redacted"
      false
      (String_util.contains_substring encoded "secret123"))

(* ── Redaction: sensitive fields stripped ────────────── *)

let test_sensitive_input_fields_redacted () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"k" ~tool_name:"masc_status"
      ~input:(`Assoc [
        ("token", `String "sk-proj-abcdefghijklmnop12345678");
        ("content", `String "hello");
      ])
      ~output_text:"done"
      ~success:true ~duration_ms:1.0 ();
    let entries = Keeper_tool_call_log.read_recent () in
    Alcotest.(check int) "one entry logged" 1 (List.length entries);
    let entry_str = Yojson.Safe.to_string (List.hd entries) in
    Alcotest.(check bool) "token value redacted" false
      (String_util.contains_substring entry_str "sk-proj-abcdefghijklmnop12345678"))

(* ── Model field redacted ───────────────────────────── *)

let test_model_field_stored () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"k" ~tool_name:"masc_status"
      ~input:(`Assoc []) ~output_text:"ok"
      ~success:true ~duration_ms:2.0
      ~model:"glm-4-9b"
      ~runtime_profile:"local_qwen3_27b_only"
      ();
    let entries = Keeper_tool_call_log.read_recent () in
    Alcotest.(check int) "one entry" 1 (List.length entries);
    let entry_str = Yojson.Safe.to_string (List.hd entries) in
    Alcotest.(check bool) "raw model absent" false
      (String_util.contains_substring entry_str "glm-4-9b");
    Alcotest.(check (option string)) "model redacted to runtime"
      (Some "runtime")
      (Safe_ops.json_string_opt "model" (List.hd entries));
    Alcotest.(check (option string)) "runtime profile stored"
      (Some "local_qwen3_27b_only")
      (Safe_ops.json_string_opt "runtime_profile" (List.hd entries)))

let test_turn_context_fields_stored () =
  with_tmp_log (fun () ->
    (* Mirrors the production reader (keeper_hooks_agent_core): context is
       written to a per-run cell, read back as a record, and passed
       explicitly to log_call — there is no ambient fallback. *)
    let cell = Keeper_tool_call_log.create_turn_ctx_cell () in
    Keeper_tool_call_log.set_turn_context
      ~cell
      ~agent_name:"keeper-k-agent"
      ~lane:"tool_optional"
      ~tool_choice:"auto"
      ~thinking_enabled:false
      ~thinking_budget:1024
      ~prompt_fingerprint:"prompt-fp-k"
      ~trace_id:"trace-k"
      ~session_id:"trace-k"
      ~turn:7
      ~keeper_turn_id:7
      ~task_id:"task-runtime-trust"
      ~sandbox_profile:"docker"
      ~sandbox_root:"/tmp/k-sandbox"
      ~sandbox_roots:["/tmp/k-sandbox"; "/tmp/shared"]
      ~network_mode:"inherit"
      ~runtime_profile:"tool_use_strict"
      ();
    let tctx : Keeper_tool_call_log_context.turn_context =
      Keeper_tool_call_log_context.get_turn_context_record ~cell ()
    in
    Keeper_tool_call_log.log_call
      ~keeper_name:"k" ~tool_name:"masc_status"
      ~input:(`Assoc [("path", `String "/tmp/k-sandbox/status.json")])
      ~output_text:"ok"
      ~success:true ~duration_ms:2.0
      ?agent_name:tctx.agent_name
      ?lane:tctx.lane ?tool_choice:tctx.tool_choice
      ?thinking_enabled:tctx.thinking_enabled
      ?thinking_budget:tctx.thinking_budget
      ?prompt_fingerprint:tctx.prompt_fingerprint
      ?trace_id:tctx.trace_id ?session_id:tctx.session_id
      ?turn:tctx.turn ?keeper_turn_id:tctx.keeper_turn_id
      ?task_id:tctx.task_id
      ?sandbox_profile:tctx.sandbox_profile
      ?sandbox_root:tctx.sandbox_root
      ?sandbox_roots:tctx.sandbox_roots
      ?network_mode:tctx.network_mode
      ?runtime_profile:tctx.runtime_profile
      ();
    let entries = Keeper_tool_call_log.read_recent () in
    Alcotest.(check int) "one entry" 1 (List.length entries);
    let entry = List.hd entries in
    Alcotest.(check (option string)) "lane field"
      (Some "tool_optional")
      (Safe_ops.json_string_opt "lane" entry);
    Alcotest.(check (option string)) "tool_choice field"
      (Some "auto")
      (Safe_ops.json_string_opt "tool_choice" entry);
    Alcotest.(check bool) "thinking_enabled present" true
      (match Yojson.Safe.Util.member "thinking_enabled" entry with
       | `Bool false -> true
       | _ -> false);
    Alcotest.(check int) "thinking_budget field" 1024
      (Safe_ops.json_int ~default:0 "thinking_budget" entry);
    Alcotest.(check (option string)) "prompt_fingerprint field"
      (Some "prompt-fp-k")
      (Safe_ops.json_string_opt "prompt_fingerprint" entry);
    Alcotest.(check (option string)) "trace_id field"
      (Some "trace-k")
      (Safe_ops.json_string_opt "trace_id" entry);
    Alcotest.(check (option string)) "session_id field"
      (Some "trace-k")
      (Safe_ops.json_string_opt "session_id" entry);
    Alcotest.(check int) "turn field" 7
      (Safe_ops.json_int ~default:0 "turn" entry);
    Alcotest.(check int) "keeper_turn_id field" 7
      (Safe_ops.json_int ~default:0 "keeper_turn_id" entry);
    Alcotest.(check (option string)) "runtime_profile field"
      (Some "tool_use_strict")
      (Safe_ops.json_string_opt "runtime_profile" entry);
    Alcotest.(check (option string)) "task_id field"
      (Some "task-runtime-trust")
      (Safe_ops.json_string_opt "task_id" entry);
    Alcotest.(check (option string)) "sandbox_profile field"
      (Some "docker")
      (Safe_ops.json_string_opt "sandbox_profile" entry);
    Alcotest.(check (option string)) "network_mode field"
      (Some "inherit")
      (Safe_ops.json_string_opt "network_mode" entry);
    let runtime_contract =
      Yojson.Safe.Util.member "runtime_contract" entry
    in
    Alcotest.(check (option string)) "runtime_contract keeper"
      (Some "k")
      (Safe_ops.json_string_opt "keeper_name" runtime_contract);
    (* Top level, not inside runtime_contract: that is where the readers look.
       The dashboard's turn-actor resolver takes entry.agent_name first and
       never descends into the contract, and no producer has ever put the name
       there. Asserting the contract slot pinned a field nothing wrote and
       nothing read. *)
    Alcotest.(check (option string)) "agent_name field"
      (Some "keeper-k-agent")
      (Safe_ops.json_string_opt "agent_name" entry);
    Alcotest.(check bool) "agent_name is not duplicated into runtime_contract" true
      (match Yojson.Safe.Util.member "agent_name" runtime_contract with
       | `Null -> true
       | _ -> false);
    Alcotest.(check (list string)) "runtime_contract sandbox_roots"
      ["/tmp/k-sandbox"; "/tmp/shared"]
      Yojson.Safe.Util.(
        runtime_contract |> member "sandbox_roots" |> to_list |> List.map to_string);
    let path_resolution =
      Yojson.Safe.Util.member "path_resolution" runtime_contract
    in
    Alcotest.(check bool)
      "runtime contract explains Execute repo cwd path basis"
      true
      (String_util.contains_substring
         Yojson.Safe.Util.(member "execute_path_basis" path_resolution |> to_string)
         "do not repeat the cwd prefix");
    Alcotest.(check bool)
      "runtime contract points .masc state at task/context tools"
      true
      (String_util.contains_substring
         Yojson.Safe.Util.(member "masc_state_basis" path_resolution |> to_string)
         "Use keeper task/context tools");
    let omits_field name =
      match runtime_contract with
      | `Assoc fields -> not (List.mem_assoc name fields)
      | _ -> false
    in
    Alcotest.(check bool) "runtime_contract omits required_tools" true
      (omits_field "required_tools");
    Alcotest.(check bool) "runtime_contract omits required_tool_candidates" true
      (omits_field "required_tool_candidates");
    Alcotest.(check bool) "runtime_contract omits missing_required_tools" true
      (omits_field "missing_required_tools");
    Alcotest.(check (option string)) "runtime_contract runtime_profile"
      (Some "tool_use_strict")
      (Safe_ops.json_string_opt "runtime_profile" runtime_contract);
    let action_radius = Yojson.Safe.Util.member "action_radius" entry in
    Alcotest.(check (option string)) "action_radius tool"
      (Some "masc_status")
      (Safe_ops.json_string_opt "tool_name" action_radius);
    Alcotest.(check (option string)) "action_radius target path"
      (Some "/tmp/k-sandbox/status.json")
      (Safe_ops.json_string_opt "target_path" action_radius);
    Alcotest.(check bool) "action_radius success" true
      (Safe_ops.json_bool ~default:false "success" action_radius))

(* RFC-0225 §3.3 regression: two runs of the SAME keeper each carry their
   own cell — setting one must not disturb the other. Under the previous
   keeper_name-keyed global the second set overwrote the first and the
   first run's tool calls were logged with the second run's identity. *)
let test_turn_context_cells_do_not_cross_runs () =
  let cell_a = Keeper_tool_call_log.create_turn_ctx_cell () in
  let cell_b = Keeper_tool_call_log.create_turn_ctx_cell () in
  Keeper_tool_call_log.set_turn_context
    ~cell:cell_a ~trace_id:"trace-a" ~keeper_turn_id:1 ();
  Keeper_tool_call_log.set_turn_context
    ~cell:cell_b ~trace_id:"trace-b" ~keeper_turn_id:2 ();
  let ctx_a : Keeper_tool_call_log_context.turn_context =
    Keeper_tool_call_log_context.get_turn_context_record ~cell:cell_a ()
  in
  let ctx_b : Keeper_tool_call_log_context.turn_context =
    Keeper_tool_call_log_context.get_turn_context_record ~cell:cell_b ()
  in
  Alcotest.(check (option string)) "run A keeps its trace_id"
    (Some "trace-a") ctx_a.trace_id;
  Alcotest.(check (option int)) "run A keeps its keeper_turn_id"
    (Some 1) ctx_a.keeper_turn_id;
  Alcotest.(check (option string)) "run B keeps its trace_id"
    (Some "trace-b") ctx_b.trace_id;
  Alcotest.(check (option int)) "run B keeps its keeper_turn_id"
    (Some 2) ctx_b.keeper_turn_id;
  let fresh : Keeper_tool_call_log_context.turn_context =
    Keeper_tool_call_log_context.get_turn_context_record
      ~cell:(Keeper_tool_call_log.create_turn_ctx_cell ()) ()
  in
  Alcotest.(check (option string)) "fresh cell reads empty" None
    fresh.trace_id

let test_turn_context_fields_absent_without_context () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"k" ~tool_name:"masc_status"
      ~input:(`Assoc []) ~output_text:"ok"
      ~success:true ~duration_ms:2.0 ();
    let entries = Keeper_tool_call_log.read_recent () in
    Alcotest.(check int) "one entry" 1 (List.length entries);
    let entry = List.hd entries in
    Alcotest.(check (option string)) "lane absent"
      None
      (Safe_ops.json_string_opt "lane" entry);
    Alcotest.(check (option string)) "tool_choice absent"
      None
      (Safe_ops.json_string_opt "tool_choice" entry);
    Alcotest.(check bool) "thinking_enabled absent" true
      (match Yojson.Safe.Util.member "thinking_enabled" entry with
       | `Null -> true
       | _ -> false);
    Alcotest.(check bool) "thinking_budget absent" true
      (match Yojson.Safe.Util.member "thinking_budget" entry with
       | `Null -> true
       | _ -> false);
    Alcotest.(check bool) "prompt_fingerprint absent" true
      (match Yojson.Safe.Util.member "prompt_fingerprint" entry with
       | `Null -> true
       | _ -> false);
    Alcotest.(check bool) "trace_id absent" true
      (match Yojson.Safe.Util.member "trace_id" entry with
       | `Null -> true
       | _ -> false);
    Alcotest.(check bool) "session_id absent" true
      (match Yojson.Safe.Util.member "session_id" entry with
       | `Null -> true
       | _ -> false);
    Alcotest.(check bool) "turn absent" true
      (match Yojson.Safe.Util.member "turn" entry with
       | `Null -> true
       | _ -> false))

let test_route_evidence_stored_for_git_push () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"omega"
      ~tool_name:"tool_execute"
      ~input:
        (`Assoc
           [
             ( "argv",
               `List
                 [
                   `String "git";
                   `String "push";
                   `String "-u";
                   `String "origin";
                   `String "keeper/executor-direct-clone-pr-proof-20260506-1039";
                 ] );
             ( "cwd",
               `String "repos/masc-keeper-direct-proof-20260506-1039" );
           ])
      ~output_text:
        {|{"ok":true,"via":"docker","cwd":"repos/masc-keeper-direct-proof-20260506-1039","sandbox_profile":"docker","network_mode":"bridge","status":{"label":"success","kind":"exit","code":0},"output":"branch pushed"}|}
      ~success:true
      ~duration_ms:42.0
      ();
    let entries = Keeper_tool_call_log.read_recent ~n:1 () in
    Alcotest.(check int) "entry persisted" 1 (List.length entries);
    match entries with
    | [ entry ] ->
      let evidence = Yojson.Safe.Util.member "route_evidence" entry in
      Alcotest.(check (option string)) "tool name"
        (Some "tool_execute")
        (Safe_ops.json_string_opt "tool_name" evidence);
      Alcotest.(check (option string)) "descriptor id"
        (Some "agent.execute")
        (Safe_ops.json_string_opt "descriptor_id" evidence);
      Alcotest.(check (option string)) "public name"
        (Some "Execute")
        (Safe_ops.json_string_opt "public_name" evidence);
      Alcotest.(check (option string)) "canonical name"
        (Some "tool_execute")
        (Safe_ops.json_string_opt "canonical_name" evidence);
      Alcotest.(check (option string)) "command captured"
        (Some "[REDACTED]")
        (Safe_ops.json_string_opt "command" evidence);
      Alcotest.(check (option string)) "cwd captured"
        (Some "[REDACTED]")
        (Safe_ops.json_string_opt "cwd" evidence);
      Alcotest.(check (option string)) "via captured"
        (Some "docker")
        (Safe_ops.json_string_opt "via" evidence);
      Alcotest.(check (option string)) "sandbox profile captured"
        (Some "docker")
        (Safe_ops.json_string_opt "sandbox_profile" evidence);
      Alcotest.(check (option string)) "network mode captured"
        (Some "bridge")
        (Safe_ops.json_string_opt "network_mode" evidence);
      let status = Yojson.Safe.Util.member "status" evidence in
      Alcotest.(check (option string)) "status label"
        (Some "success")
        (Safe_ops.json_string_opt "label" status)
    | _ -> Alcotest.fail "expected exactly one entry")

let test_route_evidence_stored_for_blob_backed_git_push () =
  with_tmp_log (fun () ->
    let marker =
      Tool_output.encode_for_agent_core
        (Tool_output.Stored
           (artifact_ref_exn
              ~sha256:(String.make 64 'b')
              ~bytes:8192
              ~mime:"application/json"
              ~preview:{|{"ok":true,"via":"docker","sandbox_profile":"docker","network_mode":"bridge","status":{"label":"success","kind":"exit","code":0},"output":"branch pushed"}|}))
    in
    Keeper_tool_call_log.log_call
      ~keeper_name:"omega"
      ~tool_name:"tool_execute"
      ~input:
        (`Assoc
           [
             ( "argv",
               `List
                 [
                   `String "git";
                   `String "push";
                   `String "-u";
                   `String "origin";
                   `String "keeper/large-route-proof";
                 ] );
             ("cwd", `String "repos/masc-keeper-direct-proof");
           ])
      ~output_text:marker
      ~success:true
      ~duration_ms:42.0
      ();
    let entries = Keeper_tool_call_log.read_recent ~n:1 () in
    Alcotest.(check int) "entry persisted" 1 (List.length entries);
    match entries with
    | [ entry ] ->
      let evidence = Yojson.Safe.Util.member "route_evidence" entry in
      Alcotest.(check (option string)) "via captured from blob preview"
        (Some "docker")
        (Safe_ops.json_string_opt "via" evidence);
      Alcotest.(check (option string)) "network mode captured"
        (Some "bridge")
        (Safe_ops.json_string_opt "network_mode" evidence);
      let status = Yojson.Safe.Util.member "status" evidence in
      Alcotest.(check (option string)) "status label captured"
        (Some "success")
        (Safe_ops.json_string_opt "label" status);
      Alcotest.(check (option string)) "command captured"
        (Some "[REDACTED]")
        (Safe_ops.json_string_opt "command" evidence)
    | _ -> Alcotest.fail "expected exactly one entry")

let test_route_evidence_redacts_wrapped_git_push () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"omega"
      ~tool_name:"tool_execute"
      ~input:
        (`Assoc
           [
             ( "cmd",
               `String
                 "env FOO=bar git -C repos/private-worktree push origin feature/private-proof"
             );
           ])
      ~output_text:
        {|{"ok":true,"via":"docker","sandbox_profile":"docker","network_mode":"bridge","status":{"label":"success","kind":"exit","code":0},"output":"branch pushed"}|}
      ~success:true
      ~duration_ms:42.0
      ();
    let entries = Keeper_tool_call_log.read_recent ~n:1 () in
    match entries with
    | [ entry ] ->
      let evidence = Yojson.Safe.Util.member "route_evidence" entry in
      Alcotest.(check (option string)) "wrapped command redacted"
        (Some "[REDACTED]")
        (Safe_ops.json_string_opt "command" evidence)
    | _ -> Alcotest.fail "expected exactly one entry")

let test_route_evidence_command_redaction_fails_closed () =
  let commands =
    [
      "git push --repo /Users/dancer/private origin feature/private-proof";
      "git push --repo=/Users/dancer/private origin feature/private-proof";
      "git -c safe.directory=/Users/dancer/private push origin feature/private-proof";
      "env FOO=bar git push origin 'feature/private proof'";
    ]
  in
  List.iter
    (fun command ->
       with_tmp_log (fun () ->
         Keeper_tool_call_log.log_call
           ~keeper_name:"omega"
           ~tool_name:"tool_execute"
           ~input:(`Assoc [ ("cmd", `String command) ])
           ~output_text:
             {|{"ok":true,"via":"docker","sandbox_profile":"docker","network_mode":"bridge","status":{"label":"success","kind":"exit","code":0},"output":"branch pushed"}|}
           ~success:true
           ~duration_ms:42.0
           ();
         match Keeper_tool_call_log.read_recent ~n:1 () with
         | [ entry ] ->
           let evidence = Yojson.Safe.Util.member "route_evidence" entry in
           Alcotest.(check (option string))
             "command is fail-closed"
             (Some "[REDACTED]")
             (Safe_ops.json_string_opt "command" evidence);
           let evidence_text = Yojson.Safe.to_string evidence in
           Alcotest.(check bool)
             "absolute path is absent"
             false
             (String_util.contains_substring evidence_text "/Users/dancer");
           Alcotest.(check bool)
             "private branch marker is absent"
             false
             (String_util.contains_substring evidence_text "private-proof")
           ;
           Alcotest.(check bool)
             "quoted private branch marker is absent"
             false
             (String_util.contains_substring evidence_text "private proof")
         | _ -> Alcotest.fail "expected exactly one entry"))
    commands
;;

let test_route_evidence_records_descriptor_for_filesystem_calls () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"omega"
      ~tool_name:"Read"
      ~input:(`Assoc [ ("file_path", `String "README.md") ])
      ~output_text:"file contents"
      ~success:true
      ~duration_ms:4.0
      ();
    let entries = Keeper_tool_call_log.read_recent ~n:1 () in
    Alcotest.(check int) "entry persisted" 1 (List.length entries);
    match entries with
    | [ entry ] ->
      let evidence = Yojson.Safe.Util.member "route_evidence" entry in
      Alcotest.(check (option string)) "tool name"
        (Some "Read")
        (Safe_ops.json_string_opt "tool_name" evidence);
      Alcotest.(check (option string)) "descriptor id"
        (Some "agent.read_file")
        (Safe_ops.json_string_opt "descriptor_id" evidence);
      Alcotest.(check (option string)) "public name"
        (Some "Read")
        (Safe_ops.json_string_opt "public_name" evidence);
      Alcotest.(check (option string)) "canonical name"
        (Some "tool_read_file")
        (Safe_ops.json_string_opt "canonical_name" evidence);
      Alcotest.(check (option string)) "executor"
        (Some "filesystem")
        (Safe_ops.json_string_opt "executor" evidence);
      Alcotest.(check (option string)) "backend"
        (Some "sandbox_process")
        (Safe_ops.json_string_opt "backend" evidence);
      Alcotest.(check (option string)) "sandbox"
        (Some "backend_selected")
        (Safe_ops.json_string_opt "sandbox" evidence)
    | _ -> Alcotest.fail "expected exactly one entry")

let test_route_evidence_records_internal_descriptor () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"omega"
      ~tool_name:"keeper_time_now"
      ~input:(`Assoc [])
      ~output_text:
        {|{"ok":true,"iso":"2026-05-26T00:00:00Z","epoch":1780000000}|}
      ~success:true
      ~duration_ms:1.0
      ();
    let entries = Keeper_tool_call_log.read_recent ~n:1 () in
    Alcotest.(check int) "entry persisted" 1 (List.length entries);
    match entries with
    | [ entry ] ->
      let evidence = Yojson.Safe.Util.member "route_evidence" entry in
      Alcotest.(check (option string)) "tool name"
        (Some "keeper_time_now")
        (Safe_ops.json_string_opt "tool_name" evidence);
      Alcotest.(check (option string)) "descriptor id"
        (Some "keeper.time.now")
        (Safe_ops.json_string_opt "descriptor_id" evidence);
      Alcotest.(check (option string)) "public name"
        (Some "keeper_time_now")
        (Safe_ops.json_string_opt "public_name" evidence);
      Alcotest.(check (option string)) "canonical name"
        (Some "keeper_time_now")
        (Safe_ops.json_string_opt "canonical_name" evidence);
      Alcotest.(check (option string)) "executor"
        (Some "in_process")
        (Safe_ops.json_string_opt "executor" evidence);
      Alcotest.(check (option string)) "backend"
        (Some "ocaml_runtime")
        (Safe_ops.json_string_opt "backend" evidence);
      Alcotest.(check (option string)) "sandbox"
        (Some "none")
        (Safe_ops.json_string_opt "sandbox" evidence);
      Alcotest.(check (option string)) "runtime handler"
        (Some "tool_time_now")
        (Safe_ops.json_string_opt "runtime_handler" evidence)
    | _ -> Alcotest.fail "expected exactly one entry")

let test_route_evidence_records_masc_board_descriptor () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"omega"
      ~tool_name:"mcp__masc__masc_board_post"
      ~input:(`Assoc [ "body", `String "descriptor evidence test" ])
      ~output_text:{|{"ok":true,"post_id":"post-1"}|}
      ~success:true
      ~duration_ms:2.0
      ();
    let entries = Keeper_tool_call_log.read_recent ~n:1 () in
    Alcotest.(check int) "entry persisted" 1 (List.length entries);
    match entries with
    | [ entry ] ->
      let evidence = Yojson.Safe.Util.member "route_evidence" entry in
      Alcotest.(check (option string)) "tool name"
        (Some "mcp__masc__masc_board_post")
        (Safe_ops.json_string_opt "tool_name" evidence);
      Alcotest.(check (option string)) "descriptor id"
        (Some "masc.board.post")
        (Safe_ops.json_string_opt "descriptor_id" evidence);
      Alcotest.(check (option string)) "public name"
        (Some "masc_board_post")
        (Safe_ops.json_string_opt "public_name" evidence);
      Alcotest.(check (option string)) "canonical name"
        (Some "masc_board_post")
        (Safe_ops.json_string_opt "canonical_name" evidence);
      Alcotest.(check (option string)) "executor"
        (Some "in_process")
        (Safe_ops.json_string_opt "executor" evidence);
      Alcotest.(check (option string)) "runtime handler"
        (Some "tool_board_dispatch")
        (Safe_ops.json_string_opt "runtime_handler" evidence)
    | _ -> Alcotest.fail "expected exactly one entry")

let route_evidence_for_tool tool_name =
  match
    Keeper_tool_call_log.route_evidence_json_of_tool_io
      ~tool_name
      ~input:(`Assoc [])
      ~output_text:"{}"
  with
  | Some evidence -> evidence
  | None -> Alcotest.failf "missing route evidence for %s" tool_name
;;

let check_eval_tags tool_name expected =
  let evidence = route_evidence_for_tool tool_name in
  Alcotest.(check (list string))
    (tool_name ^ " eval tags")
    expected
    (Safe_ops.json_string_list "eval_tags" evidence)
;;

let test_route_evidence_records_descriptor_eval_tags () =
  check_eval_tags "keeper_tools_list" [ "capability_introspection" ];
  check_eval_tags "keeper_surface_read" [ "surface_context_read" ];
  check_eval_tags "masc_agent_card" [ "agent_profile_lookup" ];
  check_eval_tags "keeper_time_now" []
;;

let test_non_object_input_still_logs_action_radius () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"omega"
      ~tool_name:"tool_write_file"
      ~input:(`String "raw pre-tool gate payload")
      ~output_text:"gate_waiting_for_operator"
      ~success:false
      ~duration_ms:3.0
      ();
    let entries = Keeper_tool_call_log.read_recent ~n:1 () in
    Alcotest.(check int) "entry persisted" 1 (List.length entries);
    match entries with
    | [ entry ] ->
      let action_radius = Yojson.Safe.Util.member "action_radius" entry in
      Alcotest.(check (option string)) "action key falls back to tool"
        (Some "tool_write_file")
        (Safe_ops.json_string_opt "action_key" action_radius);
      Alcotest.(check (option string)) "target kind falls back to tool"
        (Some "tool")
        (Safe_ops.json_string_opt "target_kind" action_radius);
      Alcotest.(check bool) "input preserved as string" true
        (match Yojson.Safe.Util.member "input" entry with
         | `String "raw pre-tool gate payload" -> true
         | _ -> false)
    | _ -> Alcotest.fail "expected exactly one entry")

let find_bucket name json =
  json
  |> Yojson.Safe.Util.to_list
  |> List.find (fun item ->
         Safe_ops.json_string_opt "name" item = Some name)

let test_dashboard_aggregate_groups_runtime_fields () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"k1" ~tool_name:"masc_status"
      ~input:(`Assoc []) ~output_text:"ok" ~result_bytes:2
      ~success:true ~duration_ms:2.0
      ~model:"glm-5.1" ~lane:"tool_optional"
      ~tool_choice:"auto"
      ~thinking_enabled:false ~thinking_budget:1024
      ~runtime_profile:"primary" ();
    let failure_output = "error: {\"ok\":false,\"error\":\"boom\"}" in
    Keeper_tool_call_log.log_call
      ~keeper_name:"k2" ~tool_name:"masc_status"
      ~input:(`Assoc []) ~output_text:failure_output
      ~result_bytes:(String.length failure_output)
      ~success:false ~duration_ms:3.0
      ~model:"qwen3.5-27b-unified" ~lane:"retry"
      ~tool_choice:"auto"
      ~thinking_enabled:true ~thinking_budget:4096
      ~runtime_profile:"local_qwen3_27b_only" ();
    let summary = Dashboard_http_tool_quality.aggregate ~n:10 () in
    Alcotest.(check (option string)) "sampling mode present"
      (Some "recent_n")
      (Safe_ops.json_string_opt "sampling_mode" summary);
    Alcotest.(check int) "sample limit echoed" 10
      (Safe_ops.json_int ~default:0 "sample_limit" summary);
    Alcotest.(check (option string)) "dashboard source"
      (Some "tool_call_io")
      (Safe_ops.json_string_opt "source" summary);
    Alcotest.(check (option string)) "dashboard producer"
      (Some "keeper_hooks_agent_core|mcp_server_eio_call_tool")
      (Safe_ops.json_string_opt "producer" summary);
    Alcotest.(check (option string)) "dashboard surface"
      (Some "/api/v1/dashboard/tool-quality")
      (Safe_ops.json_string_opt "dashboard_surface" summary);
    Alcotest.(check bool) "dashboard durable store present" true
      (Safe_ops.json_string ~default:"" "durable_store" summary <> "");
    Alcotest.(check int) "source entry count" 2
      (Safe_ops.json_int ~default:0 "entry_count" summary);
    Alcotest.(check bool) "source store exists" true
      (Safe_ops.json_bool ~default:false "exists" summary);
    Alcotest.(check (option string)) "source health ok"
      (Some "ok")
      (Safe_ops.json_string_opt "health" summary);
    Alcotest.(check bool) "latest age present" true
      (Safe_ops.json_float_opt "latest_age_s" summary |> Option.is_some);
    let by_model = Yojson.Safe.Util.member "by_model" summary in
    let by_runtime = Yojson.Safe.Util.member "by_runtime" summary in
    let by_lane = Yojson.Safe.Util.member "by_lane" summary in
    let by_thinking = Yojson.Safe.Util.member "by_thinking_mode" summary in
    let by_tool_choice = Yojson.Safe.Util.member "by_tool_choice" summary in
    let runtime_bucket = find_bucket "runtime" by_model in
    let primary_runtime_bucket = find_bucket "primary" by_runtime in
    let local_runtime_bucket = find_bucket "local_qwen3_27b_only" by_runtime in
    let retry_bucket = find_bucket "retry" by_lane in
    let enabled_bucket = find_bucket "enabled" by_thinking in
    let auto_bucket = find_bucket "auto" by_tool_choice in
    Alcotest.(check int) "runtime bucket calls" 2
      (Safe_ops.json_int ~default:0 "calls" runtime_bucket);
    Alcotest.(check int) "primary runtime bucket calls" 1
      (Safe_ops.json_int ~default:0 "calls" primary_runtime_bucket);
    Alcotest.(check int) "local runtime bucket calls" 1
      (Safe_ops.json_int ~default:0 "calls" local_runtime_bucket);
    Alcotest.(check int) "retry bucket calls" 1
      (Safe_ops.json_int ~default:0 "calls" retry_bucket);
    Alcotest.(check int) "enabled thinking calls" 1
      (Safe_ops.json_int ~default:0 "calls" enabled_bucket);
    Alcotest.(check int) "auto tool_choice calls" 2
      (Safe_ops.json_int ~default:0 "calls" auto_bucket))

let test_dashboard_aggregate_missing_runtime_profile_is_unknown () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"k-missing-runtime"
      ~tool_name:"masc_status"
      ~input:(`Assoc [])
      ~output_text:"ok"
      ~result_bytes:2
      ~success:true
      ~duration_ms:1.0
      ();
    let summary = Dashboard_http_tool_quality.aggregate ~n:10 () in
    let by_runtime = Yojson.Safe.Util.member "by_runtime" summary in
    let unknown_bucket =
      find_bucket Dashboard_http_tool_quality.unknown_runtime_profile_bucket by_runtime
    in
    Alcotest.(check int)
      "missing runtime profile goes to unknown bucket"
      1
      (Safe_ops.json_int ~default:0 "calls" unknown_bucket))

let test_dashboard_aggregate_excludes_typed_deferred_from_failure_rate () =
  with_tmp_log (fun () ->
    let result =
      Tool_result.make_deferred
        ~tool_name:"keeper_wait"
        ~start_time:(Time_compat.now ())
        ~data:(`Assoc [ "reason", `String "external_effect_pending" ])
        ()
    in
    Keeper_tool_call_log.log_call
      ~keeper_name:"k-deferred"
      ~tool_name:"keeper_wait"
      ~input:(`Assoc [])
      ~output_text:(Tool_result.message result)
      ~success:(Tool_result.is_success result)
      ~duration_ms:(Tool_result.duration_ms result)
      ~typed_result:result
      ();
    let summary = Dashboard_http_tool_quality.aggregate ~n:10 () in
    Alcotest.(check int)
      "deferred remains visible as typed neutral outcome"
      1
      (Safe_ops.json_int ~default:0 "deferred" summary);
    Alcotest.(check int)
      "deferred excluded from settled quality total"
      0
      (Safe_ops.json_int ~default:(-1) "total" summary);
    Alcotest.(check int)
      "deferred is not a failure"
      0
      (Safe_ops.json_int ~default:(-1) "failure" summary);
    Alcotest.(check bool)
      "deferred is absent from settled per-tool rates"
      true
      Yojson.Safe.Util.(member "by_tool" summary |> to_list |> List.is_empty))

let test_dashboard_hourly_trend_numeric_ts () =
  with_tmp_log_dir (fun dir ->
    let store =
      Dated_jsonl.create
        ~base_dir:(Filename.concat dir ".masc/tool_calls")
        ()
    in
    let ts = 1_710_000_000 in
    Dated_jsonl.append store
      (`Assoc
         [ ("ts", `Int ts)
         ; ("keeper", `String "k")
         ; ("tool", `String "masc_status")
         ; ("input", `Assoc [])
         ; ("output", `String "ok")
         ; ("result_bytes", `Int 2)
         ; ("success", `Bool true)
         ; ("duration_ms", `Float 2.0)
         ]);
    let expected_hour =
      let tm = Unix.gmtime (Float.of_int ts) in
      Printf.sprintf "%04d-%02d-%02dT%02d"
        (tm.Unix.tm_year + 1900)
        (tm.Unix.tm_mon + 1)
        tm.Unix.tm_mday
        tm.Unix.tm_hour
    in
    let hourly =
      Dashboard_http_tool_quality.aggregate ~n:10 ()
      |> Yojson.Safe.Util.member "hourly_trend"
      |> Yojson.Safe.Util.to_list
    in
    let bucket =
      List.find (fun item ->
        Safe_ops.json_string_opt "hour" item = Some expected_hour
      ) hourly
    in
    Alcotest.(check int) "hour bucket calls" 1
      (Safe_ops.json_int ~default:0 "calls" bucket);
    Alcotest.(check int) "hour bucket success" 1
      (Safe_ops.json_int ~default:0 "success" bucket))

let test_dashboard_aggregate_window_hours () =
  with_tmp_log_dir (fun dir ->
    let store =
      Dated_jsonl.create
        ~base_dir:(Filename.concat dir ".masc/tool_calls")
        ()
    in
    let now = Unix.gettimeofday () in
    let inside = now -. (30.0 *. 60.0) in
    let outside = now -. (48.0 *. 3600.0) in
    Dated_jsonl.append store
      (`Assoc
         [ ("ts", `Float inside)
         ; ("keeper", `String "k")
         ; ("tool", `String "masc_status")
         ; ("input", `Assoc [])
         ; ("output", `String "ok")
         ; ("result_bytes", `Int 2)
         ; ("success", `Bool true)
         ; ("duration_ms", `Float 2.0)
         ]);
    Dated_jsonl.append store
      (`Assoc
         [ ("ts", `Float outside)
         ; ("keeper", `String "k")
         ; ("tool", `String "masc_status")
         ; ("input", `Assoc [])
         ; ("output", `String "error: {\"ok\":false,\"error\":\"stale\"}")
         ; ("result_bytes", `Int 35)
         ; ("success", `Bool false)
         ; ("duration_ms", `Float 5.0)
         ]);
    let summary = Dashboard_http_tool_quality.aggregate ~n:10 ~window_hours:24.0 () in
    Alcotest.(check (option string)) "window sampling mode"
      (Some "window_hours")
      (Safe_ops.json_string_opt "sampling_mode" summary);
    Alcotest.(check int) "window total" 1
      (Safe_ops.json_int ~default:0 "total" summary);
    Alcotest.(check (option int)) "sample limit omitted"
      None
      (Safe_ops.json_int_opt "sample_limit" summary);
    Alcotest.(check (option (float 0.0001))) "window echoed"
      (Some 24.0)
      (Safe_ops.json_float_opt "window_hours" summary))

let test_dashboard_aggregate_drops_rows_without_result_bytes () =
  with_tmp_log_dir (fun dir ->
    let store =
      Dated_jsonl.create
        ~base_dir:(Filename.concat dir ".masc/tool_calls")
        ()
    in
    let now = Unix.gettimeofday () in
    Dated_jsonl.append store
      (`Assoc
         [ ("ts", `Float now)
         ; ("keeper", `String "k")
         ; ("tool", `String "masc_status")
         ; ("input", `Assoc [])
         ; ("output", `String "ok")
         ; ("result_bytes", `Int 2)
         ; ("success", `Bool true)
         ; ("duration_ms", `Float 2.0)
         ]);
    (* No [result_bytes]: an inline output string must not stand in for it. *)
    Dated_jsonl.append store
      (`Assoc
         [ ("ts", `Float now)
         ; ("keeper", `String "k")
         ; ("tool", `String "masc_status")
         ; ("input", `Assoc [])
         ; ("output", `String "error: {\"ok\":false,\"error\":\"boom\"}")
         ; ("success", `Bool false)
         ; ("duration_ms", `Float 5.0)
         ]);
    let summary = Dashboard_http_tool_quality.aggregate ~n:10 () in
    Alcotest.(check int) "malformed row counted" 1
      (Safe_ops.json_int ~default:(-1) "malformed" summary);
    Alcotest.(check int) "malformed row excluded from total" 1
      (Safe_ops.json_int ~default:(-1) "total" summary);
    Alcotest.(check int) "malformed row excluded from failures" 0
      (Safe_ops.json_int ~default:(-1) "failure" summary);
    let masc_status =
      find_bucket "masc_status" (Yojson.Safe.Util.member "by_tool" summary)
    in
    Alcotest.(check int) "malformed row excluded from per-tool calls" 1
      (Safe_ops.json_int ~default:(-1) "calls" masc_status);
    Alcotest.(check bool) "malformed row excluded from failure categories" true
      Yojson.Safe.Util.(member "failure_categories" summary |> to_list |> List.is_empty))

let test_dashboard_aggregate_only_malformed_rows_is_empty_summary () =
  with_tmp_log_dir (fun dir ->
    let store =
      Dated_jsonl.create
        ~base_dir:(Filename.concat dir ".masc/tool_calls")
        ()
    in
    Dated_jsonl.append store
      (`Assoc
         [ ("ts", `Float (Unix.gettimeofday ()))
         ; ("keeper", `String "k")
         ; ("tool", `String "masc_status")
         ; ("input", `Assoc [])
         ; ("output", `String "ok")
         ; ("success", `Bool true)
         ; ("duration_ms", `Float 2.0)
         ]);
    let summary = Dashboard_http_tool_quality.aggregate ~n:10 () in
    Alcotest.(check int) "malformed row counted" 1
      (Safe_ops.json_int ~default:(-1) "malformed" summary);
    Alcotest.(check int) "nothing aggregated" 0
      (Safe_ops.json_int ~default:(-1) "total" summary))

let test_append_failure_records_coverage_gap () =
  with_tmp_corrupt_tool_call_store (fun ~dir:_ ~masc_root ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"k" ~tool_name:"masc_status"
      ~input:(`Assoc []) ~output_text:"ok"
      ~success:true ~duration_ms:2.0
      ~trace_id:"trace-gap" ();
    let gaps = Telemetry_coverage_gap.read_recent ~masc_root ~n:10 in
    Alcotest.(check int) "one coverage gap" 1 (List.length gaps);
    match gaps with
    | [ gap ] ->
      Alcotest.(check (option string)) "coverage source"
        (Some "tool_call_io")
        (Safe_ops.json_string_opt "source" gap);
      Alcotest.(check (option string)) "coverage stale reason"
        (Some "tool_call_io_append_failed")
        (Safe_ops.json_string_opt "stale_reason" gap);
      Alcotest.(check (option string)) "coverage keeper"
        (Some "k")
        (Safe_ops.json_string_opt "keeper_name" gap);
      Alcotest.(check (option string)) "coverage trace"
        (Some "trace-gap")
      (Safe_ops.json_string_opt "trace_id" gap)
    | _ -> Alcotest.fail "expected exactly one coverage gap")

let test_dashboard_aggregate_surfaces_coverage_gap () =
  with_tmp_log_dir (fun dir ->
    let masc_root = Filename.concat dir ".masc" in
    Telemetry_coverage_gap.record
      ~masc_root
      ~source:"tool_call_io"
      ~producer:"keeper_hooks_agent_core"
      ~durable_store:(Filename.concat masc_root "tool_calls")
      ~dashboard_surface:"/api/v1/keepers/:name/tool-calls"
      ~stale_reason:"tool_call_io_append_failed"
      ~keeper_name:"k"
      ~trace_id:"trace-gap"
      ();
    let summary = Dashboard_http_tool_quality.aggregate ~n:10 () in
    Alcotest.(check (option string)) "coverage gap health"
      (Some "coverage_gap")
      (Safe_ops.json_string_opt "health" summary);
    Alcotest.(check (option string)) "coverage gap stale reason"
      (Some "tool_call_io_append_failed")
      (Safe_ops.json_string_opt "stale_reason" summary);
    Alcotest.(check int) "coverage gap count" 1
      (Safe_ops.json_int ~default:0 "coverage_gap_count" summary))

let test_dashboard_aggregate_ignores_recovered_coverage_gap () =
  with_tmp_log_dir (fun dir ->
    let masc_root = Filename.concat dir ".masc" in
    Telemetry_coverage_gap.record
      ~masc_root
      ~source:"tool_call_io"
      ~producer:"keeper_hooks_agent_core"
      ~durable_store:(Filename.concat masc_root "tool_calls")
      ~dashboard_surface:"/api/v1/keepers/:name/tool-calls"
      ~stale_reason:"tool_call_io_append_failed"
      ~keeper_name:"k"
      ~trace_id:"trace-gap"
      ();
    Keeper_tool_call_log.log_call
      ~keeper_name:"k" ~tool_name:"masc_status"
      ~input:(`Assoc []) ~output_text:"ok" ~result_bytes:2
      ~success:true ~duration_ms:2.0
      ~trace_id:"trace-recovered" ();
    let summary = Dashboard_http_tool_quality.aggregate ~n:10 () in
    Alcotest.(check (option string)) "recovered gap health"
      (Some "ok")
      (Safe_ops.json_string_opt "health" summary);
    Alcotest.(check (option string)) "recovered gap stale reason cleared"
      None
      (Safe_ops.json_string_opt "stale_reason" summary);
    Alcotest.(check int) "historical gap count" 1
      (Safe_ops.json_int ~default:0 "coverage_gap_count" summary);
    Alcotest.(check int) "active gap count" 0
      (Safe_ops.json_int ~default:(-1) "active_coverage_gap_count" summary))

(* ── UTF-8 sanitization ────────────────────────────── *)

(* Regression guard: tool output may contain invalid UTF-8 bytes from
   subprocess captures or truncated multi-byte sequences. Without the
   writer-side sanitize, Python / dashboard readers fail to decode the
   entire JSONL file and silently drop rows. *)
let test_output_invalid_utf8_sanitized () =
  with_tmp_log_dir (fun dir ->
    Safe_ops.reset_persistence_utf8_repair_stats_for_tests ();
    let raw_output = "prefix\xecsuffix" in
    Keeper_tool_call_log.log_call
      ~keeper_name:"k" ~tool_name:"tool_bin"
      ~input:(`Assoc []) ~output_text:raw_output
      ~success:true ~duration_ms:1.0 ();
    let results = Keeper_tool_call_log.read_recent ~n:1 () in
    Alcotest.(check int) "entry persisted" 1 (List.length results);
    let today =
      let open Unix in
      let tm = gmtime (gettimeofday ()) in
      Printf.sprintf "%04d-%02d/%02d.jsonl"
        (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    in
    let file =
      Filename.concat dir (Filename.concat ".masc/tool_calls" today)
    in
    let contents =
      let ic = open_in_bin file in
      Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
        let n = in_channel_length ic in
        really_input_string ic n)
    in
    let len = String.length contents in
    let rec scan i =
      if i >= len then true
      else
        let dec = String.get_utf_8_uchar contents i in
        let dlen = Uchar.utf_decode_length dec in
        if dlen > 0 && Uchar.utf_decode_is_valid dec then scan (i + dlen)
        else false
    in
    Alcotest.(check bool) "persisted file is valid UTF-8" true (scan 0);
    let repair_stats = Safe_ops.persistence_utf8_repair_stats () in
    Alcotest.(check int)
      "writer-side tool output parsing does not emit persistence repair"
      0
      repair_stats.repaired_reads)

let test_output_valid_utf8_untouched () =
  with_tmp_log (fun () ->
    let korean = "한글 메시지" in
    Keeper_tool_call_log.log_call
      ~keeper_name:"k" ~tool_name:"tool_ok"
      ~input:(`Assoc []) ~output_text:korean
      ~success:true ~duration_ms:1.0 ();
    let results = Keeper_tool_call_log.read_recent ~n:1 () in
    Alcotest.(check int) "entry persisted" 1 (List.length results);
    match results with
    | [ json ] ->
        let output = Safe_ops.json_string ~default:"" "output" json in
        Alcotest.(check string) "valid UTF-8 preserved verbatim" korean output
    | _ -> Alcotest.fail "expected exactly one entry")

(* When the tool output is the OCaml [%S]-quoted [masc:blob ...] marker
   produced by Tool_output.encode_for_agent_core, the persisted record must
   normalize it into a structured _blob object so that telemetry readers
   (UI, jq scripts) see a clean JSON shape instead of doubly-escaped
   string fields. *)
let test_output_blob_marker_normalized () =
  with_tmp_log (fun () ->
    let marker =
      Tool_output.encode_for_agent_core
        (Tool_output.Stored
           (artifact_ref_exn
              ~sha256:(String.make 64 'a')
              ~bytes:6436
              ~mime:"text/plain"
              ~preview:"{\"ok\":true,\"result\":\"42\"}"))
    in
    Keeper_tool_call_log.log_call
      ~keeper_name:"k" ~tool_name:"tool_blob"
      ~input:(`Assoc []) ~output_text:marker
      ~success:true ~duration_ms:1.0 ();
    let results = Keeper_tool_call_log.read_recent ~n:1 () in
    Alcotest.(check int) "entry persisted" 1 (List.length results);
    match results with
    | [ json ] ->
      let output =
        match json with
        | `Assoc fields -> List.assoc_opt "output" fields
        | _ -> None
      in
      (match output with
       | Some (`Assoc [("_blob", `Assoc blob)]) ->
         let sha = Safe_ops.json_string ~default:"" "sha256" (`Assoc blob) in
         let bytes = Safe_ops.json_int ~default:0 "bytes" (`Assoc blob) in
         let mime = Safe_ops.json_string ~default:"" "mime" (`Assoc blob) in
         let preview = Safe_ops.json_string ~default:"" "preview" (`Assoc blob) in
         Alcotest.(check string) "sha256 round-trips" (String.make 64 'a') sha;
         Alcotest.(check int) "bytes round-trips" 6436 bytes;
         Alcotest.(check string) "mime round-trips" "text/plain" mime;
         Alcotest.(check string) "preview round-trips"
           "{\"ok\":true,\"result\":\"42\"}" preview
       | Some (`String s) ->
         Alcotest.failf "expected normalized _blob object, got string: %s" s
       | _ -> Alcotest.fail "missing/unexpected output field")
    | _ -> Alcotest.fail "expected exactly one entry")

(* Inline outputs (below the externalization threshold) must stay as
   plain JSON strings so legacy jq pipelines and the UI's string-render
   path keep working. *)
let test_output_inline_string_preserved () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"k" ~tool_name:"tool_inline"
      ~input:(`Assoc []) ~output_text:"small inline result"
      ~success:true ~duration_ms:1.0 ();
    let results = Keeper_tool_call_log.read_recent ~n:1 () in
    match results with
    | [ json ] ->
      let s = Safe_ops.json_string ~default:"" "output" json in
      Alcotest.(check string) "inline output stays a string"
        "small inline result" s
    | _ -> Alcotest.fail "expected exactly one entry")

let test_output_preview_derives_truncation_metadata () =
  with_tmp_log (fun () ->
    let output_text = String.make 5000 'x' in
    Keeper_tool_call_log.log_call
      ~keeper_name:"k"
      ~tool_name:"tool_large"
      ~input:(`Assoc [])
      ~output_text
      ~result_bytes:(String.length output_text)
      ~success:true
      ~duration_ms:1.0
      ();
    match Keeper_tool_call_log.read_recent ~n:1 () with
    | [ `Assoc fields ] ->
      Alcotest.(check (option int))
        "producer bytes retained"
        (Some 5000)
        (List.assoc_opt "result_bytes" fields |> Option.map Yojson.Safe.Util.to_int);
      Alcotest.(check (option int))
        "log preview clamp is explicit"
        (Some 4000)
        (List.assoc_opt "truncated_to" fields |> Option.map Yojson.Safe.Util.to_int)
    | _ -> Alcotest.fail "expected exactly one object entry")

(* A file target and a working directory are both strings. Reported as the
   same target_kind, a consumer reading "path" as "a file" opened a directory:
   1,094 of 2026-08-18's 1,323 Execute rows carried a cwd that way (#29013). *)
let test_action_radius_tells_a_file_from_a_directory () =
  with_tmp_log (fun () ->
    let radius_of_input input =
      Keeper_tool_call_log.log_call
        ~keeper_name:"k" ~tool_name:"probe" ~input ~output_text:"ok"
        ~success:true ~duration_ms:1.0 ();
      match Keeper_tool_call_log.read_recent ~n:1 () with
      | [ json ] ->
        let radius =
          match json with
          | `Assoc fields ->
            Option.value (List.assoc_opt "action_radius" fields) ~default:`Null
          | _ -> `Null
        in
        ( Safe_ops.json_string ~default:"" "target_kind" radius
        , Safe_ops.json_string ~default:"" "target_path" radius )
      | _ -> Alcotest.fail "expected exactly one entry"
    in
    Alcotest.(check (pair string string))
      "file_path is a file target"
      ("path", "lib/keeper/keeper_tool_call_log.ml")
      (radius_of_input
         (`Assoc [ "file_path", `String "lib/keeper/keeper_tool_call_log.ml" ]));
    Alcotest.(check (pair string string))
      "cwd is a directory target"
      ("directory", "repos/masc")
      (radius_of_input (`Assoc [ "cwd", `String "repos/masc" ]));
    Alcotest.(check (pair string string))
      "repo_path is a directory target"
      ("directory", "repos/masc")
      (radius_of_input (`Assoc [ "repo_path", `String "repos/masc" ]));
    (* An explicit declaration still wins over the key it was found under. *)
    Alcotest.(check (pair string string))
      "declared target_kind is not overridden"
      ("workspace", "repos/masc")
      (radius_of_input
         (`Assoc
            [ "cwd", `String "repos/masc"; "target_kind", `String "workspace" ])))
;;

let test_string_input_keeps_action_radius () =
  with_tmp_log (fun () ->
    Keeper_tool_call_log.log_call
      ~keeper_name:"k" ~tool_name:"tool_large_input"
      ~input:(`String "{\"action\":\"write\"}")
      ~output_text:"ok"
      ~success:true ~duration_ms:1.0 ();
    let results = Keeper_tool_call_log.read_recent ~n:1 () in
    match results with
    | [ json ] ->
      let action_radius =
        match json with
        | `Assoc fields ->
          Option.value (List.assoc_opt "action_radius" fields) ~default:`Null
        | _ -> `Null
      in
      let action_key =
        Safe_ops.json_string ~default:"" "action_key" action_radius
      in
      let target_kind =
        Safe_ops.json_string ~default:"" "target_kind" action_radius
      in
      Alcotest.(check string)
        "falls back when input is not a JSON object"
        "tool_large_input"
        action_key;
      Alcotest.(check string) "non-object input has tool target" "tool" target_kind
    | _ -> Alcotest.fail "expected exactly one entry")

let test_async_append_defers_until_flush env =
  with_tmp_log_dir (fun _dir ->
    Eio.Switch.run (fun sw ->
      Keeper_tool_call_log.start_flush_fiber
        ~sw
        ~clock:(Eio.Stdenv.clock env);
      Keeper_tool_call_log.log_call
        ~keeper_name:"async-k"
        ~tool_name:"masc_status"
        ~input:(`Assoc [])
        ~output_text:"ok"
        ~success:true
        ~duration_ms:1.0
        ();
      Alcotest.(check int)
        "record queued before background flush"
        1
        (Keeper_tool_call_log.queued_count_for_testing ());
      Alcotest.(check int)
        "queued record not visible before explicit flush"
        0
        (List.length (Keeper_tool_call_log.read_recent ~n:1 ()));
      Keeper_tool_call_log.flush_now ();
      Alcotest.(check int)
        "queue drained by explicit flush"
        0
        (Keeper_tool_call_log.queued_count_for_testing ());
      let entries = Keeper_tool_call_log.read_recent ~n:1 () in
      Alcotest.(check int) "record persisted after flush" 1 (List.length entries);
      match entries with
      | [ entry ] ->
        Alcotest.(check (option string))
          "keeper persisted"
          (Some "async-k")
          (Safe_ops.json_string_opt "keeper" entry)
      | _ -> Alcotest.fail "expected exactly one entry"))

let test_commit_callback_bypasses_async_queue env =
  with_tmp_log_dir (fun _dir ->
    Eio.Switch.run (fun sw ->
      Keeper_tool_call_log.start_flush_fiber
        ~sw
        ~clock:(Eio.Stdenv.clock env);
      let committed = ref false in
      Keeper_tool_call_log.log_call
        ~keeper_name:"chat-k"
        ~tool_name:"masc_status"
        ~input:(`Assoc [])
        ~output_text:"ready"
        ~success:true
        ~duration_ms:1.0
        ~on_committed:(fun () -> committed := true)
        ();
      Alcotest.(check bool) "callback observed committed row" true !committed;
      Alcotest.(check int)
        "committed row did not enter async queue"
        0
        (Keeper_tool_call_log.queued_count_for_testing ());
      Alcotest.(check int)
        "committed row is immediately readable"
        1
        (List.length (Keeper_tool_call_log.read_recent ~n:1 ()))))

let test_commit_callback_fails_closed_without_store () =
  Keeper_tool_call_log.reset_for_testing ();
  let raised =
    try
      Keeper_tool_call_log.log_call
        ~keeper_name:"chat-k"
        ~tool_name:"masc_status"
        ~input:(`Assoc [])
        ~output_text:"unavailable"
        ~success:true
        ~duration_ms:1.0
        ~on_committed:(fun () -> Alcotest.fail "callback must not run")
        ();
      false
    with _ -> true
  in
  Alcotest.(check bool) "required commit fails closed" true raised

let () =
  Alcotest.run "keeper_tool_call_log"
    [ ( "invocation observation",
        [ Alcotest.test_case
            "blank and repeated ids remain occurrence-scoped"
            `Quick
            test_pending_observations_are_occurrence_scoped
        ; Alcotest.test_case
            "file evidence remains occurrence-scoped"
            `Quick
            test_pending_file_change_evidence_is_occurrence_scoped
        ; Alcotest.test_case
            "cancelled invocation releases abandoned observation"
            `Quick
            test_abandoned_observation_is_released_with_invocation
        ; Alcotest.test_case
            "cancelled invocation releases file evidence"
            `Quick
            test_abandoned_file_change_evidence_is_released_with_invocation
        ] )
    ; ( "file_change_tally",
        [ eio_test "matches a whole read and sees appends"
            test_file_change_tally_matches_a_whole_read
        ] )
    ; ( "read_window",
        [ eio_test "keeps the keeper's rows in order"
            test_read_window_keeps_the_keepers_rows_in_order
        ] )
    ; ( "read_recent",
        [ eio_test "n=0 returns []" test_read_recent_n_zero
        ; eio_test "n<0 returns []" test_read_recent_n_negative
        ; eio_test "keeper filter" test_read_recent_keeper_filter
        ; eio_test "fleet-row derivation equals read_recent"
            test_fleet_rows_derivation_matches_read_recent
        ; eio_test "unfiltered read is exactly n; filtered still finds n"
            test_unfiltered_read_is_exactly_n_and_filtered_still_finds_n
        ; eio_test "exact AGENT_CORE occurrence" test_exact_agent_core_occurrence_persisted
        ; eio_test "ordinary path disposition"
            test_ordinary_path_disposition_persisted
        ; eio_test "file evidence shares the execution identity row"
            test_file_change_evidence_persists_with_execution_identity
        ; eio_test "no typed outcome omits the field"
            test_row_without_a_typed_outcome_omits_the_field
        ; eio_test "composition action context"
            test_composition_action_context_persisted
        ; eio_test "composition rows separate submitted from autonomous turn"
            test_composition_rows_separate_submitted_from_autonomous_turn
        ] )
    ; ( "redaction",
        [ eio_test "sensitive-named tool logged with redaction"
            test_sensitive_named_tool_logged_with_redaction
        ; eio_test "sensitive input fields redacted" test_sensitive_input_fields_redacted
        ; eio_test "model field stored" test_model_field_stored
        ; eio_test "turn context fields stored" test_turn_context_fields_stored
        ; Alcotest.test_case "turn context cells do not cross runs" `Quick
            test_turn_context_cells_do_not_cross_runs
        ; eio_test "turn context fields absent without context"
            test_turn_context_fields_absent_without_context
        ; eio_test "route evidence stored for git push"
            test_route_evidence_stored_for_git_push
        ; eio_test "route evidence reads blob-backed git push preview"
            test_route_evidence_stored_for_blob_backed_git_push
        ; eio_test "route evidence redacts wrapped git push"
            test_route_evidence_redacts_wrapped_git_push
        ; eio_test "route evidence command redaction fails closed"
            test_route_evidence_command_redaction_fails_closed
        ; eio_test "route evidence records descriptor for filesystem calls"
            test_route_evidence_records_descriptor_for_filesystem_calls
        ; eio_test "route evidence records internal descriptor"
            test_route_evidence_records_internal_descriptor
        ; eio_test "route evidence records masc board descriptor"
            test_route_evidence_records_masc_board_descriptor
        ; Alcotest.test_case
            "route evidence records descriptor eval tags"
            `Quick
            test_route_evidence_records_descriptor_eval_tags
        ; eio_test "non-object input still logs action radius"
            test_non_object_input_still_logs_action_radius
        ; eio_test "dashboard aggregate groups runtime fields"
            test_dashboard_aggregate_groups_runtime_fields
        ; eio_test "dashboard aggregate marks missing runtime profile unknown"
            test_dashboard_aggregate_missing_runtime_profile_is_unknown
        ; eio_test "dashboard aggregate keeps deferred neutral"
            test_dashboard_aggregate_excludes_typed_deferred_from_failure_rate
        ; eio_test "dashboard hourly trend buckets numeric ts"
            test_dashboard_hourly_trend_numeric_ts
        ; eio_test "dashboard aggregate window hours"
            test_dashboard_aggregate_window_hours
        ; eio_test "dashboard aggregate drops rows without result_bytes"
            test_dashboard_aggregate_drops_rows_without_result_bytes
        ; eio_test "dashboard aggregate with only malformed rows is empty"
            test_dashboard_aggregate_only_malformed_rows_is_empty_summary
        ; eio_test "append failure records coverage gap"
            test_append_failure_records_coverage_gap
        ; eio_test "dashboard aggregate surfaces coverage gap"
            test_dashboard_aggregate_surfaces_coverage_gap
        ; eio_test "dashboard aggregate ignores recovered coverage gap"
            test_dashboard_aggregate_ignores_recovered_coverage_gap
        ] )
    ; ( "utf8_sanitize",
        [ eio_test "invalid UTF-8 bytes scrubbed before persist"
            test_output_invalid_utf8_sanitized
        ; eio_test "valid UTF-8 preserved verbatim"
            test_output_valid_utf8_untouched
        ] )
    ; ( "blob_normalize",
        [ eio_test "blob marker persists as structured _blob object"
            test_output_blob_marker_normalized
        ; eio_test "inline string output stays a JSON string"
            test_output_inline_string_preserved
        ; eio_test "large output records preview truncation"
            test_output_preview_derives_truncation_metadata
        ] )
    ; ( "action_radius",
        [ eio_test "string input does not break action radius"
            test_string_input_keeps_action_radius
        ; Alcotest.test_case "action radius tells a file from a directory" `Quick
            test_action_radius_tells_a_file_from_a_directory
        ] )
    ; ( "async_append",
        [ eio_env_test "append queues until flush when async fiber is active"
            test_async_append_defers_until_flush
        ; eio_env_test "commit callback runs after synchronous readable append"
            test_commit_callback_bypasses_async_queue
        ; eio_test "commit callback fails closed without store"
            test_commit_callback_fails_closed_without_store
        ] )
    ]
