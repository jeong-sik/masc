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

let node ~node_id ~(schedule : Agent_core.Tool_contract.schedule) () =
  `Assoc
    [ "node_id", `String node_id
    ; "execution_id", Ids.Execution_id.(generate () |> to_yojson)
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
  Filename.concat (Workspace.masc_root_dir config) "skill-composition-evidence-v1"
;;

let partition reference =
  Skill_reference.to_yojson reference
  |> Yojson.Safe.to_string
  |> Digestif.SHA256.digest_string
  |> Digestif.SHA256.to_hex
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
         (loaded |> member "composition_run_id" |> to_string))
;;

(* Records written by the pre-append layout (a single [<partition>.json] per
   reference) must remain readable, and lose only to a strictly newer run. *)
let test_legacy_single_file_remains_a_candidate () =
  let base_path =
    Filename.temp_file "masc_skill_composition_evidence" ""
  in
  Sys.remove base_path;
  Unix.mkdir base_path 0o755;
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let config = Workspace.default_config base_path in
       let reference = make_reference "legacy-proof" 'c' in
       let settlements = settlements_fixture () in
       let legacy_run = Keeper_tool_plan.Composition_run_id.fresh () in
       let legacy =
         make_evidence reference settlements legacy_run ~recorded_at:100.0
       in
       let evidence_json =
         Keeper_skill_composition_evidence.to_yojson legacy
         |> Yojson.Safe.to_string
       in
       Fs_compat.mkdir_p (store_dir config);
       Out_channel.with_open_bin
         (Filename.concat (store_dir config) (partition reference ^ ".json"))
         (fun channel -> output_string channel evidence_json);
       let load () =
         Keeper_skill_composition_evidence.load_latest config reference
         |> Result.get_ok
         |> Option.get
         |> Keeper_skill_composition_evidence.to_yojson
       in
       let open Yojson.Safe.Util in
       Alcotest.(check string) "legacy record remains readable"
         (Keeper_tool_plan.Composition_run_id.to_string legacy_run)
         (load () |> member "composition_run_id" |> to_string);
       let older_run = Keeper_tool_plan.Composition_run_id.fresh () in
       (Keeper_skill_composition_evidence.save_latest
          config
          (make_evidence reference settlements older_run ~recorded_at:50.0)
        |> Result.get_ok
        |> ignore);
       Alcotest.(check string) "legacy record still wins over a strictly older run"
         (Keeper_tool_plan.Composition_run_id.to_string legacy_run)
         (load () |> member "composition_run_id" |> to_string);
       let newer_run = Keeper_tool_plan.Composition_run_id.fresh () in
       (Keeper_skill_composition_evidence.save_latest
          config
          (make_evidence reference settlements newer_run ~recorded_at:150.0)
        |> Result.get_ok
        |> ignore);
       Alcotest.(check string) "a strictly newer run wins over the legacy record"
         (Keeper_tool_plan.Composition_run_id.to_string newer_run)
         (load () |> member "composition_run_id" |> to_string))
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
      let settled = node ~node_id:"read" ~schedule:{planned_index=1;batch_index=1;
        batch_size=1;execution_mode=Agent_core.Tool_contract.Serial} ()
        |> replace "tool_name" (`String "BrowserRead")
        |> replace "result" node_result in
      let result = failure "keeper_compose_failed-read" in
      let evidence = E.make ~reference
        ~composition_run_id:(Keeper_tool_plan.Composition_run_id.fresh ())
        ~parent_invocation:(parent_invocation ()) ~request_id:None ~keeper_name:"delta"
        ~composition_tool:"keeper_compose_failed-read"
        ~composition_execution:Keeper_tool_composition_catalog.Inline
        ~result ~executor_settlements:[settled] |> Result.get_ok in
      E.save_latest config evidence |> Result.get_ok |> ignore;
      let loaded = E.load_latest config reference |> Result.get_ok |> Option.get |> E.to_yojson in
      let open Yojson.Safe.Util in
      Alcotest.(check bool) "failed top-level result round-trips exactly" true
        (member "result" loaded = Tool_result.to_json result);
      Alcotest.(check bool) "failed node result round-trips exactly" true
        (member "executor_settlements" loaded |> to_list = [settled]);
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
      let path = Filename.concat (Workspace.masc_root_dir config) "skill-composition-evidence-v1" in
      Fs_compat.remove_tree path;
      Out_channel.with_open_bin path (fun channel -> output_string channel "occupied");
      (match E.save_latest config evidence with
       | Error (E.Directory_prepare_failed _) -> ()
       | Error error -> Alcotest.fail ("expected directory IO refusal: " ^ E.error_to_string error)
       | Ok _ -> Alcotest.fail "occupied evidence directory accepted a write");
      Sys.remove path)
      [Tool_result.Proven_pre_effect; Tool_result.Proven_post_effect; Tool_result.Effect_outcome_unknown])
;;

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Alcotest.run
    "keeper_skill_composition_evidence"
    [ ( "latest authority"
      , [ Alcotest.test_case "canonical failed results and storage refusal" `Quick test_canonical_failed_results
        ; Alcotest.test_case
            "newest recorded_at wins regardless of write order"
            `Quick
            test_latest_selects_newest_recorded_at
        ; Alcotest.test_case
            "same-reference runs stay side by side"
            `Quick
            test_same_reference_runs_do_not_overlap
        ; Alcotest.test_case
            "legacy single file remains a candidate"
            `Quick
            test_legacy_single_file_remains_a_candidate
        ] )
    ]
;;
