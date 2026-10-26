(** Actual original-source capture and locked private-file retention. No wake,
    Browser, credential provider or real-account operation runs here. *)
open Alcotest
open Masc
module O=Lane_addon_companion_origin
module Recovery_test=Fs_compat_test_support.Publication_recovery_for_testing
let ok = function Ok value -> value | Error error -> fail (O.error_to_string error)
let with_root run =
  let root=Filename.temp_dir "companion-origin-" "" |> Unix.realpath in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    run root (Workspace.default_config root))
let trace=Random_id.uuid_v7 ()
let turn_ref=Ids.Turn_ref.make ~trace_id:trace ~absolute_turn:42
let context=Keeper_tool_call_log_context.{empty_turn_context with trace_id=Some trace;
  keeper_turn_id=Some 42;task_id=Some "task-original"}
let channel thread = match Keeper_continuation_channel.dashboard ~thread_id:thread with
  | Ok value -> value | Error message -> fail message
let make_source ?(task="task-original") ?(thread="original-thread") ?(tool_use="original-use") () =
  O.source ~keeper_name:"original-keeper" ~turn_ref:(Some turn_ref) ~tool_use_id:(Some tool_use)
    ~trace_id:(Some trace) ~source_context:(Some {context with task_id=Some task})
    ~channel:(Some (channel thread)) |> ok
let destination=O.{instance_id="original-instance";package_id="onepassword";package_revision="0.1.0";
  tool="onepassword_login";declaration_id=Some "original-declaration";configuration_revision=Some "original-revision"}
let arguments=`Assoc ["browser_instance_id",`String "original-browser";"tab_id",`Int 7]
let retained = function O.Fresh record | O.Existing record -> record
let directory root = Filename.concat (Filename.concat (Common.masc_dir_from_base_path ~base_path:root)
  "lane-addons") "companion-invocations"
let path root record = Filename.concat (directory root) (record.O.id ^ ".jsonl")
let write path bytes = Out_channel.with_open_bin path (fun stream -> output_string stream bytes)
let source_capture () =
  let create ?(turn=Some turn_ref) ?(use=Some "original-use") ?(trace_id=Some trace) ?(ctx=Some context) () =
    O.source ~keeper_name:"original-keeper" ~turn_ref:turn ~tool_use_id:use ~trace_id
      ~source_context:ctx ~channel:None in
  let original=create () |> ok in
  check (option string) "task comes from this call's source" (Some "task-original") original.task_id;
  check bool "absent route remains explicit" false (Keeper_continuation_channel.is_routable original.channel);
  check bool "source context supplies its actually observed turn" true (Result.is_ok (create ~turn:None ()));
  check bool "missing turn cannot be invented" true (Result.is_error (create ~turn:None ~ctx:None ()));
  check bool "missing tool-use cannot be invented" true (Result.is_error (create ~use:None ()));
  check bool "contradictory trace refused" true (Result.is_error (create ~trace_id:(Some "other-trace") ()));
  check bool "contradictory physical turn refused" true
    (Result.is_error (create ~ctx:(Some {context with keeper_turn_id=Some 43}) ()));
  check bool "observed original Keeper is accepted" true
    (Result.is_ok (create ~ctx:(Some {context with agent_name=Some "original-keeper"}) ()));
  check bool "another Keeper's task cannot borrow the same turn" true
    (create ~ctx:(Some {context with agent_name=Some "other-keeper";task_id=Some "other-task"}) ()
     = Error O.Invalid_source)
let original_binding fs () = with_root (fun root config ->
  let source=make_source () in
  check bool "lookup creates no authority" true (O.lookup ~config ~source=Ok None);
  check bool "lookup creates no directories" false (Sys.file_exists (Common.masc_dir_from_base_path ~base_path:root));
  let first=O.reserve ~fs ~config ~source ~destination ~arguments |> ok in
  check bool "first writer retains before dispatch" true (match first with O.Fresh _ -> true | O.Existing _ -> false);
  let original=retained first in
  check (option string) "original task is retained" (Some "task-original") original.source.task_id;
  check bool "original conversation is retained" true
    (Keeper_continuation_channel.same_route original.source.channel (channel "original-thread"));
  let file=path root original in
  let initial=Unix.lstat file in
  let bytes=In_channel.with_open_bin file In_channel.input_all in
  let reordered=`Assoc ["tab_id",`Int 7;"browser_instance_id",`String "original-browser"] in
  check bool "same source/input recovers only an existing binding" true
    (match O.reserve ~fs ~config ~source ~destination ~arguments:reordered |> ok with
     | O.Existing found -> found=original | O.Fresh _ -> false);
  let repeated=Unix.lstat file in
  check bool "existing reservation preserves original inode" true
    (initial.st_dev=repeated.st_dev && initial.st_ino=repeated.st_ino);
  List.iter (fun (source,destination,arguments) ->
    check bool "changed immutable call cannot adopt original authority" true
      (O.reserve ~fs ~config ~source ~destination ~arguments=Error O.Binding_conflict))
    [source,{destination with instance_id="replacement"},arguments;
     source,destination,`Assoc ["tab_id",`Int 8];
     make_source ~task:"later-task" (),destination,arguments;
     make_source ~thread:"later-thread" (),destination,arguments];
  check string "refusals do not rewrite original evidence" bytes (In_channel.with_open_bin file In_channel.input_all);
  check bool "same source strictly reloads original" true (O.lookup ~config ~source=Ok (Some original)))
