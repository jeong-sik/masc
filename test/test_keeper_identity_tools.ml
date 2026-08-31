(** What an attached work service contributes to a Keeper's tool surface.

    The catalog is written to disk and read back, so these run against real
    files under a temp base path. Nothing here reaches a provider: the point
    is what happens between the written catalog and the tool list a turn is
    handed. *)

module Identity_tools = Masc.Keeper_identity_tools
module Provider = Keeper_oauth_provider
module Projection = Masc.Keeper_secret_projection

(* The Keeper name here is deliberately not a word: an ordinary one
   eventually picks a live Keeper's, which is what
   test/fixtures/concrete-keeper-identities.txt exists to stop. *)
let check = Alcotest.check
let str = Alcotest.string

let declaration =
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

let provider () =
  match Provider.load ~file_name:"atlassian" ~contents:declaration with
  | Ok provider -> provider
  | Error err ->
      Alcotest.failf "declaration rejected: %s" (Provider.error_to_string err)

let temp_base () =
  let path =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-identity-tools-%d-%d" (Unix.getpid ())
         (Random.int 1_000_000))
  in
  Unix.mkdir path 0o700;
  path

let tool ?read_only name =
  {
    Mcp_client.name;
    read_only;
    description = "does " ^ name;
    input_schema =
      `Assoc
        [ ("type", `String "object");
          ("properties", `Assoc [ ("key", `Assoc [ ("type", `String "string") ]) ])
        ];
  }

(* The catalog is normally written by a refresh against a live provider.
   Writing it directly is what lets everything after that point be tested
   without one. *)
let write_catalog ~base_path ~keeper_name tools =
  let catalog_json =
    `Assoc
      [ ("provider_id", `String "atlassian");
        ("provider_label", `String "Atlassian");
        ("discovered_at", `Float 1786000000.0);
        ( "tools",
          `List
            (List.map
               (fun (t : Mcp_client.tool) ->
                 `Assoc
                   ([ ("name", `String t.Mcp_client.name);
                      ("description", `String t.Mcp_client.description);
                      ("input_schema", t.Mcp_client.input_schema)
                    ]
                    @
                    match t.Mcp_client.read_only with
                    | Some value -> [ ("read_only", `Bool value) ]
                    | None -> []))
               tools) )
      ]
  in
  let dir =
    Filename.concat
      (Filename.concat (Filename.concat base_path ".masc") "identity")
      (Filename.concat "catalogs" keeper_name)
  in
  let rec ensure path =
    if not (Sys.file_exists path) then (
      ensure (Filename.dirname path);
      try Unix.mkdir path 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  in
  ensure dir;
  Out_channel.with_open_bin (Filename.concat dir "atlassian.json") (fun oc ->
      Out_channel.output_string oc (Yojson.Safe.to_string catalog_json))

let names offering =
  List.map
    (fun (offered : Identity_tools.offered_tool) ->
      offered.Identity_tools.schema.name)
    offering.Identity_tools.offered

(* Executing an offered tool in a turn now goes through
   {!Keeper_identity_gate}, which needs a turn's config and meta. What the
   tests here pin is the layer under it — which credential is read and what
   the model is told — and [run_call] plus [tool_result_of_call] is that
   layer. *)
let execute_offered ?post ~base_path (offered : Identity_tools.offered_tool)
    arguments =
  Identity_tools.tool_result_of_call
    (Identity_tools.run_call ?post ~base_path ~keeper_name:"acme-daycare"
       ~provider:offered.Identity_tools.provider
       ~remote_name:offered.Identity_tools.remote_name ~arguments ())

(* ── the on/off switch ───────────────────────────────────────────────── *)

module Switch = Masc.Keeper_identity_switch

let switch_config base_path = Masc.Workspace.default_config base_path

let names_offered_for_turn ~base_path ~keeper_name =
  (Identity_tools.for_turn ~base_path ~keeper_name).Identity_tools.offered
  |> List.map (fun (offered : Identity_tools.offered_tool) ->
         offered.Identity_tools.schema.name)

let test_no_switch_file_means_everything_on () =
  let base_path = temp_base () in
  (match Switch.disabled_rows ~base_path with
  | Ok [] -> ()
  | Ok _ -> Alcotest.fail "switches appeared that nobody threw"
  | Error message -> Alcotest.failf "an absent store read as broken: %s" message);
  match
    Switch.is_disabled ~base_path ~keeper_name:"acme-daycare"
      ~provider_id:"atlassian"
  with
  | Ok false -> ()
  | Ok true -> Alcotest.fail "an absent store switched a service off"
  | Error message -> Alcotest.failf "an absent store read as broken: %s" message

let test_a_thrown_switch_takes_the_tools_out_of_the_turn () =
  let base_path = temp_base () in
  write_catalog ~base_path ~keeper_name:"acme-daycare" [ tool "getJiraIssue" ];
  check (Alcotest.list str) "on: the turn is handed the tool"
    [ "atlassian_getJiraIssue" ]
    (names_offered_for_turn ~base_path ~keeper_name:"acme-daycare");
  (match
     Switch.set (switch_config base_path) ~actor:"switch-test"
       ~keeper_name:"acme-daycare" ~provider_id:"atlassian" ~enabled:false
   with
  | Ok () -> ()
  | Error message -> Alcotest.failf "could not throw the switch: %s" message);
  let off = Identity_tools.for_turn ~base_path ~keeper_name:"acme-daycare" in
  check (Alcotest.list str) "off: the turn is handed nothing" []
    (List.map
       (fun (offered : Identity_tools.offered_tool) ->
         offered.Identity_tools.schema.name)
       off.Identity_tools.offered);
  check Alcotest.bool "and off is a choice, not a problem" true
    (not
       (List.exists
          (fun (id, _) -> String.equal id "atlassian")
          off.Identity_tools.unusable));
  (* Another keeper's turn is untouched: the switch is per keeper. *)
  write_catalog ~base_path ~keeper_name:"other-fixture" [ tool "getJiraIssue" ];
  check (Alcotest.list str) "another keeper keeps its tools"
    [ "atlassian_getJiraIssue" ]
    (names_offered_for_turn ~base_path ~keeper_name:"other-fixture");
  (match
     Switch.set (switch_config base_path) ~actor:"switch-test"
       ~keeper_name:"acme-daycare" ~provider_id:"atlassian" ~enabled:true
   with
  | Ok () -> ()
  | Error message -> Alcotest.failf "could not clear the switch: %s" message);
  check (Alcotest.list str) "back on: the tool returns"
    [ "atlassian_getJiraIssue" ]
    (names_offered_for_turn ~base_path ~keeper_name:"acme-daycare")

let test_setting_the_state_it_already_has_writes_nothing () =
  let base_path = temp_base () in
  (match
     Switch.set (switch_config base_path) ~actor:"switch-test"
       ~keeper_name:"acme-daycare" ~provider_id:"atlassian" ~enabled:true
   with
  | Ok () -> ()
  | Error message -> Alcotest.failf "an on/on no-op failed: %s" message);
  check Alcotest.bool "no store file appears for a no-op" false
    (Sys.file_exists (Switch.path ~base_path))

let test_an_unreadable_switch_store_offers_nothing () =
  (* Handing out tools an operator may have turned off is the one wrong
     answer. The turn gets nothing, loudly, until the store is repaired. *)
  let base_path = temp_base () in
  write_catalog ~base_path ~keeper_name:"acme-daycare" [ tool "getJiraIssue" ];
  let file = Switch.path ~base_path in
  let rec ensure path =
    if not (Sys.file_exists path) then (
      ensure (Filename.dirname path);
      try Unix.mkdir path 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  in
  ensure (Filename.dirname file);
  Out_channel.with_open_bin file (fun oc ->
      Out_channel.output_string oc "{ not a list");
  let off = Identity_tools.for_turn ~base_path ~keeper_name:"acme-daycare" in
  check (Alcotest.list str) "nothing is offered" []
    (List.map
       (fun (offered : Identity_tools.offered_tool) ->
         offered.Identity_tools.schema.name)
       off.Identity_tools.offered);
  check Alcotest.bool "and the reason is loud, not silent" true
    (List.exists
       (fun (id, _) -> String.equal id "atlassian")
       off.Identity_tools.unusable)

(* ── the catalog ─────────────────────────────────────────────────────── *)

let test_never_attached_is_not_an_error () =
  (* "no catalog" and "a catalog that will not read" are different things,
     and reading the first as the second would have an operator hunting a
     failure that never happened. *)
  let base_path = temp_base () in
  match
    Identity_tools.load ~base_path ~keeper_name:"acme-daycare"
      ~provider_id:"atlassian"
  with
  | Ok None -> ()
  | Ok (Some _) -> Alcotest.fail "found a catalog nobody wrote"
  | Error message -> Alcotest.failf "an absent catalog read as broken: %s" message

let test_an_unreadable_catalog_is_not_no_tools () =
  let base_path = temp_base () in
  let dir =
    Filename.concat
      (Filename.concat (Filename.concat base_path ".masc") "identity")
      (Filename.concat "catalogs" "acme-daycare")
  in
  let rec ensure path =
    if not (Sys.file_exists path) then (
      ensure (Filename.dirname path);
      try Unix.mkdir path 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  in
  ensure dir;
  Out_channel.with_open_bin (Filename.concat dir "atlassian.json") (fun oc ->
      Out_channel.output_string oc "{ this is not json");
  match
    Identity_tools.load ~base_path ~keeper_name:"acme-daycare"
      ~provider_id:"atlassian"
  with
  | Error _ -> ()
  | Ok None -> Alcotest.fail "a broken catalog read as never attached"
  | Ok (Some _) -> Alcotest.fail "read a broken catalog as a catalog"

(* Measured against the live Atlassian server on 2026-08-26: the access
   token came back 3,446 characters long and the refresh token 2,792. Both
   go through the secret projection, and every earlier check here used a
   short placeholder -- which would have passed while a real one was
   refused. *)
let live_access_token_chars = 3_446
let live_refresh_token_chars = 2_792

let test_a_real_sized_token_is_storable () =
  let base_path = temp_base () in
  let provider = provider () in
  (match
     Projection.set_env_entry ~base_path ~keeper_name:"attaching-fixture"
       ~scope:Projection.Keeper_secret
       ~name:provider.Provider.access_token_env
       ~value:(String.make live_access_token_chars 'x')
   with
  | Ok () -> ()
  | Error message ->
      Alcotest.failf "a real-sized access token is not storable: %s" message);
  match
    Projection.set_file_entry ~base_path ~keeper_name:"attaching-fixture"
      ~scope:Projection.Keeper_secret
      ~container_path:provider.Provider.refresh_token_file
      ~value:(String.make live_refresh_token_chars 'y')
  with
  | Ok () -> ()
  | Error message ->
      Alcotest.failf "a real-sized refresh token is not storable: %s" message

let test_a_real_sized_token_survives_the_projection () =
  (* Stored is not the same as handed to a runtime. The token reaches a tool
     call through the projected environment, and that is the array a child
     process is given. *)
  let base_path = temp_base () in
  let provider = provider () in
  let token = String.make live_access_token_chars 'x' in
  (match
     Projection.set_env_entry ~base_path ~keeper_name:"attaching-fixture"
       ~scope:Projection.Keeper_secret
       ~name:provider.Provider.access_token_env ~value:token
   with
  | Ok () -> ()
  | Error message -> Alcotest.failf "could not store: %s" message);
  match
    Projection.local_env_for_keeper ~host_env:[||] ~base_path
      ~keeper_name:"attaching-fixture" ()
  with
  | Error message -> Alcotest.failf "projection failed: %s" message
  | Ok None -> Alcotest.fail "no projection for this keeper"
  | Ok (Some entries) ->
      let prefix = provider.Provider.access_token_env ^ "=" in
      let found =
        Array.to_list entries
        |> List.find_map (fun entry ->
               if String.starts_with ~prefix entry then
                 Some
                   (String.sub entry (String.length prefix)
                      (String.length entry - String.length prefix))
               else None)
      in
      check (Alcotest.option Alcotest.int) "the whole token comes through"
        (Some live_access_token_chars)
        (Option.map String.length found)

let test_a_written_catalog_comes_back () =
  let base_path = temp_base () in
  write_catalog ~base_path ~keeper_name:"acme-daycare"
    [ tool "getJiraIssue"; tool "searchIssues" ];
  match
    Identity_tools.load ~base_path ~keeper_name:"acme-daycare"
      ~provider_id:"atlassian"
  with
  | Ok (Some catalog) ->
      check str "label" "Atlassian" catalog.Identity_tools.provider_label;
      check (Alcotest.list str) "tool names"
        [ "getJiraIssue"; "searchIssues" ]
        (List.map
           (fun (t : Mcp_client.tool) -> t.Mcp_client.name)
           catalog.Identity_tools.tools)
  | Ok None -> Alcotest.fail "the written catalog did not come back"
  | Error message -> Alcotest.failf "reading back failed: %s" message

(* ── the tool surface ────────────────────────────────────────────────── *)

let test_names_are_namespaced_by_provider () =
  (* A provider is free to call something [search], and so is masc. Without
     the prefix the model is handed two tools with one name and no way to
     mean either. *)
  let base_path = temp_base () in
  write_catalog ~base_path ~keeper_name:"acme-daycare" [ tool "search" ];
  match
    Identity_tools.load ~base_path ~keeper_name:"acme-daycare"
      ~provider_id:"atlassian"
  with
  | Ok (Some catalog) ->
      let offering =
        Identity_tools.agent_tools ~provider:(provider ()) catalog
      in
      check (Alcotest.list str) "prefixed" [ "atlassian_search" ]
        (names offering)
  | Ok None | Error _ -> Alcotest.fail "the catalog did not come back"

let test_a_schema_that_cannot_be_projected_is_reported () =
  (* Excluded, but named. A shorter tool list with no reason for it is how
     an operator ends up reading code to find out what happened. *)
  let base_path = temp_base () in
  let bad =
    { Mcp_client.name = "weird"; description = ""; read_only = None;
      input_schema = `String "not a schema" }
  in
  write_catalog ~base_path ~keeper_name:"acme-daycare" [ tool "fine"; bad ];
  match
    Identity_tools.load ~base_path ~keeper_name:"acme-daycare"
      ~provider_id:"atlassian"
  with
  | Ok (Some catalog) ->
      let offering =
        Identity_tools.agent_tools ~provider:(provider ()) catalog
      in
      check (Alcotest.list str) "the usable one is offered"
        [ "atlassian_fine" ] (names offering);
      check Alcotest.int "and the other is named" 1
        (List.length offering.Identity_tools.unusable)
  | Ok None | Error _ -> Alcotest.fail "the catalog did not come back"

let test_a_keeper_with_no_token_gets_a_refusal_not_a_crash () =
  (* The tools are on the surface because the catalog says so; the token is
     read when one is called. A Keeper whose credential was deleted has to
     get an answer, not an exception. *)
  let base_path = temp_base () in
  write_catalog ~base_path ~keeper_name:"acme-daycare" [ tool ~read_only:true "getJiraIssue" ];
  match
    Identity_tools.load ~base_path ~keeper_name:"acme-daycare"
      ~provider_id:"atlassian"
  with
  | Ok (Some catalog) -> (
      let offering =
        Identity_tools.agent_tools ~provider:(provider ()) catalog
      in
      match offering.Identity_tools.offered with
      | [ offered ] -> (
          match execute_offered ~base_path offered (`Assoc []) with
          | Error err ->
              check Alcotest.bool "and the model is not told to retry" false
                err.Agent_core.Types.recoverable
          | Ok _ -> Alcotest.fail "called a provider with no credential")
      | _ -> Alcotest.fail "expected exactly one tool")
  | Ok None | Error _ -> Alcotest.fail "the catalog did not come back"

(* A transport that records what it was asked and answers whatever the test
   set. Nothing here reaches a network. *)
let recording_transport () =
  let sent = ref [] in
  let post ~url ~headers ~body =
    sent := (url, headers, body) :: !sent;
    let answer =
      if String.length body > 0 && Str.string_match (Str.regexp ".*initialize") body 0
      then
        Printf.sprintf
          {|{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":%S,"capabilities":{}}}|}
          Mcp_transport_protocol.default_protocol_version
      else
        {|{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"PK-1"}]}}|}
    in
    Ok
      {
        Masc_http_client.status = 200;
        headers = [ ("content-type", "application/json") ];
        body = answer;
      }
  in
  (post, sent)

let bearer sent =
  List.rev !sent
  |> List.find_map (fun (_, headers, _) -> List.assoc_opt "Authorization" headers)

let single_offered ~base_path =
  match
    Identity_tools.load ~base_path ~keeper_name:"acme-daycare"
      ~provider_id:"atlassian"
  with
  | Ok (Some catalog) -> (
      let offering = Identity_tools.agent_tools ~provider:(provider ()) catalog in
      match offering.Identity_tools.offered with
      | [ offered ] -> offered
      | _ -> Alcotest.fail "expected exactly one tool")
  | Ok None | Error _ -> Alcotest.fail "the catalog did not come back"

(* ── where the bearer comes from ─────────────────────────────────────── *)

module Github = Masc.Keeper_github_identity

let github_declaration =
  {|
id = "github"
label = "GitHub"
mcp_url = "https://api.githubcopilot.com/mcp/"
credential_source = "github_cli"
credential_source_host = "github.com"
access_token_env = "GITHUB_ACCESS_TOKEN"
expires_at_env = "GITHUB_ACCESS_TOKEN_EXPIRES_AT"
refresh_token_file = "/home/keeper/.github/refresh_token"
renew_before_sec = 600
|}

let github_provider () =
  match Provider.load ~file_name:"github" ~contents:github_declaration with
  | Ok provider -> provider
  | Error err ->
      Alcotest.failf "declaration rejected: %s" (Provider.error_to_string err)

(* Writes the credential the way the GitHub tab does -- through
   [ensure_config_dir], which resolves the directory from a workspace config
   -- and leaves the reader to resolve it from a base path. If those two ever
   name different directories the token is written where nothing looks. *)
let rec mkdir_p path =
  if Sys.file_exists path
  then ()
  else (
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o700)

let write_gh_identity ~base_path ~keeper_name token =
  let config = Masc.Workspace.default_config base_path in
  mkdir_p (Masc.Workspace.keepers_runtime_dir config);
  let config_dir =
    match Github.ensure_config_dir ~config ~keeper_name with
    | Error message -> Alcotest.failf "gh config dir: %s" message
    | Ok path -> path
  in
  let hosts = Filename.concat config_dir "hosts.yml" in
  let channel = open_out_bin hosts in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel (Printf.sprintf "github.com:\n  oauth_token: %s\n" token));
  Unix.chmod hosts 0o600

