open Alcotest
open Masc_mcp

let test_elapsed_duration_ms_rounds_positive_sub_ms_to_one () =
  check int "positive sub-ms interval" 1
    (Keeper_timing.elapsed_duration_ms ~start_time:10.0 ~end_time:10.0004)

let test_elapsed_duration_ms_preserves_integral_floor () =
  check int "integer millisecond floor" 12
    (Keeper_timing.elapsed_duration_ms ~start_time:2.0 ~end_time:2.0129)

let test_elapsed_duration_ms_keeps_non_positive_zero () =
  check int "same timestamp" 0
    (Keeper_timing.elapsed_duration_ms ~start_time:5.0 ~end_time:5.0);
  check int "backwards timestamp" 0
    (Keeper_timing.elapsed_duration_ms ~start_time:5.0 ~end_time:4.999)

let test_elapsed_duration_ms_rejects_non_finite () =
  check int "infinite interval" 0
    (Keeper_timing.elapsed_duration_ms ~start_time:0.0 ~end_time:infinity);
  check int "nan interval" 0
    (Keeper_timing.elapsed_duration_ms ~start_time:0.0 ~end_time:nan)

let test_elapsed_duration_ms_clamps_overflow () =
  check int "oversized finite interval" max_int
    (Keeper_timing.elapsed_duration_ms ~start_time:0.0
       ~end_time:(float_of_int max_int))

let () =
  run "Keeper_timing"
    [
      ( "duration_ms",
        [
          test_case "positive sub-ms intervals round up" `Quick
            test_elapsed_duration_ms_rounds_positive_sub_ms_to_one;
          test_case "larger intervals use integer floor" `Quick
            test_elapsed_duration_ms_preserves_integral_floor;
          test_case "non-positive intervals stay zero" `Quick
            test_elapsed_duration_ms_keeps_non_positive_zero;
          test_case "non-finite intervals stay zero" `Quick
            test_elapsed_duration_ms_rejects_non_finite;
          test_case "oversized intervals clamp to max_int" `Quick
            test_elapsed_duration_ms_clamps_overflow;
        ] );
    ]
