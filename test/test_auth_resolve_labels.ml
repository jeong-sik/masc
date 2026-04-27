(** test_auth_resolve_labels — pure helpers of [Auth_resolve].

    Step 15 (partial) of the bloodflow restoration plan. Covers the
    label / show / pp helpers added by Step 1 (Auth_resolve typed
    Result). The [resolve] function itself depends on filesystem +
    env state, so it is exercised in higher-level integration tests;
    this file pins the pure formatting surface so a variant rename or
    addition cannot silently break operator-facing trace messages. *)

open Masc_mcp

(* ── Helpers ─────────────────────────────────────────────────── *)

let duplicates labels =
  let seen = Hashtbl.create 16 in
  List.filter
    (fun s ->
      let dup = Hashtbl.mem seen s in
      Hashtbl.replace seen s ();
      dup)
    labels

let contains haystack needle =
  try
    ignore (Str.search_forward (Str.regexp_string needle) haystack 0);
    true
  with Not_found -> false

(* ── token_source ────────────────────────────────────────────── *)

let all_token_sources : Auth_resolve.token_source list =
  [
    Internal_keeper_token;
    Internal_keeper_env;
    Mcp_bearer_env;
    Provider_api_key_env { var_name = "ANTHROPIC_API_KEY" };
  ]

let test_token_source_labels_unique () =
  let labels = List.map Auth_resolve.token_source_label all_token_sources in
  Alcotest.(check (list string))
    "no duplicate token_source labels" [] (duplicates labels)

let test_provider_api_key_env_label_carries_var_name () =
  let s =
    Auth_resolve.token_source_label
      (Provider_api_key_env { var_name = "KIMI_API_KEY" })
  in
  Alcotest.(check bool) "label embeds var_name" true (contains s "KIMI_API_KEY")

(* ── auth_error: show / pp surface payload ────────────────────── *)

let test_show_token_hash_missing_includes_path () =
  let s =
    Auth_resolve.show_auth_error
      (Token_hash_missing { path = "/tmp/keeper.token.hash" })
  in
  Alcotest.(check bool)
    "show_auth_error embeds path"
    true
    (contains s "/tmp/keeper.token.hash")

let test_show_token_hash_mismatch_includes_keeper_id_and_source () =
  let s =
    Auth_resolve.show_auth_error
      (Token_hash_mismatch
         {
           keeper_id = "vincent";
           presented_source = Mcp_bearer_env;
         })
  in
  Alcotest.(check bool)
    "show_auth_error embeds keeper_id"
    true (contains s "vincent");
  Alcotest.(check bool)
    "show_auth_error embeds presented_source label"
    true (contains s "mcp_bearer_env")

let test_show_credential_file_missing_includes_path () =
  let s =
    Auth_resolve.show_auth_error
      (Credential_file_missing { path = "/tmp/agents/x.json" })
  in
  Alcotest.(check bool) "embeds path" true (contains s "/tmp/agents/x.json")

let test_show_api_key_env_unset_includes_var_name () =
  let s =
    Auth_resolve.show_auth_error (Api_key_env_unset { var_name = "ZHIPU_API_KEY" })
  in
  Alcotest.(check bool) "embeds var_name" true (contains s "ZHIPU_API_KEY")

(* ── pp_auth_error symmetric to show ──────────────────────────── *)

let test_pp_auth_error_matches_show () =
  let err : Auth_resolve.auth_error =
    Token_hash_missing { path = "/p" }
  in
  let buf = Buffer.create 16 in
  let fmt = Format.formatter_of_buffer buf in
  Auth_resolve.pp_auth_error fmt err;
  Format.pp_print_flush fmt ();
  Alcotest.(check string)
    "pp_auth_error and show_auth_error produce identical output"
    (Auth_resolve.show_auth_error err)
    (Buffer.contents buf)

(* ── Test runner ─────────────────────────────────────────────── *)

let () =
  Alcotest.run "auth_resolve_labels"
    [
      ( "token_source",
        [
          Alcotest.test_case "labels unique" `Quick
            test_token_source_labels_unique;
          Alcotest.test_case "Provider_api_key_env carries var_name" `Quick
            test_provider_api_key_env_label_carries_var_name;
        ] );
      ( "auth_error",
        [
          Alcotest.test_case "Token_hash_missing surfaces path" `Quick
            test_show_token_hash_missing_includes_path;
          Alcotest.test_case "Token_hash_mismatch surfaces keeper+source"
            `Quick test_show_token_hash_mismatch_includes_keeper_id_and_source;
          Alcotest.test_case "Credential_file_missing surfaces path" `Quick
            test_show_credential_file_missing_includes_path;
          Alcotest.test_case "Api_key_env_unset surfaces var_name" `Quick
            test_show_api_key_env_unset_includes_var_name;
          Alcotest.test_case "pp_auth_error == show_auth_error" `Quick
            test_pp_auth_error_matches_show;
        ] );
    ]
