(** The declared-provider contract and the exchange it drives.

    Every case here runs without a provider: the exchange takes its HTTP call
    as an argument, so what is pinned is the request this builds and the
    answer it accepts, which is the part a live provider cannot tell us
    anything about anyway. *)

let check = Alcotest.check
let str = Alcotest.string

(* The shipped declaration, read from the same embedded tree the binary
   serves it from. Copying it into this file would let the two drift, and
   then a broken shipped file would pass a green test. *)
let shipped_atlassian () =
  match Embedded_config.read "identity/atlassian.toml" with
  | Some contents -> contents
  | None ->
      Alcotest.fail
        "config/identity/atlassian.toml is not in the embedded config tree"

let atlassian_toml =
  {|
id = "atlassian"
label = "Atlassian"
authorize_url = "https://auth.atlassian.com/authorize"
token_url = "https://auth.atlassian.com/oauth/token"
audience = "api.atlassian.com"
scopes = ["offline_access", "read:jira-work", "write:jira-work"]
access_token_env = "ATLASSIAN_ACCESS_TOKEN"
refresh_token_file = "atlassian/refresh_token"
renew_before_sec = 600
|}

let load_or_fail ?(file_name = "atlassian") contents =
  match Keeper_oauth_provider.load ~file_name ~contents with
  | Ok provider -> provider
  | Error err ->
      Alcotest.failf "declaration rejected: %s"
        (Keeper_oauth_provider.error_to_string err)

let expect_rejected ~why ?(file_name = "atlassian") contents =
  match Keeper_oauth_provider.load ~file_name ~contents with
  | Ok _ -> Alcotest.failf "accepted a declaration that %s" why
  | Error _ -> ()

let test_reads_the_shipped_declaration () =
  let provider = load_or_fail (shipped_atlassian ()) in
  check str "label" "Atlassian" provider.Keeper_oauth_provider.label;
  check str "access token env" "ATLASSIAN_ACCESS_TOKEN"
    provider.Keeper_oauth_provider.access_token_env;
  check (Alcotest.option str) "audience" (Some "api.atlassian.com")
    provider.Keeper_oauth_provider.audience;
  check Alcotest.bool "asks for a refresh token" true
    (Keeper_oauth_provider.requires_offline_access provider)

let test_rejects_a_renamed_file () =
  (* A file renamed to jira.toml keeping id = "atlassian" would answer for a
     provider nobody declared under that name. *)
  expect_rejected ~why:"was renamed away from its id" ~file_name:"jira"
    atlassian_toml

let test_rejects_a_plaintext_endpoint () =
  let downgraded =
    Str.global_replace
      (Str.regexp_string "https://auth.atlassian.com/oauth/token")
      "http://auth.atlassian.com/oauth/token" atlassian_toml
  in
  expect_rejected ~why:"names a plaintext token endpoint" downgraded

let test_rejects_a_missing_field () =
  let without_token_url =
    Str.global_replace
      (Str.regexp {|token_url = .*|})
      "" atlassian_toml
  in
  expect_rejected ~why:"declares no token endpoint" without_token_url

(* ── the exchange ────────────────────────────────────────────────────── *)

let redirect_uri = "http://127.0.0.1:8935/api/v1/keepers/kidsnote/oauth/callback"

let begin_for provider =
  Keeper_oauth_flow.begin_authorization ~provider ~client_id:"client-abc"
    ~redirect_uri ~keeper:"kidsnote"

let query_of url =
  match String.index_opt url '?' with
  | None -> Alcotest.failf "authorize URL carries no query: %s" url
  | Some at ->
      String.sub url (at + 1) (String.length url - at - 1)
      |> String.split_on_char '&'
      |> List.filter_map (fun pair ->
             match String.index_opt pair '=' with
             | None -> None
             | Some eq ->
                 Some
                   ( Uri.pct_decode (String.sub pair 0 eq),
                     Uri.pct_decode
                       (String.sub pair (eq + 1) (String.length pair - eq - 1))
                   ))

let param query key =
  match List.assoc_opt key query with
  | Some value -> value
  | None -> Alcotest.failf "authorize URL carries no %s" key

let test_authorize_url_proves_the_verifier () =
  let provider = load_or_fail atlassian_toml in
  let pending = begin_for provider in
  let query = query_of pending.Keeper_oauth_flow.authorize_url in
  check str "response type" "code" (param query "response_type");
  check str "method" "S256" (param query "code_challenge_method");
  (* The challenge has to be this verifier's, or the provider will refuse the
     redemption with nothing on our side saying why. *)
  check str "challenge is the verifier's"
    (Auth_oauth.pkce_s256 pending.Keeper_oauth_flow.verifier)
    (param query "code_challenge");
  check str "state is echoed back to us" pending.Keeper_oauth_flow.state
    (param query "state");
  check str "audience is named" "api.atlassian.com" (param query "audience");
  check str "scopes are space separated"
    "offline_access read:jira-work write:jira-work" (param query "scope")

