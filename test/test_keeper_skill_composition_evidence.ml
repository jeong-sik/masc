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

let node () =
  `Assoc
    [ "node_id", `String "clock"
    ; "execution_id", Ids.Execution_id.(generate () |> to_yojson)
    ; "tool_name", `String "keeper_time_now"
    ; "input", `Assoc []
    ; ( "schedule"
      , `Assoc
          [ "planned_index", `Int 0
          ; "batch_index", `Int 0
          ; "batch_size", `Int 1
          ; "execution_mode", `String "serial"
          ] )
    ; ( "result"
      , `Assoc
          [ "disposition", `String "completed"
          ; "data", `Assoc []
          ; "tool_name", `String "keeper_time_now"
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

let test_latest_exact_reference_replaces_prior_publication () =
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
       let settlement = node () in
       let save composition_run_id =
         let result =
           Tool_result.make_ok
             ~tool_name:"keeper_compose_indexed-proof"
             ~start_time:(Time_compat.now ())
             ~data:(`Assoc [ "actions", `List [ settlement ] ])
             ()
         in
         let evidence =
           Keeper_skill_composition_evidence.make
             ~reference
             ~composition_run_id
             ~parent_invocation:(parent_invocation ())
             ~request_id:None
             ~keeper_name:"delta"
             ~composition_tool:"keeper_compose_indexed-proof"
             ~composition_execution:Keeper_tool_composition_catalog.Inline
             ~result
             ~executor_settlements:[ settlement ]
           |> Result.get_ok
         in
         Keeper_skill_composition_evidence.save_latest config evidence
         |> Result.get_ok
         |> ignore
       in
       let first = Keeper_tool_plan.Composition_run_id.fresh () in
       let second = Keeper_tool_plan.Composition_run_id.fresh () in
       save first;
       save second;
       let loaded =
         Keeper_skill_composition_evidence.load_latest config reference
         |> Result.get_ok
         |> Option.get
         |> Keeper_skill_composition_evidence.to_yojson
       in
       let open Yojson.Safe.Util in
       Alcotest.(check string)
         "latest run"
         (Keeper_tool_plan.Composition_run_id.to_string second)
         (loaded |> member "composition_run_id" |> to_string);
       Alcotest.(check string) "blank provider id remains opaque" ""
         (loaded |> member "parent_tool_use_id" |> to_string);
       Alcotest.(check int) "parent turn" 7
         (loaded |> member "parent_turn" |> to_int);
       Alcotest.(check int) "one typed settlement" 1
         (loaded |> member "executor_settlements" |> to_list |> List.length);
       Alcotest.(check bool) "another reference remains absent" true
         (Keeper_skill_composition_evidence.load_latest
            config
            (make_reference "other-proof" 'b')
          |> Result.get_ok
          |> Option.is_none))
;;

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Alcotest.run
    "keeper_skill_composition_evidence"
    [ ( "latest authority"
      , [ Alcotest.test_case
            "replaces only the exact reference"
            `Quick
            test_latest_exact_reference_replaces_prior_publication
        ] )
    ]
;;
