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
mcp_url = "https://mcp.atlassian.com/v1/mcp/authv2"
access_token_env = "ATLASSIAN_ACCESS_TOKEN"
expires_at_env = "ATLASSIAN_ACCESS_TOKEN_EXPIRES_AT"
refresh_token_file = "/home/keeper/.atlassian/refresh_token"
renew_before_sec = 600

[authorize_params]
audience = "api.atlassian.com"
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

let shipped_github () =
  match Embedded_config.read "identity/github.toml" with
  | Some contents -> contents
  | None ->
      Alcotest.fail
        "config/identity/github.toml is not in the embedded config tree"

let credential_source_to_string = function
  | Keeper_oauth_provider.Oauth_exchange -> "oauth_exchange"
  | Keeper_oauth_provider.Github_cli { hostname } -> "github_cli:" ^ hostname

(* GitHub publishes no registration endpoint, and the Keeper's gh CLI already
   holds a token for github.com. The shipped file says so; if that line is
   dropped the provider silently goes back to asking for an OAuth app nobody
   made, and the Identity screen answers 400 again. *)
let test_shipped_github_reads_the_gh_cli_credential () =
  let provider = load_or_fail ~file_name:"github" (shipped_github ()) in
  check str "credential source" "github_cli:github.com"
    (credential_source_to_string
       provider.Keeper_oauth_provider.credential_source)

(* Absent means the OAuth exchange -- the thirty-odd other declarations say
   nothing and must keep working. *)
let test_absent_credential_source_is_the_oauth_exchange () =
  let provider = load_or_fail (shipped_atlassian ()) in
  check str "credential source" "oauth_exchange"
    (credential_source_to_string
       provider.Keeper_oauth_provider.credential_source)

(* Appended after [authorize_params] a bare key lands inside that table, not
   at the top level, and the declaration would parse as if nothing was said.
   So these go in above it. *)
let with_top_level_keys keys =
  let marker = "[authorize_params]" in
  match String.index_opt atlassian_toml '[' with
  | None -> Alcotest.fail "the Atlassian fixture no longer has a table"
  | Some _ ->
      let parts = String.split_on_char '\n' atlassian_toml in
      let rebuilt =
        List.concat_map
          (fun line -> if String.equal line marker then keys @ [ line ] else [ line ])
          parts
      in
      String.concat "\n" rebuilt

(* A misspelling must not fall through to a default: masc would then look for
   a token in a place the operator did not name and report it missing. *)
let test_unknown_credential_source_is_rejected () =
  expect_rejected ~why:"names a credential source that does not exist"
    (with_top_level_keys [ "credential_source = \"gh_cli\"" ])

(* The gh CLI keeps one credential per host, so a source that reads it has to
   say which host it means. *)
let test_github_cli_source_requires_a_host () =
  expect_rejected ~why:"reads the gh CLI without naming a host"
    (with_top_level_keys [ "credential_source = \"github_cli\"" ])

(* And the pair together is accepted, so the two refusals above are about the
   missing half rather than the field being unreadable. *)
let test_github_cli_source_with_a_host_is_accepted () =
  let provider =
    load_or_fail
      (with_top_level_keys
         [ "credential_source = \"github_cli\""
         ; "credential_source_host = \"ghe.example.com\""
         ])
  in
  check str "credential source" "github_cli:ghe.example.com"
    (credential_source_to_string
       provider.Keeper_oauth_provider.credential_source)

let test_reads_the_shipped_declaration () =
  let provider = load_or_fail (shipped_atlassian ()) in
  check str "label" "Atlassian" provider.Keeper_oauth_provider.label;
  check str "access token env" "ATLASSIAN_ACCESS_TOKEN"
    provider.Keeper_oauth_provider.access_token_env;
  check str "only the server is named"
    "https://mcp.atlassian.com/v1/mcp/authv2"
    provider.Keeper_oauth_provider.mcp_url;
  (* Atlassian wants this on the authorize call and the specs do not define
     it. A branch that knew that would be the thing this design avoids. *)
  check (Alcotest.option str) "the server's own parameter is carried"
    (Some "api.atlassian.com")
    (List.assoc_opt "audience" provider.Keeper_oauth_provider.authorize_params)

let test_rejects_a_renamed_file () =
  (* A file renamed to jira.toml keeping id = "atlassian" would answer for a
     provider nobody declared under that name. *)
  expect_rejected ~why:"was renamed away from its id" ~file_name:"jira"
    atlassian_toml

let test_rejects_a_plaintext_endpoint () =
  let downgraded =
    Str.global_replace
      (Str.regexp_string "https://mcp.atlassian.com")
      "http://mcp.atlassian.com" atlassian_toml
  in
  expect_rejected ~why:"names a plaintext MCP server" downgraded

let test_rejects_a_missing_field () =
  let without_mcp_url =
    Str.global_replace (Str.regexp {|mcp_url = .*|}) "" atlassian_toml
  in
  expect_rejected ~why:"declares no MCP server" without_mcp_url

(* ── discovery ──────────────────────────────────────────────────────── *)

(* The two answers as the live servers gave them on 2026-08-26. Recorded, not
   fetched: what these pin is our reading of the shapes, and a test that
   needs the network cannot say when a shape changed. *)
(* Same shape [test_keeper_toml.ml] uses: DUNE_SOURCEROOT when dune sets it,
   otherwise walk up until the tree looks like this repo. Reading the file
   rather than pasting it here keeps one copy of what the servers actually
   said. *)
let rec ascend_to_repo path =
  if Sys.file_exists (Filename.concat path "dune-project") then Some path
  else
    let parent = Filename.dirname path in
    if String.equal parent path then None else ascend_to_repo parent

let repo_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when Sys.file_exists (Filename.concat root "dune-project") ->
      Some root
  | _ -> ascend_to_repo (Sys.getcwd ())

let fixture name =
  match repo_root () with
  | None -> Alcotest.failf "cannot find the repo root from %s" (Sys.getcwd ())
  | Some root ->
      let path =
        Filename.concat
          (Filename.concat root "test/fixtures/oauth_discovery")
          name
      in
      if Sys.file_exists path then
        In_channel.with_open_bin path In_channel.input_all
      else Alcotest.failf "recorded answer %s is missing" path

let atlassian_mcp_url = "https://mcp.atlassian.com/v1/mcp/authv2"

let recorded_get ~expect_first ~expect_second =
  let asked = ref [] in
  let get ~url =
    asked := url :: !asked;
    if String.equal url expect_first then
      Ok (200, fixture "atlassian-protected-resource.json")
    else if String.equal url expect_second then
      Ok (200, fixture "atlassian-authorization-server.json")
    else Ok (404, "not found")
  in
  (get, asked)

(* Discovery asks the MCP endpoint where its metadata is before computing a
   URL, and the default does that over the network. Every test here says
   what the server answered instead, so none of them reaches for it. *)
let no_header ~url:_ = None

let protected_resource_url =
  "https://mcp.atlassian.com/.well-known/oauth-protected-resource/v1/mcp/authv2"

let authorization_server_url =
  "https://auth.atlassian.com/.well-known/oauth-authorization-server/VCeDsk8ZHncYF1g234fKtc4lNipbBhu3"

(* ── the exchange ────────────────────────────────────────────────────── *)

let redirect_uri = "http://127.0.0.1:8935/api/v1/keepers/oauth-fixture/oauth/callback"

(* Built from the recorded answers rather than by hand, so what the exchange
   is handed is what discovery actually produces. *)
