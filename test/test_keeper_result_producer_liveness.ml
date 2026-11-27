open Alcotest
open Masc
module Outbox = Keeper_client_tool_outbox
let get = function Ok value -> value | Error detail -> fail detail
let keeper_name = "producer-owner"
let retain producer =
  get (Outbox.retain_host_result producer ~invocation_index:0 ~call_id:"same-client-id"
    ~tool_name:"effect" ~arguments:(Outbox.Known (`Assoc ["owner",`String keeper_name]))
    ~response:(`Assoc ["content",`String "ORIGINAL_EFFECT_RESULT"]))
let load base_path = get (Outbox.load ~base_path ~keeper_name ~viewer:Outbox.Every_receipt)
let ids base_path = Outbox.receipt_ids (load base_path)

let () =
  if Array.length Sys.argv = 4 && Sys.argv.(1) = "--hold-result-producer" then (
    Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
      Fs_compat.set_fs env#fs;
      let producer = get (Outbox.start_host_producer ~sw ~base_path:Sys.argv.(2)
        ~keeper_name:Sys.argv.(3) ~runtime_label:"child-producer" ~turn_count:1) in
      retain producer;
      output_char stdout 'R'; flush stdout;
      Eio_unix.run_in_systhread (fun () -> ignore (input_char stdin))));
    exit 0)

let with_workspace f =
  let base_path = Filename.temp_dir "keeper-result-producer-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () -> f base_path)

