open Alcotest

let verdict parsed hostname =
  Gh_auth_status.verdict_for_host parsed ~hostname
  |> Gh_auth_status.verdict_to_string
;;

let entry
      ?error
      ?scopes
      ~active
      ~git_protocol
      ~host
      ~login
      ~state
      ~token_source
      ()
  =
  `Assoc
    ([ "active", `Bool active
     ; "gitProtocol", `String git_protocol
     ; "host", `String host
     ; "login", `String login
     ; "state", `String state
     ; "tokenSource", `String token_source
     ]
     @ (match error with None -> [] | Some value -> [ "error", `String value ])
     @ (match scopes with None -> [] | Some value -> [ "scopes", `String value ]))
;;

let document hosts =
  `Assoc [ "hosts", `Assoc hosts ] |> Yojson.Safe.to_string
;;

(* Captured from gh 2.87.3's token-free [--json hosts] surface. The account
   name is replaced, but field names, enum values and the comma-delimited
   scopes string are unchanged. *)
let actual_cli_json =
  {|{"hosts":{"github.com":[{"active":true,"gitProtocol":"https","host":"github.com","login":"octo","scopes":"gist, read:org, repo, workflow","state":"success","tokenSource":"keyring"}]}}|}
;;

let keyring_entry ?(host = "github.com") ?(active = true) () =
  entry
    ~active
    ~git_protocol:"https"
    ~host
    ~login:"octo"
    ~scopes:"gist, read:org, repo"
    ~state:"success"
    ~token_source:"keyring"
    ()
;;

let environment_entry ?(host = "github.com") ?(active = true) ?error ~state () =
  entry
    ?error
    ~active
    ~git_protocol:"https"
    ~host
    ~login:(if String.equal state "success" then "env-octo" else "")
    ~state
    ~token_source:"GITHUB_TOKEN"
    ()
;;

let test_command_targets_one_host_without_token () =
  check
    (array string)
    "argv"
    [| "gh"
     ; "auth"
     ; "status"
     ; "--hostname"
     ; "ghe.example.com"
     ; "--json"
     ; "hosts"
    |]
    (Gh_auth_status.command_argv ~hostname:"  GHE.Example.COM ")
;;

let test_command_rejects_empty_hostname () =
  List.iter
    (fun hostname ->
       try
         ignore (Gh_auth_status.command_argv ~hostname);
         failf "empty hostname %S was accepted" hostname
       with
       | Invalid_argument _ -> ())
    [ ""; "   "; "\t\n" ]
;;

let replace_token_source token_source json =
  match json with
  | `Assoc fields ->
    `Assoc
      (List.map
         (fun (name, value) ->
            if String.equal name "tokenSource"
            then name, `String token_source
            else name, value)
         fields)
  | _ -> json
;;
let test_actual_cli_json_decodes () =
  let parsed = Gh_auth_status.parse actual_cli_json in
  check (option string) "schema" None parsed.schema_error;
  check string "target verdict" "authenticated" (verdict parsed "github.com");
  match parsed.entries with
  | [ observed ] ->
    check string "host" "github.com" observed.host;
    check (option string) "account" (Some "octo") observed.account;
    check bool "active" true observed.active;
    check
      (option (list string))
      "scopes"
      (Some [ "gist"; "read:org"; "repo"; "workflow" ])
      observed.scopes;
    (match observed.source with
     | Gh_auth_status.Keyring -> ()
     | Gh_auth_status.Environment _ | Gh_auth_status.Config_file _ ->
       fail "keyring source was misclassified")
  | entries -> failf "expected one entry, got %d" (List.length entries)
;;

let test_relative_config_and_documented_environment_sources () =
  let config_sources =
    [ "hosts.yml"
    ; Filename.concat "config" "hosts.yml"
    ; Filename.concat (Filename.get_temp_dir_name ()) "hosts.yml"
    ; "config\\hosts.yml"
    ]
  in
  List.iter
    (fun config_source ->
       let config_json =
         document
           [ ( "github.com"
             , `List
                 [ replace_token_source config_source (keyring_entry ()) ] ) ]
       in
       let parsed = Gh_auth_status.parse config_json in
       check (option string) "config source schema" None parsed.schema_error;
       match parsed.entries with
       | [ observed ] ->
         (match observed.source with
          | Gh_auth_status.Config_file observed_source ->
            check string "config source identity" config_source observed_source
          | Gh_auth_status.Keyring | Gh_auth_status.Environment _ ->
            fail "hosts.yml was not classified as a config source")
       | entries -> failf "expected one entry, got %d" (List.length entries))
    config_sources;
  List.iter
    (fun token_source ->
       let json =
         document
           [ ( "github.com"
             , `List
                 [ replace_token_source token_source (environment_entry ~state:"success" ()) ] ) ]
       in
       let parsed = Gh_auth_status.parse json in
       check (option string) (token_source ^ " is documented") None parsed.schema_error)
    [ "GH_TOKEN"; "GITHUB_TOKEN"; "GH_ENTERPRISE_TOKEN"; "GITHUB_ENTERPRISE_TOKEN" ]
;;

let test_environment_shadows_stored_account_on_same_host () =
  let json =
    document
      [ ( "github.com"
        , `List
            [ environment_entry
                ~state:"error"
                ~error:"HTTP 401"
                ()
            ; keyring_entry ~active:false ()
            ] )
      ]
  in
  let parsed = Gh_auth_status.parse json in
  check string "same-host shadow" "shadowed" (verdict parsed " GITHUB.COM ")
;;

let test_hosts_are_isolated () =
  let json =
    document
      [ ( "github.com"
        , `List
            [ environment_entry
                ~state:"error"
                ~error:"HTTP 401"
                ()
            ; keyring_entry ~active:false ()
            ] )
      ; ( "ghe.example.com"
        , `List [ keyring_entry ~host:"ghe.example.com" () ] )
      ]
  in
  let parsed = Gh_auth_status.parse json in
  check string "github target" "shadowed" (verdict parsed "github.com");
  check string
    "enterprise target"
    "authenticated"
    (verdict parsed "ghe.example.com");
  check string
    "missing target"
    "unauthenticated"
    (verdict parsed "missing.example.com")
;;

let test_active_account_is_target_authority () =
  let json =
    document
      [ ( "github.com"
        , `List
            [ environment_entry ~active:false ~state:"success" ()
            ; keyring_entry ()
            ] )
      ]
  in
  let parsed = Gh_auth_status.parse json in
  check string
    "inactive environment row does not shadow the active keyring"
    "authenticated"
    (verdict parsed "github.com")
;;

let test_timeout_is_unknown () =
  let json =
    document
      [ ( "github.com"
        , `List
            [ environment_entry
                ~state:"timeout"
                ~error:"request timed out"
                ()
            ] )
      ]
  in
  let parsed = Gh_auth_status.parse json in
  check string "timeout" "unknown" (verdict parsed "github.com")
;;

let test_empty_hosts_is_target_unauthenticated () =
  let parsed = Gh_auth_status.parse {|{"hosts":{}}|} in
  check (option string) "schema" None parsed.schema_error;
  check string "missing host" "unauthenticated" (verdict parsed "github.com")
;;

let check_schema_declines label json =
  let parsed = Gh_auth_status.parse json in
  check bool (label ^ " has typed detail") true (Option.is_some parsed.schema_error);
  check int (label ^ " publishes no partial entries") 0 (List.length parsed.entries);
  check string (label ^ " verdict") "unknown" (verdict parsed "github.com")
;;

let test_schema_drift_is_unknown () =
  let valid_fields =
    [ "active", `Bool true
    ; "gitProtocol", `String "https"
    ; "host", `String "github.com"
    ; "login", `String "octo"
    ; "state", `String "success"
    ; "tokenSource", `String "keyring"
    ]
  in
  List.iter
    (fun (label, fields) ->
       document [ "github.com", `List [ `Assoc fields ] ]
       |> check_schema_declines label)
    [ "unknown field", ("future", `Bool true) :: valid_fields
    ; ( "unknown state"
      , List.map
          (fun (name, value) ->
             if String.equal name "state" then name, `String "degraded" else name, value)
          valid_fields )
    ; ( "unknown protocol"
      , List.map
          (fun (name, value) ->
             if String.equal name "gitProtocol" then name, `String "git" else name, value)
          valid_fields )
    ; ( "unknown token source"
      , List.map
          (fun (name, value) ->
             if String.equal name "tokenSource"
             then name, `String "secure_enclave"
             else name, value)
          valid_fields )
    ; ( "undocumented environment token source"
      , List.map
          (fun (name, value) ->
             if String.equal name "tokenSource"
             then name, `String "NOT_DOCUMENTED_TOKEN"
             else name, value)
          valid_fields )
    ; ( "successful entry without an account"
      , List.map
          (fun (name, value) ->
             if String.equal name "login" then name, `String "" else name, value)
          valid_fields )
    ; "token exposure", ("token", `String "must-not-be-ingested") :: valid_fields
    ]
;;

let test_schema_errors_redact_json_values () =
  List.iter
    (fun (label, secret, json) ->
       let parsed = Gh_auth_status.parse json in
       match parsed.schema_error with
       | None -> failf "%s was accepted" label
       | Some detail ->
         check bool (label ^ " does not expose the secret") false
           (String_util.contains_substring detail secret);
         check bool (label ^ " reports the JSON kind") true
           (String_util.contains_substring detail "string"))
    [ ( "malformed hosts value"
      , "ghp_secret_value"
      , {|{"hosts":"ghp_secret_value"}|} )
    ; ( "malformed host-map value"
      , "ghp_secret_key"
      , {|{"hosts":{"ghp_secret_key":"bad"}}|} )
    ]
;;

let test_host_identity_mismatch_is_unknown () =
  document [ "github.com", `List [ keyring_entry ~host:"ghe.example.com" () ] ]
  |> check_schema_declines "host mismatch"
;;

let test_case_insensitive_duplicate_hosts_are_unknown () =
  document
    [ "github.com", `List [ keyring_entry () ]
    ; "GITHUB.COM", `List [ keyring_entry ~host:"GITHUB.COM" ~active:false () ]
    ]
  |> check_schema_declines "case-insensitive duplicate host key"
;;

let test_empty_entry_arrays_still_validate_host_keys () =
  List.iter
    (fun host ->
       document [ host, `List [] ]
       |> check_schema_declines "invalid empty-array host key")
    [ ""; " github.com " ]
;;

let test_invalid_json_is_unknown () =
  List.iter
    (fun (label, json) -> check_schema_declines label json)
    [ "empty", ""; "human prose", "github.com\n  Logged in"; "truncated", {|{"hosts":|} ]
;;

let () =
  run
    "gh_auth_status"
    [ ( "typed JSON"
      , [ test_case
            "command targets one host without token"
            `Quick
            test_command_targets_one_host_without_token
        ; test_case
            "command rejects empty hostname"
            `Quick
            test_command_rejects_empty_hostname
        ; test_case "actual CLI JSON decodes" `Quick test_actual_cli_json_decodes
        ; test_case
            "relative config and documented environment sources"
            `Quick
            test_relative_config_and_documented_environment_sources
        ; test_case
            "same-host environment shadows stored account"
            `Quick
            test_environment_shadows_stored_account_on_same_host
        ; test_case "hosts are isolated" `Quick test_hosts_are_isolated
        ; test_case
            "active account is target authority"
            `Quick
            test_active_account_is_target_authority
        ; test_case "timeout is unknown" `Quick test_timeout_is_unknown
        ; test_case
            "empty hosts is target unauthenticated"
            `Quick
            test_empty_hosts_is_target_unauthenticated
        ; test_case "schema drift is unknown" `Quick test_schema_drift_is_unknown
        ; test_case
            "host identity mismatch is unknown"
            `Quick
            test_host_identity_mismatch_is_unknown
        ; test_case
            "case-insensitive duplicate hosts are unknown"
            `Quick
            test_case_insensitive_duplicate_hosts_are_unknown
        ; test_case
            "empty entry arrays still validate host keys"
            `Quick
            test_empty_entry_arrays_still_validate_host_keys
        ; test_case
            "schema errors redact JSON values"
            `Quick
            test_schema_errors_redact_json_values
        ; test_case "invalid JSON is unknown" `Quick test_invalid_json_is_unknown
        ] )
    ]
;;