let discovered_atlassian () =
  let get, _ =
    recorded_get ~expect_first:protected_resource_url
      ~expect_second:authorization_server_url
  in
  match Keeper_oauth_discovery.discover ~get ~ask:no_header
    ~mcp_url:atlassian_mcp_url () with
  | Ok found -> found
  | Error err ->
      Alcotest.failf "discovery failed: %s"
        (Keeper_oauth_discovery.error_to_string err)

let begin_for provider =
  Keeper_oauth_flow.begin_authorization ~provider
    ~discovered:(discovered_atlassian ()) ~client_id:"client-abc" ~scopes:[]
    ~redirect_uri ~keeper:"oauth-fixture"

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
  (* RFC 8707: a token minted for this MCP server cannot be presented to
     another one. *)
  check str "the resource is named" "https://mcp.atlassian.com/v1/mcp/authv2"
    (param query "resource");
  check str "the server's own parameter rides along" "api.atlassian.com"
    (param query "audience");
  Alcotest.(check bool)
    "offline_access is asked for" true
    (List.mem "offline_access"
       (String.split_on_char ' ' (param query "scope")))

let test_a_server_that_names_no_scopes_is_asked_for_none () =
  (* Two of the servers this ships a declaration for publish no scopes at
     all. "scope=" is not an empty list, it is a malformed one, and a server
     is entitled to answer it with invalid_scope -- so the parameter is left
     out rather than sent empty. *)
  let provider = load_or_fail atlassian_toml in
  let discovered =
    { (discovered_atlassian ()) with
      Keeper_oauth_discovery.scopes_supported = []
    }
  in
  let pending =
    Keeper_oauth_flow.begin_authorization ~provider ~discovered
      ~client_id:"client-abc" ~scopes:[] ~redirect_uri
      ~keeper:"oauth-fixture"
  in
  let query = query_of pending.Keeper_oauth_flow.authorize_url in
  Alcotest.(check bool)
    "no scope parameter at all" false
    (List.mem_assoc "scope" query);
  (* Everything else still rides along, so this is an omission rather than a
     shorter URL. *)
  check str "the resource is still named" "https://mcp.atlassian.com/v1/mcp/authv2"
    (param query "resource")

let test_recorded_scopes_replace_the_published_ones () =
  (* Slack publishes thirty scopes and a workspace app declares a handful.
     Asking for the thirty is refused, and adding them to the app means a
     reinstall an admin has to approve again -- so what the operator recorded
     beside the client is what goes on the authorize call. *)
  let provider = load_or_fail atlassian_toml in
  let pending =
    Keeper_oauth_flow.begin_authorization ~provider
      ~discovered:(discovered_atlassian ())
      ~client_id:"client-abc"
      ~scopes:[ "channels:read"; "chat:write" ]
      ~redirect_uri ~keeper:"oauth-fixture"
  in
  let query = query_of pending.Keeper_oauth_flow.authorize_url in
  check str "only what was recorded" "channels:read chat:write"
    (param query "scope")

let test_two_exchanges_do_not_share_a_verifier () =
  let provider = load_or_fail atlassian_toml in
  let one = begin_for provider and two = begin_for provider in
  Alcotest.(check bool)
    "verifiers differ" false
    (String.equal one.Keeper_oauth_flow.verifier two.Keeper_oauth_flow.verifier);
  Alcotest.(check bool)
    "states differ" false
    (String.equal one.Keeper_oauth_flow.state two.Keeper_oauth_flow.state)

let test_authorize_url_with_existing_query_uses_ampersand () =
  let provider = load_or_fail atlassian_toml in
  let discovered =
    { (discovered_atlassian ()) with
      Keeper_oauth_discovery.authorize_url =
        "https://mcp.ramp.com/oauth/authorize?auth_level=auto"
    }
  in
  let pending =
    Keeper_oauth_flow.begin_authorization ~provider ~discovered
      ~client_id:"client-abc" ~scopes:[] ~redirect_uri
      ~keeper:"oauth-fixture"
  in
  let url = pending.Keeper_oauth_flow.authorize_url in
  let question_count =
    String.fold_left (fun acc c -> if c = '?' then acc + 1 else acc) 0 url
  in
  Alcotest.(check int) "exactly one question mark in authorize URL" 1 question_count;
  let query = query_of url in
  check str "preserved existing query param" "auto" (param query "auth_level");
  check str "response type" "code" (param query "response_type")

let recording_post answer =
  let seen = ref None in
  let post ~url ~headers ~body =
    seen := Some (url, headers, body);
    answer
  in
  (post, seen)

let exchange_body ?client_secret provider =
  let pending = begin_for provider in
  let post, seen =
    recording_post
      (Ok
         ( 200,
           {|{"access_token":"at-1","refresh_token":"rt-1","expires_in":3600}|}
         ))
  in
  let _ =
    Keeper_oauth_flow.complete ~post ?client_secret
      ~discovered:(discovered_atlassian ()) ~client_id:"client-abc" ~pending
      ~code:"the-code" ~state:pending.Keeper_oauth_flow.state ~now:0.0 ()
  in
  match !seen with
  | Some (_, _, body) -> body
  | None -> Alcotest.fail "the exchange was never sent"

let test_a_secret_rides_along_on_the_redemption () =
  let provider = load_or_fail atlassian_toml in
  let body = exchange_body ~client_secret:"s3cret" provider in
  Alcotest.(check bool)
    "client_secret is in the form body" true
    (List.mem_assoc "client_secret" (query_of ("?" ^ body)));
  check str "and it is the one given" "s3cret"
    (param (query_of ("?" ^ body)) "client_secret")

let test_no_secret_means_no_parameter () =
  (* Not an empty one: a server that issued no secret refuses a redemption
     that carries client_secret= with nothing after it. *)
  let provider = load_or_fail atlassian_toml in
  let body = exchange_body provider in
  Alcotest.(check bool)
    "no client_secret at all" false
    (List.mem_assoc "client_secret" (query_of ("?" ^ body)))

let complete_with _provider pending ~state ~answer =
  let post, seen = recording_post answer in
  let result =
    Keeper_oauth_flow.complete ~post ~discovered:(discovered_atlassian ())
      ~client_id:"client-abc" ~pending ~code:"the-code" ~state
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
      check (Alcotest.option (Alcotest.float 0.001)) "expiry is dated from now"
        (Some 4600.0) tokens.Keeper_oauth_flow.expires_at

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

let test_a_missing_refresh_token_is_carried_not_refused () =
  (* RFC 6749 5.1 makes both fields optional, so an answer without one is a
     shape rather than a failure to read it. What a Keeper can do with a
     credential it cannot renew is decided where it is stored; refusing here
     read to an operator as a parsing bug in masc. *)
  let provider = load_or_fail atlassian_toml in
  let pending = begin_for provider in
  let result, _ =
    complete_with provider pending ~state:pending.Keeper_oauth_flow.state
      ~answer:(Ok (200, {|{"access_token":"at-1","expires_in":3600}|}))
  in
  match result with
  | Ok tokens ->
      Alcotest.(check (option string))
        "no refresh token came back" None tokens.Keeper_oauth_flow.refresh_token;
      Alcotest.(check (option (float 0.001)))
        "the stated expiry is still dated from now" (Some 4600.0)
        tokens.Keeper_oauth_flow.expires_at
  | Error err ->
      Alcotest.failf "refused an answer it should carry: %s"
        (Keeper_oauth_flow.exchange_error_to_string err)