let release_failure_on_existing fs () = with_root (fun root config ->
  let source=make_source () in
  let original=O.reserve ~fs ~config ~source ~destination ~arguments |> ok |> retained in
  let file=path root original in
  let bytes=In_channel.with_open_bin file In_channel.input_all in
  let initial=Unix.lstat file in
  let fault=Recovery_test.lane_scope_release_fault
    ~owner:("companion-origin-" ^ original.id)
    ~exception_:(Failure "origin recovery lane release")
    |> Result.get_ok in
  let result=Recovery_test.with_lane_scope_release_fault fault (fun () ->
    O.reserve ~fs ~config ~source ~destination ~arguments) in
  check bool "existing target cannot hide recovery lane release failure" true
    (result=Error O.Commit_unconfirmed);
  check string "release failure preserves exact original bytes" bytes
    (In_channel.with_open_bin file In_channel.input_all);
  let current=Unix.lstat file in
  check bool "release failure preserves original inode" true
    (initial.st_dev=current.st_dev && initial.st_ino=current.st_ino);
  check bool "healthy repeat remains an existing reservation" true
    (match O.reserve ~fs ~config ~source ~destination ~arguments |> ok with
     | O.Existing found -> found=original | O.Fresh _ -> false))
let live_owner_record fs () = with_root (fun root config ->
  let source=make_source () in
  let original=O.reserve ~fs ~config ~source ~destination ~arguments |> ok |> retained in
  let target=path root original in
  let owner="companion-origin-" ^ original.id in
  let lock_path=File_lock_eio.lock_file_path (target ^ ".publication-owner") in
  let observation=File_lock_eio.with_durable_lock_observed ~lock_path (fun () ->
    let private_root=Common.masc_dir_from_base_path ~base_path:root in
    Eio.Path.with_open_dir Eio.Path.(fs / private_root) (fun owned_root ->
      Eio.Switch.run (fun sw ->
        let registry=Fs_compat.Publication_recovery.open_registry ~sw ~fs
          ~registry_root:owned_root |> Result.get_ok in
        let root_stat=Unix.stat private_root and parent=Unix.stat (Filename.dirname target) in
        let operation_id=Uuidm.of_string (Random_id.uuid_v7 ()) |> Option.get in
        Recovery_test.seed_prepared ~registry ~owner ~operation_id
          ~allowed_root_path:private_root ~allowed_root_device:(Int64.of_int root_stat.st_dev)
          ~allowed_root_inode:(Int64.of_int root_stat.st_ino)
          ~parent_components:["lane-addons";"companion-invocations"]
          ~parent_device:(Int64.of_int parent.st_dev) ~parent_inode:(Int64.of_int parent.st_ino)
          ~target_leaf:(Filename.basename target) ~permissions:0o600 |> Result.get_ok;
        let record=List.fold_left Filename.concat private_root
          ["fs-publication-recovery";"lanes";owner;"active";Uuidm.to_string operation_id] in
        let bytes=In_channel.with_open_bin record In_channel.input_all and before=Unix.lstat record in
        check bool "active origin owner refuses retry before recovery readiness" true
          (O.reserve ~fs ~config ~source ~destination ~arguments=Error O.Commit_unconfirmed);
        check string "live Prepared record is not reconciled or rewritten" bytes
          (In_channel.with_open_bin record In_channel.input_all);
        let after=Unix.lstat record in
        check bool "live Prepared record keeps its inode" true
          (before.st_dev=after.st_dev && before.st_ino=after.st_ino)))) in
  match observation with
  | File_lock_eio.Body_completed {value=();release_error=None} -> ()
  | Lock_not_acquired _ | Body_completed {release_error=Some _;_} -> fail "owner fixture lock failed")
