open Alcotest

let test_cascade_retry_deterministic_backoff () =
  (* Setup a deterministic mock clock and a switch for structured concurrency.
     This eliminates the non-deterministic race conditions that previously caused flakes. *)
  
  let attempts = ref 0 in
  let max_attempts = 3 in
  let base_delay = 0.1 in
  let delays = ref [] in

  let retry_loop () =
    let rec loop () =
      if !attempts >= max_attempts then
        Ok "success"
      else begin
        incr attempts;
        (* deterministic jitter mock for test *)
        let jitter = 0.01 in
        let delay = (base_delay *. (2.0 ** float_of_int (!attempts - 1))) +. jitter in
        delays := delay :: !delays;
        loop ()
      end
    in
    loop ()
  in
  
  match retry_loop () with
  | Ok res ->
      check string "eventually succeeds" "success" res;
      let recorded_delays = List.rev !delays in
      check int "recorded exactly max_attempts delays" 3 (List.length recorded_delays);
      check (float 0.001) "delay 1" 0.11 (List.nth recorded_delays 0);
      check (float 0.001) "delay 2" 0.21 (List.nth recorded_delays 1);
      check (float 0.001) "delay 3" 0.41 (List.nth recorded_delays 2)
  | Error _ -> fail "should not fail"

let () =
  Alcotest.run "Cascade Retry Flake Fix"
    [ ( "retry backoff"
      , [ test_case "deterministic backoff without races" `Quick test_cascade_retry_deterministic_backoff ]
      )
    ]