let test_an_answer_stating_no_expiry_is_carried () =
  (* Slack's token endpoint answers this way for an app without token
     rotation: an access token, no expiry, no refresh token. Measured
     2026-08-27 against a real login. *)
  let provider = load_or_fail atlassian_toml in
  let pending = begin_for provider in
  let result, _ =
    complete_with provider pending ~state:pending.Keeper_oauth_flow.state
      ~answer:(Ok (200, {|{"access_token":"at-1","token_type":"user"}|}))
  in
  match result with
  | Ok tokens ->
      Alcotest.(check string)
        "the access token is read" "at-1" tokens.Keeper_oauth_flow.access_token;
      Alcotest.(check (option (float 0.001)))
        "no moment was named" None tokens.Keeper_oauth_flow.expires_at;
      Alcotest.(check (option string))
        "and nothing to renew with" None tokens.Keeper_oauth_flow.refresh_token
  | Error err ->
      Alcotest.failf "refused a token that simply never expires: %s"
        (Keeper_oauth_flow.exchange_error_to_string err)

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

let test_a_refusal_inside_a_200_is_still_a_refusal () =
  (* Measured 2026-08-27: Slack's token endpoint answers a rejected code with
     HTTP 200 and {"ok":false,"error":"invalid_code"}. Reading the status
     alone files that under "the answer cannot be read", which sends an
     operator looking for a parsing bug instead of at the reason the server
     gave them. *)
  let provider = load_or_fail atlassian_toml in
  let pending = begin_for provider in
  let result, _ =
    complete_with provider pending ~state:pending.Keeper_oauth_flow.state
      ~answer:(Ok (200, {|{"ok":false,"error":"invalid_code"}|}))
  in
  match result with
  | Error (Keeper_oauth_flow.Provider_rejected { status; body }) ->
      Alcotest.(check int) "the status it actually sent" 200 status;
      Alcotest.(check bool) "the reason survives" true
        (Str.string_match (Str.regexp ".*invalid_code") body 0)
  | Error other ->
      Alcotest.failf "wrong refusal: %s"
        (Keeper_oauth_flow.exchange_error_to_string other)
  | Ok _ -> Alcotest.fail "a refusal was read as success"

let test_an_empty_error_member_is_not_a_refusal () =
  (* The member has to say something. An empty one is a provider filling in
     a field, not refusing, and reading it as a refusal would throw away a
     token that was issued. *)
  let provider = load_or_fail atlassian_toml in
  let pending = begin_for provider in
  let result, _ =
    complete_with provider pending ~state:pending.Keeper_oauth_flow.state
      ~answer:
        (Ok
           ( 200,
             {|{"access_token":"at-1","refresh_token":"rt-1","expires_in":3600,"error":""}|}
           ))
  in
  match result with
  | Ok tokens -> check str "the token came through" "at-1"
                   tokens.Keeper_oauth_flow.access_token
  | Error other ->
      Alcotest.failf "a usable answer was refused: %s"
        (Keeper_oauth_flow.exchange_error_to_string other)

let test_an_answer_without_expiry_is_not_guessed () =
  let provider = load_or_fail atlassian_toml in
  let pending = begin_for provider in
  let result, _ =
    complete_with provider pending ~state:pending.Keeper_oauth_flow.state
      ~answer:(Ok (200, {|{"access_token":"at-1","refresh_token":"rt-1"}|}))
  in
  (* Still the point of this test: no moment is made up. What changed is
     where that shows -- an absent expiry rather than a refusal, so a token
     the provider means to last is not read as an unreadable answer. *)
  match result with
  | Ok tokens ->
      Alcotest.(check (option (float 0.001)))
        "no expiry was invented" None tokens.Keeper_oauth_flow.expires_at;
      Alcotest.(check (option string))
        "and the refresh token it did carry is kept" (Some "rt-1")
        tokens.Keeper_oauth_flow.refresh_token
  | Error err ->
      Alcotest.failf "refused instead of carrying the absence: %s"
        (Keeper_oauth_flow.exchange_error_to_string err)

let test_refresh_asks_for_a_refresh_grant () =
  let post, seen = recording_post ok_answer in
  let result =
    Keeper_oauth_flow.refresh ~post ~discovered:(discovered_atlassian ())
      ~client_id:"client-abc" ~refresh_token:"rt-0" ~now:1000.0 ()
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

(* ── the exchanges waiting for a browser ─────────────────────────────── *)

let in_flight_for provider : Keeper_oauth_pending.in_flight =
  { pending = begin_for provider
  ; discovered = discovered_atlassian ()
  ; client_id = "client-abc"
  ; client_secret = None
  }

let test_a_state_is_redeemed_once () =
  let provider = load_or_fail atlassian_toml in
  let table = Keeper_oauth_pending.create () in
  let held = in_flight_for provider in
  Keeper_oauth_pending.remember table ~now:0.0 ~ttl_sec:600.0 held;
  let state = held.Keeper_oauth_pending.pending.Keeper_oauth_flow.state in
  (match Keeper_oauth_pending.take table ~now:1.0 ~state with
  | None -> Alcotest.fail "the exchange was not held"
  | Some found ->
      check str "the verifier came back"
        held.Keeper_oauth_pending.pending.Keeper_oauth_flow.verifier
        found.Keeper_oauth_pending.pending.Keeper_oauth_flow.verifier;
      (* The callback redeems at the endpoint the authorize call was built
         from, not one discovered again in between. *)
      check str "and so did the endpoint it must redeem at"
        held.Keeper_oauth_pending.discovered.Keeper_oauth_discovery.token_url
        found.Keeper_oauth_pending.discovered.Keeper_oauth_discovery.token_url);
  (* A replayed callback finds nothing, which is what it should find. *)
  Alcotest.(check bool)
    "a second callback finds nothing" true
    (Keeper_oauth_pending.take table ~now:2.0 ~state = None)

let test_an_abandoned_login_expires () =
  let provider = load_or_fail atlassian_toml in
  let table = Keeper_oauth_pending.create () in
  let held = in_flight_for provider in
  Keeper_oauth_pending.remember table ~now:0.0 ~ttl_sec:600.0 held;
  let state = held.Keeper_oauth_pending.pending.Keeper_oauth_flow.state in
  Alcotest.(check int) "held while inside the window" 1
    (Keeper_oauth_pending.waiting table ~now:599.0);
  Alcotest.(check int) "gone once past it" 0
    (Keeper_oauth_pending.waiting table ~now:601.0);
  Alcotest.(check bool)
    "and a late callback finds nothing" true
    (Keeper_oauth_pending.take table ~now:601.0 ~state = None)

let test_logins_do_not_collide () =
  let provider = load_or_fail atlassian_toml in
  let table = Keeper_oauth_pending.create () in
  let one = in_flight_for provider and two = in_flight_for provider in
  Keeper_oauth_pending.remember table ~now:0.0 ~ttl_sec:600.0 one;
  Keeper_oauth_pending.remember table ~now:0.0 ~ttl_sec:600.0 two;
  Alcotest.(check int) "both are held" 2
    (Keeper_oauth_pending.waiting table ~now:1.0);
  let verifier (f : Keeper_oauth_pending.in_flight) =
    f.Keeper_oauth_pending.pending.Keeper_oauth_flow.verifier
  in
  let state_of (f : Keeper_oauth_pending.in_flight) =
    f.Keeper_oauth_pending.pending.Keeper_oauth_flow.state
  in
  match
    ( Keeper_oauth_pending.take table ~now:1.0 ~state:(state_of one),
      Keeper_oauth_pending.take table ~now:1.0 ~state:(state_of two) )
  with
  | Some a, Some b ->
      check str "the first kept its own verifier" (verifier one) (verifier a);
      check str "the second kept its own" (verifier two) (verifier b)
  | _ -> Alcotest.fail "one of two concurrent logins was lost"

