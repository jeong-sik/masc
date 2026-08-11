open Alcotest

(* Fixtures marked "measured" are verbatim stdout from
   `gh auth status --json hosts` on gh 2.87.3 (2026-02-23), tokens masked.
   Fixtures marked "constructed" follow the same shape for a state this host
   could not be put into. *)

(* measured: host keyring only. *)
let keyring_payload =
  {|{"hosts":{"github.com":[{"state":"success","active":true,"host":"github.com","login":"jeong-sik","tokenSource":"keyring","scopes":"gist, read:org, repo, workflow","gitProtocol":"https"}]}}|}
;;

(* measured: an invalid GITHUB_TOKEN over a logged-in keyring. The keyring row
   stays healthy and simply stops being the active one. *)
let invalid_env_over_keyring_payload =
  {|{"hosts":{"github.com":[{"state":"error","error":"non-200 OK status code: 401 Unauthorized body: \"Bad credentials\"","active":true,"host":"github.com","login":"","tokenSource":"GITHUB_TOKEN","gitProtocol":"https"},{"state":"success","active":false,"host":"github.com","login":"jeong-sik","tokenSource":"keyring","scopes":"gist, read:org, repo, workflow","gitProtocol":"https"}]}}|}
;;

(* measured: a VALID token in GITHUB_TOKEN over a logged-in keyring. Both rows
   are healthy and nothing is broken, yet the keyring credential is not what
   authenticates. *)
let valid_env_over_keyring_payload =
  {|{"hosts":{"github.com":[{"state":"success","active":true,"host":"github.com","login":"jeong-sik","tokenSource":"GITHUB_TOKEN","scopes":"gist, read:org, repo, workflow","gitProtocol":"https"},{"state":"success","active":false,"host":"github.com","login":"jeong-sik","tokenSource":"keyring","scopes":"gist, read:org, repo, workflow","gitProtocol":"https"}]}}|}
;;

(* measured: an enterprise host whose DNS does not resolve, beside a healthy
   github.com keyring. Two independent answers, not a shadow. The text output
   of the same command says "The token in GH_ENTERPRISE_TOKEN is invalid",
   which is false — only the JSON carries the real cause. *)
let two_hosts_payload =
  {|{"hosts":{"ghes.example.invalid":[{"state":"error","error":"Post \"https://ghes.example.invalid/api/graphql\": dial tcp: lookup ghes.example.invalid: no such host","active":true,"host":"ghes.example.invalid","login":"","tokenSource":"GH_ENTERPRISE_TOKEN","gitProtocol":"https"}],"github.com":[{"state":"success","active":true,"host":"github.com","login":"jeong-sik","tokenSource":"keyring","scopes":"gist, read:org, repo, workflow","gitProtocol":"https"}]}}|}
;;

(* measured: empty GH_CONFIG_DIR with both token variables cleared. gh prints
   the human sentence on stderr and this on stdout. *)
let no_hosts_payload = {|{"hosts":{}}|}

(* constructed: gh names a config-file source by absolute path. *)
let config_file_payload =
  {|{"hosts":{"github.com":[{"state":"success","active":true,"host":"github.com","login":"octo","tokenSource":"/Users/octo/.config/gh/hosts.yml","scopes":"repo","gitProtocol":"https"}]}}|}
;;

