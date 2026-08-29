open Alcotest
open Masc

(* An attached service's answer, in the shape [Keeper_identity_tools] writes
   down when a Keeper attaches. *)
let provider () =
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
  in
  match Keeper_oauth_provider.load ~file_name:"atlassian" ~contents:declaration with
  | Ok provider -> provider
  | Error e ->
    failf "the declaration must parse: %s" (Keeper_oauth_provider.error_to_string e)
;;

(* Wide enough that the schemas are what costs, which is the thing being
   moved off the wire. *)
let wide_input_schema =
  `Assoc
    [ "type", `String "object"
    ; ( "properties"
      , `Assoc
          (List.init 12 (fun i ->
             ( Printf.sprintf "field_%d" i
             , `Assoc
                 [ "type", `String "string"
                 ; ( "description"
                   , `String
                       "A parameter whose description is the sort of prose an \
                        attached service writes for every field it takes." )
                 ] ))) )
    ]
;;

let offered ?(input_schema = wide_input_schema) tools =
  let catalog =
    { Keeper_identity_tools.provider_id = "atlassian"
    ; provider_label = "Atlassian"
    ; discovered_at = 0.0
    ; tools =
        List.map
          (fun (name, description) ->
             { Mcp_client.name; description; input_schema; read_only = Some true })
          tools
    }
  in
  (Keeper_identity_tools.agent_tools ~provider:(provider ()) catalog)
    .Keeper_identity_tools.offered
;;

(* [build] stands in for the Gate wrapper the bundle supplies: what the
   listing does with the tool is the subject here, not what the tool does. *)
let build (offer : Keeper_identity_tools.offered_tool) =
  Agent_core.Tool.of_schema
    offer.Keeper_identity_tools.schema
    (Agent_core.Tool.ignoring_execution_env (fun _ ->
       Ok { Agent_core.Types.content = offer.Keeper_identity_tools.remote_name
          ; _meta = None
          }))
;;

let search ?(agent_cell = ref None) offering =
  Keeper_identity_tool_search.make
    ~keeper_name:"search-test"
    ~build
    { Keeper_identity_tool_search.offered = offering; agent_cell }
;;

let the_tool offering =
  match search offering with
  | Some tool -> tool
  | None -> fail "an attached service was offered and produced no tool"
;;

let execute tool input = Agent_core.Tool.execute tool input

let contains haystack needle =
  let n = String.length haystack
  and m = String.length needle in
  let rec at i = i + m <= n && (String.sub haystack i m = needle || at (i + 1)) in
  at 0
;;

(* Truncating a summary must not leave a half-written character behind. *)
let valid_utf8 s =
  let n = String.length s in
  let rec continuations i width k =
    k >= width || (Char.code s.[i + k] land 0xC0 = 0x80 && continuations i width (k + 1))
  in
  let rec scan i =
    if i >= n
    then true
    else (
      let byte = Char.code s.[i] in
      let width =
        if byte < 0x80
        then 1
        else if byte land 0xE0 = 0xC0
        then 2
        else if byte land 0xF0 = 0xE0
        then 3
        else if byte land 0xF8 = 0xF0
        then 4
        else 0
      in
      width > 0 && i + width <= n && continuations i width 1 && scan (i + width))
  in
  scan 0
;;