(* GitHub publishes no registration endpoint, so nothing ever writes
   GITHUB_ACCESS_TOKEN into the projection. The declaration says the bearer is
   the one gh already holds, and this is that claim as a sent request rather
   than as a field being set somewhere. *)
let test_github_cli_credential_is_what_gets_sent () =
  let base_path = temp_base () in
  let keeper_name = "acme-daycare" in
  write_gh_identity ~base_path ~keeper_name "gho_from_device_login";
  let post, sent = recording_transport () in
  match
    Identity_tools.run_call ~post ~base_path ~keeper_name
      ~provider:(github_provider ()) ~remote_name:"list_issues"
      ~arguments:(`Assoc []) ()
  with
  | Error _ -> Alcotest.fail "a logged-in gh identity did not authorize the call"
  | Ok _ ->
      check (Alcotest.option str) "the gh token is the bearer"
        (Some "Bearer gho_from_device_login") (bearer sent)

(* The next login has to be the one that gets spent. masc keeps no copy, so
   this is the property that copy would have broken. *)
let test_github_cli_credential_follows_a_relogin () =
  let base_path = temp_base () in
  let keeper_name = "acme-daycare" in
  write_gh_identity ~base_path ~keeper_name "gho_first";
  let post, sent = recording_transport () in
  (match
     Identity_tools.run_call ~post ~base_path ~keeper_name
       ~provider:(github_provider ()) ~remote_name:"list_issues"
       ~arguments:(`Assoc []) ()
   with
  | Error _ -> Alcotest.fail "the first credential did not authorize the call"
  | Ok _ -> check (Alcotest.option str) "first" (Some "Bearer gho_first") (bearer sent));
  write_gh_identity ~base_path ~keeper_name "gho_second";
  let post, sent = recording_transport () in
  match
    Identity_tools.run_call ~post ~base_path ~keeper_name
      ~provider:(github_provider ()) ~remote_name:"list_issues"
      ~arguments:(`Assoc []) ()
  with
  | Error _ -> Alcotest.fail "the second credential did not authorize the call"
  | Ok _ ->
      check (Alcotest.option str) "the newer login is spent"
        (Some "Bearer gho_second") (bearer sent)

(* The field has to gate, not decorate. A provider that did not declare the gh
   source must not pick that credential up just because it is on disk --
   otherwise every provider silently starts sending a GitHub token. *)
let test_an_oauth_provider_ignores_the_gh_credential () =
  let base_path = temp_base () in
  let keeper_name = "acme-daycare" in
  write_gh_identity ~base_path ~keeper_name "gho_not_for_atlassian";
  let post, sent = recording_transport () in
  match
    Identity_tools.run_call ~post ~base_path ~keeper_name ~provider:(provider ())
      ~remote_name:"getJiraIssue" ~arguments:(`Assoc []) ()
  with
  | Ok _ -> Alcotest.fail "an OAuth provider spent the gh credential"
  | Error _ -> check (Alcotest.option str) "nothing was sent" None (bearer sent)

