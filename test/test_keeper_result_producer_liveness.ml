open Alcotest
open Masc
module Outbox = Keeper_client_tool_outbox
let get = function Ok value -> value | Error detail -> fail detail
let keeper_name = "producer-owner"
let retain producer =
  get (Outbox.retain_host_result producer ~invocation_index:0 ~call_id:"same-client-id"
    ~tool_name:"effect" ~arguments:(`Assoc ["owner",`String keeper_name])
    ~response:(`Assoc ["content",`String "ORIGINAL_EFFECT_RESULT"]))
let load base_path = get (Outbox.load ~base_path ~keeper_name)
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
         tool_name="independent";arguments=`Assoc [];response=`String "independent-result"} in
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
  let reaped = ref false in
  Fun.protect ~finally:(fun () ->
    Unix.close parent_input; Unix.close parent_output;
    if not !reaped then (
      (try Unix.kill child Sys.sigkill with Unix.Unix_error (Unix.ESRCH,_,_) -> ());
      ignore (Unix.waitpid [] child))) (fun () ->
    let readable, _, _ = Unix.select [parent_output] [] [] 10.0 in
    check bool "actual child publishes a retained original" true (readable <> []);
    let marker = Bytes.create 1 in
    check int "child readiness byte" 1 (Unix.read parent_output marker 0 1);
    check string "child holds its producer" "R" (Bytes.to_string marker);
    check (list string) "another process cannot wake/consume the live original" [] (ids base_path);
    Unix.kill child Sys.sigkill;
    let _, status = Unix.waitpid [] child in
    reaped := true;
    check bool "the actual producer process ended" true
      (match status with Unix.WSIGNALED signal -> signal=Sys.sigkill | WEXITED _ | WSTOPPED _ -> false);
    check int "kernel release exposes the original after crash" 1 (List.length (ids base_path))))

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
  match Outbox.load ~base_path ~keeper_name with
  | Error _ -> ()
  | Ok _ -> fail "missing producer authority became an inactive/empty success")

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
      test_missing_lease_is_not_inactive_authority]]