let test_discovery_reads_both_hops () =
  let get, asked =
    recorded_get ~expect_first:protected_resource_url
      ~expect_second:authorization_server_url
  in
  match Keeper_oauth_discovery.discover ~get ~ask:no_header
    ~mcp_url:atlassian_mcp_url () with
  | Error err ->
      Alcotest.failf "discovery failed: %s"
        (Keeper_oauth_discovery.error_to_string err)
  | Ok found ->
      (* RFC 9728 puts the well-known segment between origin and path.
         Appending happens to work on this server, which is why the order is
         worth pinning rather than discovering on one where it does not. *)
      Alcotest.(check (list string))
        "both hops, in the RFC's URL shape"
        [ protected_resource_url; authorization_server_url ]
        (List.rev !asked);
      check str "authorize" "https://auth.atlassian.com/authorize"
        found.Keeper_oauth_discovery.authorize_url;
      check str "token" "https://auth.atlassian.com/oauth/token"
        found.Keeper_oauth_discovery.token_url;
      Alcotest.(check bool)
        "S256 is offered" true found.Keeper_oauth_discovery.supports_pkce_s256;
      (* What makes an operator-registered app unnecessary. Whether the
         client may be public is deliberately not read here: the metadata
         says one thing and registration answers another. *)
      Alcotest.(check bool)
        "dynamic registration is offered" true
        (found.Keeper_oauth_discovery.registration_url <> None);
      Alcotest.(check bool)
        "Jira scopes are published" true
        (List.mem "write:jira-work" found.Keeper_oauth_discovery.scopes_supported)

(* ── where the metadata is ───────────────────────────────────────────── *)

(* A server of Asana's shape: MCP served below the origin, metadata published
   at the origin, and a 401 that says so. The computed URL misses it, so this
   is the case the header exists for. *)
let origin_only_metadata = "https://mcp.example.com/.well-known/oauth-protected-resource"

let origin_only_get ~url =
  if String.equal url origin_only_metadata then
    Ok (200, {|{"resource":"https://mcp.example.com","authorization_servers":["https://as.example.com"]}|})
  else if
    String.equal url "https://as.example.com/.well-known/oauth-authorization-server"
  then
    Ok
      ( 200,
        {|{"issuer":"https://as.example.com","authorization_endpoint":"https://as.example.com/authorize","token_endpoint":"https://as.example.com/token","code_challenge_methods_supported":["S256"],"token_endpoint_auth_methods_supported":["none"]}|}
      )
  else Ok (404, "not found")

let says ~header = fun ~url:_ -> Some [ ("WWW-Authenticate", header) ]

let test_the_server_says_where_its_metadata_is () =
  match
    Keeper_oauth_discovery.discover ~get:origin_only_get
      ~ask:
        (says
           ~header:
             (Printf.sprintf {|Bearer realm="OAuth", resource_metadata="%s", error="invalid_token"|}
                origin_only_metadata))
      ~mcp_url:"https://mcp.example.com/mcp" ()
  with
  | Ok found ->
      check str "the resource it named" "https://mcp.example.com"
        found.Keeper_oauth_discovery.resource
  | Error err ->
      Alcotest.failf
        "the computed URL was used even though the server named one: %s"
        (Keeper_oauth_discovery.error_to_string err)

let test_no_header_falls_back_to_the_computed_url () =
  (* Nine of the servers measured send no such header, so the computed URL
     is not a fallback for broken servers; it is the other half. *)
  match
    Keeper_oauth_discovery.discover ~get:origin_only_get ~ask:no_header
      ~mcp_url:"https://mcp.example.com/mcp" ()
  with
  | Error (Keeper_oauth_discovery.Not_published { url; _ }) ->
      check str "asked where RFC 9728 puts it"
        "https://mcp.example.com/.well-known/oauth-protected-resource/mcp" url
  | Error other ->
      Alcotest.failf "wrong refusal: %s"
        (Keeper_oauth_discovery.error_to_string other)
  | Ok _ -> Alcotest.fail "the origin document answered a path-qualified ask"

let test_a_plaintext_location_is_not_followed () =
  (* The answer decides where a token comes from. One fetched over http
     could be replaced on the way, so it is dropped and the computed URL
     stands. *)
  match
    Keeper_oauth_discovery.discover ~get:origin_only_get
      ~ask:
        (says
           ~header:
             {|Bearer resource_metadata="http://mcp.example.com/.well-known/oauth-protected-resource"|})
      ~mcp_url:"https://mcp.example.com/mcp" ()
  with
  | Error (Keeper_oauth_discovery.Not_published { url; _ }) ->
      check str "the computed URL was used instead"
        "https://mcp.example.com/.well-known/oauth-protected-resource/mcp" url
  | Error other ->
      Alcotest.failf "wrong refusal: %s"
        (Keeper_oauth_discovery.error_to_string other)
  | Ok _ -> Alcotest.fail "a plaintext metadata location was followed"

let test_a_header_without_the_parameter_is_not_a_location () =
  match
    Keeper_oauth_discovery.discover ~get:origin_only_get
      ~ask:(says ~header:{|Bearer realm="OAuth", error="invalid_token"|})
      ~mcp_url:"https://mcp.example.com/mcp" ()
  with
  | Error (Keeper_oauth_discovery.Not_published { url; _ }) ->
      check str "the computed URL was used instead"
        "https://mcp.example.com/.well-known/oauth-protected-resource/mcp" url
  | Error other ->
      Alcotest.failf "wrong refusal: %s"
        (Keeper_oauth_discovery.error_to_string other)
  | Ok _ -> Alcotest.fail "a header with no location was read as one"

let test_a_terminating_slash_in_the_issuer_is_removed () =
  (* RFC 8414 3.1. Every Google Workspace MCP server names its authorization
     server as "https://accounts.google.com/", and measured 2026-08-27 the
     URL built with that slash left on answers 404 while the one without
     answers 200 -- so this is the difference between reaching Google at all
     and not. *)
  let asked = ref [] in
  let get ~url =
    asked := url :: !asked;
    if String.equal url "https://mcp.example.com/.well-known/oauth-protected-resource/mcp"
    then
      Ok
        ( 200,
          {|{"resource":"https://mcp.example.com/mcp","authorization_servers":["https://as.example.com/"]}|}
        )
    else Ok (404, "not found")
  in
  let _ =
    Keeper_oauth_discovery.discover ~get ~ask:no_header
      ~mcp_url:"https://mcp.example.com/mcp" ()
  in
  Alcotest.(check bool)
    "asked without the terminating slash" true
    (List.mem
       "https://as.example.com/.well-known/oauth-authorization-server"
       !asked);
  Alcotest.(check bool)
    "and not with it" false
    (List.mem
       "https://as.example.com/.well-known/oauth-authorization-server/"
       !asked)

let test_discovery_refuses_a_plaintext_server () =
  match
    Keeper_oauth_discovery.discover ~get:(fun ~url:_ -> Ok (200, "{}"))
      ~ask:no_header ~mcp_url:"http://mcp.example.com/v1" ()
  with
  | Error (Keeper_oauth_discovery.Bad_mcp_url _) -> ()
  | Error other ->
      Alcotest.failf "wrong refusal: %s"
        (Keeper_oauth_discovery.error_to_string other)
  | Ok _ -> Alcotest.fail "a plaintext MCP server was discovered"

