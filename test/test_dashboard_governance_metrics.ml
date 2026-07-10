(** Tests for Dashboard_governance_metrics — tool rejection ring + approval queue. *)

module GM = Dashboard_governance_metrics
module P = Masc.Otel_metric_store

open Alcotest

let with_fresh f () =
  Eio_main.run (fun _env ->
    GM.reset_for_testing ();
    f ())

let now = 1_000_000.0

let inject ~tool ~reason ?(keeper="k1") ?(ts=now) () =
  GM.inject_for_testing ~keeper_name:keeper ~tool_name:tool ~reason_code:reason ~ts

let test_empty_ring () =
  let counts = GM.tool_rejection_counts ~now_ts:now ~window_minutes:60 () in
  check int "empty ring → no counts" 0 (List.length counts)

let test_single_rejection () =
  inject ~tool:"bash" ~reason:"denied" ();
  let counts = GM.tool_rejection_counts ~now_ts:(now +. 1.0) ~window_minutes:60 () in
  check int "one rejection" 1 (List.length counts);
  let (tool, reason, count) = List.hd counts in
  check string "tool" "bash" tool;
  check string "reason" "denied" reason;
  check int "count" 1 count

let test_window_filter () =
  inject ~tool:"old_tool" ~reason:"r1" ~ts:(now -. 7200.0) ();
  inject ~tool:"new_tool" ~reason:"r1" ~ts:now ();
  let counts = GM.tool_rejection_counts ~now_ts:(now +. 1.0) ~window_minutes:1 () in
  check int "only recent in 1m window" 1 (List.length counts);
  let (tool, _, _) = List.hd counts in
  check string "recent tool" "new_tool" tool

let test_deterministic_sort () =
  inject ~tool:"zz_tool" ~reason:"r1" ();
  inject ~tool:"aa_tool" ~reason:"r1" ();
  inject ~tool:"aa_tool" ~reason:"r1" ();
  let counts = GM.tool_rejection_counts ~now_ts:(now +. 1.0) ~window_minutes:60 () in
  check int "two distinct pairs" 2 (List.length counts);
  let (first_tool, _, first_count) = List.hd counts in
  check string "higher count first" "aa_tool" first_tool;
  check int "aa_tool count" 2 first_count;
  let (second_tool, _, _) = List.nth counts 1 in
  check string "tie-break: tool asc" "zz_tool" second_tool

let test_ring_caps_oldest_event () =
  let max_ring_size = GM.max_ring_size_for_testing in
  inject ~tool:"bash" ~reason:"oldest" ();
  for _ = 1 to max_ring_size do
    inject ~tool:"bash" ~reason:"kept" ()
  done;
  check int "ring size remains capped" max_ring_size (GM.ring_size_for_testing ());
  let counts = GM.tool_rejection_counts ~now_ts:(now +. 1.0) ~window_minutes:60 () in
  check int "only kept reason remains" 1 (List.length counts);
  let (tool, reason, count) = List.hd counts in
  check string "tool" "bash" tool;
  check string "oldest reason pruned" "kept" reason;
  check int "kept count" max_ring_size count

let test_approval_summary_empty () =
  let summary = GM.approval_queue_summary ~base_path:"" in
  check int "empty queue depth" 0 summary.depth;
  check bool "p50 None" true (Option.is_none summary.p50_wait_sec);
  check bool "oldest None" true (Option.is_none summary.oldest_pending_sec)

let test_json_shape () =
  inject ~tool:"bash" ~reason:"policy" ();
  let json =
    GM.governance_tool_events_json
      ~now_ts:(now +. 1.0)
      ~base_path:""
      ~window_minutes:60
      ()
  in
  let open Yojson.Safe.Util in
  let rejections = json |> member "tool_rejections" |> to_list in
  check bool "has rejections" true (List.length rejections > 0);
  let q = json |> member "approval_queue" in
  let depth = q |> member "depth" |> to_int in
  check bool "depth is int" true (depth >= 0);
  let window = json |> member "window_minutes" |> to_int in
  check int "window propagated" 60 window

let test_record_failure_is_metric_visible () =
  let labels =
    [ ("callback", "dashboard_governance_tool_skipped_record") ]
  in
  let before =
    P.metric_value_or_zero
      Keeper_metrics.(to_string LifecycleCallbackFailures)
      ~labels
      ()
  in
  GM.record_tool_skipped_with_append_for_testing
    ~append:(fun () -> raise (Failure "synthetic ring failure"))
    ~keeper_name:"k1"
    ~tool_name:"bash"
    ~reason_code:"policy";
  let after =
    P.metric_value_or_zero
      Keeper_metrics.(to_string LifecycleCallbackFailures)
      ~labels
      ()
  in
  check (float 0.0001) "ring failure metric increments" (before +. 1.0) after;
  let counts = GM.tool_rejection_counts ~now_ts:now ~window_minutes:60 () in
  check int "failed append does not create a phantom event" 0 (List.length counts)

let () =
  run "Dashboard_governance_metrics" [
    "tool_rejection_counts", [
      test_case "empty ring" `Quick (with_fresh test_empty_ring);
      test_case "single rejection" `Quick (with_fresh test_single_rejection);
      test_case "window filter" `Quick (with_fresh test_window_filter);
      test_case "deterministic sort" `Quick (with_fresh test_deterministic_sort);
      test_case "ring caps oldest event" `Quick (with_fresh test_ring_caps_oldest_event);
    ];
    "approval_queue", [
      test_case "empty queue summary" `Quick test_approval_summary_empty;
    ];
    "json", [
      test_case "json shape" `Quick (with_fresh test_json_shape);
    ];
    "failure_visibility", [
      test_case "record failure increments metric" `Quick
        (with_fresh test_record_failure_is_metric_visible);
    ];
  ]