let test_this_process_env_is_not_a_keepers_credential () =
  (* masc's own environment is not what a Keeper is handed. If it were, a
     variable of the same name here would be spent as that Keeper's
     credential against a real service.

     The guarantee comes from [Env_keeper_scrub]: an exact closed set of
     process keys is inherited and a provider credential is not in it. Both
     halves are checked -- the allowlist directly, so growing it fails here
     rather than somewhere a token has already been sent, and the end-to-end
     refusal, so the property survives the mechanism moving.

     Checked by the words of the refusal, not just that there was one: with
     a transport that answers everything, a leaked token would have made the
     call succeed, and asserting only [Error] would have passed either way. *)
  check Alcotest.bool "a provider credential is not an inherited host key"
    false
    (Masc.Env_keeper_scrub.is_allowed "ATLASSIAN_ACCESS_TOKEN");
  let base_path = temp_base () in
  Unix.putenv "ATLASSIAN_ACCESS_TOKEN" "this-process-token";
  write_catalog ~base_path ~keeper_name:"acme-daycare" [ tool ~read_only:true "getJiraIssue" ];
  let post, sent = recording_transport () in
  match execute_offered ~post ~base_path (single_offered ~base_path) (`Assoc []) with
  | Ok _ ->
      Alcotest.fail
        "spent this process's environment as the Keeper's credential"
  | Error err ->
      check (Alcotest.option str) "nothing was even sent" None (bearer sent);
      check Alcotest.bool "the refusal names the missing credential" true
        (Str.string_match (Str.regexp ".*has no ATLASSIAN_ACCESS_TOKEN")
           err.Agent_core.Types.message 0);
      check Alcotest.bool "and the model is not told to retry" false
        err.Agent_core.Types.recoverable

let test_the_projected_token_is_the_one_sent () =
  (* The positive half, and the one that matters: what reaches the provider
     is the Keeper's own projected credential. *)
  let base_path = temp_base () in
  Unix.putenv "ATLASSIAN_ACCESS_TOKEN" "this-process-token";
  write_catalog ~base_path ~keeper_name:"acme-daycare" [ tool ~read_only:true "getJiraIssue" ];
  (match
     Projection.set_env_entry ~base_path ~keeper_name:"acme-daycare"
       ~scope:Projection.Keeper_secret ~name:"ATLASSIAN_ACCESS_TOKEN"
       ~value:"the-keepers-token"
   with
  | Ok () -> ()
  | Error message -> Alcotest.failf "could not project a token: %s" message);
  let post, sent = recording_transport () in
  match execute_offered ~post ~base_path (single_offered ~base_path) (`Assoc []) with
  | Error err ->
      Alcotest.failf "the call did not go through: %s"
        err.Agent_core.Types.message
  | Ok output ->
      check (Alcotest.option str) "the Keeper's token, not this process's"
        (Some "Bearer the-keepers-token") (bearer sent);
      check str "and the tool's answer comes back" "PK-1"
        output.Agent_core.Types.content

