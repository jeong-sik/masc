open Alcotest
open Masc

module Ledger = Keeper_skill_activation_ledger
module Projection = Keeper_skill_activation_projection

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Sys.readdir path
    |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO
  | Unix.S_SOCK -> Unix.unlink path
;;

let with_workspace operation =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let root = Filename.temp_dir "skill-activation-projection-" "" in
  let config = Workspace.default_config root in
  ignore (Workspace.init config ~agent_name:(Some "test"));
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () -> operation config)
;;

let meta keeper_name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
         [ "name", `String keeper_name
         ; "trace_id", `String "trace-projection"
         ])
  with
  | Ok meta -> meta
  | Error detail -> fail detail
;;

let persist_session config keeper_name =
  let meta = meta keeper_name in
  (match Keeper_meta_store.replace_snapshot config meta with
   | Ok () -> ()
   | Error detail -> fail detail);
  let session_dir =
    Keeper_fs.keeper_session_dir
      config
      (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
  in
  Unix.mkdir session_dir 0o700;
  meta
;;

let test_missing_keeper_is_no_session () =
  with_workspace @@ fun config ->
  match Projection.resolve ~config ~keeper_name:"absent" with
  | Projection.No_session { keeper_name } ->
    check string "exact Keeper" "absent" keeper_name
  | Projection.Available _ | Projection.Unavailable _ ->
    fail "missing Keeper did not remain no_session"
;;

let source_id =
  match Skill_source_config.source_id_of_string "workspace" with
  | Ok source_id -> source_id
  | Error detail -> fail detail
;;

let package_id =
  match Skill_reference.package_id_of_directory "review" with
  | Ok package_id -> package_id
  | Error _ -> fail "invalid package fixture"
;;

let revision parse value =
  match parse value with
  | Ok revision -> revision
  | Error _ -> fail "invalid revision fixture"
;;

let record_one config (meta : Keeper_meta_contract.keeper_meta) =
  let reference =
    Skill_reference.make
      ~identity:
        (Skill_reference.make_identity
           ~source_id
           ~package_id
           ~name:"review")
      ~content_revision:
        (revision
           Skill_reference.content_revision_of_string
           (String.make 64 'a'))
  in
  let activation =
    match
      Ledger.make_activation
        ~identity:reference.identity
        ~content_revision:reference.content_revision
        ~snapshot_revision:
          (revision
             Skill_catalog_snapshot.snapshot_revision_of_string
             (String.make 64 'b'))
        ~turn_ref:
          (Ids.Turn_ref.make
             ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
             ~absolute_turn:1)
        ~runtime_id:"test.runtime"
        ~skill_tool_use_id:"call-projection"
        ~agent_core_turn:0
        ~body:"projection body"
        ~activated_at:"2026-08-26T00:00:00Z"
        ~origin:Ledger.Session_instruction
    with
    | Ok activation -> activation
    | Error _ -> fail "activation fixture rejected"
  in
  match Ledger.record ~config ~trace_id:meta.runtime.trace_id activation with
  | Ok _ -> ()
  | Error error -> fail (Ledger.store_error_to_string error)
;;

let activation_count json =
  let open Yojson.Safe.Util in
  json
  |> member "skill_activations"
  |> member "ledger"
  |> member "activations"
  |> to_list
  |> List.length
;;

let test_dashboard_projection_is_live_outside_inventory_cache () =
  with_workspace @@ fun config ->
  let keeper_name = "projection-keeper" in
  let meta = persist_session config keeper_name in
  let before =
    Server_dashboard_http_runtime_info.dashboard_tools_http_json
      ~keeper:keeper_name
      config
  in
  check int "empty live ledger" 0 (activation_count before);
  record_one config meta;
  let after =
    Server_dashboard_http_runtime_info.dashboard_tools_http_json
      ~keeper:keeper_name
      config
  in
  check int "same cached inventory gets fresh activation ledger" 1
    (activation_count after)
;;

let test_corrupt_ledger_is_unavailable_not_empty () =
  with_workspace @@ fun config ->
  let keeper_name = "corrupt-ledger" in
  let meta = persist_session config keeper_name in
  let path =
    Filename.concat
      (Keeper_fs.keeper_session_dir
         config
         (Keeper_id.Trace_id.to_string meta.runtime.trace_id))
      "skill-activations.json"
  in
  let channel = open_out_bin path in
  output_string channel "not-json";
  close_out channel;
  match Projection.resolve ~config ~keeper_name with
  | Projection.Unavailable { reason; _ } ->
    check string "typed reason" "activation_ledger_unreadable" reason
  | Projection.Available _ | Projection.No_session _ ->
    fail "corrupt ledger was projected as an empty success"
;;

let () =
  run
    "keeper Skill activation projection"
    [ ( "projection"
      , [ test_case "missing Keeper is no_session" `Quick
            test_missing_keeper_is_no_session
        ; test_case "dashboard attachment bypasses inventory cache" `Quick
            test_dashboard_projection_is_live_outside_inventory_cache
        ; test_case "corrupt ledger is unavailable" `Quick
            test_corrupt_ledger_is_unavailable_not_empty
        ] )
    ]
;;
