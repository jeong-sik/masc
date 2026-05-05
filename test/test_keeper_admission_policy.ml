(** Unit tests for Keeper_admission_policy.

    Covers two surfaces in isolation:

    1. [of_fields] — validated constructor, all five [validation_error]
       branches.
    2. [parse_admission_json] — JSON parser, default field handling,
       and error surfacing for malformed inputs.

    The constructor surface intentionally allows policies that the
    runtime would later reject only at scheduling time (e.g. all
    candidates throttled).  Those scheduling-time concerns belong to
    the admission router (PR-C), not to this module. *)

open Masc_mcp
module KAP = Keeper_admission_policy

(* ------------------------------------------------------------------ *)
(* Helpers                                                             *)
(* ------------------------------------------------------------------ *)

let candidate ~p ~m ~t : KAP.candidate = { provider = p; model = m; tier = t }

let assert_validation_error name (got : ('a, KAP.validation_error) result)
    expected =
  match got with
  | Error e when e = expected -> ()
  | Error _ ->
      Alcotest.failf "%s: expected error %s, got other variant"
        name
        (match expected with
         | KAP.Empty_candidate_list -> "Empty_candidate_list"
         | KAP.Min_tier_above_preferred -> "Min_tier_above_preferred"
         | KAP.Duplicate_provider _ -> "Duplicate_provider _"
         | KAP.Unknown_tier_label _ -> "Unknown_tier_label _"
         | KAP.Weight_out_of_range _ -> "Weight_out_of_range _")
  | Ok _ -> Alcotest.failf "%s: expected Error, got Ok" name

(* ------------------------------------------------------------------ *)
(* of_fields — validation error coverage                              *)
(* ------------------------------------------------------------------ *)

let test_of_fields_valid_three_candidates () =
  let cands =
    [ candidate ~p:"anthropic" ~m:"claude-sonnet-4-6" ~t:KAP.Preferred
    ; candidate ~p:"glm" ~m:"auto" ~t:KAP.Acceptable
    ; candidate ~p:"ollama" ~m:"qwen3.6:27b-coding-nvfp4" ~t:KAP.Survival
    ]
  in
  match
    KAP.of_fields ~keeper_id:"analyst" ~candidates:cands ~weight:1
      ~min_tier:KAP.Acceptable
  with
  | Ok t ->
      Alcotest.(check string) "keeper_id" "analyst" (KAP.keeper_id t);
      Alcotest.(check int) "weight" 1 (KAP.weight t);
      Alcotest.(check string) "top_provider" "anthropic" (KAP.top_provider t);
      Alcotest.(check int) "candidates count" 3 (List.length (KAP.candidates t))
  | Error _ -> Alcotest.fail "expected Ok, got Error"

let test_of_fields_empty_list () =
  let got =
    KAP.of_fields ~keeper_id:"analyst" ~candidates:[] ~weight:1
      ~min_tier:KAP.Acceptable
  in
  assert_validation_error "empty list" got KAP.Empty_candidate_list

let test_of_fields_zero_weight () =
  let cands =
    [ candidate ~p:"anthropic" ~m:"x" ~t:KAP.Preferred ]
  in
  let got =
    KAP.of_fields ~keeper_id:"analyst" ~candidates:cands ~weight:0
      ~min_tier:KAP.Acceptable
  in
  match got with
  | Error (KAP.Weight_out_of_range 0) -> ()
  | _ -> Alcotest.fail "expected Weight_out_of_range 0"

let test_of_fields_min_tier_above_preferred () =
  (* head candidate is Acceptable, but min_tier = Preferred — that is
     "min_tier strictly above the most preferred candidate", which makes
     the policy unsatisfiable on its own preference list. *)
  let cands =
    [ candidate ~p:"glm" ~m:"auto" ~t:KAP.Acceptable ]
  in
  let got =
    KAP.of_fields ~keeper_id:"analyst" ~candidates:cands ~weight:1
      ~min_tier:KAP.Preferred
  in
  assert_validation_error "min_tier above preferred"
    got KAP.Min_tier_above_preferred

let test_of_fields_duplicate_provider () =
  let cands =
    [ candidate ~p:"anthropic" ~m:"claude-sonnet-4-6" ~t:KAP.Preferred
    ; candidate ~p:"anthropic" ~m:"claude-sonnet-4-6" ~t:KAP.Acceptable
    ]
  in
  let got =
    KAP.of_fields ~keeper_id:"analyst" ~candidates:cands ~weight:1
      ~min_tier:KAP.Acceptable
  in
  match got with
  | Error (KAP.Duplicate_provider "anthropic") -> ()
  | _ -> Alcotest.fail "expected Duplicate_provider \"anthropic\""

let test_of_fields_same_provider_different_models_allowed () =
  let cands =
    [ candidate ~p:"anthropic" ~m:"claude-sonnet-4-6" ~t:KAP.Preferred
    ; candidate ~p:"anthropic" ~m:"claude-haiku-4-5" ~t:KAP.Acceptable
    ]
  in
  match
    KAP.of_fields ~keeper_id:"analyst" ~candidates:cands ~weight:1
      ~min_tier:KAP.Acceptable
  with
  | Ok t ->
      Alcotest.(check int)
        "same provider can appear for distinct model fallbacks"
        2 (List.length (KAP.candidates t))
  | Error _ ->
      Alcotest.fail
        "same provider with distinct models should be accepted"

(* ------------------------------------------------------------------ *)
(* candidates_above_min_tier filtering                                *)
(* ------------------------------------------------------------------ *)

let test_candidates_above_min_tier_filters_survival () =
  let cands =
    [ candidate ~p:"anthropic" ~m:"x" ~t:KAP.Preferred
    ; candidate ~p:"glm" ~m:"y" ~t:KAP.Acceptable
    ; candidate ~p:"ollama" ~m:"z" ~t:KAP.Survival
    ]
  in
  match
    KAP.of_fields ~keeper_id:"k" ~candidates:cands ~weight:1
      ~min_tier:KAP.Acceptable
  with
  | Ok t ->
      let above = KAP.candidates_above_min_tier t in
      Alcotest.(check int) "two above-or-equal Acceptable"
        2 (List.length above)
  | Error _ -> Alcotest.fail "expected Ok"

(* ------------------------------------------------------------------ *)
(* tier helpers                                                        *)
(* ------------------------------------------------------------------ *)

let test_tier_compare_total_order () =
  let p = KAP.Preferred and a = KAP.Acceptable and s = KAP.Survival in
  Alcotest.(check bool) "P < A" true (KAP.tier_compare p a < 0);
  Alcotest.(check bool) "A < S" true (KAP.tier_compare a s < 0);
  Alcotest.(check bool) "P < S" true (KAP.tier_compare p s < 0);
  Alcotest.(check int) "P = P" 0 (KAP.tier_compare p p)

let test_tier_label_roundtrip () =
  List.iter
    (fun t ->
      let label = KAP.tier_label t in
      match KAP.tier_of_label label with
      | Some t' -> Alcotest.(check int) label 0 (KAP.tier_compare t t')
      | None -> Alcotest.failf "tier_of_label rejected %S" label)
    [ KAP.Preferred; KAP.Acceptable; KAP.Survival ]

let test_tier_of_label_unknown_returns_none () =
  Alcotest.(check bool) "unknown -> None" true
    (KAP.tier_of_label "Premium" = None)

(* ------------------------------------------------------------------ *)
(* parse_admission_json                                                *)
(* ------------------------------------------------------------------ *)

let valid_json : Yojson.Safe.t =
  `Assoc
    [ ("weight", `Int 2)
    ; ("min_tier", `String "Acceptable")
    ; ( "candidates"
      , `List
          [ `Assoc
              [ ("provider", `String "anthropic")
              ; ("model", `String "claude-sonnet-4-6")
              ; ("tier", `String "Preferred")
              ]
          ; `Assoc
              [ ("provider", `String "glm")
              ; ("model", `String "auto")
              ; ("tier", `String "Acceptable")
              ]
          ] )
    ]

