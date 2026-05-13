(* test/test_keeper_long_turn_9943.ml

   #9943 reports a 20-minute turn where the post-turn
   compaction step appears to no-op and the turn keeps
   running.  Several adjacent issues report the same
   "long-running turn that nobody noticed" symptom from
   different angles (#9982 trust pause, #10121 livelock).

   This test pins the observability surface that surfaces
   such turns directly to Prometheus instead of leaving
   the duration trapped in a single info log line:

     1. The bucket vocabulary is bounded to five labels
        ([under_60s | 60-300s | 300-600s | 600-1200s |
        over_1200s]) so [keeper × bucket] cardinality is
        bounded at runtime.
     2. Bucket boundaries are inclusive on the lower end
        (60_000 ms classifies as [60-300s], 600_000 ms as
        [600-1200s], 1_200_000 ms as [over_1200s]).
     3. [record_turn_latency_bucket] increments the matching
        bucket counter and is keeper-isolated.
     4. The WARN threshold reads
        [MASC_KEEPER_LONG_TURN_WARN_MS] on each call (default
        600_000 = 10 min) so operators can dial it without
        a restart.
*)

let () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-keeper-long-turn-9943-%06x"
         (Random.bits ()))
  in
  Unix.putenv "MASC_BASE_PATH" dir

module M = Masc_mcp.Keeper_unified_metrics
module Prom = Masc_mcp.Prometheus

let bucket_count ~keeper ~bucket =
  Prom.metric_value_or_zero
    Masc_mcp.Keeper_metrics.metric_keeper_turn_latency_bucket
    ~labels:[ ("keeper", keeper); ("bucket", bucket) ]
    ()

let model_bucket_count ~keeper ~channel ~provider_kind ~model_used
    ~resolved_model_id ~cascade_profile ~bucket =
  Prom.metric_value_or_zero
    Masc_mcp.Keeper_metrics.metric_keeper_turn_latency_by_model_bucket
    ~labels:
      [ ("keeper", keeper)
      ; ("channel", channel)
      ; ("provider_kind", provider_kind)
      ; ("model_used", model_used)
      ; ("resolved_model_id", resolved_model_id)
      ; ("cascade_profile", cascade_profile)
      ; ("bucket", bucket)
      ]
    ()

(* Bucket vocabulary is exactly five labels.  Shrinking or
   exploding this set is a breaking dashboard change. *)
let test_bucket_vocabulary () =
  let cases =
    [ 0, "under_60s"
    ; 30_000, "under_60s"
    ; 59_999, "under_60s"
    ; 60_000, "60-300s"
    ; 299_999, "60-300s"
    ; 300_000, "300-600s"
    ; 599_999, "300-600s"
    ; 600_000, "600-1200s"
    ; 1_199_999, "600-1200s"
    ; 1_200_000, "over_1200s"
    ; 7_200_000, "over_1200s"
    ]
  in
  List.iter
    (fun (ms, expected) ->
      Alcotest.(check string)
        (Printf.sprintf "%d ms -> %s" ms expected)
        expected
        (M.turn_latency_bucket ms))
    cases

(* The boundary 60_000 must classify as [60-300s], not
   [under_60s].  This is the smallest "this turn looked
   suspicious" boundary and getting it wrong by a single
   millisecond turns into a dashboard step-change. *)
let test_bucket_boundaries () =
  Alcotest.(check string) "59_999 -> under_60s"
    "under_60s" (M.turn_latency_bucket 59_999);
  Alcotest.(check string) "60_000 -> 60-300s"
    "60-300s" (M.turn_latency_bucket 60_000);
  Alcotest.(check string) "599_999 -> 300-600s"
    "300-600s" (M.turn_latency_bucket 599_999);
  Alcotest.(check string) "600_000 -> 600-1200s"
    "600-1200s" (M.turn_latency_bucket 600_000);
  Alcotest.(check string) "1_199_999 -> 600-1200s"
    "600-1200s" (M.turn_latency_bucket 1_199_999);
  Alcotest.(check string) "1_200_000 -> over_1200s"
    "over_1200s" (M.turn_latency_bucket 1_200_000)

(* Recording a single observation increments exactly one
   bucket on the labelled keeper. *)
let test_record_increments_matching_bucket () =
  let keeper = "test-keeper-long-turn-9943-record" in
  let before = bucket_count ~keeper ~bucket:"60-300s" in
  M.record_turn_latency_bucket ~keeper ~latency_ms:120_000;
  Alcotest.(check (float 0.0001))
    "60-300s bucket +1"
    (before +. 1.0)
    (bucket_count ~keeper ~bucket:"60-300s");
  Alcotest.(check (float 0.0001))
    "under_60s bucket unchanged"
    0.0
    (bucket_count ~keeper ~bucket:"under_60s");
  Alcotest.(check (float 0.0001))
    "over_1200s bucket unchanged"
    0.0
    (bucket_count ~keeper ~bucket:"over_1200s")