(* ── unexpected not-found: catalog drift recovery ─────────────────── *)

(* Says -32601 for the first tools/call, lists a catalog with one more
   tool than the fixture wrote, then answers the retry. Nothing reaches a
   network. *)
let drifting_transport () =
  let sent = ref [] in
  let calls = ref 0 in
  let post ~url ~headers ~body =
    sent := (url, headers, body) :: !sent;
    let answer =
      if String.length body > 0 && Str.string_match (Str.regexp ".*initialize") body 0
      then
        Printf.sprintf
          {|{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":%S,"capabilities":{}}}|}
          Mcp_transport_protocol.default_protocol_version
      else if String.length body > 0 && Str.string_match (Str.regexp ".*tools/list") body 0
      then
        {|{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"getJiraIssue","description":"does getJiraIssue"},{"name":"searchIssues","description":"does searchIssues"}]}}|}
      else (
        incr calls;
        if !calls = 1
        then {|{"jsonrpc":"2.0","id":3,"error":{"code":-32601,"message":"Unknown tool"}}|}
        else
          {|{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"PK-1"}]}}|})
    in
    Ok
      { Masc_http_client.status = 200;
        headers = [ ("content-type", "application/json") ];
        body = answer;
      }
  in
  (post, sent, calls)

let project_token ~base_path =
  match
    Projection.set_env_entry ~base_path ~keeper_name:"acme-daycare"
      ~scope:Projection.Keeper_secret ~name:"ATLASSIAN_ACCESS_TOKEN"
      ~value:"the-keepers-token"
  with
  | Ok () -> ()
  | Error message -> Alcotest.failf "could not project a token: %s" message