let test_same_process_owner_and_independent_result () = with_workspace (fun base_path ->
  Eio_main.run (fun env ->
    Fs_compat.set_fs env#fs;
    Eio.Switch.run (fun sw ->
      let producer = get (Outbox.start_host_producer ~sw ~base_path ~keeper_name
        ~runtime_label:"active-producer" ~turn_count:1) in
      retain producer;
      check (list string) "own live result is not a wake or consumption source" [] (ids base_path);
      let independent : Outbox.receipt =
        {thread_id="finished-vendor";turn_id="finished-turn";call_id="other-original";
         tool_name="independent";arguments=Outbox.Known (`Assoc []);response=`String "independent-result"} in
      get (Outbox.retain ~base_path ~keeper_name independent);
      let ready = load base_path in
      check int "independent result remains available" 1 (List.length (Outbox.receipt_ids ready));
      get (Outbox.acknowledge ready);
      check (list string) "closing inspection and ACK do not drop the live producer lease"
        [] (ids base_path)));
  let ready = load base_path in
  check int "normal scope end exposes the original result" 1 (List.length (Outbox.receipt_ids ready));
  check bool "original returned bytes survived" true
    (String_util.contains_substring (String.concat "" (Outbox.developer_context ready))
      "ORIGINAL_EFFECT_RESULT");
  get (Outbox.acknowledge ready);
  check (list string) "only exact completed consumption removes the original" [] (ids base_path))

let test_cancellation_releases_owner_without_consuming () = with_workspace (fun base_path ->
  let raised = match
    Eio_main.run (fun env ->
      Fs_compat.set_fs env#fs;
      Eio.Switch.run (fun sw ->
        let producer = get (Outbox.start_host_producer ~sw ~base_path ~keeper_name
          ~runtime_label:"cancelled-producer" ~turn_count:2) in
        retain producer;
        check (list string) "producer is active before cancellation" [] (ids base_path);
        raise Exit))
  with
  | () -> false
  | exception Exit -> true in
  check bool "original owner exception propagates" true raised;
  check int "cancelled owner releases its exact original without ACK" 1 (List.length (ids base_path)))

let test_cancelled_owner_keeps_lease_until_protected_worker_drains () = with_workspace (fun base_path ->
  Eio_main.run (fun env -> Eio.Switch.run (fun outer_scope ->
    Fs_compat.set_fs env#fs;
    let owner_ready, signal_owner_ready = Eio.Promise.create () in
    let worker_ready, signal_worker_ready = Eio.Promise.create () in
    let worker_draining, signal_worker_draining = Eio.Promise.create () in
    let worker_release, release_worker = Eio.Promise.create () in
    let owner_done, signal_owner_done = Eio.Promise.create () in
    Eio.Fiber.fork ~sw:outer_scope (fun () ->
      let original_interrupt =
        match Eio.Switch.run (fun owner_scope ->
            let producer = get (Outbox.start_host_producer ~sw:owner_scope ~base_path ~keeper_name
              ~runtime_label:"protected-settlement-producer" ~turn_count:3) in
            Eio.Fiber.fork ~sw:owner_scope (fun () ->
              Eio.Promise.resolve signal_worker_ready ();
              try Eio.Fiber.await_cancel () with
              | Eio.Cancel.Cancelled _ as exn ->
                Eio.Cancel.protect (fun () ->
                  (* A real worker can publish its completed original while
                     the cancelled owner is still draining its settlement. *)
                  retain producer;
                  Eio.Promise.resolve signal_worker_draining ();
                  Eio.Promise.await worker_release);
                raise exn);
            Eio.Promise.await worker_ready;
            Eio.Promise.resolve signal_owner_ready owner_scope;
            Eio.Fiber.await_cancel ())
        with
        | () -> false
        | exception exn when Keeper_registry_types.is_operator_interrupt exn -> true in
      Eio.Promise.resolve signal_owner_done original_interrupt);
    let owner_scope = Eio.Promise.await owner_ready in
    Eio.Switch.fail owner_scope Keeper_registry_types.Operator_interrupt;
    Eio.Promise.await worker_draining;
    Fun.protect ~finally:(fun () -> Eio.Promise.resolve release_worker ()) (fun () ->
      check bool "owner cannot finish while protected settlement is blocked" true
        (Eio.Promise.peek owner_done=None);
      check (list string) "outside consumer cannot load original during protected worker drain"
        [] (ids base_path));
    check bool "the owner's original typed cancellation survives worker drain" true
      (Eio.Promise.await owner_done);
    let ready = load base_path in
    check int "switch release exposes the original only after every worker drains" 1
      (List.length (Outbox.receipt_ids ready));
    check bool "worker settlement retains its exact returned bytes without ACK" true
      (String_util.contains_substring (String.concat "" (Outbox.developer_context ready))
        "ORIGINAL_EFFECT_RESULT"))))

let test_other_process_crash_releases_original () = with_workspace (fun base_path ->
  let child_input, parent_input = Unix.pipe ~cloexec:true () in
  let parent_output, child_output = Unix.pipe ~cloexec:true () in
  let child = Unix.create_process Sys.executable_name
      [|Sys.executable_name;"--hold-result-producer";base_path;keeper_name|]
      child_input child_output Unix.stderr in
  Unix.close child_input; Unix.close child_output;
  let rec waitpid_eintr pid =
    match Unix.waitpid [] pid with
    | result -> result
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> waitpid_eintr pid
  in
  let reaped = ref false in
  Fun.protect ~finally:(fun () ->
    Unix.close parent_input; Unix.close parent_output;
    if not !reaped then (
      (try Unix.kill child Sys.sigkill with Unix.Unix_error (Unix.ESRCH,_,_) -> ());
      ignore (waitpid_eintr child))) (fun () ->
    let readable, _, _ = Unix.select [parent_output] [] [] 10.0 in
    check bool "actual child publishes a retained original" true (readable <> []);
    let marker = Bytes.create 1 in
    check int "child readiness byte" 1 (Unix.read parent_output marker 0 1);
    check string "child holds its producer" "R" (Bytes.to_string marker);
    check (list string) "another process cannot wake/consume the live original" [] (ids base_path);
    Unix.kill child Sys.sigkill;
    let _, status = waitpid_eintr child in
    reaped := true;
    check bool "the actual producer process ended" true
      (match status with Unix.WSIGNALED signal -> signal=Sys.sigkill | WEXITED _ | WSTOPPED _ -> false);
    check int "kernel release exposes the original after crash" 1 (List.length (ids base_path))))

let lease_files base_path =
  let root = Filename.concat
      (Filename.dirname (get (Keeper_official_client_session_store.path ~base_path ~keeper_name)))
      "tool-result-producer-leases" in
  if Sys.file_exists root && Sys.is_directory root
  then Sys.readdir root |> Array.to_list |> List.sort String.compare
  else []

let test_missing_lease_is_not_inactive_authority () = with_workspace (fun base_path ->
  let producer = get (Outbox.host_producer ~base_path ~keeper_name
      ~runtime_label:"missing-authority" ~turn_count:1) in
  retain producer;
  let root = Filename.concat
      (Filename.dirname (get (Keeper_official_client_session_store.path ~base_path ~keeper_name)))
      "tool-result-producer-leases" in
  let name = match Sys.readdir root |> Array.to_list with
    | [name] -> name | _ -> fail "one producer lease expected" in
  Sys.remove (Filename.concat root name);
  match Outbox.load ~base_path ~keeper_name ~viewer:Outbox.Every_receipt with
  | Error _ -> ()
  | Ok _ -> fail "missing producer authority became an inactive/empty success")

let test_finished_producer_cleans_up_unused_lease () = with_workspace (fun base_path ->
  Eio_main.run (fun env ->
    Fs_compat.set_fs env#fs;
    (* Turn with zero tool calls cleans up its lease on switch exit. *)
    Eio.Switch.run (fun sw ->
      let _producer = get (Outbox.start_host_producer ~sw ~base_path ~keeper_name
        ~runtime_label:"no-tools-producer" ~turn_count:1) in
      check int "live producer holds one lease file" 1 (List.length (lease_files base_path)));
    check (list string) "unused lease is removed when switch exits" [] (lease_files base_path);
    (* Turn that retains and ACKs all its receipts before switch exit also cleans up its lease. *)
    Eio.Switch.run (fun sw ->
      let producer = get (Outbox.start_host_producer ~sw ~base_path ~keeper_name
        ~runtime_label:"completed-turn-producer" ~turn_count:2) in
      let delivery = get (Outbox.retain_host_result_with_delivery producer ~invocation_index:0
        ~call_id:"completed-call" ~tool_name:"effect"
        ~arguments:(Outbox.Known (`Assoc [])) ~response:(`Assoc ["ok", `Bool true])) in
      Outbox.mark_response_sent delivery;
      let frontier = Outbox.close_delivery_frontier producer in
      get (Outbox.settle_after_turn frontier ~stop_reason:(Completed {provider_turn_ordinal=1}));
      check int "live producer keeps lease until switch exits" 1 (List.length (lease_files base_path)));
    check (list string) "acknowledged producer lease is removed on switch exit" [] (lease_files base_path)))

let test_acknowledge_cleans_up_inactive_producer_lease_after_last_receipt () = with_workspace (fun base_path ->
  Eio_main.run (fun env ->
    Fs_compat.set_fs env#fs;
    Eio.Switch.run (fun sw ->
      let producer = get (Outbox.start_host_producer ~sw ~base_path ~keeper_name
        ~runtime_label:"interrupted-producer" ~turn_count:1) in
      get (Outbox.retain_host_result producer ~invocation_index:0 ~call_id:"call-a"
        ~tool_name:"effect" ~arguments:(Outbox.Known (`Assoc [])) ~response:(`String "res-a"));
      get (Outbox.retain_host_result producer ~invocation_index:1 ~call_id:"call-b"
        ~tool_name:"effect" ~arguments:(Outbox.Known (`Assoc [])) ~response:(`String "res-b")));
    check int "lease survives switch exit while pending receipts remain" 1
      (List.length (lease_files base_path));
    let ready = load base_path in
    check int "both pending receipts load cleanly" 2 (List.length (Outbox.receipt_ids ready));
    get (Outbox.acknowledge ready);
    check (list string) "pending receipts retired" [] (ids base_path);
    check (list string) "inactive lease is removed once its last receipt is acknowledged"
      [] (lease_files base_path)))

let test_prune_stale_leases_preserves_live_and_referenced_and_fails_closed () = with_workspace (fun base_path ->
  Eio_main.run (fun env ->
    Fs_compat.set_fs env#fs;
    (* Create two stale standalone leases: one unreferenced, one referenced by a pending receipt. *)
    let _stale_unreferenced = get (Outbox.host_producer ~base_path ~keeper_name
      ~runtime_label:"stale-unreferenced" ~turn_count:1) in
    let stale_referenced = get (Outbox.host_producer ~base_path ~keeper_name
      ~runtime_label:"stale-referenced" ~turn_count:2) in
    retain stale_referenced;
    Eio.Switch.run (fun sw ->
      (* Manually call prune while a live producer holds its flock; note start_host_producer
         also prunes stale unreferenced leases once on startup, so create another stale one after. *)
      let _live = get (Outbox.start_host_producer ~sw ~base_path ~keeper_name
        ~runtime_label:"live-producer" ~turn_count:3) in
      check int "startup sweep already removed unreferenced stale lease, keeping live + referenced" 2
        (List.length (lease_files base_path));
      let _stale_after = get (Outbox.host_producer ~base_path ~keeper_name
        ~runtime_label:"stale-after" ~turn_count:4) in
      check int "three leases present before explicit prune" 3 (List.length (lease_files base_path));
      let removed = get (Outbox.prune_stale_leases ~base_path ~keeper_name) in
      check int "explicit prune removes only the unreferenced unlocked lease" 1 removed;
      check int "live lease and referenced lease both survive prune" 2
        (List.length (lease_files base_path)));
    (* Live producer exited with zero retained receipts, so only the referenced lease remains. *)
    check int "only referenced lease remains after live switch ends" 1
      (List.length (lease_files base_path));
    check int "referenced pending receipt still loads cleanly" 1 (List.length (ids base_path));
    (* Corrupt outbox makes prune_stale_leases fail closed and remove nothing. *)
    let _extra_stale = get (Outbox.host_producer ~base_path ~keeper_name
      ~runtime_label:"extra-stale" ~turn_count:5) in
    let outbox_dir = Filename.concat
      (Filename.dirname (get (Keeper_official_client_session_store.path ~base_path ~keeper_name)))
      "undelivered-tools" in
    Fs_compat.save_file (Filename.concat outbox_dir "corrupt.json") "{not-valid-json";
    (match Outbox.prune_stale_leases ~base_path ~keeper_name with
     | Error _ -> ()
     | Ok _ -> fail "prune_stale_leases must fail closed on corrupt outbox");
    check int "fail-closed prune removes zero leases" 2 (List.length (lease_files base_path))))

let test_cancelled_switch_exit_cleans_up_unused_lease () =
  Eio_main.run (fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    with_workspace (fun base_path ->
      let exception Cancelled_turn in
      (match
         Eio.Switch.run (fun sw ->
           let _producer = get (Outbox.start_host_producer ~sw ~base_path ~keeper_name
             ~runtime_label:"cancelled-unused" ~turn_count:1) in
           check int "lease exists before switch cancellation" 1
             (List.length (lease_files base_path));
           Eio.Switch.fail sw Cancelled_turn;
           Eio.Fiber.yield ())
       with
       | () -> fail "expected cancelled switch failure"
       | exception Cancelled_turn -> ());
      check (list string) "cancelled switch exit cleans up unused lease without clobbering exn"
        [] (lease_files base_path)))

let () = run "Keeper result producer liveness"
  ["ownership",[
    test_case "same process owner excludes itself while independent results progress" `Quick
      test_same_process_owner_and_independent_result;
    test_case "owner cancellation preserves and exposes original result" `Quick
      test_cancellation_releases_owner_without_consuming;
    test_case "cancelled owner excludes results through protected worker drain" `Quick
      test_cancelled_owner_keeps_lease_until_protected_worker_drains;
    test_case "separate live process excludes results until actual crash" `Quick
      test_other_process_crash_releases_original;
    test_case "missing authority is not proof of owner completion" `Quick
      test_missing_lease_is_not_inactive_authority;
    test_case "finished producer cleans up unused lease on switch exit" `Quick
      test_finished_producer_cleans_up_unused_lease;
    test_case "acknowledge removes inactive producer lease after last receipt" `Quick
      test_acknowledge_cleans_up_inactive_producer_lease_after_last_receipt;
    test_case "prune_stale_leases preserves live and referenced leases and fails closed" `Quick
      test_prune_stale_leases_preserves_live_and_referenced_and_fails_closed;
    test_case "cancelled switch exit cleans up unused lease" `Quick
      test_cancelled_switch_exit_cleans_up_unused_lease]]
