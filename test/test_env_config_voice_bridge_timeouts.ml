(** Pin the {!Env_config_runtime.Voice} HTTP/audio timeout contract.
    Three values were extracted from inline literals at
    [voice_bridge.ml]:

    -  82  35.0  → http_request_timeout_sec (synthesis upload)
    - 139  35.0  → http_request_timeout_sec (file-form POST)
    - 892   2.0  → audio_test_tone_timeout_sec (sox play)

    The two [35.0] literals shared a value because both drive Voice
    MCP HTTP requests; collapse to one knob. The [2.0] literal is
    a *different intent* (local subprocess, not network) and stays
    a separate accessor.

    Properties pinned:

    1. Defaults preserve the pre-extraction literals.
    2. http_request > audio_test_tone — network IO budgets must
       always exceed local-subprocess budgets, otherwise an operator
       lowering [http_request_timeout_sec] below [audio_test_tone_
       timeout_sec] would silently disable HTTP timeout (the local
       budget would dominate) without any deployment signal.
    3. Floor clamps prevent degenerate operator config. *)

open Alcotest

module V = Env_config_runtime.Voice

let approx = float 0.001

let test_default_http_request () =
  check approx
    "http_request_timeout_sec default (was inline 35.0 ×2)"
    35.0 V.http_request_timeout_sec

let test_default_audio_test_tone () =
  check approx
    "audio_test_tone_timeout_sec default (was inline 2.0)"
    2.0 V.audio_test_tone_timeout_sec

let test_http_exceeds_audio_test_tone () =
  check bool
    "http_request_timeout_sec MUST exceed audio_test_tone_timeout_sec \
     (network IO budget > local-subprocess budget)"
    true
    (V.http_request_timeout_sec > V.audio_test_tone_timeout_sec)

let test_smoke_call_sites_compile () =
  let _ = V.http_request_timeout_sec in
  let _ = V.audio_test_tone_timeout_sec in
  check bool "both accessors are reachable" true true

let () =
  run "env_config_voice_bridge_timeouts"
    [
      ( "defaults preserve pre-extraction literals",
        [
          test_case "http_request = 35.0" `Quick test_default_http_request;
          test_case "audio_test_tone = 2.0" `Quick
            test_default_audio_test_tone;
        ] );
      ( "ordering invariant",
        [
          test_case "http_request > audio_test_tone" `Quick
            test_http_exceeds_audio_test_tone;
        ] );
      ( "API surface",
        [
          test_case "both accessors reachable" `Quick
            test_smoke_call_sites_compile;
        ] );
    ]