let test_an_unexpected_not_found_rediscovers_and_retries () =
  (* The catalog the turn was assembled from still names the tool, and the
     service says it does not exist. What recovery owes: one tools/list on
     the live session, one retry, the drift written back so the next turn
     is assembled from what the service actually has, and a catalog time
     an operator can read. *)
  let base_path = temp_base () in
  Unix.putenv "ATLASSIAN_ACCESS_TOKEN" "this-process-token";
  write_catalog ~base_path ~keeper_name:"acme-daycare" [ tool ~read_only:true "getJiraIssue" ];
  project_token ~base_path;
  let post, sent, calls = drifting_transport () in
  match execute_offered ~post ~base_path (single_offered ~base_path) (`Assoc []) with
  | Error err ->
    Alcotest.failf "the call did not recover: %s" err.Agent_core.Types.message
  | Ok output ->
    check str "the retried call answered" "PK-1" output.Agent_core.Types.content;
    check Alcotest.int "exactly one failed call and one retry" 2 !calls;
    check Alcotest.bool "a tools/list went out on the same session" true
      (List.exists
         (fun (_, _, body) -> Str.string_match (Str.regexp ".*tools/list") body 0)
         (List.rev !sent));
    (match
       Identity_tools.load ~base_path ~keeper_name:"acme-daycare"
         ~provider_id:"atlassian"
     with
     | Ok (Some catalog) ->
       check Alcotest.bool "the gained tool is now on disk" true
         (List.exists
            (fun (t : Mcp_client.tool) -> String.equal t.Mcp_client.name "searchIssues")
            catalog.Identity_tools.tools);
       check Alcotest.bool "and the catalog time moved off the fixture" true
         (catalog.Identity_tools.discovered_at > 1786000000.0)
     | Ok None | Error _ -> Alcotest.fail "no catalog after rediscovery")

let test_an_expected_not_found_does_not_reach_for_the_catalog () =
  (* A name no catalog ever carried is the model guessing, not drift. The
     honest answer is the error itself; a rediscovery here would spend a
     round trip to learn nothing. *)
  let base_path = temp_base () in
  Unix.putenv "ATLASSIAN_ACCESS_TOKEN" "this-process-token";
  write_catalog ~base_path ~keeper_name:"acme-daycare" [ tool ~read_only:true "getJiraIssue" ];
  project_token ~base_path;
  let post, sent, calls = drifting_transport () in
  match
    Identity_tools.run_call ~post ~base_path ~keeper_name:"acme-daycare"
      ~provider:(provider ()) ~remote_name:"aToolNobodyOffered"
      ~arguments:(`Assoc []) ()
  with
  | Ok _ -> Alcotest.fail "a name no catalog ever named came back with an answer"
  | Error _ ->
    check Alcotest.int "the call was attempted exactly once" 1 !calls;
    check Alcotest.bool "and no tools/list went out" false
      (List.exists
         (fun (_, _, body) -> Str.string_match (Str.regexp ".*tools/list") body 0)
         (List.rev !sent))

