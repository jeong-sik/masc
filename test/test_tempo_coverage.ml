(** What Tempo publishes.

    This file used to cover an adaptive controller: JSON round-trips for a
    persisted state, a pending-task classifier, and a priority-to-interval
    calculation with fast/normal/slow arms. None of it ran in production --
    nothing called the adjusting half, so the state file was never written and
    every read returned the configured default. The tests passed because they
    called the functions themselves.

    What is left is the constant those surfaces were actually showing, so these
    cases check that: the published interval is the configured one, and it does
    not vary with the workspace it is asked about. *)

open Alcotest

module Tempo = Masc.Tempo
module Env_config = Env_config

let config_for base_path = Masc.Workspace.default_config base_path

let test_publishes_the_configured_interval () =
  let tempo = Tempo.get_tempo (config_for "/tmp/tempo-coverage-a") in
  check
    (float 0.001)
    "published interval is MASC_TEMPO_DEFAULT_INTERVAL_SEC"
    Env_config.Tempo.default_interval_seconds
    tempo.Tempo.current_interval_s

(* The signature still takes a config because operator surfaces pass one. It is
   a setting, so two workspaces must report the same number -- a difference
   would mean something is adjusting it again. *)
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
      , [ test_case "is the configured one" `Quick
            test_publishes_the_configured_interval
        ; test_case "does not vary by workspace" `Quick
            test_does_not_vary_by_workspace
        ; test_case "is positive" `Quick test_interval_is_usable_as_a_period
        ] )
    ]