let malformed_retention fs () = with_root (fun root config ->
  let source=make_source () in
  let record=O.reserve ~fs ~config ~source ~destination ~arguments |> ok |> retained in
  let file=path root record in
  let bytes=In_channel.with_open_bin file In_channel.input_all in
  let fields=match Yojson.Safe.from_string bytes with `Assoc fields -> fields | _ -> fail "retained object missing" in
  List.iter (fun bytes ->
    write file bytes;
    check bool "empty or corrupt authority is not absence" true (O.lookup ~config ~source=Error O.Corrupt);
    check bool "empty or corrupt authority never dispatches again" true
      (O.reserve ~fs ~config ~source ~destination ~arguments=Error O.Corrupt);
    check string "refused authority is never repaired" bytes (In_channel.with_open_bin file In_channel.input_all))
    ["";bytes ^ bytes;Yojson.Safe.to_string (`Assoc (("version",`Int 1)::fields));
     Yojson.Safe.to_string (`Assoc (("unknown",`Bool true)::fields));
     Yojson.Safe.to_string (`Assoc (("version",`Int 2)::List.remove_assoc "version" fields));"{"])
let unsafe_retention fs () = with_root (fun root config ->
  let source=make_source () in
  let record=O.reserve ~fs ~config ~source ~destination ~arguments |> ok |> retained in
  let file=path root record in
  Unix.chmod file 0o644;
  check bool "unsafe file refused" true (O.lookup ~config ~source=Error O.Unavailable);
  check bool "unsafe file cannot be adopted by exclusive reservation" true
    (O.reserve ~fs ~config ~source ~destination ~arguments=Error O.Unavailable);
  check int "refused authority permissions stay unchanged" 0o644 ((Unix.lstat file).Unix.st_perm land 0o777);
  Unix.chmod file 0o600;
  let linked=Filename.concat root "linked" in
  Unix.link file linked;
  check bool "hard-linked authority refused" true (O.lookup ~config ~source=Error O.Unavailable);
  Unix.unlink linked;
  let held=Filename.concat root "held" in
  Unix.rename (directory root) held;
  Unix.symlink held (directory root);
  check bool "symlinked parent refused" true (O.lookup ~config ~source=Error O.Unavailable);
  Unix.unlink (directory root);
  Unix.symlink (Filename.concat root "missing") (directory root);
  check bool "missing beneath an unowned parent is not absence" true (O.lookup ~config ~source=Error O.Unavailable))
let concurrent_first_writer () = with_root (fun _root config ->
  let source=make_source () in
  (* Fork before either process starts an Eio event loop. A loser may encounter
     an active recovery owner or a committed winner: it must return Existing
     or refuse, and must never receive a second Fresh. *)
  let reserve () = Eio_main.run (fun env ->
    O.reserve ~fs:(Eio.Stdenv.fs env) ~config ~source ~destination ~arguments) in
  let read_fd,write_fd=Unix.pipe ~cloexec:true () in
  match Unix.fork () with
  | 0 ->
      Unix.close read_fd;
      let code=match reserve () with
        | Ok (O.Fresh _) -> 'F' | Ok (O.Existing _) -> 'E' | Error _ -> 'X' in
      ignore (Unix.write write_fd (Bytes.make 1 code) 0 1);
      Unix.close write_fd;exit 0
  | child ->
      Unix.close write_fd;
      let parent=reserve () in
      let byte=Bytes.create 1 in
      let count=Unix.read read_fd byte 0 1 in
      Unix.close read_fd;
      let rec reap () = match Unix.waitpid [] child with
        | result -> result
        | exception Unix.Unix_error (Unix.EINTR,_,_) -> reap () in
      let _,status=reap () in
      check bool "child completed its original reservation" true (status=Unix.WEXITED 0 && count=1);
      check bool "only one process receives a fresh origin" true
        (match parent,Bytes.get byte 0 with
         | Ok (O.Fresh _),('E'|'X') | Ok (O.Existing _),'F' | Error _,'F' -> true
         | Ok (O.Fresh _),_ | Ok (O.Existing _),_ | Error _,_ -> false);
      check bool "completed winner remains strictly readable" true
        (match O.lookup ~config ~source |> ok with Some _ -> true | None -> false))
let with_fs run () = Eio_main.run (fun env -> run (Eio.Stdenv.fs env) ())
let () = run "Original companion invocation" ["origin",[
  test_case "capture original source and reject contradictions" `Quick source_capture;
  test_case "retain once and refuse changed source/input/destination" `Quick (with_fs original_binding);
  test_case "existing origin does not hide recovery release failure" `Quick
    (with_fs release_failure_on_existing);
  test_case "live origin owner protects its actual Prepared record" `Quick
    (with_fs live_owner_record);
  test_case "empty and corrupt immutable records never authorize replay" `Quick (with_fs malformed_retention);
  test_case "unsafe existing paths are refused" `Quick (with_fs unsafe_retention);
  test_case "cross-process first writer retains one origin" `Quick concurrent_first_writer]]