(* ── the approval policy ─────────────────────────────────────────────── *)

module Policy = Masc.Keeper_tool_approval_policy
module Index = Masc.Keeper_identity_tool_index

let offer ~base_path tools =
  write_catalog ~base_path ~keeper_name:"attaching-fixture" tools;
  match
    Identity_tools.load ~base_path ~keeper_name:"attaching-fixture"
      ~provider_id:"atlassian"
  with
  | Ok (Some catalog) ->
      Identity_tools.agent_tools ~provider:(provider ()) catalog
  | Ok None | Error _ -> Alcotest.fail "the catalog did not come back"

(* The effect-level cases — a declared read reaches the wire, a write and a
   service's silence never do, and the Gate is asked before the credential is
   read — live in test_keeper_identity_gate.ml, against the gated tool the
   bundle actually places. This file keeps the wire and the catalog. *)

let test_the_policy_can_place_an_attached_tool () =
  (* The bundle gate walks every tool a Keeper is handed through this. A tool
     it cannot place asks its operator a question with no reason they can act
     on, which is what four composition tools did before they were
     classified. *)
  Index.forget_all (Index.shared ());
  let base_path = temp_base () in
  let _ = offer ~base_path [ tool ~read_only:true "getJiraIssue" ] in
  check Alcotest.bool "classifiable" true
    (Policy.classifies ~composition_plan_index:None ~tool_name:"atlassian_getJiraIssue")