let test_two_exchanges_do_not_share_a_verifier () =
  let provider = load_or_fail atlassian_toml in
  let one = begin_for provider and two = begin_for provider in
  Alcotest.(check bool)
    "verifiers differ" false
    (String.equal one.Keeper_oauth_flow.verifier two.Keeper_oauth_flow.verifier);
  Alcotest.(check bool)
    "states differ" false
    (String.equal one.Keeper_oauth_flow.state two.Keeper_oauth_flow.state)

let recording_post answer =
  let seen = ref None in
  let post ~url ~headers ~body =
    seen := Some (url, headers, body);
    answer
  in
  (post, seen)

let complete_with provider pending ~state ~answer =
  let post, seen = recording_post answer in
  let result =
    Keeper_oauth_flow.complete ~post ~provider ~client_id:"client-abc"
      ~client_secret:"shhh" ~redirect_uri ~pending ~code:"the-code" ~state
      ~now:1000.0 ()
  in
  (result, seen)

let ok_answer =
  Ok
    ( 200,
      {|{"access_token":"at-1","refresh_token":"rt-1","expires_in":3600,"scope":"read:jira-work"}|}
    )

let test_completion_sends_the_verifier_and_dates_the_expiry () =
  let provider = load_or_fail atlassian_toml in
  let pending = begin_for provider in
  let result, seen =
    complete_with provider pending ~state:pending.Keeper_oauth_flow.state
      ~answer:ok_answer
  in
  (match !seen with
  | None -> Alcotest.fail "the exchange sent nothing"
  | Some (url, _, body) ->
      check str "token endpoint" "https://auth.atlassian.com/oauth/token" url;
      Alcotest.(check bool)
        "the verifier is redeemed with the code" true
        (Str.string_match
           (Str.regexp (".*code_verifier=" ^ pending.Keeper_oauth_flow.verifier))
           body 0));
  match result with
  | Error err ->
      Alcotest.failf "exchange failed: %s"
        (Keeper_oauth_flow.exchange_error_to_string err)
  | Ok tokens ->
      check str "access token" "at-1" tokens.Keeper_oauth_flow.access_token;
      check (Alcotest.option str) "refresh token" (Some "rt-1")
        tokens.Keeper_oauth_flow.refresh_token;
      (* expires_in is relative to the moment it was read, so what is stored
         is the instant. A later reader should not have to know when the
         exchange happened. *)
      check (Alcotest.float 0.001) "expiry is dated from now" 4600.0
        tokens.Keeper_oauth_flow.expires_at

let test_a_foreign_state_is_refused_before_anything_is_sent () =
  let provider = load_or_fail atlassian_toml in
  let pending = begin_for provider in
  let result, seen =
    complete_with provider pending ~state:"someone-elses-state" ~answer:ok_answer
  in
  Alcotest.(check bool) "nothing was sent" true (!seen = None);
  match result with
  | Error Keeper_oauth_flow.State_mismatch -> ()
  | Error other ->
      Alcotest.failf "wrong refusal: %s"
        (Keeper_oauth_flow.exchange_error_to_string other)
  | Ok _ -> Alcotest.fail "a code arriving under another state was redeemed"

let test_a_missing_refresh_token_is_named () =
  (* The declaration asks for offline_access. Storing only the access token
     would leave the Keeper working for an hour and then stopping with no
     record of why. *)
  let provider = load_or_fail atlassian_toml in
  let pending = begin_for provider in
  let result, _ =
    complete_with provider pending ~state:pending.Keeper_oauth_flow.state
      ~answer:(Ok (200, {|{"access_token":"at-1","expires_in":3600}|}))
  in
  match result with
  | Error Keeper_oauth_flow.No_refresh_token -> ()
  | Error other ->
      Alcotest.failf "wrong refusal: %s"
        (Keeper_oauth_flow.exchange_error_to_string other)
  | Ok _ -> Alcotest.fail "an access token with no refresh token was accepted"

let test_a_refusal_keeps_the_providers_reason () =
  let provider = load_or_fail atlassian_toml in
  let pending = begin_for provider in
  let result, _ =
    complete_with provider pending ~state:pending.Keeper_oauth_flow.state
      ~answer:(Ok (400, {|{"error":"invalid_grant"}|}))
  in
  match result with
  | Error (Keeper_oauth_flow.Provider_rejected { status; body }) ->
      Alcotest.(check int) "status" 400 status;
      Alcotest.(check bool) "the reason survives" true
        (Str.string_match (Str.regexp ".*invalid_grant") body 0)
  | Error other ->
      Alcotest.failf "wrong refusal: %s"
        (Keeper_oauth_flow.exchange_error_to_string other)
  | Ok _ -> Alcotest.fail "a 400 was read as success"