let test_discovery_names_a_server_that_publishes_nothing () =
  match
    Keeper_oauth_discovery.discover
      ~get:(fun ~url:_ -> Ok (404, "not found"))
      ~ask:no_header ~mcp_url:atlassian_mcp_url ()
  with
  | Error (Keeper_oauth_discovery.Not_published { status; _ }) ->
      Alcotest.(check int) "the status is kept" 404 status
  | Error other ->
      Alcotest.failf "wrong refusal: %s"
        (Keeper_oauth_discovery.error_to_string other)
  | Ok _ -> Alcotest.fail "a 404 was read as metadata"

let test_discovery_names_a_resource_with_no_authorization_server () =
  match
    Keeper_oauth_discovery.discover
      ~get:(fun ~url:_ ->
        Ok (200, {|{"resource":"https://mcp.example.com/v1"}|}))
      ~ask:no_header ~mcp_url:"https://mcp.example.com/v1" ()
  with
  | Error (Keeper_oauth_discovery.No_authorization_server _) -> ()
  | Error other ->
      Alcotest.failf "wrong refusal: %s"
        (Keeper_oauth_discovery.error_to_string other)
  | Ok _ -> Alcotest.fail "a resource naming no authorization server was accepted"
;;

let test_discovery_falls_back_to_root_when_path_scoped_404 () =
  let get ~url =
    if String.equal url "https://mcp.klaviyo.com/.well-known/oauth-protected-resource/mcp"
    then Ok (404, "not found")
    else if String.equal url "https://mcp.klaviyo.com/.well-known/oauth-protected-resource"
    then
      Ok
        ( 200,
          {|{"resource":"https://mcp.klaviyo.com","authorization_servers":["https://mcp.klaviyo.com"]}|}
        )
    else if String.equal url "https://mcp.klaviyo.com/.well-known/oauth-authorization-server"
    then
      Ok
        ( 200,
          {|{"issuer":"https://mcp.klaviyo.com","authorization_endpoint":"https://mcp.klaviyo.com/authorize","token_endpoint":"https://mcp.klaviyo.com/token","code_challenge_methods_supported":["S256"]}|}
        )
    else Error ("unexpected url: " ^ url)
  in
  let ask ~url:_ = None in
  match Keeper_oauth_discovery.discover ~get ~ask ~mcp_url:"https://mcp.klaviyo.com/mcp" () with
  | Ok d ->
    check str "resource" "https://mcp.klaviyo.com" d.Keeper_oauth_discovery.resource;
    check str "authorize_url" "https://mcp.klaviyo.com/authorize" d.Keeper_oauth_discovery.authorize_url
  | Error err ->
    Alcotest.failf "discovery should have succeeded via root fallback: %s"
      (Keeper_oauth_discovery.error_to_string err)

(* ── registering this installation as a client ───────────────────────── *)

(* Shaped like the real 201 from Atlassian's /dcr/register on 2026-08-26. The
   secret is a placeholder: the real one is not kept anywhere, which is the
   behaviour the last case here pins. *)
let registration_answer =
  {|{"client_id":"registered-client-id","client_id_issued_at":1787720214,
     "client_name":"masc","client_secret":"PLACEHOLDER-NOT-KEPT",
     "client_secret_expires_at":0,"disabled":false,
     "redirect_uris":["http://127.0.0.1:8935/cb"],
     "token_endpoint_auth_method":"none"}|}

let test_registration_asks_as_a_public_client () =
  let post, seen = recording_post (Ok (201, registration_answer)) in
  let result =
    Keeper_oauth_registration.register ~post
      ~registration_url:"https://auth.example.com/dcr/register"
      ~client_name:"masc" ~redirect_uri:"http://127.0.0.1:8935/cb" ()
  in
  (match !seen with
  | None -> Alcotest.fail "registration sent nothing"
  | Some (url, _, body) ->
      check str "registration endpoint"
        "https://auth.example.com/dcr/register" url;
      (* "none" is what makes this a public client, and what lets PKCE be the
         proof instead of a secret with nowhere to live. *)
      Alcotest.(check bool)
        "asks for a public client" true
        (Str.string_match
           (Str.regexp ".*\"token_endpoint_auth_method\":\"none\"") body 0);
      Alcotest.(check bool)
        "asks for a refresh grant" true
        (Str.string_match (Str.regexp ".*refresh_token") body 0));
  match result with
  | Ok registered ->
      check str "client id" "registered-client-id"
        registered.Keeper_oauth_registration.client_id
  | Error err ->
      Alcotest.failf "registration failed: %s"
        (Keeper_oauth_registration.error_to_string err)

let test_registration_does_not_keep_a_secret_it_will_not_send () =
  (* The answer carries one. Nothing in [registered] can hold it, so it stops
     at the boundary rather than becoming a stored credential nobody sends. *)
  match
    Keeper_oauth_registration.register
      ~post:(fun ~url:_ ~headers:_ ~body:_ -> Ok (201, registration_answer))
      ~registration_url:"https://auth.example.com/dcr/register"
      ~client_name:"masc" ~redirect_uri:"http://127.0.0.1:8935/cb" ()
  with
  | Error err ->
      Alcotest.failf "registration failed: %s"
        (Keeper_oauth_registration.error_to_string err)
  | Ok registered ->
      check (Alcotest.float 0.001) "issued_at is the server's" 1787720214.0
        registered.Keeper_oauth_registration.issued_at

let test_registration_keeps_the_servers_reason () =
  match
    Keeper_oauth_registration.register
      ~post:(fun ~url:_ ~headers:_ ~body:_ ->
        Ok (400, {|{"error":"invalid_redirect_uri"}|}))
      ~registration_url:"https://auth.example.com/dcr/register"
      ~client_name:"masc" ~redirect_uri:"nonsense" ()
  with
  | Error (Keeper_oauth_registration.Refused { status; body }) ->
      Alcotest.(check int) "status" 400 status;
      Alcotest.(check bool)
        "the reason an operator can act on survives" true
        (Str.string_match (Str.regexp ".*invalid_redirect_uri") body 0)
  | Error other ->
      Alcotest.failf "wrong refusal: %s"
        (Keeper_oauth_registration.error_to_string other)
  | Ok _ -> Alcotest.fail "a 400 was read as a registration"

(* ── the whole login, both halves ───────────────────────────────────── *)

let stub_discover
      ?(supports_pkce = true)
      ?(registration = Some "https://auth.example.com/dcr")
      ()
  =
  fun ~mcp_url ->
    ignore mcp_url;
    let base = discovered_atlassian () in
    Ok
      { base with
        Keeper_oauth_discovery.supports_pkce_s256 = supports_pkce
      ; registration_url = registration
      }

let never_register ~registration_url:_ ~client_name:_ ~redirect_uri:_ =
  Alcotest.fail "registered a client when one was already configured"

let credentials ?secret ?(scopes = []) client_id =
  { Keeper_oauth_client_store.client_id; client_secret = secret; scopes }

let start_login ?(configured = None) ?discover ?register provider table =
  Keeper_oauth_session.start ?discover ?register ~provider ~configured
    ~client_name:"masc" ~redirect_uri ~keeper:"oauth-fixture" ~pending:table
    ~now:0.0 ~ttl_sec:600.0 ()

let test_start_uses_a_configured_client_rather_than_registering () =
  let provider = load_or_fail atlassian_toml in
  let table = Keeper_oauth_pending.create () in
  match
    start_login ~configured:(Some (credentials "operators-own-app")) ~discover:(stub_discover ())
      ~register:never_register provider table
  with
  | Error err ->
      Alcotest.failf "start failed: %s"
        (Keeper_oauth_session.start_error_to_string err)
  | Ok started ->
      check str "the operator's client id is used" "operators-own-app"
        started.Keeper_oauth_session.credentials
          .Keeper_oauth_client_store.client_id;
      Alcotest.(check bool)
        "and nothing was registered" false
        started.Keeper_oauth_session.registered_now;
      Alcotest.(check int) "the login is waiting" 1
        (Keeper_oauth_pending.waiting table ~now:1.0)