let test_parse_admission_json_valid () =
  match KAP.parse_admission_json ~keeper_id:"analyst" valid_json with
  | Ok t ->
      Alcotest.(check int) "weight 2" 2 (KAP.weight t);
      Alcotest.(check string) "top anthropic" "anthropic" (KAP.top_provider t);
      Alcotest.(check int) "two candidates" 2 (List.length (KAP.candidates t))
  | Error _ -> Alcotest.fail "expected Ok on valid_json"

let test_parse_admission_json_missing_candidates () =
  let json : Yojson.Safe.t =
    `Assoc [ ("weight", `Int 1); ("min_tier", `String "Acceptable") ]
  in
  let got = KAP.parse_admission_json ~keeper_id:"analyst" json in
  assert_validation_error "missing candidates" got KAP.Empty_candidate_list

let test_parse_admission_json_empty_candidates () =
  let json : Yojson.Safe.t =
    `Assoc
      [ ("weight", `Int 1)
      ; ("min_tier", `String "Acceptable")
      ; ("candidates", `List [])
      ]
  in
  let got = KAP.parse_admission_json ~keeper_id:"analyst" json in
  assert_validation_error "empty list" got KAP.Empty_candidate_list

let test_parse_admission_json_unknown_tier () =
  let json : Yojson.Safe.t =
    `Assoc
      [ ("min_tier", `String "Premium")  (* invalid label *)
      ; ( "candidates"
        , `List
            [ `Assoc
                [ ("provider", `String "x")
                ; ("model", `String "y")
                ; ("tier", `String "Preferred")
                ]
            ] )
      ]
  in
  let got = KAP.parse_admission_json ~keeper_id:"analyst" json in
  match got with
  | Error (KAP.Unknown_tier_label "Premium") -> ()
  | _ -> Alcotest.fail "expected Unknown_tier_label \"Premium\""

let test_parse_admission_json_defaults () =
  (* No weight, no min_tier — defaults are 1 and Acceptable.  Single
     Preferred candidate so policy is well-formed. *)
  let json : Yojson.Safe.t =
    `Assoc
      [ ( "candidates"
        , `List
            [ `Assoc
                [ ("provider", `String "anthropic")
                ; ("model", `String "claude-sonnet-4-6")
                ; ("tier", `String "Preferred")
                ]
            ] )
      ]
  in
  match KAP.parse_admission_json ~keeper_id:"analyst" json with
  | Ok t ->
      Alcotest.(check int) "weight default 1" 1 (KAP.weight t);
      Alcotest.(check int)
        "min_tier default = Acceptable -> tier_compare Acceptable Acceptable"
        0
        (KAP.tier_compare (KAP.min_tier t) KAP.Acceptable)
  | Error _ -> Alcotest.fail "expected Ok with defaults"

