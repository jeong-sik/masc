open Alcotest

module Tempo = Masc.Tempo
module Runtime_params = Masc.Runtime_params
module Runtime_settings = Masc.Runtime_settings

let config_for base_path = Masc.Workspace.default_config base_path

let test_publishes_the_configured_interval () =
  let tempo = Tempo.get_tempo (config_for "/tmp/tempo-coverage-a") in
  check
    (float 0.001)
    "published interval is the Keeper execution interval"
    (float_of_int (Runtime_params.get Runtime_settings.keeper_keepalive_interval_sec))
    tempo.Tempo.current_interval_s

(* The signature still takes a config because operator surfaces pass one. It is
   a setting, so two workspaces must report the same number -- a difference
   would mean something is adjusting it again. *)
let test_live_override_changes_published_interval () =
  Eio_main.run (fun _ ->
    let parameter = Runtime_settings.keeper_keepalive_interval_sec in
    let prior = Runtime_params.get parameter in
    Fun.protect
      ~finally:(fun () -> ignore (Runtime_params.set parameter prior))
      (fun () ->
        List.iter (fun interval ->
          (match Runtime_params.set parameter interval with
           | Ok () -> () | Error error -> fail error);
          let published = Tempo.get_tempo (config_for "/tmp/tempo-coverage-a") in
          check (float 0.) "live execution override is published"
            (float_of_int interval) published.current_interval_s)
          [600; 317]))

let test_does_not_vary_by_workspace () =
  let a = Tempo.get_tempo (config_for "/tmp/tempo-coverage-a") in
  let b = Tempo.get_tempo (config_for "/tmp/tempo-coverage-b") in
  check
    (float 0.001)
    "same interval for two workspaces"
    a.Tempo.current_interval_s
    b.Tempo.current_interval_s

let test_interval_is_usable_as_a_period () =
  let tempo = Tempo.get_tempo (config_for "/tmp/tempo-coverage-a") in
  check bool "interval is positive" true (tempo.Tempo.current_interval_s > 0.0)

let () =
  Alcotest.run
    "Tempo"
    [ ( "published interval"
      , [ test_case "tracks live cadence override" `Quick test_live_override_changes_published_interval
        ; test_case "is the configured one" `Quick
            test_publishes_the_configured_interval
        ; test_case "does not vary by workspace" `Quick
            test_does_not_vary_by_workspace
        ; test_case "is positive" `Quick test_interval_is_usable_as_a_period
        ] )
    ]