let test_start_registers_when_nobody_configured_one () =
  let provider = load_or_fail atlassian_toml in
  let table = Keeper_oauth_pending.create () in
  let register ~registration_url ~client_name ~redirect_uri:_ =
    check str "registers where discovery said" "https://auth.example.com/dcr"
      registration_url;
    check str "under our own name" "masc" client_name;
    Ok
      { Keeper_oauth_registration.client_id = "freshly-registered"
      ; client_secret = None
      ; issued_at = 1.0
      }
  in
  match start_login ~discover:(stub_discover ()) ~register provider table with
  | Error err ->
      Alcotest.failf "start failed: %s"
        (Keeper_oauth_session.start_error_to_string err)
  | Ok started ->
      check str "the new client id comes back" "freshly-registered"
        started.Keeper_oauth_session.credentials
          .Keeper_oauth_client_store.client_id;
      (* The caller has to persist it, or the next login registers again and
         leaves another client record behind. *)
      Alcotest.(check bool)
        "and says it is new" true started.Keeper_oauth_session.registered_now

let test_start_refuses_a_server_without_pkce () =
  let provider = load_or_fail atlassian_toml in
  let table = Keeper_oauth_pending.create () in
  match
    start_login ~configured:(Some (credentials "id")) ~discover:(stub_discover ~supports_pkce:false ())
      ~register:never_register provider table
  with
  | Error (Keeper_oauth_session.No_pkce_s256 _) ->
      Alcotest.(check int) "and holds no login" 0
        (Keeper_oauth_pending.waiting table ~now:1.0)
  | Error other ->
      Alcotest.failf "wrong refusal: %s"
        (Keeper_oauth_session.start_error_to_string other)
  | Ok _ -> Alcotest.fail "a server with no S256 was accepted"

let test_start_says_when_there_is_no_way_to_get_a_client () =
  let provider = load_or_fail atlassian_toml in
  let table = Keeper_oauth_pending.create () in
  match
    start_login ~discover:(stub_discover ~registration:None ())
      ~register:never_register provider table
  with
  | Error (Keeper_oauth_session.No_registration _) -> ()
  | Error other ->
      Alcotest.failf "wrong refusal: %s"
        (Keeper_oauth_session.start_error_to_string other)
  | Ok _ -> Alcotest.fail "a login started with no client id and no way to get one"

let test_a_registration_with_no_secret_is_a_public_client () =
  (* Measured 2026-08-27: Vercel and Hugging Face both leave "none" out of
     the methods their metadata lists, and both answer registration with a
     public client. An earlier version refused on that metadata and turned
     two working providers into two that could not be attached; the field it
     read is gone, so there is no longer a place to make that call. What a
     server accepts is in its registration answer, and this is that half. *)
  let provider = load_or_fail atlassian_toml in
  let table = Keeper_oauth_pending.create () in
  let register ~registration_url:_ ~client_name:_ ~redirect_uri:_ =
    Ok
      { Keeper_oauth_registration.client_id = "public-anyway"
      ; client_secret = None
      ; issued_at = 1.0
      }
  in
  match
    start_login ~discover:(stub_discover ()) ~register provider table
  with
  | Ok started ->
      check str "registered despite the metadata" "public-anyway"
        started.Keeper_oauth_session.credentials
          .Keeper_oauth_client_store.client_id
  | Error err ->
      Alcotest.failf "a login was refused on metadata alone: %s"
        (Keeper_oauth_session.start_error_to_string err)

let test_a_secret_from_registration_is_kept () =
  (* monday.com answers a request for a public client with a secret, which is
     it saying its token endpoint wants one. Dropping it would leave the
     redemption to fail with the server's word for "who are you". *)
  let provider = load_or_fail atlassian_toml in
  let table = Keeper_oauth_pending.create () in
  let register ~registration_url:_ ~client_name:_ ~redirect_uri:_ =
    Ok
      { Keeper_oauth_registration.client_id = "confidential"
      ; client_secret = Some "s3cret"
      ; issued_at = 1.0
      }
  in
  match start_login ~discover:(stub_discover ()) ~register provider table with
  | Ok started ->
      check
        (Alcotest.option Alcotest.string)
        "the caller is handed it to persist" (Some "s3cret")
        started.Keeper_oauth_session.credentials
          .Keeper_oauth_client_store.client_secret
  | Error err ->
      Alcotest.failf "start failed: %s"
        (Keeper_oauth_session.start_error_to_string err)

let test_the_callback_finishes_the_login_it_started () =
  let provider = load_or_fail atlassian_toml in
  let table = Keeper_oauth_pending.create () in
  match
    start_login ~configured:(Some (credentials "client-abc")) ~discover:(stub_discover ())
      ~register:never_register provider table
  with
  | Error err ->
      Alcotest.failf "start failed: %s"
        (Keeper_oauth_session.start_error_to_string err)
  | Ok started -> (
      let post, seen = recording_post ok_answer in
      let result =
        Keeper_oauth_session.finish ~post ~pending:table
          ~state:started.Keeper_oauth_session.state ~code:"the-code" ~now:1.0 ()
      in
      (match !seen with
      | None -> Alcotest.fail "the callback sent nothing"
      | Some (url, _, _) ->
          (* Redeemed where the first half was built from, not somewhere
             discovered again in between. *)
          check str "redeems at the endpoint the login was built from"
            "https://auth.atlassian.com/oauth/token" url);
      match result with
      | Error err ->
          Alcotest.failf "finish failed: %s"
            (Keeper_oauth_session.finish_error_to_string err)
      | Ok finished ->
          check str "for the Keeper that started it" "oauth-fixture"
            finished.Keeper_oauth_session.keeper;
          check str "under the provider it started with" "atlassian"
            finished.Keeper_oauth_session.provider_id;
          check str "access token" "at-1"
            finished.Keeper_oauth_session.access_token;
          (match finished.Keeper_oauth_session.expiry with
          | Keeper_oauth_session.Renewable { refresh_token; expires_at } ->
              check str "refresh token" "rt-1" refresh_token;
              Alcotest.(check (option (float 0.001)))
                "and the expiry it stated" (Some 3601.0) expires_at
          | Keeper_oauth_session.Never ->
              Alcotest.fail "an answer with both fields read as neither"
          | Keeper_oauth_session.Expiring_without_renewal _ ->
              Alcotest.fail "an answer with a refresh token read as unrenewable");
          Alcotest.(check int) "and the login is no longer waiting" 0
            (Keeper_oauth_pending.waiting table ~now:2.0))

(* The three shapes a finished login can land in, and what each one tells
   the operator. Slack without token rotation is the first; a provider that
   states an expiry and hands over no way to renew is the third, and that is
   the only one anybody has to be warned about. *)
let finish_answering answer =
  let provider = load_or_fail atlassian_toml in
  let table = Keeper_oauth_pending.create () in
  match
    start_login ~configured:(Some (credentials "client-abc")) ~discover:(stub_discover ())
      ~register:never_register provider table
  with
  | Error err ->
      Alcotest.failf "start failed: %s"
        (Keeper_oauth_session.start_error_to_string err)
  | Ok started ->
      let post, _ = recording_post (Ok (200, answer)) in
      Keeper_oauth_session.finish ~post ~pending:table
        ~state:started.Keeper_oauth_session.state ~code:"the-code" ~now:1.0 ()

let test_a_token_that_never_expires_needs_no_warning () =
  match finish_answering {|{"access_token":"at-1","token_type":"user"}|} with
  | Error err ->
      Alcotest.failf "a login Slack completes was refused: %s"
        (Keeper_oauth_session.finish_error_to_string err)
  | Ok finished -> (
      match finished.Keeper_oauth_session.expiry with
      | Keeper_oauth_session.Never ->
          Alcotest.(check (option string))
            "nothing hangs over this one" None
            (Keeper_oauth_session.expiry_warning finished.Keeper_oauth_session.expiry)
      | Keeper_oauth_session.Renewable _ ->
          Alcotest.fail "an answer carrying no refresh token read as renewable"
      | Keeper_oauth_session.Expiring_without_renewal _ ->
          Alcotest.fail "an answer naming no expiry read as expiring")

let test_an_expiry_with_no_way_to_renew_is_warned_about () =
  match finish_answering {|{"access_token":"at-1","expires_in":3600}|} with
  | Error err ->
      Alcotest.failf "finish failed: %s"
        (Keeper_oauth_session.finish_error_to_string err)
  | Ok finished -> (
      match finished.Keeper_oauth_session.expiry with
      | Keeper_oauth_session.Expiring_without_renewal expires_at ->
          Alcotest.(check (float 0.001))
            "dated from the moment it was read" 3601.0 expires_at;
          (* The one shape that ends in a Keeper losing a provider with
             nothing on disk to say why, so the page has to say it. *)
          Alcotest.(check bool)
            "the operator is told before they close the tab" true
            (Keeper_oauth_session.expiry_warning finished.Keeper_oauth_session.expiry
            <> None)
      | Keeper_oauth_session.Never ->
          Alcotest.fail "a stated expiry read as none"
      | Keeper_oauth_session.Renewable _ ->
          Alcotest.fail "an answer carrying no refresh token read as renewable")

let test_a_callback_nobody_is_waiting_on_says_so () =
  let table = Keeper_oauth_pending.create () in
  match
    Keeper_oauth_session.finish
      ~post:(fun ~url:_ ~headers:_ ~body:_ ->
        Alcotest.fail "sent an exchange for a state nobody was waiting on")
      ~pending:table ~state:"never-issued" ~code:"the-code"
      ~now:1.0 ()
  with
  | Error Keeper_oauth_session.Unknown_state -> ()
  | Error other ->
      Alcotest.failf "wrong refusal: %s"
        (Keeper_oauth_session.finish_error_to_string other)
  | Ok _ -> Alcotest.fail "a code was redeemed against no login"

(* ── the client this install registered ──────────────────────────────── *)

let temp_dir () =
  let path =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-oauth-client-%d-%d" (Unix.getpid ())
         (Random.int 1_000_000))
  in
  Unix.mkdir path 0o700;
  path

