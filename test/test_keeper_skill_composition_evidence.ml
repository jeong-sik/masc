open Masc

let () = Mirage_crypto_rng_unix.use_default ()

let cleanup_dir dir =
  if Sys.file_exists dir then Fs_compat.remove_tree dir
;;

let make_reference name revision =
  let source_id =
    Skill_source_config.source_id_of_string "workspace" |> Result.get_ok
  in
  let package_id =
    Skill_catalog_snapshot.package_id_of_directory name |> Result.get_ok
  in
  Skill_reference.make
    ~identity:(Skill_reference.make_identity ~source_id ~package_id ~name)
    ~content_revision:
      (Skill_reference.content_revision_of_string (String.make 64 revision)
       |> Result.get_ok)
;;

let node ~node_id
      ?(execution_origin = Keeper_skill_composition_evidence.Node_execution_origin.Fresh_dispatch)
      ~(schedule : Agent_core.Tool_contract.schedule) () =
  `Assoc
    [ "node_id", `String node_id
    ; "execution_id", Ids.Execution_id.(generate () |> to_yojson)
    ; ( "execution_origin"
      , `String (Keeper_skill_composition_evidence.Node_execution_origin.to_string execution_origin) )
    ; "tool_name", `String "keeper_lane_status"
    ; "input", `Assoc []
    ; ( "schedule"
      , `Assoc
          [ "planned_index", `Int schedule.planned_index
          ; "batch_index", `Int schedule.batch_index
          ; "batch_size", `Int schedule.batch_size
          ; ( "execution_mode"
            , `String
                (match schedule.execution_mode with
                 | Agent_core.Tool_contract.Serial -> "serial"
                 | Agent_core.Tool_contract.Concurrent -> "concurrent") )
          ] )
    ; ( "result"
      , `Assoc
          [ "disposition", `String "completed"
          ; "data", `Assoc []
          ; "tool_name", `String "keeper_lane_status"
          ; "duration_ms", `Float 1.0
          ] )
    ; "tool_use_id", `String ""
    ; "failure_effect_disposition", `Null
    ; "deferred_kind", `Null
    ; "result_bytes", `Int 2
    ; "truncated_to", `Null
    ]
;;

let parent_invocation () =
  Agent_core.Tool_contract.Invocation.create
    ~tool_use_id:""
    ~turn:7
    ~schedule:
      { planned_index = 0
      ; batch_index = 0
      ; batch_size = 1
      ; execution_mode = Agent_core.Tool_contract.Serial
      }
    ~completion:Agent_core.Tool_contract.Continue_after_success
;;

