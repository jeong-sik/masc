(** test_cascade_capability_gate — Provider ceiling clamping.

    Verifies TLA+ KeeperCoreTriad.CapabilityGate (S3 invariant):
    requested_max_tokens never exceeds provider ceiling after clamping. *)

open Alcotest

let clamp = Masc_mcp.Cascade_inference.clamp_max_tokens_to_ceiling

let test_clamp_above_ceiling () =
  let result = clamp ~provider_ceiling:(Some 40960) 65536 in
  check int "65536 clamped to 40960" 40960 result

let test_clamp_below_ceiling () =
  let result = clamp ~provider_ceiling:(Some 131072) 32768 in
  check int "32768 unchanged (below ceiling)" 32768 result

let test_clamp_equal_ceiling () =
  let result = clamp ~provider_ceiling:(Some 32768) 32768 in
  check int "equal to ceiling stays" 32768 result

let test_clamp_no_ceiling () =
  let result = clamp ~provider_ceiling:None 65536 in
  check int "None ceiling -> unchanged" 65536 result

let test_clamp_zero_ceiling () =
  let result = clamp ~provider_ceiling:(Some 0) 1024 in
  check int "zero ceiling clamps to 0" 0 result

let () =
  run "cascade_capability_gate" [
    "clamp_max_tokens", [
      test_case "above ceiling -> clamped"    `Quick test_clamp_above_ceiling;
      test_case "below ceiling -> unchanged"  `Quick test_clamp_below_ceiling;
      test_case "equal ceiling -> unchanged"  `Quick test_clamp_equal_ceiling;
      test_case "no ceiling -> unchanged"     `Quick test_clamp_no_ceiling;
      test_case "zero ceiling -> clamped to 0" `Quick test_clamp_zero_ceiling;
    ];
  ]