let test_a_read_only_tool_runs_unasked () =
  Index.forget_all (Index.shared ());
  let base_path = temp_base () in
  let _ = offer ~base_path [ tool ~read_only:true "getJiraIssue" ] in
  match
    Policy.verdict_for ~composition_plan_index:None ~tool_name:"atlassian_getJiraIssue" ~input:(`Assoc [])
  with
  | Policy.Run _ -> ()
  | Policy.Ask { because } ->
      Alcotest.failf "asked about a read the service declared: %s" because

let test_a_writing_tool_belongs_to_the_durable_gate () =
  (* The stream policy no longer asks about identity writes: asking here too
     would put two authorities in front of one call, and this stream-bound
     one holds nothing on the lanes that cannot ask — where the 2026-08-27
     incident ran. The tool itself defers to the durable Gate
     ({!Keeper_identity_gate}); what this policy owes the call is passage. *)
  Index.forget_all (Index.shared ());
  let base_path = temp_base () in
  let _ = offer ~base_path [ tool ~read_only:false "editJiraIssue" ] in
  match
    Policy.verdict_for ~composition_plan_index:None ~tool_name:"atlassian_editJiraIssue" ~input:(`Assoc [])
  with
  | Policy.Run { because } ->
      check Alcotest.bool "and the reason names the durable Gate" true
        (Str.string_match (Str.regexp ".*durable Gate") because 0)
  | Policy.Ask { because } ->
      Alcotest.failf
        "the stream policy asked about a call the durable Gate owns: %s"
        because