let evidence_with_recorded_at timestamp evidence =
  match Keeper_skill_composition_evidence.to_yojson evidence with
  | `Assoc fields ->
    `Assoc
      (("recorded_at", `Float timestamp)
       :: List.remove_assoc "recorded_at" fields)
    |> Keeper_skill_composition_evidence.of_yojson
    |> Result.get_ok
  | _ -> Alcotest.fail "expected evidence object"
;;

let make_evidence
      reference
      settlements
      composition_run_id
      ~recorded_at
  =
  let result =
    Tool_result.make_ok
      ~tool_name:"keeper_compose_indexed-proof"
      ~start_time:(Tool_timing.start ())
      ~data:(`Assoc [ "actions", `List settlements ])
      ()
  in
  Keeper_skill_composition_evidence.make
    ~reference
    ~composition_run_id
    ~parent_invocation:(parent_invocation ())
    ~request_id:None
    ~keeper_name:"delta"
    ~composition_tool:"keeper_compose_indexed-proof"
    ~composition_execution:Keeper_tool_composition_catalog.Inline
    ~result
    ~executor_settlements:settlements
  |> Result.get_ok
  |> evidence_with_recorded_at recorded_at
;;

let settlements_fixture () =
  [ node ~node_id:"first"
      ~schedule:
        { planned_index = 0; batch_index = 0; batch_size = 1
        ; execution_mode = Agent_core.Tool_contract.Serial }
      ()
  ; node ~node_id:"second"
      ~execution_origin:Keeper_skill_composition_evidence.Node_execution_origin.Retained_completion
      ~schedule:
        { planned_index = 1; batch_index = 1; batch_size = 1
        ; execution_mode = Agent_core.Tool_contract.Serial }
      ()
  ; node ~node_id:"left"
      ~schedule:
        { planned_index = 2; batch_index = 2; batch_size = 2
        ; execution_mode = Agent_core.Tool_contract.Concurrent }
      ()
  ; node ~node_id:"right"
      ~schedule:
        { planned_index = 3; batch_index = 2; batch_size = 2
        ; execution_mode = Agent_core.Tool_contract.Concurrent }
      ()
  ]
;;

(* The stale-writer boundary: with an append-only store the run that started
   earlier but finished later can no longer clobber the newer record, so
   selection must follow recorded_at rather than write order. *)
let test_latest_selects_newest_recorded_at () =
  let base_path =
    Filename.temp_file "masc_skill_composition_evidence" ""
  in
  Sys.remove base_path;
  Unix.mkdir base_path 0o755;
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let config = Workspace.default_config base_path in
       let reference = make_reference "indexed-proof" 'a' in
       let settlements = settlements_fixture () in
       let save evidence =
         Keeper_skill_composition_evidence.save_latest config evidence
         |> Result.get_ok
         |> ignore
       in
       let first = Keeper_tool_plan.Composition_run_id.fresh () in
       let second = Keeper_tool_plan.Composition_run_id.fresh () in
       save (make_evidence reference settlements second ~recorded_at:200.0);
       save (make_evidence reference settlements first ~recorded_at:100.0);
       let loaded =
         Keeper_skill_composition_evidence.load_latest config reference
         |> Result.get_ok
         |> Option.get
         |> Keeper_skill_composition_evidence.to_yojson
       in
       let open Yojson.Safe.Util in
       Alcotest.(check string)
         "newest run wins even when the older run wrote later"
         (Keeper_tool_plan.Composition_run_id.to_string second)
         (loaded |> member "composition_run_id" |> to_string);
       Alcotest.(check string) "blank provider id remains opaque" ""
         (loaded |> member "parent_tool_use_id" |> to_string);
       Alcotest.(check int) "parent turn" 7
         (loaded |> member "parent_turn" |> to_int);
       Alcotest.(check int) "all later batches remain published" 4
         (loaded |> member "executor_settlements" |> to_list |> List.length);
       Alcotest.(check bool) "each published batch keeps its schedule" true
         (loaded |> member "executor_settlements" |> to_list = settlements);
       Alcotest.(check bool) "another reference remains absent" true
         (Keeper_skill_composition_evidence.load_latest
            config
            (make_reference "other-proof" 'b')
          |> Result.get_ok
          |> Option.is_none))
;;

let store_dir config =
  Filename.concat (Workspace.masc_dir config) "skill-composition-evidence-v1"
;;

let partition reference =
  Skill_reference.to_yojson reference
  |> Yojson.Safe.to_string
  |> Agent_core_sha256.digest_string
  |> Agent_core_sha256.to_hex
;;

let test_same_reference_runs_do_not_overlap () =
  let base_path =
    Filename.temp_file "masc_skill_composition_evidence" ""
  in
  Sys.remove base_path;
  Unix.mkdir base_path 0o755;
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let config = Workspace.default_config base_path in
       let reference = make_reference "indexed-proof" 'a' in
       let settlements = settlements_fixture () in
       let save evidence =
         Keeper_skill_composition_evidence.save_latest config evidence
         |> Result.get_ok
         |> ignore
       in
       let first = Keeper_tool_plan.Composition_run_id.fresh () in
       let second = Keeper_tool_plan.Composition_run_id.fresh () in
       save (make_evidence reference settlements first ~recorded_at:100.0);
       save (make_evidence reference settlements second ~recorded_at:200.0);
       let partition_dirs =
         Sys.readdir (store_dir config)
         |> Array.to_list
         |> List.filter (fun name ->
              Sys.is_directory (Filename.concat (store_dir config) name))
       in
       Alcotest.(check int) "one partition directory per exact reference" 1
         (List.length partition_dirs);
       let run_files =
         Sys.readdir (Filename.concat (store_dir config) (List.hd partition_dirs))
         |> Array.to_list
       in
       Alcotest.(check int) "both runs remain stored side by side" 2
         (List.length run_files);
       Alcotest.(check bool) "run files are named by their run id" true
         (List.exists
            (fun name ->
               String.equal
                 name
                 (Keeper_tool_plan.Composition_run_id.to_string first ^ ".json"))
            run_files
          && List.exists
               (fun name ->
                  String.equal
                    name
                    (Keeper_tool_plan.Composition_run_id.to_string second
                     ^ ".json"))
               run_files);
       let loaded =
         Keeper_skill_composition_evidence.load_latest config reference
         |> Result.get_ok
         |> Option.get
         |> Keeper_skill_composition_evidence.to_yojson
       in
       let open Yojson.Safe.Util in
       Alcotest.(check string) "latest still selects the newest run"
         (Keeper_tool_plan.Composition_run_id.to_string second)
         (loaded |> member "composition_run_id" |> to_string);
       save (make_evidence reference settlements first ~recorded_at:200.0);
       let tied = Keeper_skill_composition_evidence.load_observation config reference |> Result.get_ok in
       let ids = List.map (fun evidence ->
         (Keeper_skill_composition_evidence.run_summary evidence).run_id
         |> Keeper_tool_plan.Composition_run_id.to_string) tied.runs in
       Alcotest.(check (list string)) "equal timestamps use descending original ID order"
         (List.sort (fun a b -> String.compare b a)
           [Keeper_tool_plan.Composition_run_id.to_string first; Keeper_tool_plan.Composition_run_id.to_string second]) ids;
       save (make_evidence reference settlements first ~recorded_at:300.0);
       let updated = Keeper_skill_composition_evidence.load_observation config reference |> Result.get_ok in
       Alcotest.(check int) "a replacement result keeps one original run" 2 updated.statistics.records;
       Alcotest.(check int) "history and samples share original-run deduplication" 2 (List.length updated.runs);
       Alcotest.(check string) "updated result is first in retained history"
         (Keeper_tool_plan.Composition_run_id.to_string first)
         ((Keeper_skill_composition_evidence.run_summary (List.hd updated.runs)).run_id
          |> Keeper_tool_plan.Composition_run_id.to_string))
;;

let test_only_run_partition_is_authoritative () =
  let module E = Keeper_skill_composition_evidence in
  let base = Filename.temp_dir "composition-partition-authority" "" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
    let config = Workspace.default_config base in
    let reference = make_reference "partition-proof" 'c' in
    Fs_compat.mkdir_p (store_dir config);
    Out_channel.with_open_bin
      (Filename.concat (store_dir config) (partition reference ^ ".json"))
      (fun channel -> output_string channel "obsolete invalid JSON");
    let run = Keeper_tool_plan.Composition_run_id.fresh () in
    let evidence = make_evidence reference (settlements_fixture ()) run ~recorded_at:100. in
    E.save_latest config evidence |> Result.get_ok |> ignore;
    let observed = E.load_observation config reference |> Result.get_ok in
    Alcotest.(check int) "current partition remains readable" 1 observed.statistics.records;
    Alcotest.(check string) "only the producer-owned run is selected"
      (Keeper_tool_plan.Composition_run_id.to_string run)
      (Option.get observed.latest |> E.to_yojson
       |> Yojson.Safe.Util.member "composition_run_id" |> Yojson.Safe.Util.to_string))
;;

let test_canonical_failed_results () =
  let module E = Keeper_skill_composition_evidence in
  let base = Filename.temp_dir "failed-composition-evidence" "" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
    let config = Workspace.default_config base in
    let reference = make_reference "failed-read" 'b' in
    let replace key value = function
      | `Assoc fields -> `Assoc ((key,value) :: List.remove_assoc key fields)
      | _ -> Alcotest.fail "expected object" in
    List.iter (fun phase ->
      let failure tool_name = Tool_result.make_err ~tool_name ~start_time:(Tool_timing.start ())
        ~class_:Tool_result.Workflow_rejection ~effect_disposition:phase
        "Missing host permission for the tab" in
      let node_result = Tool_result.to_json (failure "masc_browser_read") in
      let execution_origin = match phase with
        | Tool_result.Proven_pre_effect -> E.Node_execution_origin.Dispatch_refused
        | Tool_result.Proven_post_effect | Tool_result.Effect_outcome_unknown -> E.Node_execution_origin.Fresh_dispatch in
      let settled = node ~node_id:"read" ~execution_origin ~schedule:{planned_index=1;batch_index=1;
        batch_size=1;execution_mode=Agent_core.Tool_contract.Serial} ()
        |> replace "tool_name" (`String "BrowserRead")
        |> replace "result" node_result in
      let result = failure "keeper_compose_failed-read" in
      let make settlements = E.make ~reference
        ~composition_run_id:(Keeper_tool_plan.Composition_run_id.fresh ())
        ~parent_invocation:(parent_invocation ()) ~request_id:None ~keeper_name:"delta"
        ~composition_tool:"keeper_compose_failed-read"
        ~composition_execution:Keeper_tool_composition_catalog.Inline
        ~result ~executor_settlements:settlements in
      let evidence = make [settled] |> Result.get_ok in
      E.save_latest config evidence |> Result.get_ok |> ignore;
      let loaded = E.load_latest config reference |> Result.get_ok |> Option.get |> E.to_yojson in
      let open Yojson.Safe.Util in
      Alcotest.(check bool) "failed top-level result round-trips exactly" true
        (member "result" loaded = Tool_result.to_json result);
      Alcotest.(check bool) "failed node result round-trips exactly" true
        (member "executor_settlements" loaded |> to_list = [settled]);
      let fields = to_assoc settled in
      List.iter (fun malformed ->
        Alcotest.(check bool) "malformed origin cannot become writable evidence" true
          (Result.is_error (make [malformed]));
        Alcotest.(check bool) "malformed origin cannot become readable evidence" true
          (Result.is_error (E.of_yojson
             (replace "executor_settlements" (`List [malformed]) loaded))))
        [ `Assoc (List.remove_assoc "execution_origin" fields)
        ; replace "execution_origin" (`String "invented") settled
        ; replace "execution_origin" (`Int 1) settled
        ; `Assoc (("execution_origin", `String "fresh_dispatch") :: fields)
        ];
      let wrong_node = replace "result"
        (Tool_result.to_json (failure "masc_browser_act")) settled in
      Alcotest.(check bool) "unrelated registered tool identity is rejected" true
        (Result.is_error (E.of_yojson
           (replace "executor_settlements" (`List [wrong_node]) loaded)));
      let fields = member "result" loaded |> to_assoc in
      List.iter (fun malformed ->
        Alcotest.(check bool) "missing or ambiguous failure phase is rejected" true
          (Result.is_error (E.of_yojson (replace "result" malformed loaded))))
        [`Assoc (List.remove_assoc "effect_disposition" fields);
         replace "effect_disposition" (`String "invented") (`Assoc fields);
         `Assoc (("effect_disposition",`String "proven_pre_effect") :: fields)];
      (* Canonical failed evidence must reach storage, where the occupied
         directory fails independently of result schema validation. *)
      let path = Filename.concat (Workspace.masc_dir config) "skill-composition-evidence-v1" in
      Fs_compat.remove_tree path;
      Out_channel.with_open_bin path (fun channel -> output_string channel "occupied");
      (match E.save_latest config evidence with
       | Error (E.Directory_prepare_failed _) -> ()
       | Error error -> Alcotest.fail ("expected directory IO refusal: " ^ E.error_to_string error)
       | Ok _ -> Alcotest.fail "occupied evidence directory accepted a write");
      Sys.remove path)
      [Tool_result.Proven_pre_effect; Tool_result.Proven_post_effect; Tool_result.Effect_outcome_unknown])
;;

let test_duration_statistics () =
  let module E = Keeper_skill_composition_evidence in
  let reference = make_reference "indexed-proof" 'a' in
  let run = Keeper_tool_plan.Composition_run_id.fresh () in
  let first = make_evidence reference [] run ~recorded_at:100. in
  let change ~disposition ~duration ~recorded_at evidence =
    let json = E.to_yojson evidence in
    let fields = match json with `Assoc fields -> fields | _ -> Alcotest.fail "object" in
    let result = `Assoc ["disposition", `String disposition; "duration_ms", `Float duration;
      "tool_name", `String "keeper_compose_indexed-proof"; "data", `Assoc []] in
    `Assoc (("recorded_at", `Float recorded_at) :: ("result", result)
      :: List.remove_assoc "recorded_at" (List.remove_assoc "result" fields))
    |> E.of_yojson |> Result.get_ok in
  let older = change ~disposition:"completed" ~duration:1000. ~recorded_at:100. first in
  let latest = change ~disposition:"completed" ~duration:10. ~recorded_at:200. first in
  let other = make_evidence reference [] (Keeper_tool_plan.Composition_run_id.fresh ()) ~recorded_at:300.
    |> change ~disposition:"completed" ~duration:30. ~recorded_at:300. in
  let deferred = make_evidence reference [] (Keeper_tool_plan.Composition_run_id.fresh ()) ~recorded_at:400.
    |> change ~disposition:"deferred" ~duration:900. ~recorded_at:400. in
  let stats = E.statistics [older; latest; other; deferred] in
  Alcotest.(check int) "original run counted once" 3 stats.records;
  Alcotest.(check int) "only completed samples" 2 stats.completed.samples;
  Alcotest.(check (option (float 0.00001))) "completed mean excludes old and deferred" (Some 20.) stats.completed.mean_ms;
  Alcotest.(check (option (float 0.00001))) "deduplicated nearest-rank p50" (Some 10.) stats.completed.p50_ms;
  Alcotest.(check (option (float 0.00001))) "deduplicated nearest-rank p95" (Some 30.) stats.completed.p95_ms;
  Alcotest.(check (option (float 0.00001))) "window begins with selected result" (Some 200.) stats.first_recorded_at;
  Alcotest.(check (option (float 0.00001))) "window includes deferred result" (Some 400.) stats.last_recorded_at;
  Alcotest.(check int) "deferred separately" 1 stats.deferred;
  Alcotest.(check (option (float 0.00001))) "missing failures are unknown" None stats.failed.mean_ms;
  let tail = List.init 20 (fun index ->
    let duration = if index = 19 then 1000. else float_of_int index in
    make_evidence reference [] (Keeper_tool_plan.Composition_run_id.fresh ()) ~recorded_at:500.
    |> change ~disposition:"completed" ~duration ~recorded_at:500.) |> E.statistics in
  Alcotest.(check (option (float 0.00001))) "p50 retains sample distribution" (Some 9.) tail.completed.p50_ms;
  Alcotest.(check (option (float 0.00001))) "p95 distinguishes tail from maximum" (Some 18.) tail.completed.p95_ms;
  Alcotest.(check (option (float 0.00001))) "outlier remains visible" (Some 1000.) tail.completed.max_ms;
  Alcotest.(check (option (float 0.00001))) "zero is measured" (Some 0.) tail.completed.min_ms;
  let before_epoch_evidence = change ~disposition:"completed" ~duration:10. ~recorded_at:(-100.5) first in
  let summary = E.run_summary before_epoch_evidence |> E.run_summary_to_yojson in
  Alcotest.(check bool) "pre-epoch summary round-trips through its public codec" true
    ((E.run_summary_of_yojson summary |> Result.map E.run_summary_to_yojson) = Ok summary);
  List.iter (fun value ->
    let fields = Yojson.Safe.Util.to_assoc summary in
    Alcotest.(check bool) "nonfinite summary time is refused" true
      (E.run_summary_of_yojson (`Assoc (("recorded_at", `Float value)
        :: List.remove_assoc "recorded_at" fields)) |> Result.is_error))
    [nan; infinity; neg_infinity];
  let before_epoch = E.statistics [before_epoch_evidence] in
  Alcotest.(check (option (float 0.00001))) "finite pre-epoch record starts the window"
    (Some (-100.5)) before_epoch.first_recorded_at;
  Alcotest.(check (option (float 0.00001))) "finite pre-epoch record ends the window"
    (Some (-100.5)) before_epoch.last_recorded_at;
  let empty = E.statistics [] in
  List.iter (Alcotest.(check (option (float 0.00001))) "empty is unknown, not zero" None)
    [empty.completed.mean_ms; empty.completed.min_ms; empty.completed.p50_ms;
     empty.completed.p95_ms; empty.completed.max_ms; empty.first_recorded_at; empty.last_recorded_at]
;;

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Alcotest.run
    "keeper_skill_composition_evidence"
    [ ( "latest authority"
      , [ Alcotest.test_case "duration samples and original run deduplication" `Quick test_duration_statistics
        ; Alcotest.test_case "canonical failed results and storage refusal" `Quick test_canonical_failed_results
        ; Alcotest.test_case
            "newest recorded_at wins regardless of write order"
            `Quick
            test_latest_selects_newest_recorded_at
        ; Alcotest.test_case
            "same-reference runs stay side by side"
            `Quick
            test_same_reference_runs_do_not_overlap
        ; Alcotest.test_case
            "current run partition is authoritative"
            `Quick
            test_only_run_partition_is_authoritative
        ] )
    ]
;;
