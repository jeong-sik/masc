open Alcotest
open Masc_mcp

let test_elapsed_duration_ms_rounds_positive_sub_ms_to_one () =
  check int "positive sub-ms" 1 (Inference_utils.elapsed_duration_ms 0.0004)

let test_elapsed_duration_ms_preserves_integer_floor () =
  check int "floor larger interval" 12
    (Inference_utils.elapsed_duration_ms 0.0129)

let test_elapsed_duration_ms_keeps_non_positive_zero () =
  check int "zero" 0 (Inference_utils.elapsed_duration_ms 0.0);
  check int "negative" 0 (Inference_utils.elapsed_duration_ms (-0.001))

let test_elapsed_duration_ms_rejects_non_finite () =
  check int "nan" 0 (Inference_utils.elapsed_duration_ms nan);
  check int "infinity" 0 (Inference_utils.elapsed_duration_ms infinity)

let () =
  Alcotest.run "Inference_utils"
    [
      ( "timing",
        [
          test_case "positive sub-ms intervals round up" `Quick
            test_elapsed_duration_ms_rounds_positive_sub_ms_to_one;
          test_case "larger intervals use integer floor" `Quick
            test_elapsed_duration_ms_preserves_integer_floor;
          test_case "non-positive intervals stay zero" `Quick
            test_elapsed_duration_ms_keeps_non_positive_zero;
          test_case "non-finite intervals stay zero" `Quick
            test_elapsed_duration_ms_rejects_non_finite;
        ] );
    ]