let test_silence_is_not_permission () =
  (* Still true — enforced by the durable Gate now, which treats an
     unannotated tool as a write and defers it. This policy's half is to
     pass the call through to that Gate rather than answer first. *)
  Index.forget_all (Index.shared ());
  let base_path = temp_base () in
  let _ = offer ~base_path [ tool "somethingUnannotated" ] in
  match
    Policy.verdict_for ~composition_plan_index:None ~tool_name:"atlassian_somethingUnannotated"
      ~input:(`Assoc [])
  with
  | Policy.Run { because } ->
      check Alcotest.bool "and the reason names the silence" true
        (Str.string_match (Str.regexp ".*did not say") because 0)
  | Policy.Ask { because } ->
      Alcotest.failf
        "the stream policy asked about a call the durable Gate owns: %s"
        because

let test_a_name_from_no_service_stays_unknown () =
  (* The index answering "never recorded" must not read as "may write". A
     name masc has never heard of is still the unclassifiable case, and
     folding the two would let this arm swallow every unknown tool. *)
  Index.forget_all (Index.shared ());
  check Alcotest.bool "not classifiable" false
    (Policy.classifies ~composition_plan_index:None ~tool_name:"atlassian_neverOffered")

(* ── renewal ─────────────────────────────────────────────────────────── *)

let store_expiry ~base_path ~provider ~at =
  match
    Projection.set_env_entry ~base_path ~keeper_name:"attaching-fixture"
      ~scope:Projection.Keeper_secret
      ~name:provider.Provider.expires_at_env
      ~value:(Printf.sprintf "%.0f" at)
  with
  | Ok () -> ()
  | Error message -> Alcotest.failf "could not store an expiry: %s" message

let never_discover ~mcp_url:_ =
  Alcotest.fail "renewal reached the network when it should not have"

let test_a_fresh_token_is_left_alone () =
  let base_path = temp_base () in
  let provider = provider () in
  store_expiry ~base_path ~provider ~at:10_000.0;
  match
    Identity_tools.renew_if_needed ~discover:never_discover ~base_path
      ~keeper_name:"attaching-fixture" ~provider ~now:0.0 ~access_token:"still-good" ()
  with
  | Ok token -> check str "unchanged" "still-good" token
  | Error message -> Alcotest.failf "renewed a fresh token: %s" message

let test_no_stored_expiry_renews_nothing () =
  (* Replacing a working credential on a guess costs the refresh token and
     gains nothing. *)
  let base_path = temp_base () in
  match
    Identity_tools.renew_if_needed ~discover:never_discover ~base_path
      ~keeper_name:"attaching-fixture" ~provider:(provider ()) ~now:0.0
      ~access_token:"unknown-age" ()
  with
  | Ok token -> check str "unchanged" "unknown-age" token
  | Error message -> Alcotest.failf "renewed on a guess: %s" message

let test_an_expiring_token_is_exchanged_and_stored () =
  let base_path = temp_base () in
  let provider = provider () in
  (* Inside the declaration's 600s window. *)
  store_expiry ~base_path ~provider ~at:100.0;
  (match
     Projection.set_file_entry ~base_path ~keeper_name:"attaching-fixture"
       ~scope:Projection.Keeper_secret
       ~container_path:provider.Provider.refresh_token_file
       ~value:"the-refresh-token"
   with
  | Ok () -> ()
  | Error message -> Alcotest.failf "could not store a refresh token: %s" message);
  (match
     Keeper_oauth_client_store.save
       ~dir:(Filename.concat (Filename.concat base_path ".masc") "identity")
       ~provider
       { Keeper_oauth_client_store.client_id = "client-abc"
       ; client_secret = None
       ; scopes = []
       }
   with
  | Ok () -> ()
  | Error message -> Alcotest.failf "could not store a client id: %s" message);
  let sent = ref [] in
  let token_post ~url:_ ~headers:_ ~body =
    sent := body :: !sent;
    Ok
      ( 200,
        {|{"access_token":"the-new-one","refresh_token":"rotated","expires_in":28800}|}
      )
  in
  let discover ~mcp_url:_ =
    Ok
      {
        Keeper_oauth_discovery.resource = "https://mcp.example.com/v1/mcp";
        issuer = "https://auth.example.com";
        authorize_url = "https://auth.example.com/authorize";
        token_url = "https://auth.example.com/oauth/token";
        registration_url = None;
        scopes_supported = [];
        supports_pkce_s256 = true;
      }
  in
  match
    Identity_tools.renew_if_needed ~token_post ~discover ~base_path
      ~keeper_name:"attaching-fixture" ~provider ~now:0.0 ~access_token:"about-to-expire"
      ()
  with
  | Error message -> Alcotest.failf "renewal failed: %s" message
  | Ok token ->
      check str "the call uses the new token" "the-new-one" token;
      check Alcotest.bool "and it was a refresh_token grant" true
        (match !sent with
        | body :: _ -> Str.string_match (Str.regexp ".*grant_type=refresh_token") body 0
        | [] -> false);
      (* Stored, or the next turn exchanges the same expiring token again. *)
      (match
         Projection.local_env_for_keeper ~host_env:[||] ~base_path
           ~keeper_name:"attaching-fixture" ()
       with
      | Ok (Some entries) ->
          let has prefix =
            Array.exists (fun entry -> String.starts_with ~prefix entry) entries
          in
          check Alcotest.bool "the new access token is written" true
            (has (provider.Provider.access_token_env ^ "=the-new-one"));
          check Alcotest.bool "and so is its expiry" true
            (has (provider.Provider.expires_at_env ^ "=28800"))
      | Ok None | Error _ -> Alcotest.fail "no projection after renewal");
      (* A rotated refresh token replaces the spent one. *)
      match
        Projection.read_file_entry ~base_path ~keeper_name:"attaching-fixture"
          ~scope:Projection.Keeper_secret
          ~container_path:provider.Provider.refresh_token_file
      with
      | Ok (Some value) -> check str "the rotated refresh token" "rotated" value
      | Ok None | Error _ -> Alcotest.fail "the refresh token went missing"

let () =
  Alcotest.run "keeper_identity_tools"
    [ ( "the on/off switch",
        [ Alcotest.test_case "no switch file means everything on" `Quick
            test_no_switch_file_means_everything_on;
          Alcotest.test_case "a thrown switch takes the tools out of the turn"
            `Quick test_a_thrown_switch_takes_the_tools_out_of_the_turn;
          Alcotest.test_case "setting the state it already has writes nothing"
            `Quick test_setting_the_state_it_already_has_writes_nothing;
          Alcotest.test_case "an unreadable switch store offers nothing" `Quick
            test_an_unreadable_switch_store_offers_nothing;
        ] );
      ( "the written catalog",
        [ Alcotest.test_case "never attached is not an error" `Quick
            test_never_attached_is_not_an_error;
          Alcotest.test_case "an unreadable catalog is not no tools" `Quick
            test_an_unreadable_catalog_is_not_no_tools;
          Alcotest.test_case "a written catalog comes back" `Quick
            test_a_written_catalog_comes_back;
          Alcotest.test_case "a real-sized token is storable" `Quick
            test_a_real_sized_token_is_storable;
          Alcotest.test_case "a real-sized token survives the projection"
            `Quick test_a_real_sized_token_survives_the_projection;
        ] );
      ( "renewal",
        [ Alcotest.test_case "a fresh token is left alone" `Quick
            test_a_fresh_token_is_left_alone;
          Alcotest.test_case "no stored expiry renews nothing" `Quick
            test_no_stored_expiry_renews_nothing;
          Alcotest.test_case "an expiring token is exchanged and stored" `Quick
            test_an_expiring_token_is_exchanged_and_stored;
        ] );
      ( "the approval policy",
        [ Alcotest.test_case "the policy can place an attached tool" `Quick
            test_the_policy_can_place_an_attached_tool;
          Alcotest.test_case "a read-only tool runs unasked" `Quick
            test_a_read_only_tool_runs_unasked;
          Alcotest.test_case "a writing tool belongs to the durable Gate"
            `Quick test_a_writing_tool_belongs_to_the_durable_gate;
          Alcotest.test_case "silence is not permission" `Quick
            test_silence_is_not_permission;
          Alcotest.test_case "a name from no service stays unknown" `Quick
            test_a_name_from_no_service_stays_unknown;
        ] );
      ( "the tool surface",
        [ Alcotest.test_case "names are namespaced by provider" `Quick
            test_names_are_namespaced_by_provider;
          Alcotest.test_case "a schema that cannot be projected is reported"
            `Quick test_a_schema_that_cannot_be_projected_is_reported;
          Alcotest.test_case "no token is a refusal, not a crash" `Quick
            test_a_keeper_with_no_token_gets_a_refusal_not_a_crash;
          Alcotest.test_case "this process's env is not a keeper's credential"
            `Quick test_this_process_env_is_not_a_keepers_credential;
          Alcotest.test_case "the gh CLI credential is what gets sent" `Quick
            test_github_cli_credential_is_what_gets_sent;
          Alcotest.test_case "the gh CLI credential follows a relogin" `Quick
            test_github_cli_credential_follows_a_relogin;
          Alcotest.test_case "an OAuth provider ignores the gh credential" `Quick
            test_an_oauth_provider_ignores_the_gh_credential;
          Alcotest.test_case "the projected token is the one sent" `Quick
            test_the_projected_token_is_the_one_sent;
          Alcotest.test_case "an unexpected not-found rediscovers and retries"
            `Quick test_an_unexpected_not_found_rediscovers_and_retries;
          Alcotest.test_case "an expected not-found leaves the catalog alone"
            `Quick test_an_expected_not_found_does_not_reach_for_the_catalog;
        ] );
    ]
