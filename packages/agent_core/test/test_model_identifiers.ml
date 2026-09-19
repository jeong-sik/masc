(* [Id_prefix] opaque boundary — regression suite.  Legacy round c-ffbfc4c6
   (p-5d6ad8f6, 2026-09-18): prefix matching must live inside the opaque
   boundary with the same semantics as [equal].  Since the #37022 functor
   round, that semantics is byte equality on the normalized (lowercased)
   form: normalization happens in [of_string], so [equal] and
   [starts_with] are plain byte comparisons over [t] values that are
   normalized by construction. *)
let prefix_of entry = Llm_provider.Model_identifiers.Id_prefix.of_string_exn entry

let starts_with ~prefix raw =
  Llm_provider.Model_identifiers.Id_prefix.starts_with
    ~prefix:(prefix_of prefix)
    (prefix_of raw)
;;

let test_starts_with_exact () =
  Alcotest.(check bool) "claude- matches exactly" true
    (starts_with ~prefix:"claude-" "claude-opus-5");
  Alcotest.(check bool) "gpt- matches exactly" true
    (starts_with ~prefix:"gpt-" "gpt-5.6-sol");
  Alcotest.(check bool) "unrelated prefix" false
    (starts_with ~prefix:"gpt-" "claude-opus-5")
;;

let test_starts_with_normalization () =
  Alcotest.(check bool) "case-different prefix now matches" true
    (starts_with ~prefix:"CLAUDE-" "claude-opus-5");
  Alcotest.(check bool) "case-different value matches" true
    (starts_with ~prefix:"claude-" "CLAUDE-opus-5");
  Alcotest.(check bool) "of_string returns normalized form" true
    (String.equal
       (Llm_provider.Model_identifiers.Id_prefix.to_string (prefix_of "GLM-5.3"))
       "glm-5.3")
;;

let test_starts_with_not_suffix () =
  Alcotest.(check bool) "suffix is not a prefix" false
    (starts_with ~prefix:"opus-5" "claude-opus-5")
;;

let () =
  Alcotest.run "model_identifiers"
    [ ( "Id_prefix.starts_with"
      , [ Alcotest.test_case "exact" `Quick test_starts_with_exact
        ; Alcotest.test_case "normalization" `Quick test_starts_with_normalization
        ; Alcotest.test_case "not_suffix" `Quick test_starts_with_not_suffix ] ) ]