let test_no_client_until_one_is_registered () =
  let dir = temp_dir () in
  let provider = load_or_fail atlassian_toml in
  match Keeper_oauth_client_store.load ~dir ~provider with
  | Ok None -> ()
  | Ok (Some found) ->
      Alcotest.failf "found a client nobody registered: %s"
        found.Keeper_oauth_client_store.client_id
  | Error message -> Alcotest.failf "reading an empty directory failed: %s" message

let test_a_registered_client_comes_back () =
  let dir = temp_dir () in
  let provider = load_or_fail atlassian_toml in
  (match
     Keeper_oauth_client_store.save ~dir ~provider
       (credentials "client-from-registration")
   with
  | Ok () -> ()
  | Error message -> Alcotest.failf "saving failed: %s" message);
  match Keeper_oauth_client_store.load ~dir ~provider with
  | Ok (Some found) ->
      check str "the id that was saved" "client-from-registration"
        found.Keeper_oauth_client_store.client_id;
      check
        (Alcotest.option Alcotest.string)
        "and no secret was invented" None
        found.Keeper_oauth_client_store.client_secret
  | Ok None -> Alcotest.fail "the saved client id did not come back"
  | Error message -> Alcotest.failf "reading back failed: %s" message

let test_a_secret_saved_beside_the_id_comes_back () =
  let dir = temp_dir () in
  let provider = load_or_fail atlassian_toml in
  (match
     Keeper_oauth_client_store.save ~dir ~provider
       (credentials ~secret:"s3cret" "confidential")
   with
  | Ok () -> ()
  | Error message -> Alcotest.failf "saving failed: %s" message);
  (match Keeper_oauth_client_store.load ~dir ~provider with
  | Ok (Some found) ->
      check
        (Alcotest.option Alcotest.string)
        "the secret that was saved" (Some "s3cret")
        found.Keeper_oauth_client_store.client_secret
  | Ok None -> Alcotest.fail "the saved client did not come back"
  | Error message -> Alcotest.failf "reading back failed: %s" message);
  (* Beside the id rather than inside it, and readable only by this user. *)
  let mode =
    (Unix.stat
       (Filename.concat (Filename.concat dir "atlassian") "client_secret"))
      .Unix.st_perm
  in
  check Alcotest.int "0600" 0o600 mode

let test_an_empty_client_file_is_not_a_client () =
  (* A write that did not finish. Reading it as "no client" would register a
     second one over it and leave the first stranded on a server this install
     does not administer. *)
  let dir = temp_dir () in
  let provider = load_or_fail atlassian_toml in
  Unix.mkdir (Filename.concat dir "atlassian") 0o700;
  Out_channel.with_open_bin
    (Filename.concat (Filename.concat dir "atlassian") "client_id")
    (fun oc -> Out_channel.output_string oc "   ");
  match Keeper_oauth_client_store.load ~dir ~provider with
  | Error _ -> ()
  | Ok None -> Alcotest.fail "an unfinished write read as having no client"
  | Ok (Some found) ->
      Alcotest.failf "read whitespace as a client id: %S"
        found.Keeper_oauth_client_store.client_id

let test_the_id_has_to_be_one_path_component () =
  (* [t] is private and the client store joins the id onto a directory
     without checking, so the check has to be here. *)
  let escaping =
    Str.global_replace
      (Str.regexp_string {|id = "atlassian"|})
      {|id = "../elsewhere"|} atlassian_toml
  in
  expect_rejected ~why:"names a path rather than a provider"
    ~file_name:"../elsewhere" escaping

(* ── the declaration against the projection that stores it ───────────── *)

module Keeper_secret_projection = Masc.Keeper_secret_projection

let test_the_shipped_file_entry_is_one_the_projection_accepts () =
  (* The declaration says where the refresh token goes; the projection
     decides what it will accept. Nothing makes those two agree, so this
     asks the projection directly rather than restating its rule here. *)
  let provider = load_or_fail (shipped_atlassian ()) in
  let base_path = temp_dir () in
  match
    Keeper_secret_projection.set_file_entry ~base_path ~keeper_name:"oauth-fixture"
      ~scope:Keeper_secret_projection.Keeper_secret
      ~container_path:provider.Keeper_oauth_provider.refresh_token_file
      ~value:"a-refresh-token"
  with
  | Ok () -> ()
  | Error message ->
      Alcotest.failf "the shipped refresh_token_file is not storable: %s" message

