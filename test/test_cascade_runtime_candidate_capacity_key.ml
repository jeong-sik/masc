(** Unit tests for [Cascade_runtime_candidate] capacity key partitioning.

    Validates per-model capacity bucketing: same base_url with different
    model_ids must yield different capacity keys so that concurrent requests
    to different models on the same provider endpoint do not share a single
    capacity slot. *)

module Candidate = Masc_mcp.Cascade_runtime_candidate
module PC = Llm_provider.Provider_config

let capacity_key_testable = Alcotest.string

let make_candidate ~kind ~model_id ~base_url () =
  let cfg = PC.make ~kind ~model_id ~base_url () in
  Candidate.of_provider_config cfg

let capacity_key ~kind ~model_id ~base_url () =
  let c = make_candidate ~kind ~model_id ~base_url () in
  Candidate.capacity_key c

(* -- Same base_url, different model_id → different keys ---------------- *)

let test_different_models_different_keys () =
  let key_a =
    capacity_key ~kind:PC.Ollama ~model_id:"llama3"
      ~base_url:"http://127.0.0.1:11434" ()
  in
  let key_b =
    capacity_key ~kind:PC.Ollama ~model_id:"mistral"
      ~base_url:"http://127.0.0.1:11434" ()
  in
  Alcotest.(check bool)
    "different model_id on same base_url → different capacity keys"
    true
    (key_a <> key_b)

(* -- Same base_url, same model_id → same keys ------------------------- *)

let test_same_models_same_keys () =
  let key_a =
    capacity_key ~kind:PC.Ollama ~model_id:"llama3"
      ~base_url:"http://127.0.0.1:11434" ()
  in
  let key_b =
    capacity_key ~kind:PC.Ollama ~model_id:"llama3"
      ~base_url:"http://127.0.0.1:11434" ()
  in
  Alcotest.check capacity_key_testable
    "same model_id on same base_url → same capacity key"
    key_a key_b

(* -- model_id="" → falls back to base_url only ------------------------- *)

let test_empty_model_id_uses_base_url_only () =
  let key =
    capacity_key ~kind:PC.Ollama ~model_id:""
      ~base_url:"http://127.0.0.1:11434" ()
  in
  Alcotest.check capacity_key_testable
    "model_id='' → capacity key is base_url without model suffix"
    "http://127.0.0.1:11434"
    key

(* -- base_url="" with CLI kind → returns cli sentinel ------------------- *)

let test_cli_kind_returns_sentinel () =
  let key =
    capacity_key ~kind:PC.Cli_tool_d ~model_id:"some-model" ~base_url:"" ()
  in
  Alcotest.(check bool)
    "CLI kind with empty base_url → sentinel key (not empty)"
    true
    (key <> "")

let test_cli_sentinel_contains_kind_prefix () =
  let key =
    capacity_key ~kind:PC.Cli_tool_d ~model_id:"some-model" ~base_url:"" ()
  in
  Alcotest.(check bool)
    "CLI sentinel key starts with 'cli:'"
    true
    (String.length key > 4 && String.sub key 0 4 = "cli:")

(* -- CLI kind with same model_id → same sentinel ----------------------- *)

let test_cli_same_model_same_key () =
  let key_a =
    capacity_key ~kind:PC.Cli_tool_d ~model_id:"model-x" ~base_url:"" ()
  in
  let key_b =
    capacity_key ~kind:PC.Cli_tool_d ~model_id:"model-x" ~base_url:"" ()
  in
  Alcotest.check capacity_key_testable
    "CLI kind same model → same sentinel key"
    key_a key_b

(* -- CLI kind with different model_id → different sentinel -------------- *)

let test_cli_different_model_different_key () =
  let key_a =
    capacity_key ~kind:PC.Cli_tool_d ~model_id:"model-x" ~base_url:"" ()
  in
  let key_b =
    capacity_key ~kind:PC.Cli_tool_d ~model_id:"model-y" ~base_url:"" ()
  in
  Alcotest.(check bool)
    "CLI kind different model → different sentinel keys"
    true
    (key_a <> key_b)

(* -- base_url="" and non-CLI kind → empty string ----------------------- *)

let test_non_cli_empty_base_url_returns_empty () =
  let key =
    capacity_key ~kind:PC.Ollama ~model_id:"llama3" ~base_url:"" ()
  in
  Alcotest.check capacity_key_testable
    "non-CLI kind with empty base_url → empty capacity key"
    ""
    key

(* -- Key format includes ":" separator -------------------------------- *)

let test_key_format_contains_separator () =
  let key =
    capacity_key ~kind:PC.Ollama ~model_id:"llama3"
      ~base_url:"http://localhost:11434" ()
  in
  Alcotest.(check bool)
    "capacity key with model contains ':' separator"
    true
    (String.contains key ':')

let () =
  Alcotest.run "cascade_runtime_candidate.capacity_key"
    [
      ( "per-model bucketing",
        [
          Alcotest.test_case
            "different models → different keys"
            `Quick
            test_different_models_different_keys;
          Alcotest.test_case
            "same models → same keys"
            `Quick
            test_same_models_same_keys;
          Alcotest.test_case
            "empty model_id → base_url only"
            `Quick
            test_empty_model_id_uses_base_url_only;
        ] );
      ( "CLI sentinel",
        [
          Alcotest.test_case
            "CLI kind → non-empty sentinel"
            `Quick
            test_cli_kind_returns_sentinel;
          Alcotest.test_case
            "CLI sentinel starts with 'cli:'"
            `Quick
            test_cli_sentinel_contains_kind_prefix;
          Alcotest.test_case
            "CLI same model → same key"
            `Quick
            test_cli_same_model_same_key;
          Alcotest.test_case
            "CLI different model → different key"
            `Quick
            test_cli_different_model_different_key;
        ] );
      ( "edge cases",
        [
          Alcotest.test_case
            "non-CLI empty base_url → empty"
            `Quick
            test_non_cli_empty_base_url_returns_empty;
          Alcotest.test_case
            "key format contains ':'"
            `Quick
            test_key_format_contains_separator;
        ] );
    ]
