open Alcotest

module Recovery = Masc.Keeper_turn_driver_try_provider
module Http = Llm_provider.Http_client

let network kind = Agent_core.Error.Api (Agent_core.Retry.NetworkError {kind; message="fixture"})

let test_peer_close_reconnects () =
  List.iter (fun kind ->
    let observed = ref [] in
    let result = Recovery.connection_recovery_sequence
      ~same_run_retry_authorized:(fun () -> true)
      ~attempt:(fun () -> Error (network kind), None, "failed")
      ~on_reconnect:(fun value -> observed := value :: !observed)
      ~reconnect:(fun () -> Ok "done", Some "fresh checkpoint", "fresh usage") () in
    check bool "fresh response, checkpoint and usage survive" true
      (result = (Ok "done", Some "fresh checkpoint", "fresh usage"));
    check bool "the exact transport cause is observed" true (!observed = [kind]))
    [Http.Connection_reset; End_of_file]
;;

let test_progress_fences_reconnect () =
  let failed = Error (network Http.End_of_file), Some "saved progress", "usage" in
  let result = Recovery.connection_recovery_sequence
    ~same_run_retry_authorized:(fun () -> false)
    ~attempt:(fun () -> failed)
    ~on_reconnect:(fun _ -> fail "progress cannot reconnect")
    ~reconnect:(fun () -> fail "saved tools cannot be replayed") () in
  check bool "failure and its saved progress remain unchanged" true (result == failed)
;;

let test_non_connection_failures_remain () =
  let errors = List.map network
    [Http.Connection_refused; Dns_failure; Unreachable; Tls_error; Timeout; Local_resource_exhaustion;
     Unknown]
    @ [Agent_core.Error.Config (Agent_core.Error.InvalidConfig {field="fixture"; detail="fixture"})] in
  List.iter (fun error ->
    let failed = Error error, None, () in
    let result = Recovery.connection_recovery_sequence
      ~same_run_retry_authorized:(fun () -> fail "not a peer close")
      ~attempt:(fun () -> failed)
      ~on_reconnect:(fun _ -> fail "not a peer close")
      ~reconnect:(fun () -> fail "not a peer close") () in
    check bool "unrelated failure is returned unchanged" true (result == failed)) errors
;;

let test_fresh_failure_is_not_replayed () =
  let reconnects = ref 0 in
  let fresh_failure = Error (network Http.Connection_reset), Some "fresh state", "usage" in
  let result = Recovery.connection_recovery_sequence
    ~same_run_retry_authorized:(fun () -> true)
    ~attempt:(fun () -> Error (network Http.End_of_file), None, "old usage")
    ~on_reconnect:(fun _ -> incr reconnects)
    ~reconnect:(fun () -> fresh_failure) () in
  check int "one transport transition, without another loop" 1 !reconnects;
  check bool "the fresh failure and its state survive" true (result == fresh_failure)
;;

let test_progress_during_request_revokes_reconnect () =
  let authorized = ref true in
  let failed = Error (network Http.End_of_file), None, () in
  let result = Recovery.connection_recovery_sequence
    ~same_run_retry_authorized:(fun () -> !authorized)
    ~attempt:(fun () -> authorized := false; failed)
    ~on_reconnect:(fun _ -> fail "stream/checkpoint progress already revoked recovery")
    ~reconnect:(fun () -> fail "the initial permission is no longer current") () in
  check bool "authority is checked after the failed request" true (result == failed)
;;

let () = run "keeper provider connection recovery"
  ["connection recovery", [
    test_case "peer close reconnects" `Quick test_peer_close_reconnects;
    test_case "checkpoint/effect authority fences reconnect" `Quick test_progress_fences_reconnect;
    test_case "unrelated failures remain" `Quick test_non_connection_failures_remain;
    test_case "fresh failure returns directly" `Quick test_fresh_failure_is_not_replayed;
    test_case "progress during the request revokes reconnect" `Quick test_progress_during_request_revokes_reconnect;
  ]]