(* ------------------------------------------------------------------ *)
(* Test runner                                                         *)
(* ------------------------------------------------------------------ *)

let () =
  Alcotest.run "keeper_admission_policy"
    [ ( "of_fields"
      , [ Alcotest.test_case "valid 3 candidates" `Quick
            test_of_fields_valid_three_candidates
        ; Alcotest.test_case "empty list" `Quick test_of_fields_empty_list
        ; Alcotest.test_case "zero weight" `Quick test_of_fields_zero_weight
        ; Alcotest.test_case "min_tier above preferred" `Quick
            test_of_fields_min_tier_above_preferred
        ; Alcotest.test_case "duplicate provider" `Quick
            test_of_fields_duplicate_provider
        ; Alcotest.test_case "same provider different models allowed"
            `Quick test_of_fields_same_provider_different_models_allowed
        ] )
    ; ( "filtering"
      , [ Alcotest.test_case "candidates_above_min_tier filters Survival"
            `Quick test_candidates_above_min_tier_filters_survival
        ] )
    ; ( "tier"
      , [ Alcotest.test_case "tier_compare total order" `Quick
            test_tier_compare_total_order
        ; Alcotest.test_case "tier_label roundtrip" `Quick
            test_tier_label_roundtrip
        ; Alcotest.test_case "unknown tier label returns None" `Quick
            test_tier_of_label_unknown_returns_none
        ] )
    ; ( "parser"
      , [ Alcotest.test_case "valid full JSON" `Quick
            test_parse_admission_json_valid
        ; Alcotest.test_case "missing candidates field" `Quick
            test_parse_admission_json_missing_candidates
        ; Alcotest.test_case "empty candidates list" `Quick
            test_parse_admission_json_empty_candidates
        ; Alcotest.test_case "unknown min_tier label" `Quick
            test_parse_admission_json_unknown_tier
        ; Alcotest.test_case "defaults applied when fields missing" `Quick
            test_parse_admission_json_defaults
        ] )
    ]
