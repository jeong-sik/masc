open Alcotest
open Masc
module Birth = Keeper_input_birth
module Store = Keeper_chat_operation_store
module Checkpoint = Keeper_checkpoint_store
module Registry = Keeper_owner_registry
let ok show = function Ok value -> value | Error cause -> fail (show cause)
let born result = ok Birth.error_to_string result
let stored result = ok Store.error_to_string result
let registered result = ok Registry.command_error_to_string result
let contents path = In_channel.with_open_bin path In_channel.input_all
let rec remove path = match Unix.lstat path with
  | {Unix.st_kind=Unix.S_DIR;_} -> Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
  | {Unix.st_kind=(S_REG | S_LNK | S_CHR | S_BLK | S_FIFO | S_SOCK);_} -> Unix.unlink path
let with_workspace f = Eio_main.run @@ fun env ->
  if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Filename.temp_dir "input-birth-" "" |> Unix.realpath in
  Fun.protect ~finally:(fun () -> remove base_path) (fun () ->
    let config = Workspace.default_config base_path in
    ignore (Workspace.init config ~agent_name:(Some "input-birth-test"));
    let path = Store.path_for_keeper ~keepers_runtime_dir:(Workspace.keepers_runtime_dir config) ~keeper_name:"imp" in
    Fs_compat.mkdir_p (Filename.dirname path);
    let store = Store.open_or_create ~path |> stored in
    Store.close store |> stored;
    let db = Sqlite3.db_open path in
    let result = Sqlite3.exec db "UPDATE input_history SET basis='prior_unavailable'" in
    check bool "fixture retains unknown prior history" true (result=Sqlite3.Rc.OK);
    check bool "fixture database closed" true (Sqlite3.db_close db);
    f config)
let with_inventory ?(operation_runner=None) config f = Eio.Switch.run @@ fun sw ->
  ignore (Registry.install_from_store ~sw ~operation_runner ~on_turn_slot_released:None config
    |> ok Registry.install_error_to_string);
  f ()
let under_intake config f = match Keeper_shutdown_intake_fence.run_durable_intake_if_open
    ~base_path:config.Workspace.base_path ~keeper_name:"imp" f with
  | Intake_committed value -> value
  | Intake_shutdown_reserved _ -> fail "fixture intake unexpectedly reserved"
let initial config intake_token =
  let creation = Birth.generate ~keeper_name:"imp" () |> ok Fun.id in
  let reserved = Birth.reserve_session ~base_path:config.Workspace.base_path ~intake_token creation |> born in
  let session = Keeper_context_core.create_session ~base_dir:(Birth.session_root reserved)
    ~session_id:(Keeper_id.Trace_id.to_string (Birth.trace_id creation)) in
  let checkpoint,outcome = Keeper_context_core.save_agent_core_checkpoint_classified
    ~runtime_id:"test-runtime" ~keeper_name:"imp" ~agent_name:"imp" ~session
    ~ctx:(Keeper_context_core.create ~eio:true ~system_prompt:"Original initial prompt")
    |> ok (Keeper_context_core.checkpoint_write_error_to_string ~persistence_error_to_string:Fun.id) in
  let seed = Birth.retain_initial reserved ~checkpoint ~outcome |> born in
  let fixture = Masc_test_deps.meta_of_json_fixture
    (`Assoc ["name",`String "imp";"trace_id",`String checkpoint.session_id;
      "activation_mode",`String "manual"]) |> ok Fun.id in
  let meta = {fixture with Keeper_meta_contract.keeper_id=Some (Birth.keeper_uid creation)} in
  creation,reserved,seed,meta,checkpoint,session
let observe config trace_id = Registry.input_checkpoint ~base_path:config.Workspace.base_path ~keeper_name:"imp" ~trace_id |> registered
let unknown config =
  let trace_id = Keeper_id.Trace_id.of_string "trace-unresolved-original" |> ok Fun.id in
  match observe config trace_id with
  | Store.Prior_input_unavailable -> ()
  | Input_unobserved | Input_observed _ -> fail "new birth erased the unrelated historical floor"
let create config intake_token seed meta =
  match Registry.create_meta ~base_path:config.Workspace.base_path ~intake_token ~initial_input:seed meta |> registered with
  | Some committed -> committed
  | None -> fail "creation did not publish metadata"
