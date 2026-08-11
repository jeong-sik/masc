open Alcotest

(* Fixtures marked "measured" are verbatim `gh auth status` output from gh
   2.87.3 (2026-02-23), token values masked. Fixtures marked "constructed"
   follow the same grammar for a case the host could not be put into. *)

(* measured: host keyring only. *)
let keyring_output =
  {|github.com
  ✓ Logged in to github.com account jeong-sik (keyring)
  - Active account: true
  - Git operations protocol: https
  - Token: gho_MASKED
  - Token scopes: 'gist', 'read:org', 'repo', 'workflow'
|}
;;

(* measured: GITHUB_TOKEN injected over a logged-in host. The keyring entry
   stays valid and simply stops being the active one. *)
let github_token_shadow_output =
  {|github.com
  X Failed to log in to github.com using token (GITHUB_TOKEN)
  - Active account: true
  - The token in GITHUB_TOKEN is invalid.

  ✓ Logged in to github.com account jeong-sik (keyring)
  - Active account: false
  - Git operations protocol: https
  - Token: gho_MASKED
  - Token scopes: 'gist', 'read:org', 'repo', 'workflow'
|}
;;

(* measured: GH_TOKEN injected over the same host. gh reports the config entry
   as invalid too, so no entry is logged in — the verdict must still be
   shadowed, because the fix is to unset the variable, not to log in. *)
let gh_token_shadow_output =
  {|github.com
  X Failed to log in to github.com using token (GH_TOKEN)
  - Active account: true
  - The token in GH_TOKEN is invalid.

  X Failed to log in to github.com account jeong-sik (default)
  - Active account: false
  - The token in default is invalid.
  - To re-authenticate, run: gh auth login -h github.com
  - To forget about this account, run: gh auth logout -h github.com -u jeong-sik
|}
;;

(* measured: empty GH_CONFIG_DIR with both token variables cleared. *)
let unauthenticated_output =
  {|You are not logged into any GitHub hosts. To log in, run: gh auth login
|}
;;

(* constructed: a GitHub Enterprise host, same grammar as the measured cases. *)
let enterprise_output =
  {|ghe.example.com
  ✓ Logged in to ghe.example.com account octo (keyring)
  - Active account: true
  - Token scopes: 'repo'
|}
;;

(* constructed: a source label this parser does not know. *)
let future_label_output =
  {|github.com
  ✓ Logged in to github.com account octo (secure_enclave)
  - Active account: true
|}
;;

let verdict parsed = Gh_auth_status.verdict_to_string parsed.Gh_auth_status.verdict

let single_entry parsed =
  match parsed.Gh_auth_status.entries with
  | [ entry ] -> entry
  | entries ->
    failf "expected exactly one entry, parsed %d" (List.length entries)
;;

let test_keyring_is_authenticated () =
  let parsed = Gh_auth_status.parse keyring_output in
  check string "verdict" "authenticated" (verdict parsed);
  let entry = single_entry parsed in
  check string "host" "github.com" entry.Gh_auth_status.host;
  check (option string) "account" (Some "jeong-sik") entry.Gh_auth_status.account;
  check
    string
    "source"
    "keyring"
    (Gh_auth_status.token_source_to_string entry.Gh_auth_status.source);
  check (option bool) "active" (Some true) entry.Gh_auth_status.active;
  check
    (option (list string))
    "scopes"
    (Some [ "gist"; "read:org"; "repo"; "workflow" ])
    entry.Gh_auth_status.scopes
;;

(* The keyring credential here is valid and would authenticate if the variable
   were unset. A verdict driven by the logged-in mark alone would call this
   authenticated and send the operator to `gh auth login`, which no-ops. *)
let test_github_token_shadows_a_valid_keyring () =
  let parsed = Gh_auth_status.parse github_token_shadow_output in
  check string "verdict" "shadowed" (verdict parsed);
  match parsed.Gh_auth_status.entries with
  | [ env_entry; keyring_entry ] ->
    check
      string
      "environment variable is named"
      "GITHUB_TOKEN"
      (Gh_auth_status.token_source_to_string env_entry.Gh_auth_status.source);
    check
      (option bool)
      "environment entry is the active one"
      (Some true)
      env_entry.Gh_auth_status.active;
    check (option string) "environment entry has no account" None env_entry.Gh_auth_status.account;
    check
      string
      "keyring entry survives"
      "keyring"
      (Gh_auth_status.token_source_to_string keyring_entry.Gh_auth_status.source);
    (match keyring_entry.Gh_auth_status.outcome with
     | Gh_auth_status.Logged_in -> ()
     | Gh_auth_status.Login_failed -> fail "keyring entry was reported as failed");
    check
      (option bool)
      "keyring entry is not active"
      (Some false)
      keyring_entry.Gh_auth_status.active
  | entries -> failf "expected two entries, parsed %d" (List.length entries)
