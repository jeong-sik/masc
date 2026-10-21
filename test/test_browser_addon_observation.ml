open Alcotest
module Observation = Masc.Browser_addon_observation
module Types = Masc.Lane_addon_types
let ok = function Ok value -> value | Error message -> fail message
let roundtrip () =
  let snapshot=`Assoc ["state",`String "serving";
    "clients",`List [`Assoc ["interactions",`List [`Assoc ["phase",`String "running"]]]]] in
  let output=ok (Observation.of_snapshot ~observed_at:42. snapshot) in
  let retained=ok (Types.output_of_json (Types.output_to_json output)) in
  check bool "live and retained observation carry the same snapshot" true
    (match output.rows,retained.rows with [live],[retained] ->
      `Assoc live.fields=snapshot && live=retained | _ -> false)
let duplicate () = check bool "duplicate snapshot fields rejected before publication" true
  (Result.is_error (Observation.of_snapshot ~observed_at:0.
    (`Assoc ["state",`String "serving";"state",`String "retired"])))
let invalid_time () = check bool "invalid time rejected before publication" true
  (Result.is_error (Observation.of_snapshot ~observed_at:Float.nan (`Assoc [])))
let invalid_snapshot () = check bool "non-object snapshot rejected before publication" true
  (Result.is_error (Observation.of_snapshot ~observed_at:0. (`List [])))
let ()=run "browser addon observation" ["publication",[
  test_case "live and retained observations agree" `Quick roundtrip;
  test_case "duplicate snapshot fields" `Quick duplicate;
  test_case "invalid time" `Quick invalid_time;
  test_case "invalid snapshot" `Quick invalid_snapshot]]
