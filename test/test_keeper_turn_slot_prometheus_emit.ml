(** Smoke test: Prometheus emits diagnostic gauges from the Keeper_turn_slot
    snapshotter that is auto-registered at module load.

    Goal: prove the lazy emit path called by [Prometheus.to_prometheus_text]
    populates [masc_keeper_turn_slot_max_held_seconds] and
    [masc_keeper_turn_slot_held_count] for each pool, and that
    [held_count >= 1] when a slot is held inside [with_keeper_turn_slot_for_test].
*)

module KK = Masc_mcp.Keeper_keepalive
module P = Masc_mcp.Prometheus

let with_eio body () =
  Eio_main.run @@ fun _env ->
    KK.reset_autonomous_completion_for_test ();
    KK.reset_autonomous_turn_queue_for_test ();
    body ()

let contains_substring ~haystack ~needle =
  let h_len = String.length haystack in
  let n_len = String.length needle in
  if n_len = 0 then true
  else
    let last = h_len - n_len in
    let rec loop i =
      if i > last then false
      else if String.sub haystack i n_len = needle then true
      else loop (i + 1)
    in
    loop 0

let test_gauges_present_when_no_slot_held () =
  let text = P.to_prometheus_text () in
  if not (contains_substring ~haystack:text
            ~needle:"masc_keeper_turn_slot_held_count") then
    failwith "expected masc_keeper_turn_slot_held_count series in /metrics text";
  if not (contains_substring ~haystack:text
            ~needle:"masc_keeper_turn_slot_max_held_seconds") then
    failwith
      "expected masc_keeper_turn_slot_max_held_seconds series in /metrics text"

let test_held_count_reflects_active_slot () =
  let result =
    KK.with_keeper_turn_slot_for_test
      ~keeper_name:"prom-test-keeper"
      ~channel:Masc_mcp.Keeper_world_observation.Scheduled_autonomous
      (fun ~semaphore_wait_ms:_ ->
        let text = P.to_prometheus_text () in
        (* When acquired via [Scheduled_autonomous] both pool=autonomous AND
           pool=turn pick up the keeper, since [with_keeper_turn_slot] takes
           the global turn slot too. Assert via substring rather than parse. *)
        if not (contains_substring ~haystack:text
                  ~needle:"masc_keeper_turn_slot_held_count{pool=\"autonomous\"} 1")
           && not (contains_substring ~haystack:text
                     ~needle:"masc_keeper_turn_slot_held_count{pool=\"turn\"} 1")
        then
          failwith
            "expected held_count=1 for autonomous or turn pool while slot held")
  in
  match result with
  | Ok () -> ()
  | Error (`Semaphore_wait_timeout _) ->
      failwith "unexpected semaphore wait timeout in test"

let () =
  let cases =
    [
      "diagnostic gauges always present in /metrics output",
        test_gauges_present_when_no_slot_held;
      "held_count reflects an active slot",
        test_held_count_reflects_active_slot;
    ]
  in
  List.iter
    (fun (name, body) ->
      try
        with_eio body ();
        Printf.printf "ok   %s\n" name
      with exn ->
        Printf.printf "FAIL %s: %s\n" name (Printexc.to_string exn);
        exit 1)
    cases