(* Per-keeper isolation: keeper A's long turns do not
   leak into keeper B's bucket counter. *)
let test_keeper_isolation () =
  let a = "test-keeper-long-turn-iso-A-9943" in
  let b = "test-keeper-long-turn-iso-B-9943" in
  let before_b = bucket_count ~keeper:b ~bucket:"over_1200s" in
  M.record_turn_latency_bucket ~keeper:a ~latency_ms:1_500_000;
  M.record_turn_latency_bucket ~keeper:a ~latency_ms:1_800_000;
  Alcotest.(check (float 0.0001))
    "keeper B over_1200s unchanged by keeper A"
    before_b
    (bucket_count ~keeper:b ~bucket:"over_1200s")

(* WARN threshold default is 10 minutes.  Crossing it
   trips the warn log, but the bucket is still counted —
   logs are not the gate. *)
let test_warn_threshold_default_is_ten_minutes () =
  Alcotest.(check int) "default 600_000 ms"
    600_000 M.long_turn_warn_threshold_ms_default;
  let env = M.long_turn_warn_threshold_ms () in
  Alcotest.(check bool)
    "threshold reads positive ms"
    true (env > 0)

(* Threshold is read on every call, not cached at module
   init.  Operators flip the env var via the running
   process's [Unix.putenv] equivalent. *)
let test_warn_threshold_reads_env () =
  let saved =
    try Some (Unix.getenv "MASC_KEEPER_LONG_TURN_WARN_MS")
    with Not_found -> None
  in
  Unix.putenv "MASC_KEEPER_LONG_TURN_WARN_MS" "300000";
  let observed = M.long_turn_warn_threshold_ms () in
  Alcotest.(check int) "threshold honours env override"
    300_000 observed;
  (match saved with
   | Some v -> Unix.putenv "MASC_KEEPER_LONG_TURN_WARN_MS" v
   | None -> Unix.putenv "MASC_KEEPER_LONG_TURN_WARN_MS" "")

let test_provider_kind_of_model_used () =
  Alcotest.(check string) "claude_code label"
    "claude_code" (M.provider_kind_of_model_used "claude_code:auto");
  Alcotest.(check string) "kimi_cli label"
    "kimi_cli" (M.provider_kind_of_model_used " kimi_cli:kimi-for-coding ");
  Alcotest.(check string) "direct api prefix stays distinct from cli"
    "claude" (M.provider_kind_of_model_used "claude:auto");
  Alcotest.(check string) "unknown prefixed label is not trusted"
    "unknown" (M.provider_kind_of_model_used "pretend_provider:model");
  Alcotest.(check string) "custom endpoint label remains bounded"
    "custom" (M.provider_kind_of_model_used "custom:model@https://example.test/v1");
  Alcotest.(check string) "unprefixed"
    "unknown" (M.provider_kind_of_model_used "gpt-5.4");
  Alcotest.(check string) "empty"
    "unknown" (M.provider_kind_of_model_used "")

let test_record_by_model_bucket () =
  let keeper = "test-keeper-provider-latency-9933" in
  let before =
    model_bucket_count
      ~keeper
      ~channel:"scheduled_autonomous"
      ~provider_kind:"claude_code"
      ~model_used:"claude_code:auto"
      ~resolved_model_id:"claude-sonnet-4.7"
      ~cascade_profile:"primary"
      ~bucket:"over_1200s"
  in
  M.record_turn_latency_by_model_bucket
    ~keeper
    ~channel:"scheduled_autonomous"
    ~model_used:"claude_code:auto"
    ~resolved_model_id:"claude-sonnet-4.7"
    ~cascade_profile:"primary"
    ~latency_ms:1_200_000;
  Alcotest.(check (float 0.0001))
    "by-model over_1200s bucket +1"
    (before +. 1.0)
    (model_bucket_count
       ~keeper
       ~channel:"scheduled_autonomous"
       ~provider_kind:"claude_code"
       ~model_used:"claude_code:auto"
       ~resolved_model_id:"claude-sonnet-4.7"
       ~cascade_profile:"primary"
       ~bucket:"over_1200s");
  Alcotest.(check (float 0.0001))
    "different cascade unchanged"
    0.0
    (model_bucket_count
       ~keeper
       ~channel:"scheduled_autonomous"
       ~provider_kind:"claude_code"
       ~model_used:"claude_code:auto"
       ~resolved_model_id:"claude-sonnet-4.7"
       ~cascade_profile:"tool_use_strict"
       ~bucket:"over_1200s")

let () =
  Alcotest.run "keeper_long_turn_9943"
    [
      ( "bucket-vocabulary",
        [
          Alcotest.test_case "five labels, exhaustive" `Quick
            test_bucket_vocabulary;
          Alcotest.test_case "boundaries land correctly" `Quick
            test_bucket_boundaries;
        ] );
      ( "record",
        [
          Alcotest.test_case "matching bucket increments" `Quick
            test_record_increments_matching_bucket;
          Alcotest.test_case "per-keeper isolation" `Quick
            test_keeper_isolation;
        ] );
      ( "warn-threshold",
        [
          Alcotest.test_case "default is 10 minutes" `Quick
            test_warn_threshold_default_is_ten_minutes;
          Alcotest.test_case "reads env per call" `Quick
            test_warn_threshold_reads_env;
        ] );
      ( "provider-model",
        [
          Alcotest.test_case "provider kind from model surface" `Quick
            test_provider_kind_of_model_used;
          Alcotest.test_case "records by model/cascade bucket" `Quick
            test_record_by_model_bucket;
        ] );
    ]