let names_input names =
  `Assoc [ "names", `List (List.map (fun n -> `String n) names) ]
;;

let test_nothing_attached_offers_no_tool () =
  check bool "no tool" true (Option.is_none (search []))
;;

let test_the_listing_names_every_attached_tool () =
  let tool = the_tool (offered [ "jira_search", "Search issues"; "page_create", "Make a page" ]) in
  let description = tool.Agent_core.Tool.schema.description in
  let mentions needle = contains description needle in
  check string "one name for the whole surface" "keeper_tool_search"
    tool.Agent_core.Tool.schema.name;
  check bool "the first is named" true (mentions "atlassian_jira_search");
  check bool "the second is named" true (mentions "atlassian_page_create");
  check bool "its summary is carried" true (mentions "Search issues")
;;

(* The point of the listing is the bytes. A description that carried the
   argument schemas would name the tools and save nothing. *)
let test_the_listing_costs_less_than_the_schemas () =
  let offering =
    offered (List.init 40 (fun i -> Printf.sprintf "tool_%d" i, "Does a thing to a record"))
  in
  let full =
    List.fold_left
      (fun total (offer : Keeper_identity_tools.offered_tool) ->
         total
         + String.length
             (Yojson.Safe.to_string
                (Agent_core.Types.tool_schema_to_json offer.Keeper_identity_tools.schema)))
      0
      offering
  in
  let listing =
    String.length
      (Yojson.Safe.to_string
         (Agent_core.Types.tool_schema_to_json (the_tool offering).Agent_core.Tool.schema))
  in
  check bool
    (Printf.sprintf "listing %d bytes against %d of schemas" listing full)
    true
    (listing * 4 < full)
;;

let test_a_named_tool_becomes_callable_in_the_running_agent () =
  Eio_main.run
  @@ fun env ->
  let agent =
    Agent_core.Agent.create
      ~config:(Agent_core.Types.default_config ~model:"test-model")
      ~net:env#net
      ()
  in
  let agent_cell = ref (Some agent) in
  let tool =
    match search ~agent_cell (offered [ "jira_search", "Search issues" ]) with
    | Some tool -> tool
    | None -> fail "expected a listing tool"
  in
  check bool "the attached tool is not callable before it is asked for" false
    (Agent_core.Tool_set.mem "atlassian_jira_search" (Agent_core.Agent.tools agent));
  (match execute tool (names_input [ "atlassian_jira_search" ]) with
   | Ok { content; _ } ->
     check bool "the answer names what was loaded" true
       (String.length content > 0 && content <> "")
   | Error e -> failf "loading a named tool failed: %s" e.Agent_core.Types.message);
  check bool "the attached tool is callable afterwards" true
    (Agent_core.Tool_set.mem "atlassian_jira_search" (Agent_core.Agent.tools agent))
;;

let test_a_name_that_is_not_offered_is_refused () =
  Eio_main.run
  @@ fun env ->
  let agent =
    Agent_core.Agent.create
      ~config:(Agent_core.Types.default_config ~model:"test-model")
      ~net:env#net
      ()
  in
  let tool =
    match
      search ~agent_cell:(ref (Some agent)) (offered [ "jira_search", "Search issues" ])
    with
    | Some tool -> tool
    | None -> fail "expected a listing tool"
  in
  match execute tool (names_input [ "atlassian_nothing_like_it" ]) with
  | Ok { content; _ } -> failf "an unoffered name was accepted: %s" content
  | Error e ->
    check bool "the model can try again" true e.Agent_core.Types.recoverable;
    check bool "and is told which name" true
      (String.length e.Agent_core.Types.message > 0)
;;

(* Loading three when one of them is a typo should still load the two. *)
let test_the_names_that_exist_are_loaded_and_the_rest_reported () =
  Eio_main.run
  @@ fun env ->
  let agent =
    Agent_core.Agent.create
      ~config:(Agent_core.Types.default_config ~model:"test-model")
      ~net:env#net
      ()
  in
  let tool =
    match
      search
        ~agent_cell:(ref (Some agent))
        (offered [ "jira_search", "Search"; "page_create", "Create" ])
    with
    | Some tool -> tool
    | None -> fail "expected a listing tool"
  in
  match
    execute
      tool
      (names_input
         [ "atlassian_jira_search"; "atlassian_typo"; "atlassian_page_create" ])
  with
  | Error e -> failf "a partly valid request was refused: %s" e.Agent_core.Types.message
  | Ok _ ->
    let callable name = Agent_core.Tool_set.mem name (Agent_core.Agent.tools agent) in
    check bool "the first exists" true (callable "atlassian_jira_search");
    check bool "the second exists" true (callable "atlassian_page_create");
    check bool "the typo did not become a tool" false (callable "atlassian_typo")
;;

(* A cell with no agent means the turn was wired without one. Answering
   "nothing matched" would read to the model as a surface that is simply
   empty, and it would stop asking. *)
let test_a_turn_without_an_agent_fails_rather_than_answering_empty () =
  let tool = the_tool (offered [ "jira_search", "Search issues" ]) in
  match execute tool (names_input [ "atlassian_jira_search" ]) with
  | Ok { content; _ } -> failf "a turn with no agent answered: %s" content
  | Error e ->
    check bool "not something the model can retry into working" false
      e.Agent_core.Types.recoverable
;;

let test_arguments_of_the_wrong_shape_are_refused () =
  let tool = the_tool (offered [ "jira_search", "Search issues" ]) in
  let refused label input =
    match execute tool input with
    | Ok { content; _ } -> failf "%s was accepted: %s" label content
    | Error e -> check bool (label ^ " is retryable") true e.Agent_core.Types.recoverable
  in
  refused "a bare string" (`Assoc [ "names", `String "atlassian_jira_search" ]);
  refused "a list of numbers" (`Assoc [ "names", `List [ `Int 1 ] ]);
  refused "an empty list" (names_input []);
  refused "no names at all" (`Assoc []);
  refused "arguments that are not an object" (`String "atlassian_jira_search")
;;

(* Summaries are cut to a budget, and a service is free to write Korean. *)
let test_a_long_summary_is_cut_without_breaking_a_character () =
  let long = String.concat "" (List.init 40 (fun _ -> "설명")) in
  let tool = the_tool (offered [ "jira_search", long ]) in
  let description = tool.Agent_core.Tool.schema.description in
  check bool "the whole description survived encoding" true (valid_utf8 description);
  check bool "the summary was cut" false (contains description long);
  check bool "and what is left starts where the summary does" true
    (contains description (String.sub long 0 60))
;;

let () =
  run
    "keeper_identity_tool_search"
    [ ( "the listing"
      , [ test_case "is absent when nothing is attached" `Quick
            test_nothing_attached_offers_no_tool
        ; test_case "names every attached tool" `Quick
            test_the_listing_names_every_attached_tool
        ; test_case "costs less than the schemas" `Quick
            test_the_listing_costs_less_than_the_schemas
        ; test_case "cuts a long summary without breaking a character" `Quick
            test_a_long_summary_is_cut_without_breaking_a_character
        ] )
    ; ( "loading"
      , [ test_case "makes a named tool callable in the running agent" `Quick
            test_a_named_tool_becomes_callable_in_the_running_agent
        ; test_case "refuses a name that is not offered" `Quick
            test_a_name_that_is_not_offered_is_refused
        ; test_case "loads what exists and reports the rest" `Quick
            test_the_names_that_exist_are_loaded_and_the_rest_reported
        ; test_case "fails when the turn has no agent" `Quick
            test_a_turn_without_an_agent_fails_rather_than_answering_empty
        ; test_case "refuses arguments of the wrong shape" `Quick
            test_arguments_of_the_wrong_shape_are_refused
        ] )
    ]
;;
