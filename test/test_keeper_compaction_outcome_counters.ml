(** Durable compaction state records commits, not retry policy. *)

open Alcotest

module Meta_store = Masc.Keeper_meta_store

(* The commit stamp: this suite asserts on counters alone and never reads it
   back, so a fixed value keeps the fixtures reproducible. *)
let commit_at = 1_700_000_000.0

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
       Eio_main.run @@ fun env ->
       if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env);
       Eio.Switch.run @@ fun sw ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       (match Masc.Keeper_owner_registry.install_from_store ~sw ~operation_runner:None ~on_turn_slot_released:None config with
        | Ok 0 -> ()
        | Ok count -> failf "unexpected initial owner count: %d" count
        | Error error ->
          fail (Masc.Keeper_owner_registry.install_error_to_string error));
       f config)
;;

let persist_commit_projection config meta ~commit_count =
  match
    Masc.Keeper_owner_registry.apply_meta
      ~base_path:config.Masc.Workspace.base_path
      ~keeper_name:meta.Masc.Keeper_meta_contract.name
      (Masc.Keeper_owner_reducer.Record_compaction_commit
         { trace_id = meta.runtime.trace_id
         ; commit_count
         ; at = commit_at
         ; before_bytes = 0
         ; after_bytes = 0
         ; updated_at = Masc.Keeper_meta_contract.now_iso ()
         })
  with
  | Ok (Some _) -> ()
  | Ok None -> failf "%s has no durable meta to update" meta.name
  | Error error ->
    failf
      "commit persistence failed for %s: %s"
      meta.name
      (Masc.Keeper_owner_registry.command_error_to_string error)
;;

let test_commit_count_tracks_only_durable_commits () =
  with_workspace (fun config ->
    let name = "compaction-commits" in
    let meta = make_meta ~name in
    (match Masc.Keeper_owner_registry.create_meta ~base_path:config.base_path meta with
     | Ok (Some _) -> ()
     | Ok None -> fail "owner create removed metadata"
     | Error error ->
       fail (Masc.Keeper_owner_registry.command_error_to_string error));
    persist_commit_projection config meta ~commit_count:2;
    persist_commit_projection config meta ~commit_count:1;
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
      Masc.Keeper_owner_registry.apply_meta
        ~base_path:config.base_path
        ~keeper_name:"compaction-unregistered"
        (Masc.Keeper_owner_reducer.Record_compaction_commit
           { trace_id =
               (make_meta ~name:"compaction-unregistered").runtime.trace_id
           ; commit_count = 1
           ; at = commit_at
           ; before_bytes = 0
           ; after_bytes = 0
           ; updated_at = Masc.Keeper_meta_contract.now_iso ()
           })
    with
    | Error
        (Masc.Keeper_owner_registry.Command_lookup_failed
           (Masc.Keeper_owner_registry.Owner_not_found _)) -> ()
    | Ok _ -> fail "an unregistered keeper must not persist a commit"
    | Error error ->
      failf
        "unexpected commit persistence error: %s"
        (Masc.Keeper_owner_registry.command_error_to_string error))
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