let test_an_answer_without_expiry_is_not_guessed () =
  let provider = load_or_fail atlassian_toml in
  let pending = begin_for provider in
  let result, _ =
    complete_with provider pending ~state:pending.Keeper_oauth_flow.state
      ~answer:(Ok (200, {|{"access_token":"at-1","refresh_token":"rt-1"}|}))
  in
  match result with
  | Error (Keeper_oauth_flow.Malformed_response _) -> ()
  | Error other ->
      Alcotest.failf "wrong refusal: %s"
        (Keeper_oauth_flow.exchange_error_to_string other)
  | Ok _ -> Alcotest.fail "an expiry was invented for an answer that carried none"

let test_refresh_asks_for_a_refresh_grant () =
  let provider = load_or_fail atlassian_toml in
  let post, seen = recording_post ok_answer in
  let result =
    Keeper_oauth_flow.refresh ~post ~provider ~client_id:"client-abc"
      ~client_secret:"shhh" ~refresh_token:"rt-0" ~now:1000.0 ()
  in
  (match !seen with
  | None -> Alcotest.fail "the refresh sent nothing"
  | Some (_, _, body) ->
      Alcotest.(check bool)
        "grant type" true
        (Str.string_match (Str.regexp ".*grant_type=refresh_token") body 0);
      Alcotest.(check bool)
        "the spent token is presented" true
        (Str.string_match (Str.regexp ".*refresh_token=rt-0") body 0));
  match result with
  | Ok tokens ->
      (* A provider that rotates gives a new one back, and the caller has to
         store it: the one just used may already be spent. *)
      check (Alcotest.option str) "the rotated token is returned" (Some "rt-1")
        tokens.Keeper_oauth_flow.refresh_token
  | Error err ->
      Alcotest.failf "refresh failed: %s"
        (Keeper_oauth_flow.exchange_error_to_string err)

let test_renewal_window_opens_before_expiry () =
  let provider = load_or_fail atlassian_toml in
  (* renew_before_sec = 600 *)
  Alcotest.(check bool)
    "outside the window" false
    (Keeper_oauth_flow.needs_renewal ~provider ~expires_at:2000.0 ~now:1000.0);
  Alcotest.(check bool)
    "exactly at the window" true
    (Keeper_oauth_flow.needs_renewal ~provider ~expires_at:1600.0 ~now:1000.0);
  Alcotest.(check bool)
    "already expired" true
    (Keeper_oauth_flow.needs_renewal ~provider ~expires_at:900.0 ~now:1000.0)

let () =
  Alcotest.run "keeper_oauth_identity"
    [ ( "declaration",
        [ Alcotest.test_case "reads the shipped Atlassian file" `Quick
            test_reads_the_shipped_declaration;
          Alcotest.test_case "refuses a renamed file" `Quick
            test_rejects_a_renamed_file;
          Alcotest.test_case "refuses a plaintext endpoint" `Quick
            test_rejects_a_plaintext_endpoint;
          Alcotest.test_case "refuses a missing field" `Quick
            test_rejects_a_missing_field;
        ] );
      ( "authorize",
        [ Alcotest.test_case "the challenge proves the verifier" `Quick
            test_authorize_url_proves_the_verifier;
          Alcotest.test_case "two exchanges share nothing" `Quick
            test_two_exchanges_do_not_share_a_verifier;
        ] );
      ( "exchange",
        [ Alcotest.test_case "redeems the verifier and dates the expiry" `Quick
            test_completion_sends_the_verifier_and_dates_the_expiry;
          Alcotest.test_case "refuses a foreign state before sending" `Quick
            test_a_foreign_state_is_refused_before_anything_is_sent;
          Alcotest.test_case "names a missing refresh token" `Quick
            test_a_missing_refresh_token_is_named;
          Alcotest.test_case "keeps the provider's reason" `Quick
            test_a_refusal_keeps_the_providers_reason;
          Alcotest.test_case "does not invent an expiry" `Quick
            test_an_answer_without_expiry_is_not_guessed;
          Alcotest.test_case "refresh asks for a refresh grant" `Quick
            test_refresh_asks_for_a_refresh_grant;
          Alcotest.test_case "the renewal window opens before expiry" `Quick
            test_renewal_window_opens_before_expiry;
        ] );
    ]
