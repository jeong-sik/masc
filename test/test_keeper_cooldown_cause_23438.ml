(* test/test_keeper_cooldown_cause_23438.ml

   #23438 compatibility: persisted envelopes from the retired pre-dispatch
   provider-health gate may still carry [cooldown_cause]. The field remains
   decodable for evidence, but it has no retry, admission, or lifecycle
   authority.

   Pinned invariants:
   1. to_string/of_string is a total roundtrip over every constructor.
   2. sdk_error embed -> classify roundtrip preserves [cooldown_cause]
      (Some and None) through the JSON wire payload.
   3. [summary_of_masc_internal_error] names the diagnostic; a cause-less
      block renders without the suffix (legacy shape preserved).
   4. Every legacy cause remains auto-recoverable; decoded history cannot
      alter Keeper lifecycle behavior. *)

module KIE = Keeper_internal_error
module EC = Masc.Keeper_error_classify
module KTD = Masc.Keeper_turn_driver

let all_causes =
  [ KIE.Cooldown_provider_capacity
  ; KIE.Cooldown_soft_rate_limited
  ; KIE.Cooldown_server_error
  ; KIE.Cooldown_hard_quota
  ; KIE.Cooldown_terminal_failure
  ; KIE.Cooldown_provider_error
  ; KIE.Cooldown_rejected
  ]

let backpressure_error ?cooldown_cause () =
  KIE.Capacity_backpressure
    { runtime_id = "runpod_rtxa6000.gemma4-coder-fable5-q4km"
    ; source = KIE.Provider_capacity
    ; detail = "provider health cooldown active before dispatch"
    ; retry_after = KIE.No_retry_hint
    ; cooldown_cause
    }

let test_cause_string_roundtrip () =
  List.iter
    (fun cause ->
      let raw = KIE.provider_cooldown_cause_to_string cause in
      match KIE.provider_cooldown_cause_of_string raw with
      | Some decoded ->
          Alcotest.(check bool)
            (Printf.sprintf "roundtrip %s" raw)
            true
            (decoded = cause)
      | None -> Alcotest.failf "of_string rejected canonical label %S" raw)
    all_causes;
  Alcotest.(check bool)
    "unknown label decodes to None"
    true
    (KIE.provider_cooldown_cause_of_string "definitely_not_a_cause" = None)

let embed_and_classify err =
  KTD.classify_masc_internal_error (KTD.sdk_error_of_masc_internal_error err)

let test_sdk_error_roundtrip_preserves_cause () =
  List.iter
    (fun cause ->
      let original = backpressure_error ~cooldown_cause:cause () in
      match embed_and_classify original with
      | Some
          (KIE.Capacity_backpressure { cooldown_cause = Some decoded; _ }) ->
          Alcotest.(check bool)
            (Printf.sprintf
               "cause %s survives the wire"
               (KIE.provider_cooldown_cause_to_string cause))
            true
            (decoded = cause)
      | Some (KIE.Capacity_backpressure { cooldown_cause = None; _ }) ->
          Alcotest.fail "cooldown_cause dropped by the JSON roundtrip"
      | Some other ->
          Alcotest.failf
            "reclassified as %s"
            (KIE.kind_of_masc_internal_error other)
      | None -> Alcotest.fail "classify_masc_internal_error returned None")
    all_causes

let test_sdk_error_roundtrip_none_cause () =
  match embed_and_classify (backpressure_error ()) with
  | Some (KIE.Capacity_backpressure { cooldown_cause = None; _ }) -> ()
  | Some (KIE.Capacity_backpressure { cooldown_cause = Some cause; _ }) ->
      Alcotest.failf
        "cause invented from nothing: %s"
        (KIE.provider_cooldown_cause_to_string cause)
  | Some other ->
      Alcotest.failf
        "reclassified as %s"
        (KIE.kind_of_masc_internal_error other)
  | None -> Alcotest.fail "classify_masc_internal_error returned None"

let contains ~needle haystack =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  let rec scan i = i + nlen <= hlen
    && (String.sub haystack i nlen = needle || scan (i + 1))
  in
  nlen = 0 || scan 0

let summary_exn err =
  match KIE.summary_of_masc_internal_error err with
  | Some summary -> summary
  | None -> Alcotest.fail "summary_of_masc_internal_error returned None"

let test_summary_names_the_cause () =
  let summary =
    summary_exn (backpressure_error ~cooldown_cause:KIE.Cooldown_hard_quota ())
  in
  Alcotest.(check bool)
    "summary carries cooldown_cause=hard_quota"
    true
    (contains ~needle:"cooldown_cause=hard_quota" summary);
  let legacy = summary_exn (backpressure_error ()) in
  Alcotest.(check bool)
    "cause-less summary keeps the legacy shape"
    false
    (contains ~needle:"cooldown_cause=" legacy)

let test_legacy_causes_have_no_lifecycle_authority () =
  List.iter
    (fun cause ->
      let sdk_error =
        KTD.sdk_error_of_masc_internal_error
          (backpressure_error ~cooldown_cause:cause ())
      in
      Alcotest.(check bool)
        (Printf.sprintf
           "legacy %s stays auto-recoverable"
           (KIE.provider_cooldown_cause_to_string cause))
        true
        (EC.is_auto_recoverable_turn_error sdk_error))
    all_causes;
  let cause_less =
    KTD.sdk_error_of_masc_internal_error (backpressure_error ())
  in
  Alcotest.(check bool)
    "cause-less block stays auto-recoverable (legacy behaviour)"
    true
    (EC.is_auto_recoverable_turn_error cause_less)

let () =
  Alcotest.run
    "keeper_cooldown_cause_23438"
    [ ( "cooldown_cause"
      , [ Alcotest.test_case
            "to_string/of_string roundtrip"
            `Quick
            test_cause_string_roundtrip
        ; Alcotest.test_case
            "sdk-error JSON roundtrip preserves cause"
            `Quick
            test_sdk_error_roundtrip_preserves_cause
        ; Alcotest.test_case
            "sdk-error JSON roundtrip preserves None"
            `Quick
            test_sdk_error_roundtrip_none_cause
        ; Alcotest.test_case
            "summary preserves the legacy diagnostic"
            `Quick
            test_summary_names_the_cause
        ; Alcotest.test_case
            "legacy causes have no lifecycle authority"
            `Quick
            test_legacy_causes_have_no_lifecycle_authority
        ] )
    ]