(* constructed: gh's timeout state, from its own vocabulary. *)
let timeout_payload =
  {|{"hosts":{"github.com":[{"state":"timeout","active":true,"host":"github.com","login":"octo","tokenSource":"keyring","gitProtocol":"https"}]}}|}
;;

(* constructed: a tokenSource label this module does not recognise. *)
let future_label_payload =
  {|{"hosts":{"github.com":[{"state":"success","active":true,"host":"github.com","login":"octo","tokenSource":"secure_enclave","gitProtocol":"https"}]}}|}
;;

let decoded payload = Gh_auth_status.decode payload

let single_host payload =
  match (decoded payload).Gh_auth_status.hosts with
  | [ host ] -> host
  | hosts -> failf "expected exactly one host, decoded %d" (List.length hosts)
;;

let verdict_of payload =
  Gh_auth_status.verdict_to_string (single_host payload).Gh_auth_status.verdict
;;

let test_keyring_is_authenticated () =
  let host = single_host keyring_payload in
  check string "verdict" "authenticated" (Gh_auth_status.verdict_to_string host.Gh_auth_status.verdict);
  check string "host" "github.com" host.Gh_auth_status.host;
  match host.Gh_auth_status.rows with
  | [ row ] ->
    check (option string) "login" (Some "jeong-sik") row.Gh_auth_status.login;
    check string "source label" "keyring" row.Gh_auth_status.token_source_label;
    check
      (option (list string))
      "scopes"
      (Some [ "gist"; "read:org"; "repo"; "workflow" ])
      row.Gh_auth_status.scopes;
    check (option string) "no error" None row.Gh_auth_status.error
  | rows -> failf "expected one row, decoded %d" (List.length rows)
;;

let test_invalid_env_shadows_a_healthy_keyring () =
  check string "verdict" "shadowed" (verdict_of invalid_env_over_keyring_payload);
  match (single_host invalid_env_over_keyring_payload).Gh_auth_status.rows with
  | [ env_row; keyring_row ] ->
    check string "variable is named" "GITHUB_TOKEN" env_row.Gh_auth_status.token_source_label;
    check (option string) "failed row has no login" None env_row.Gh_auth_status.login;
    check bool "failure prose is carried" true (Option.is_some env_row.Gh_auth_status.error);
    check string "keyring row survives" "success" keyring_row.Gh_auth_status.state
  | rows -> failf "expected two rows, decoded %d" (List.length rows)
;;

(* Nothing is broken here. A verdict keyed on row health would call this
   authenticated and hide that pushes go out under the variable. *)
let test_valid_env_still_shadows () =
  check string "verdict" "shadowed" (verdict_of valid_env_over_keyring_payload);
  List.iter
    (fun row -> check string "row is healthy" "success" row.Gh_auth_status.state)
    (single_host valid_env_over_keyring_payload).Gh_auth_status.rows
;;

(* The shadow question is per host. A variable on an enterprise host does not
   shadow a keyring on github.com — they are separate credentials for separate
   destinations. *)
let test_two_hosts_are_judged_separately () =
  let result = decoded two_hosts_payload in
  check int "two hosts" 2 (List.length result.Gh_auth_status.hosts);
  List.iter
    (fun (host : Gh_auth_status.host_status) ->
       let verdict = Gh_auth_status.verdict_to_string host.Gh_auth_status.verdict in
       match host.Gh_auth_status.host with
       | "github.com" -> check string "github.com" "authenticated" verdict
       | "ghes.example.invalid" -> check string "enterprise host" "unauthenticated" verdict
       | other -> failf "unexpected host %s" other)
    result.Gh_auth_status.hosts
;;

(* gh's prose for the row above claims the token is invalid; it is not, the
   host does not resolve. The cause is carried verbatim and never classified. *)
let test_failure_cause_is_carried_not_classified () =
  let enterprise =
    (decoded two_hosts_payload).Gh_auth_status.hosts
    |> List.find (fun (host : Gh_auth_status.host_status) ->
      String.equal host.Gh_auth_status.host "ghes.example.invalid")
  in
  match enterprise.Gh_auth_status.rows with
  | [ row ] ->
    (match row.Gh_auth_status.error with
     | None -> fail "the failure cause was dropped"
     | Some detail ->
       check
         bool
         "cause is the DNS failure gh reported"
         true
         (String_util.contains_substring detail "no such host"))
  | rows -> failf "expected one row, decoded %d" (List.length rows)
;;

let test_no_hosts_is_unauthenticated () =
  let result = decoded no_hosts_payload in
  check int "no hosts" 0 (List.length result.Gh_auth_status.hosts);
  check (option string) "well formed, not undecodable" None result.Gh_auth_status.undecodable
;;

let test_config_file_source_is_stored () =
  check string "verdict" "authenticated" (verdict_of config_file_payload)
;;

(* gh's own vocabulary includes states beyond success and error. An unhealthy
   active row must not read as authenticated, and the row must survive so the
   operator can see what gh said. *)
let test_unrecognised_state_is_not_authenticated () =
  check string "verdict" "unauthenticated" (verdict_of timeout_payload);
  match (single_host timeout_payload).Gh_auth_status.rows with
  | [ row ] -> check string "state is carried verbatim" "timeout" row.Gh_auth_status.state
  | rows -> failf "expected one row, decoded %d" (List.length rows)
;;

(* A label gh adds later could name a variable. Reading it as stored would
   report this host authenticated while its pushes go out under that variable. *)
let test_unrecognised_source_declines_the_verdict () =
  check string "verdict" "unknown" (verdict_of future_label_payload);
  match (single_host future_label_payload).Gh_auth_status.rows with
  | [ row ] ->
    check string "label is carried" "secure_enclave" row.Gh_auth_status.token_source_label;
    check bool "label is not interpreted" true (Option.is_none row.Gh_auth_status.source)
  | rows -> failf "expected one row, decoded %d" (List.length rows)
;;

(* gh prints the human sentence on stderr. Merging the streams produces a
   payload that must be reported as undecodable rather than as "no hosts". *)
let test_undecodable_is_distinct_from_no_hosts () =
  List.iter
    (fun (name, payload) ->
       let result = decoded payload in
       check int (name ^ " has no hosts") 0 (List.length result.Gh_auth_status.hosts);
       check
         bool
         (name ^ " is undecodable")
         true
         (Option.is_some result.Gh_auth_status.undecodable))
    [ "stderr merged into stdout",
      "You are not logged into any GitHub hosts.\n{\"hosts\":{}}"
    ; "empty", ""
    ; "not an object", "[]"
    ; "hosts is not an object", {|{"hosts":[]}|}
    ]
;;

let () =
  run
    "gh_auth_status"
    [ ( "verdict"
      , [ test_case "keyring is authenticated" `Quick test_keyring_is_authenticated
        ; test_case
            "invalid env shadows a healthy keyring"
            `Quick
            test_invalid_env_shadows_a_healthy_keyring
        ; test_case "a valid env token still shadows" `Quick test_valid_env_still_shadows
        ; test_case
            "two hosts are judged separately"
            `Quick
            test_two_hosts_are_judged_separately
        ; test_case
            "failure cause is carried not classified"
            `Quick
            test_failure_cause_is_carried_not_classified
        ; test_case "no hosts is unauthenticated" `Quick test_no_hosts_is_unauthenticated
        ; test_case "config file source is stored" `Quick test_config_file_source_is_stored
        ; test_case
            "unrecognised state is not authenticated"
            `Quick
            test_unrecognised_state_is_not_authenticated
        ; test_case
            "unrecognised source declines the verdict"
            `Quick
            test_unrecognised_source_declines_the_verdict
        ; test_case
            "undecodable is distinct from no hosts"
            `Quick
            test_undecodable_is_distinct_from_no_hosts
        ] )
    ]
;;
