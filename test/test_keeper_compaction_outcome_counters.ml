(** Durable compaction state records commits, not retry policy. *)

open Alcotest

module Meta_store = Masc.Keeper_meta_store

let make_meta ~name : Masc.Keeper_meta_contract.keeper_meta =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String name; "trace_id", `String ("trace-" ^ name) ])
  with
  | Ok meta -> meta
  | Error detail -> failf "keeper meta fixture failed: %s" detail
;;

let with_workspace f =
  let base_path = Masc_test_deps.setup_test_workspace () in
  Fun.protect
    ~finally:(fun () -> Masc_test_deps.cleanup_test_workspace base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       f config)
;;

let persist_commit_projection config ~name ~commit_count =
  match
    Meta_store.persist_compaction_commit_projection
      config
      ~keeper_name:name
      ~commit_count
  with
  | Ok `Persisted -> ()
  | Ok `No_durable_meta -> failf "%s has no durable meta to update" name
  | Error msg -> failf "commit persistence failed for %s: %s" name msg
;;

let test_commit_count_tracks_only_durable_commits () =
  with_workspace (fun config ->
    let name = "compaction-commits" in
    let meta = make_meta ~name in
    (match Meta_store.write_meta config meta with
     | Ok () -> ()
     | Error msg -> failf "could not persist meta for %s: %s" name msg);
    persist_commit_projection config ~name ~commit_count:2;
    persist_commit_projection config ~name ~commit_count:1;
    match Meta_store.read_meta config name with
    | Ok (Some current) ->
      check
        int
        "a delayed projection cannot regress the checkpoint count"
        2
        current.runtime.compaction_rt.count
    | Ok None -> fail "keeper meta disappeared after compaction commits"
    | Error msg -> failf "meta read failed: %s" msg)
;;

let test_missing_keeper_has_no_commit_state () =
  with_workspace (fun config ->
    match
      Meta_store.persist_compaction_commit_projection
        config
        ~keeper_name:"compaction-unregistered"
        ~commit_count:1
    with
    | Ok `No_durable_meta -> ()
    | Ok `Persisted -> fail "an unregistered keeper must not persist a commit"
    | Error msg -> failf "unexpected commit persistence error: %s" msg)
;;

let test_metric_name_is_stable () =
  check
    string
    "dashboards and alerts key off this name"
    "masc_keeper_compaction_outcomes_total"
    Keeper_metrics.(to_string CompactionOutcomes)
;;

let () =
  run
    "keeper compaction commit count"
    [ ( "commit"
      , [ test_case
            "durable count tracks commits"
            `Quick
            test_commit_count_tracks_only_durable_commits
        ; test_case
            "missing keeper has no commit state"
            `Quick
            test_missing_keeper_has_no_commit_state
        ; test_case "metric name is stable" `Quick test_metric_name_is_stable
        ] )
    ]
;;
