

;;

(* ------------------------------------------------------------------ *)
(* Config-load gate: profile defaults resolving to [Local]            *)
(* ------------------------------------------------------------------ *)

let contains needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec scan i = i + n <= h && (String.sub haystack i n = needle || scan (i + 1)) in
  scan 0
;;

let gate_meta () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String "unstated-profile"
        ; "trace_id", `String "trace-unstated-profile"
        ])
  with
  | Ok meta -> meta
  | Error err -> Alcotest.fail err
;;

(* No profile source at all. This used to fall back to the meta's own
   [sandbox_profile] -- for any durable keeper JSON, the decoder's placeholder
   -- and a feature flag defaulting to off was what stopped that from becoming
   host execution. The placeholder is gone as an answer: a keeper with nothing
   stating a profile has none, and there is no flag that changes it. *)
let test_no_profile_source_is_refused () =
  match
    Masc.Keeper_meta_contract.effective_meta_of_profile_defaults
      Masc.Keeper_types_profile.empty_keeper_profile_defaults
      (gate_meta ())
  with
  | Error msg ->
    Alcotest.(check bool)
      "the error says a profile is required"
      true
      (contains "sandbox_profile is required" msg)
  | Ok _ -> Alcotest.fail "a keeper with no profile source must be refused"
;;

let () =
  Alcotest.run
    "keeper_turn_sandbox_profile_gate"
    [ ( "turn_meta_resolution"
      , [

        ] )
    ; ( "config_load_gate"
      , [ Alcotest.test_case
            "a keeper with no profile source is refused"
            `Quick
            test_no_profile_source_is_refused
        ] )
    ]
;;
