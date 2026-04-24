(* test/test_context_max_observed_9953.ml

   #9953: same model label was recording 3 different
   [context_max] values across turns (claude_code:auto getting
   42% / 17% / 41% split between 64k / 262k / 1M).  The data was
   in the JSONL ledger but invisible to Prometheus dashboards.

   This test pins:
     1. The [context_max_bucket] string vocabulary — dashboards
        and runbooks key off these literals, so a future change
        is an explicit decision.
     2. Boundary behaviour for each bucket transition (off-by-
        one regression guard).
     3. The counter increments on the bucket inferred from the
        observed value, with the labels operators expect.
     4. Per-(keeper, model_used, resolved_model_id) bucket
        isolation — a turn that lands in [200k] must not leak
        into the [256k] bucket for the same keeper.

   The point of the metric is that
   [count by (model_used, resolved_model_id)
            (masc_keeper_context_max_observed_total)] returning
   > 1 directly indicates drift.  Test #4 pins this counting
   contract by exercising two distinct buckets for one
   (model_used, resolved_model_id) and asserting both labels
   carry the expected count. *)

let () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-context-max-observed-9953-%06x"
         (Random.bits ()))
  in
  Unix.putenv "MASC_BASE_PATH" dir

module UM = Masc_mcp.Keeper_unified_metrics
module Prom = Masc_mcp.Prometheus

let metric = Prom.metric_keeper_context_max_observed

let counter_for ~keeper ~model_used ~resolved_model_id ~bucket =
  Prom.metric_value_or_zero metric
    ~labels:[
      ("keeper", keeper);
      ("model_used", model_used);
      ("resolved_model_id", resolved_model_id);
      ("context_max_bucket", bucket);
    ] ()

(* Pin the vocabulary: an exhaustive table of representative
   inputs and the bucket each must land in.  Adding a new
   bucket / changing a boundary is now an explicit change. *)
let test_bucket_vocabulary () =
  let cases =
    [
      0,         "zero";
      -1,        "zero";       (* clamp negative to zero bucket *)
      1,         "64k";
      32_000,    "64k";
      64_000,    "64k";
      64_001,    "128k";
      128_000,   "128k";
      128_001,   "200k";
      200_000,   "200k";
      200_001,   "256k";
      262_144,   "256k";
      262_145,   "1m";
      1_000_000, "1m";
      1_048_576, "1m";
      1_048_577, "other";
      5_000_000, "other";
    ]
  in
  List.iter
    (fun (input, expected) ->
      Alcotest.(check string)
        (Printf.sprintf "context_max_bucket %d" input)
        expected (UM.context_max_bucket input))
    cases

(* Boundary regression: each transition is +1 / -1 from the
   threshold.  Splitting these out makes a failure name the
   exact off-by-one. *)
let test_bucket_boundary_64k () =
  Alcotest.(check string) "64_000 → 64k" "64k"
    (UM.context_max_bucket 64_000);
  Alcotest.(check string) "64_001 → 128k" "128k"
    (UM.context_max_bucket 64_001)

let test_bucket_boundary_256k () =
  Alcotest.(check string) "262_144 → 256k" "256k"
    (UM.context_max_bucket 262_144);
  Alcotest.(check string) "262_145 → 1m" "1m"
    (UM.context_max_bucket 262_145)

let test_bucket_boundary_1m () =
  Alcotest.(check string) "1_048_576 → 1m" "1m"
    (UM.context_max_bucket 1_048_576);
  Alcotest.(check string) "1_048_577 → other" "other"
    (UM.context_max_bucket 1_048_577)

(* The counter increments on the inferred bucket and labels are
   isolated across (keeper, model_used, resolved_model_id). *)
