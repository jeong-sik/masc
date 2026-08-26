(** What an attached work service contributes to a Keeper's tool surface.

    The catalog is written to disk and read back, so these run against real
    files under a temp base path. Nothing here reaches a provider: the point
    is what happens between the written catalog and the tool list a turn is
    handed. *)

module Identity_tools = Masc.Keeper_identity_tools
module Provider = Keeper_oauth_provider
module Projection = Masc.Keeper_secret_projection

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

let tool name =
  {
    Mcp_client.name;
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
                   [ ("name", `String t.Mcp_client.name);
                     ("description", `String t.Mcp_client.description);
                     ("input_schema", t.Mcp_client.input_schema)
                   ])
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
    (fun (t : Agent_core.Tool.t) -> t.schema.name)
    offering.Identity_tools.offered

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
        Identity_tools.agent_tools ~base_path ~keeper_name:"acme-daycare"
          ~provider:(provider ()) catalog
      in
      check (Alcotest.list str) "prefixed" [ "atlassian_search" ]
        (names offering)
  | Ok None | Error _ -> Alcotest.fail "the catalog did not come back"

let test_a_schema_that_cannot_be_projected_is_reported () =
  (* Excluded, but named. A shorter tool list with no reason for it is how
     an operator ends up reading code to find out what happened. *)
  let base_path = temp_base () in
  let bad =
    { Mcp_client.name = "weird"; description = "";
      input_schema = `String "not a schema" }
  in
  write_catalog ~base_path ~keeper_name:"acme-daycare" [ tool "fine"; bad ];
  match
    Identity_tools.load ~base_path ~keeper_name:"acme-daycare"
      ~provider_id:"atlassian"
  with
  | Ok (Some catalog) ->
      let offering =
        Identity_tools.agent_tools ~base_path ~keeper_name:"acme-daycare"
          ~provider:(provider ()) catalog
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
  write_catalog ~base_path ~keeper_name:"acme-daycare" [ tool "getJiraIssue" ];
  match
    Identity_tools.load ~base_path ~keeper_name:"acme-daycare"
      ~provider_id:"atlassian"
  with
  | Ok (Some catalog) -> (
      let offering =
        Identity_tools.agent_tools ~base_path ~keeper_name:"acme-daycare"
          ~provider:(provider ()) catalog
      in
      match offering.Identity_tools.offered with
      | [ projected ] -> (
          match Agent_core.Base.Tool.execute projected (`Assoc []) with
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

let single_tool ~base_path ~post =
  match
    Identity_tools.load ~base_path ~keeper_name:"acme-daycare"
      ~provider_id:"atlassian"
  with
  | Ok (Some catalog) -> (
      let offering =
        Identity_tools.agent_tools ~post ~base_path ~keeper_name:"acme-daycare"
          ~provider:(provider ()) catalog
      in
      match offering.Identity_tools.offered with
      | [ projected ] -> projected
      | _ -> Alcotest.fail "expected exactly one tool")
  | Ok None | Error _ -> Alcotest.fail "the catalog did not come back"

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
  write_catalog ~base_path ~keeper_name:"acme-daycare" [ tool "getJiraIssue" ];
  let post, sent = recording_transport () in
  match Agent_core.Base.Tool.execute (single_tool ~base_path ~post) (`Assoc []) with
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
  write_catalog ~base_path ~keeper_name:"acme-daycare" [ tool "getJiraIssue" ];
  (match
     Projection.set_env_entry ~base_path ~keeper_name:"acme-daycare"
       ~scope:Projection.Keeper_secret ~name:"ATLASSIAN_ACCESS_TOKEN"
       ~value:"the-keepers-token"
   with
  | Ok () -> ()
  | Error message -> Alcotest.failf "could not project a token: %s" message);
  let post, sent = recording_transport () in
  match Agent_core.Base.Tool.execute (single_tool ~base_path ~post) (`Assoc []) with
  | Error err ->
      Alcotest.failf "the call did not go through: %s"
        err.Agent_core.Types.message
  | Ok output ->
      check (Alcotest.option str) "the Keeper's token, not this process's"
        (Some "Bearer the-keepers-token") (bearer sent);
      check str "and the tool's answer comes back" "PK-1"
        output.Agent_core.Types.content

let () =
  Alcotest.run "keeper_identity_tools"
    [ ( "the written catalog",
        [ Alcotest.test_case "never attached is not an error" `Quick
            test_never_attached_is_not_an_error;
          Alcotest.test_case "an unreadable catalog is not no tools" `Quick
            test_an_unreadable_catalog_is_not_no_tools;
          Alcotest.test_case "a written catalog comes back" `Quick
            test_a_written_catalog_comes_back;
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
          Alcotest.test_case "the projected token is the one sent" `Quick
            test_the_projected_token_is_the_one_sent;
        ] );
    ]
