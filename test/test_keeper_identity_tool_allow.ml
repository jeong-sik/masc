(** The profile's selection over what the attached services offered
    (RFC-0403).

    Pure set work on an offering that is built here rather than read from a
    provider: what is under test is which names survive, not how a catalog
    reaches disk. *)

module Allow = Masc.Keeper_identity_tool_allow
module Identity_tools = Masc.Keeper_identity_tools
module Provider = Keeper_oauth_provider

let declaration =
  {|
id = "atlassian"
label = "Atlassian"
mcp_url = "https://mcp.atlassian.com/v1/mcp/authv2"
access_token_env = "ATLASSIAN_ACCESS_TOKEN"
expires_at_env = "ATLASSIAN_ACCESS_TOKEN_EXPIRES_AT"
refresh_token_file = "/home/keeper/.atlassian/refresh_token"
renew_before_sec = 600
|}

let provider () =
  match Provider.load ~file_name:"atlassian" ~contents:declaration with
  | Ok provider -> provider
  | Error err ->
    Alcotest.failf "declaration rejected: %s" (Provider.error_to_string err)

(* [tool_schema] is private, so it is built through its own constructor
   rather than as a record literal. *)
let schema name =
  match
    Agent_core.Types.tool_schema_of_input_schema
      ~name
      ~description:("does " ^ name)
      ~input_schema:(`Assoc [ "type", `String "object" ])
      ()
  with
  | Ok schema -> schema
  | Error err -> Alcotest.failf "schema %s rejected: %s" name err
;;

let offered name : Identity_tools.offered_tool =
  { Identity_tools.schema = schema name
  ; read_only = None
  ; provider = provider ()
  ; remote_name = name
  }

(* The four Confluence write tools measured at 21.3 KB on
   one live keeper, beside the Jira reads it actually calls. *)
let offering =
  List.map
    offered
    [ "atlassian_searchJiraIssuesUsingJql"
    ; "atlassian_getJiraIssue"
    ; "atlassian_createConfluencePage"
    ; "atlassian_updateConfluencePage"
    ]
;;

let names (tools : Identity_tools.offered_tool list) =
  List.map
    (fun (tool : Identity_tools.offered_tool) ->
       tool.Identity_tools.schema.Agent_core.Types.name)
    tools
;;

let check_names label expected actual =
  Alcotest.(check (list string)) label expected (names actual)
;;

(* A Keeper that declares nothing keeps every byte it had before this axis
   existed. This is the row that makes the change safe to land on a live
   fleet, so it checks the whole list rather than its length. *)
let test_absent_selection_keeps_the_offering () =
  let outcome = Allow.apply ~allow:None offering in
  check_names
    "every offered tool"
    [ "atlassian_searchJiraIssuesUsingJql"
    ; "atlassian_getJiraIssue"
    ; "atlassian_createConfluencePage"
    ; "atlassian_updateConfluencePage"
    ]
    outcome.Allow.kept;
  Alcotest.(check (list string)) "nothing unnamed" [] outcome.Allow.unnamed
;;

(* An absent array and an explicit empty one are opposite answers, which is
   why the profile carries an option. *)
let test_empty_selection_keeps_nothing () =
  let outcome = Allow.apply ~allow:(Some []) offering in
  check_names "no attached tool" [] outcome.Allow.kept;
  Alcotest.(check (list string)) "nothing unnamed" [] outcome.Allow.unnamed
;;

let test_selection_keeps_exactly_what_it_names () =
  let outcome =
    Allow.apply
      ~allow:
        (Some [ "atlassian_getJiraIssue"; "atlassian_searchJiraIssuesUsingJql" ])
      offering
  in
  check_names
    "the two reads, in the offering's order"
    [ "atlassian_searchJiraIssuesUsingJql"; "atlassian_getJiraIssue" ]
    outcome.Allow.kept;
  Alcotest.(check (list string)) "nothing unnamed" [] outcome.Allow.unnamed
;;

(* A name the offering does not hold is reported, not swallowed: a dropped
   name removes a tool and says nothing otherwise. *)
let test_unnamed_is_reported () =
  let outcome =
    Allow.apply
      ~allow:(Some [ "atlassian_getJiraIssue"; "atlassian_getJiraIssu" ])
      offering
  in
  check_names "the one that exists" [ "atlassian_getJiraIssue" ] outcome.Allow.kept;
  Alcotest.(check (list string))
    "the typo, named"
    [ "atlassian_getJiraIssu" ]
    outcome.Allow.unnamed
;;

(* Exact names only. A prefix rule would put the axis back on the provider,
   which is the granularity that already exists and does not answer this. *)
let test_matching_is_exact_not_prefix () =
  let outcome = Allow.apply ~allow:(Some [ "atlassian_" ]) offering in
  check_names "no prefix match" [] outcome.Allow.kept;
  Alcotest.(check (list string))
    "the prefix is just a name nothing holds"
    [ "atlassian_" ]
    outcome.Allow.unnamed
;;

let () =
  Alcotest.run
    "Keeper_identity_tool_allow"
    [ ( "selection"
      , [ Alcotest.test_case
            "absent selection keeps the offering"
            `Quick
            test_absent_selection_keeps_the_offering
        ; Alcotest.test_case
            "empty selection keeps nothing"
            `Quick
            test_empty_selection_keeps_nothing
        ; Alcotest.test_case
            "selection keeps exactly what it names"
            `Quick
            test_selection_keeps_exactly_what_it_names
        ; Alcotest.test_case "unnamed is reported" `Quick test_unnamed_is_reported
        ; Alcotest.test_case
            "matching is exact, not prefix"
            `Quick
            test_matching_is_exact_not_prefix
        ] )
    ]
;;