let run_input config meta checkpoint session =
  match Registry.run_autonomous_if_idle ~base_path:config.Workspace.base_path ~keeper_name:"imp" (fun () ->
    let producer = Keeper_input_checkpoint_producer.prepare ~base_path:config.base_path ~keeper_name:"imp"
      ~session_dir:session.Keeper_types.session_dir ~trace_id:meta.Keeper_meta_contract.runtime.trace_id
      ~source:(Some checkpoint) |> ok Keeper_input_checkpoint_producer.error_to_string in
    ignore (Keeper_input_checkpoint_producer.publish_autonomous producer checkpoint
      |> ok Keeper_input_checkpoint_producer.error_to_string)) |> registered with
  | `Ran () -> () | `Busy _ | `Interrupted -> fail "created trace could not enter the actual input producer"
let test_created_trace_dispatches_and_restarts () = with_workspace (fun config ->
  let meta,checkpoint,session = with_inventory config (fun () ->
    under_intake config (fun intake_token ->
      let _,_,seed,meta,checkpoint,session = initial config intake_token in
      let committed = create config intake_token seed meta in
      (match observe config meta.runtime.trace_id with
       | Input_observed _ -> () | Input_unobserved | Prior_input_unavailable -> fail "birth did not install its exact predecessor");
      (match Registry.create_meta ~base_path:config.Workspace.base_path ~intake_token ~initial_input:seed meta with
       | Error _ -> () | Ok _ -> fail "birth replay recreated a nonempty Owner");
      unknown config;
      run_input config committed checkpoint session;
      committed,checkpoint,session)) in
  with_inventory config (fun () -> unknown config; run_input config meta checkpoint session))
let test_expired_birth_is_not_reconstructed () = with_workspace (fun config ->
  with_inventory config (fun () ->
    let _,_,seed,meta,_,_ = under_intake config (initial config) in
    (match Registry.create_meta ~base_path:config.Workspace.base_path ~initial_input:seed meta with
     | Error _ -> () | Ok _ -> fail "expired creation authority was reconstructed from existing files");
    (match observe config meta.runtime.trace_id with
     | Prior_input_unavailable -> () | Input_unobserved | Input_observed _ -> fail "expired birth granted input authority");
    unknown config))
let test_changed_initial_or_incarnation_is_refused () =
  List.iter (fun change -> with_workspace (fun config -> with_inventory config (fun () ->
    under_intake config (fun intake_token ->
      let _,_,seed,meta,_,session = initial config intake_token in
      let canonical = Checkpoint.agent_core_checkpoint_path ~session_dir:session.session_dir ~session_id:session.session_id in
      let meta = change meta canonical in
      let before = contents canonical in
      (match Registry.create_meta ~base_path:config.Workspace.base_path ~intake_token ~initial_input:seed meta with
       | Error _ -> () | Ok _ -> fail "stale initial evidence granted input authority");
      check string "refusal preserves current checkpoint bytes" before (contents canonical);
      (match observe config meta.runtime.trace_id with
       | Prior_input_unavailable -> () | Input_unobserved | Input_observed _ -> fail "stale initial evidence installed a predecessor");
      unknown config))))
    [(fun meta canonical ->
        let checkpoint = Checkpoint.load_agent_core_exact_snapshot ~session_dir:(Filename.dirname canonical)
          ~session_id:(Keeper_id.Trace_id.to_string meta.Keeper_meta_contract.runtime.trace_id)
          |> ok Checkpoint.checkpoint_ref_load_error_to_string |> Checkpoint.exact_snapshot_checkpoint in
        Out_channel.with_open_bin canonical (fun out -> output_string out
          (Agent_core.Checkpoint.to_string {checkpoint with system_prompt=Some "later edit"})); meta);
     (fun meta _ -> {meta with Keeper_meta_contract.keeper_id=Some (Keeper_id.Uid.generate ())})]
let test_session_collision_preserves_existing_evidence () = with_workspace (fun config ->
  under_intake config (fun intake_token ->
    let creation,_,_,_,_,session = initial config intake_token in
    let canonical = Checkpoint.agent_core_checkpoint_path ~session_dir:session.session_dir ~session_id:session.session_id in
    let before = contents canonical in
    (match Birth.reserve_session ~base_path:config.Workspace.base_path ~intake_token creation with
     | Error cause -> check bool (Birth.error_to_string cause) true (cause=Birth.Session_already_present)
     | Ok _ -> fail "an existing session was accepted as a new birth");
    check string "collision never rewrites the original checkpoint" before (contents canonical)))
let test_uncertain_registration_never_publishes_metadata () =
  List.iter (fun (arm,clear,committed) -> with_workspace (fun config ->
  with_inventory config (fun () ->
    (* Materialise an empty Owner without granting an input relation. *)
    let _,_,expired,expired_meta,_,_ = under_intake config (initial config) in
    (match Registry.create_meta ~base_path:config.Workspace.base_path ~initial_input:expired expired_meta with
     | Error _ -> () | Ok _ -> fail "expired seed unexpectedly created metadata");
    let owner = Registry.get ~base_path:config.base_path ~keeper_name:"imp" |> ok Registry.lookup_error_to_string in
    under_intake config (fun intake_token ->
      let _,_,seed,meta,_,_ = initial config intake_token in
      arm ();
      Fun.protect ~finally:clear (fun () ->
        (match Registry.create_meta ~base_path:config.base_path ~intake_token ~initial_input:seed meta with
         | Error _ -> () | Ok _ -> fail "uncertain registration published metadata");
        check bool "uncertain registration keeps the Owner empty" true
          (Option.is_none (Keeper_owner.projection owner).meta);
        (match observe config meta.runtime.trace_id,committed with
         | Input_observed _,true | Prior_input_unavailable,false -> ()
         | (Input_unobserved | Input_observed _ | Prior_input_unavailable),_ ->
           fail "failed creation misreported the actual committed input relation");
        let path = Store.path_for_keeper ~keepers_runtime_dir:(Workspace.keepers_runtime_dir config) ~keeper_name:"imp" in
        let execute sql =
          let db = Sqlite3.db_open ~mode:`NO_CREATE path in
          Fun.protect ~finally:(fun () -> ignore (Sqlite3.db_close db : bool)) (fun () ->
            check bool "fixture database edit" true (Sqlite3.exec db sql=Sqlite3.Rc.OK)) in
        execute "CREATE TABLE foreign_contract (value TEXT)";
        (match Keeper_owner.wake_operation_drain owner with
         | Error _ -> () | Ok () -> fail "operation integrity damage was not fenced");
        execute "DROP TABLE foreign_contract";
        let _,_,next_seed,next_meta,_,_ = initial config intake_token in
        (match Registry.create_meta ~base_path:config.base_path ~intake_token ~initial_input:next_seed next_meta with
         | Error _ -> () | Ok _ -> fail "new birth bypassed sticky integrity fence");
        (match Registry.input_checkpoint ~base_path:config.base_path ~keeper_name:"imp"
          ~trace_id:next_meta.runtime.trace_id with
         | Error _ -> () | Ok _ -> fail "closed sticky Owner unexpectedly supplied a read");
        (match Store.inspect_outstanding ~path |> stored with
         | Missing_store -> fail "integrity refusal removed the journal"
         | Stored_operations {input_checkpoints;input_history;_} ->
           check bool "read-only primary inspection preserves prior floor" true
             (input_history=Store.Prior_input_history_unavailable);
           check bool "fenced creation wrote no next trace relation" false
             (List.exists (fun (reference : Keeper_checkpoint_ref.t) ->
               Keeper_id.Trace_id.equal reference.trace_id next_meta.runtime.trace_id) input_checkpoints));
        check bool "no child starts through the uncertain creation" true
          (Option.is_none (Keeper_owner.turn_in_flight owner)))))))
    [(fun () -> Store.For_testing.fail_next_commit Store.For_testing.Fail_before_commit),
      Store.For_testing.clear_commit_fault,false;
     (fun () -> Store.For_testing.fail_next_commit Store.For_testing.Fail_after_commit),
      Store.For_testing.clear_commit_fault,true]
let () = run "Keeper input trace birth"
  ["creation authority",[
    test_case "created trace runs the input producer before and after restart" `Quick test_created_trace_dispatches_and_restarts;
    test_case "expired birth is not reconstructed from absence or files" `Quick test_expired_birth_is_not_reconstructed;
    test_case "changed initial source and Keeper incarnation refuse registration" `Quick test_changed_initial_or_incarnation_is_refused;
    test_case "failed registration preserves actual evidence and respects integrity fences" `Quick test_uncertain_registration_never_publishes_metadata;
    test_case "session collision preserves existing checkpoint evidence" `Quick test_session_collision_preserves_existing_evidence]]