;;

(* Same shadowing, but gh marks both entries as failed. The verdict must not
   fall through to unauthenticated: the next action is still "unset the
   variable", not "log in". *)
let test_gh_token_shadow_survives_both_entries_failing () =
  let parsed = Gh_auth_status.parse gh_token_shadow_output in
  check string "verdict" "shadowed" (verdict parsed);
  match parsed.Gh_auth_status.entries with
  | [ env_entry; config_entry ] ->
    check
      string
      "environment variable is named"
      "GH_TOKEN"
      (Gh_auth_status.token_source_to_string env_entry.Gh_auth_status.source);
    check
      string
      "config entry source"
      "default"
      (Gh_auth_status.token_source_to_string config_entry.Gh_auth_status.source);
    List.iter
      (fun entry ->
         match entry.Gh_auth_status.outcome with
         | Gh_auth_status.Login_failed -> ()
         | Gh_auth_status.Logged_in -> fail "an entry was reported as logged in")
      parsed.Gh_auth_status.entries
  | entries -> failf "expected two entries, parsed %d" (List.length entries)
;;

let test_no_hosts_is_unauthenticated () =
  let parsed = Gh_auth_status.parse unauthenticated_output in
  check string "verdict" "unauthenticated" (verdict parsed);
  check int "no entries" 0 (List.length parsed.Gh_auth_status.entries)
;;

let test_enterprise_host_is_read_verbatim () =
  let parsed = Gh_auth_status.parse enterprise_output in
  check string "verdict" "authenticated" (verdict parsed);
  let entry = single_entry parsed in
  check string "host" "ghe.example.com" entry.Gh_auth_status.host;
  check (option (list string)) "scopes" (Some [ "repo" ]) entry.Gh_auth_status.scopes
;;

(* A label gh adds later must not be read as one of the sources the verdict
   depends on. It stays verbatim, and because it is not an environment source
   it cannot manufacture a shadowed verdict. *)
let test_unknown_label_stays_verbatim () =
  let parsed = Gh_auth_status.parse future_label_output in
  check string "verdict" "authenticated" (verdict parsed);
  let entry = single_entry parsed in
  check
    string
    "label preserved"
    "secure_enclave"
    (Gh_auth_status.token_source_to_string entry.Gh_auth_status.source);
  match entry.Gh_auth_status.source with
  | Gh_auth_status.Other_source _ -> ()
  | Gh_auth_status.Keyring | Gh_auth_status.Config_default | Gh_auth_status.Environment _
    -> fail "an unrecognised label was folded into a known source"
;;

(* Output the parser does not recognise is unknown, never a stand-in for a
   credential verdict. *)
let test_unrecognised_output_is_unknown () =
  List.iter
    (fun (name, output) ->
       let parsed = Gh_auth_status.parse output in
       check string name "unknown" (verdict parsed);
       check int (name ^ " entries") 0 (List.length parsed.Gh_auth_status.entries))
    [ "empty", ""
    ; "whitespace", "   \n  \n"
    ; "crash", "panic: runtime error: index out of range\n"
    ; "prose", "gh: command not found\n"
    ]
;;

let () =
  run
    "gh_auth_status"
    [ ( "verdict"
      , [ test_case "keyring is authenticated" `Quick test_keyring_is_authenticated
        ; test_case
            "GITHUB_TOKEN shadows a valid keyring"
            `Quick
            test_github_token_shadows_a_valid_keyring
        ; test_case
            "GH_TOKEN shadow survives both entries failing"
            `Quick
            test_gh_token_shadow_survives_both_entries_failing
        ; test_case "no hosts is unauthenticated" `Quick test_no_hosts_is_unauthenticated
        ; test_case
            "enterprise host is read verbatim"
            `Quick
            test_enterprise_host_is_read_verbatim
        ; test_case "unknown label stays verbatim" `Quick test_unknown_label_stays_verbatim
        ; test_case
            "unrecognised output is unknown"
            `Quick
            test_unrecognised_output_is_unknown
        ] )
    ]
;;