let test_record_increments_correct_bucket () =
  let keeper = "test-keeper-9953" in
  let model = "claude_code:auto-9953" in
  let resolved = "anthropic-claude-opus-4-7" in
  let before_1m =
    counter_for ~keeper ~model_used:model ~resolved_model_id:resolved
      ~bucket:"1m"
  in
  let before_256k =
    counter_for ~keeper ~model_used:model ~resolved_model_id:resolved
      ~bucket:"256k"
  in
  UM.record_context_max_observation
    ~keeper ~model_used:model ~resolved_model_id:resolved
    ~context_max:1_000_000;
  Alcotest.(check (float 0.0001))
    "1m bucket +1"
    (before_1m +. 1.0)
    (counter_for ~keeper ~model_used:model ~resolved_model_id:resolved
       ~bucket:"1m");
  Alcotest.(check (float 0.0001))
    "256k bucket unchanged"
    before_256k
    (counter_for ~keeper ~model_used:model ~resolved_model_id:resolved
       ~bucket:"256k")

(* The whole point of the metric: same (model_used,
   resolved_model_id) pair landing in two buckets directly
   visible in counter rows.  A future fix that pins context_max
   to one bucket per pair will see this test still pass — it
   pins the OBSERVABILITY contract, not the underlying bug. *)
let test_drift_visible_as_two_bucket_rows () =
  let keeper = "test-keeper-drift-9953" in
  let model = "claude_code:auto-drift-9953" in
  let resolved = "auto-drift-resolved-9953" in
  let before_64k =
    counter_for ~keeper ~model_used:model ~resolved_model_id:resolved
      ~bucket:"64k"
  in
  let before_1m =
    counter_for ~keeper ~model_used:model ~resolved_model_id:resolved
      ~bucket:"1m"
  in
  (* Simulate the #9953 split: 1 turn lands at 64k, another at 1m. *)
  UM.record_context_max_observation
    ~keeper ~model_used:model ~resolved_model_id:resolved
    ~context_max:64_000;
  UM.record_context_max_observation
    ~keeper ~model_used:model ~resolved_model_id:resolved
    ~context_max:1_000_000;
  Alcotest.(check (float 0.0001))
    "64k bucket recorded one drift turn"
    (before_64k +. 1.0)
    (counter_for ~keeper ~model_used:model ~resolved_model_id:resolved
       ~bucket:"64k");
  Alcotest.(check (float 0.0001))
    "1m bucket recorded the other drift turn"
    (before_1m +. 1.0)
    (counter_for ~keeper ~model_used:model ~resolved_model_id:resolved
       ~bucket:"1m")

(* keeper isolation — a turn for keeper A must not affect
   keeper B's counters even with identical model labels. *)
let test_keeper_label_isolation () =
  let model = "model-iso-9953" in
  let resolved = "resolved-iso-9953" in
  let before_b =
    counter_for ~keeper:"keeper-B-9953" ~model_used:model
      ~resolved_model_id:resolved ~bucket:"1m"
  in
  UM.record_context_max_observation
    ~keeper:"keeper-A-9953" ~model_used:model ~resolved_model_id:resolved
    ~context_max:1_000_000;
  Alcotest.(check (float 0.0001))
    "keeper B unaffected"
    before_b
    (counter_for ~keeper:"keeper-B-9953" ~model_used:model
       ~resolved_model_id:resolved ~bucket:"1m")

let () =
  Alcotest.run "context_max_observed_9953"
    [
      ( "vocabulary",
        [
          Alcotest.test_case "bucket vocabulary table" `Quick
            test_bucket_vocabulary;
          Alcotest.test_case "boundary 64k / 128k" `Quick
            test_bucket_boundary_64k;
          Alcotest.test_case "boundary 256k / 1m" `Quick
            test_bucket_boundary_256k;
          Alcotest.test_case "boundary 1m / other" `Quick
            test_bucket_boundary_1m;
        ] );
      ( "counter_emission",
        [
          Alcotest.test_case "increments correct bucket" `Quick
            test_record_increments_correct_bucket;
          Alcotest.test_case "drift visible as two bucket rows"
            `Quick test_drift_visible_as_two_bucket_rows;
          Alcotest.test_case "keeper label isolation" `Quick
            test_keeper_label_isolation;
        ] );
    ]
