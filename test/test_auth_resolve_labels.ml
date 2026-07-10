(** Pure formatting contracts for typed [Auth_resolve] outcomes. Filesystem,
    credential, corruption, and expiry behavior is covered by
    [test_runtime_mcp_policy_auth]. *)

open Masc

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
    Mcp_bearer_env;
    Per_keeper_token_file;
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

let test_per_keeper_token_file_label_is_stable () =
  Alcotest.(check string)
    "Per_keeper_token_file label matches operator-facing trace contract"
    "per_keeper_token_file"
    (Auth_resolve.token_source_label Per_keeper_token_file)

(* ── auth_error: show / pp surface payload ────────────────────── *)

let test_show_verification_failure_is_typed_and_secret_free () =
  let s =
    Auth_resolve.show_auth_error
      (Credential_verification_failed
         {
           agent_name = "keeper-vincent-agent";
           presented_source = Per_keeper_token_file;
           failure = Invalid_token;
         })
  in
  Alcotest.(check bool)
    "show_auth_error embeds agent"
    true (contains s "keeper-vincent-agent");
  Alcotest.(check bool)
    "show_auth_error embeds presented_source label"
    true (contains s "per_keeper_token_file");
  Alcotest.(check bool) "show_auth_error embeds typed reason" true
    (contains s "invalid_token");
  Alcotest.(check bool) "show_auth_error never embeds bearer material" false
    (contains s "super-secret-bearer")

let test_show_raw_token_unavailable_includes_agent () =
  let s =
    Auth_resolve.show_auth_error
      (Raw_token_unavailable { agent_name = "keeper-x-agent" })
  in
  Alcotest.(check bool) "embeds agent" true (contains s "keeper-x-agent")

let test_show_api_key_env_unset_includes_var_name () =
  let s =
    Auth_resolve.show_auth_error (Api_key_env_unset { var_name = "ZHIPU_API_KEY" })
  in
  Alcotest.(check bool) "embeds var_name" true (contains s "ZHIPU_API_KEY")

(* ── pp_auth_error symmetric to show ──────────────────────────── *)

let test_pp_auth_error_matches_show () =
  let err : Auth_resolve.auth_error =
    Unbound_token_verification_failed
      { presented_source = Mcp_bearer_env; failure = Token_expired { agent_name = "x" } }
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
          Alcotest.test_case "Per_keeper_token_file label is stable" `Quick
            test_per_keeper_token_file_label_is_stable;
        ] );
      ( "auth_error",
        [
          Alcotest.test_case "verification failure is typed and secret-free"
            `Quick test_show_verification_failure_is_typed_and_secret_free;
          Alcotest.test_case "Raw_token_unavailable surfaces agent" `Quick
            test_show_raw_token_unavailable_includes_agent;
          Alcotest.test_case "Api_key_env_unset surfaces var_name" `Quick
            test_show_api_key_env_unset_includes_var_name;
          Alcotest.test_case "pp_auth_error == show_auth_error" `Quick
            test_pp_auth_error_matches_show;
        ] );
    ]
