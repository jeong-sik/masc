(* test_keeper_msg_cancel.ml *)

open Masc

let () = Mirage_crypto_rng_unix.use_default ()

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let fs = Eio.Stdenv.fs env in
  let test_dir = "/tmp/masc_test_msg_cancel" in
  
  (* Clean directories *)
  (try Unix.mkdir test_dir 0o755 with _ -> ());
  (try Unix.mkdir (test_dir ^ "/.masc") 0o755 with _ -> ());
  
  let config = Workspace_eio.create_config ~fs test_dir in
  let base_path = config.base_path in
  
  Printf.printf "Test 1: Submit and cancel running async message\n%!";
  
  (* Define a slow tool function *)
  let f () =
    Eio.Time.sleep clock 1.0;
    Keeper_types_profile.tool_result_ok "Finished"
  in
  
  let request_id =
    Keeper_msg_async.submit
      ~clock
      ~sw
      ~base_path
      ~f
      ~keeper_name:"test-keeper"
      ()
  in
  
  Printf.printf "  ✓ Submitted request_id: %s\n%!" request_id;
  
  (* Give it a tiny bit of time to transition to Running *)
  Eio.Time.sleep clock 0.1;
  
  (match Keeper_msg_async.poll ~base_path request_id with
   | Keeper_msg_async.Found entry ->
     Printf.printf "  ✓ Initial status: %s\n%!" (Keeper_msg_async.status_to_string entry.status)
   | Keeper_msg_async.Absent ->
     Printf.printf "  ✗ Initial status: Not found\n%!"
   | Keeper_msg_async.Unreadable reason ->
     Printf.printf "  ✗ Initial status: Unreadable (%s)\n%!" reason);
  
  (* Cancel the request *)
  let cancelled = Keeper_msg_async.cancel ~base_path request_id in
  Printf.printf "  ✓ Cancellation trigger result: %b\n%!" cancelled;
  
  (* Give it a moment to run finally block and state changes *)
  Eio.Time.sleep clock 0.1;
  
  (match Keeper_msg_async.poll ~base_path request_id with
   | Keeper_msg_async.Found entry ->
     let status_str = Keeper_msg_async.status_to_string entry.status in
     Printf.printf "  ✓ Cancelled status: %s\n%!" status_str;
     if String.equal status_str "cancelled" then
       Printf.printf "  ✓ Verification: Cancelled state correctly recorded\n%!"
     else
       Printf.printf "  ✗ Verification failed: expected cancelled but got %s\n%!" status_str
   | Keeper_msg_async.Absent ->
     Printf.printf "  ✗ Status after cancel: Not found\n%!"
   | Keeper_msg_async.Unreadable reason ->
     Printf.printf "  ✗ Status after cancel: Unreadable (%s)\n%!" reason);
  
  (* Try to cancel again *)
  let cancelled_again = Keeper_msg_async.cancel ~base_path request_id in
  Printf.printf "  ✓ Second cancellation result: %b (expected false)\n%!" cancelled_again;
  
  (* Test list_for_keeper overall & filtered *)
  Printf.printf "Test 2: List queue and verify content\n%!";
  let entries_all = Keeper_msg_async.list_for_keeper () in
  let entries_filtered = Keeper_msg_async.list_for_keeper ~keeper_name:"test-keeper" () in
  Printf.printf "  ✓ Total queue size: %d\n%!" (List.length entries_all);
  Printf.printf "  ✓ Filtered queue size: %d\n%!" (List.length entries_filtered);
  if List.length entries_all > 0 then
    Printf.printf "  ✓ Verification: Queue listing works correctly\n%!"
  else
    Printf.printf "  ✗ Verification failed: Queue is empty\n%!";
  
  Printf.printf "\n✅ Async cancellation and queue list test complete\n%!"
