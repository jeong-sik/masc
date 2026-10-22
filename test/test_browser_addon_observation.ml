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
let work registered = `Assoc ["activity",`String "enabled";"registered",`Bool registered;
  "session",`String "closed";"locate",`Bool false]
let client id browser = `Assoc ["clientId",`String id;"browser",`String browser;
  "version",`String "158.0.1";"engineVersion",`String "158.0.1";"transport",`String "web_extension";
  "interactions",`List []]
let serving clients = `Assoc ["state",`String "serving";"clients",`List clients;
  "owned_backends",`Assoc ["automation",work true;"stagehand",work false]]
(* The server reads the browser rows of the Lanes list from this cached
   observation, so what the worker published must read back whole. *)
let published_reads_back () =
  let output=ok (Observation.of_snapshot ~observed_at:1.
    (serving [client "01a16363-ef67-7000-ad62-05bcd0320d99" "firefox";
              client "01a16363-ef68-7000-aee1-37e1be230202" "zen"])) in
  let published=ok (Observation.read output) in
  check int "both connected clients read back" 2 (List.length published.clients);
  check bool "the automation backend reads as registered" true published.automation.registered;
  check bool "the Stagehand backend reads as not registered" false published.stagehand.registered
(* The runtime keeps an observation with its row renamed under the
   installation (Lane_addon_runtime.namespace); the reader must find it. *)
let namespaced_row_reads_back () =
  let output=ok (Observation.of_snapshot ~observed_at:1.
    (serving [client "01a16363-ef67-7000-ad62-05bcd0320d99" "firefox"])) in
  let cached={output with rows=List.map (fun (row:Types.row) ->
    {row with id="browser-work/7/" ^ row.id;lane_id="browser-work/" ^ row.lane_id}) output.rows} in
  let published=ok (Observation.read cached) in
  check int "the renamed row still reads back its client" 1 (List.length published.clients);
  check bool "the renamed row still reads back the registration" true published.automation.registered
let retired_is_not_connected () =
  let output=ok (Observation.of_snapshot ~observed_at:1.
    (`Assoc ["state",`String "retired";"clients",`List [];
      "owned_backends",`Assoc ["automation",work false;"stagehand",work false]])) in
  check bool "a retired worker's observation does not read as a connected browser" true
    (Result.is_error (Observation.read output))
let duplicate_client () =
  let id="01a16363-ef67-7000-ad62-05bcd0320d99" in
  check bool "the same client twice is refused" true
    (Result.is_error (Observation.decode_snapshot (serving [client id "firefox"; client id "firefox"])))
let ()=run "browser addon observation" ["publication",[
  test_case "published snapshot reads back" `Quick published_reads_back;
  test_case "namespaced row reads back" `Quick namespaced_row_reads_back;
  test_case "retired worker is not connected" `Quick retired_is_not_connected;
  test_case "duplicate client refused" `Quick duplicate_client;
  test_case "live and retained observations agree" `Quick roundtrip;
  test_case "duplicate snapshot fields" `Quick duplicate;
  test_case "invalid time" `Quick invalid_time;
  test_case "invalid snapshot" `Quick invalid_snapshot]]