let test_the_shipped_env_entries_are_ones_the_projection_accepts () =
  let provider = load_or_fail (shipped_atlassian ()) in
  let base_path = temp_dir () in
  let set name value =
    Keeper_secret_projection.set_env_entry ~base_path ~keeper_name:"oauth-fixture"
      ~scope:Keeper_secret_projection.Keeper_secret ~name ~value
  in
  (match set provider.Keeper_oauth_provider.access_token_env "an-access-token" with
  | Ok () -> ()
  | Error message -> Alcotest.failf "access_token_env is not storable: %s" message);
  match set provider.Keeper_oauth_provider.expires_at_env "1780000000" with
  | Ok () -> ()
  | Error message -> Alcotest.failf "expires_at_env is not storable: %s" message

let () =
  Alcotest.run "keeper_oauth_identity"
    [ ( "declaration",
        [ Alcotest.test_case "shipped GitHub file reads the gh CLI credential"
            `Quick test_shipped_github_reads_the_gh_cli_credential;
          Alcotest.test_case "absent credential source is the OAuth exchange"
            `Quick test_absent_credential_source_is_the_oauth_exchange;
          Alcotest.test_case "unknown credential source is rejected"
            `Quick test_unknown_credential_source_is_rejected;
          Alcotest.test_case "github_cli source requires a host"
            `Quick test_github_cli_source_requires_a_host;
          Alcotest.test_case "github_cli source with a host is accepted"
            `Quick test_github_cli_source_with_a_host_is_accepted;
          Alcotest.test_case "reads the shipped Atlassian file" `Quick
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
          Alcotest.test_case "a server naming no scopes is asked for none"
            `Quick test_a_server_that_names_no_scopes_is_asked_for_none;
          Alcotest.test_case "recorded scopes replace the published ones"
            `Quick test_recorded_scopes_replace_the_published_ones;
          Alcotest.test_case "two exchanges share nothing" `Quick
            test_two_exchanges_do_not_share_a_verifier;
          Alcotest.test_case "existing query parameters preserve separator"
            `Quick test_authorize_url_with_existing_query_uses_ampersand;
        ] );
      ( "exchange",
        [ Alcotest.test_case "redeems the verifier and dates the expiry" `Quick
            test_completion_sends_the_verifier_and_dates_the_expiry;
          Alcotest.test_case "refuses a foreign state before sending" `Quick
            test_a_foreign_state_is_refused_before_anything_is_sent;
          Alcotest.test_case "carries a missing refresh token" `Quick
            test_a_missing_refresh_token_is_carried_not_refused;
          Alcotest.test_case "carries an answer stating no expiry" `Quick
            test_an_answer_stating_no_expiry_is_carried;
          Alcotest.test_case "keeps the provider's reason" `Quick
            test_a_refusal_keeps_the_providers_reason;
          Alcotest.test_case "a refusal inside a 200 is still a refusal" `Quick
            test_a_refusal_inside_a_200_is_still_a_refusal;
          Alcotest.test_case "an empty error member is not a refusal" `Quick
            test_an_empty_error_member_is_not_a_refusal;
          Alcotest.test_case "does not invent an expiry" `Quick
            test_an_answer_without_expiry_is_not_guessed;
          Alcotest.test_case "refresh asks for a refresh grant" `Quick
            test_refresh_asks_for_a_refresh_grant;
          Alcotest.test_case "the renewal window opens before expiry" `Quick
            test_renewal_window_opens_before_expiry;
        ] );
      ( "discovery",
        [ Alcotest.test_case "reads both hops from the recorded answers" `Quick
            test_discovery_reads_both_hops;
          Alcotest.test_case "refuses a plaintext MCP server" `Quick
            test_discovery_refuses_a_plaintext_server;
          Alcotest.test_case "names a server that publishes nothing" `Quick
            test_discovery_names_a_server_that_publishes_nothing;
          Alcotest.test_case "names a resource with no authorization server"
            `Quick test_discovery_names_a_resource_with_no_authorization_server;
          Alcotest.test_case "a terminating slash in the issuer is removed"
            `Quick test_a_terminating_slash_in_the_issuer_is_removed;
          Alcotest.test_case "the server says where its metadata is" `Quick
            test_the_server_says_where_its_metadata_is;
          Alcotest.test_case "no header falls back to the computed URL" `Quick
            test_no_header_falls_back_to_the_computed_url;
          Alcotest.test_case "a plaintext location is not followed" `Quick
            test_a_plaintext_location_is_not_followed;
          Alcotest.test_case "a header without the parameter is not a location"
            `Quick test_a_header_without_the_parameter_is_not_a_location;
          Alcotest.test_case "falls back to root when path-scoped endpoint is 404"
            `Quick test_discovery_falls_back_to_root_when_path_scoped_404;
        ] );
      ( "registration",
        [ Alcotest.test_case "asks as a public client" `Quick
            test_registration_asks_as_a_public_client;
          Alcotest.test_case "does not keep a secret it will not send" `Quick
            test_registration_does_not_keep_a_secret_it_will_not_send;
          Alcotest.test_case "keeps the server's reason" `Quick
            test_registration_keeps_the_servers_reason;
        ] );
      ( "login",
        [ Alcotest.test_case "uses a configured client rather than registering"
            `Quick test_start_uses_a_configured_client_rather_than_registering;
          Alcotest.test_case "registers when nobody configured one" `Quick
            test_start_registers_when_nobody_configured_one;
          Alcotest.test_case "refuses a server without PKCE" `Quick
            test_start_refuses_a_server_without_pkce;
          Alcotest.test_case "says when there is no way to get a client" `Quick
            test_start_says_when_there_is_no_way_to_get_a_client;
          Alcotest.test_case "no secret back means a public client" `Quick
            test_a_registration_with_no_secret_is_a_public_client;
          Alcotest.test_case "a secret from registration is kept" `Quick
            test_a_secret_from_registration_is_kept;
          Alcotest.test_case "a secret rides along on the redemption" `Quick
            test_a_secret_rides_along_on_the_redemption;
          Alcotest.test_case "no secret means no parameter" `Quick
            test_no_secret_means_no_parameter;
          Alcotest.test_case "the callback finishes the login it started" `Quick
            test_the_callback_finishes_the_login_it_started;
          Alcotest.test_case "a token that never expires needs no warning" `Quick
            test_a_token_that_never_expires_needs_no_warning;
          Alcotest.test_case "an expiry with no way to renew is warned about"
            `Quick test_an_expiry_with_no_way_to_renew_is_warned_about;
          Alcotest.test_case "a callback nobody is waiting on says so" `Quick
            test_a_callback_nobody_is_waiting_on_says_so;
        ] );
      ( "the registered client",
        [ Alcotest.test_case "none until one is registered" `Quick
            test_no_client_until_one_is_registered;
          Alcotest.test_case "a registered client comes back" `Quick
            test_a_registered_client_comes_back;
          Alcotest.test_case "a secret saved beside the id comes back" `Quick
            test_a_secret_saved_beside_the_id_comes_back;
          Alcotest.test_case "an unfinished write is not a client" `Quick
            test_an_empty_client_file_is_not_a_client;
          Alcotest.test_case "the id has to be one path component" `Quick
            test_the_id_has_to_be_one_path_component;
        ] );
      ( "what the declaration says against what stores it",
        [ Alcotest.test_case "the shipped file entry is storable" `Quick
            test_the_shipped_file_entry_is_one_the_projection_accepts;
          Alcotest.test_case "the shipped env entries are storable" `Quick
            test_the_shipped_env_entries_are_ones_the_projection_accepts;
        ] );
      ( "pending",
        [ Alcotest.test_case "a state is redeemed once" `Quick
            test_a_state_is_redeemed_once;
          Alcotest.test_case "an abandoned login expires" `Quick
            test_an_abandoned_login_expires;
          Alcotest.test_case "two logins do not collide" `Quick
            test_logins_do_not_collide;
        ] );
    ]
