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

let placement ?(agent_cell = ref None) ?(history = []) offering =
  Keeper_identity_tool_search.make
    ~keeper_name:"search-test"
    { Keeper_identity_tool_search.deferred =
        List.map
          (fun (offer : Keeper_identity_tools.offered_tool) ->
             let tool = build offer in
             { Keeper_identity_tool_search.tool
             ; summary =
                 Keeper_identity_tool_search.summary_of
                   tool.Agent_core.Tool.schema.description
             })
          offering
    ; agent_cell
    ; history
    }
;;

let search ?agent_cell ?history offering =
  Option.map
    (fun (p : Keeper_identity_tool_search.placement) ->
       p.Keeper_identity_tool_search.tool)
    (placement ?agent_cell ?history offering)
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
  check bool "its summary is not on the wire" false (mentions "Search issues")
;;

(* The instructions half of what the model reads is declared in
   config/tools/keeper_tool_search.toml, and only the listing is built in
   OCaml. A wiring that dropped the declared half would still name every tool
   and still pass the test above, while telling the model nothing about how to
   ask for one. *)
let test_the_declared_prose_reaches_the_model () =
  let tool = the_tool (offered [ "jira_search", "Search issues" ]) in
  let description = tool.Agent_core.Tool.schema.description in
  let declared = Tool_schemas_identity_tool_search.schema.Masc_domain.description in
  check bool "the declaration is not empty" true (String.length declared > 0);
  check
    bool
    "the model reads the declared instructions before the listing"
    true
    (String.length description >= String.length declared
     && String.equal (String.sub description 0 (String.length declared)) declared);
  check
    bool
    "and they say how to name a tool"
    true
    (contains declared "names")
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

(* Summaries are cut to a budget, and a service is free to write Korean. The
   summary rides in the answer to a load now, so that is where it is read. *)
let test_a_long_summary_is_cut_without_breaking_a_character () =
  Eio_main.run
  @@ fun env ->
  let agent =
    Agent_core.Agent.create
      ~config:(Agent_core.Types.default_config ~model:"test-model")
      ~net:env#net
      ()
  in
  let long = String.concat "" (List.init 40 (fun _ -> "설명")) in
  let tool =
    match search ~agent_cell:(ref (Some agent)) (offered [ "jira_search", long ]) with
    | Some tool -> tool
    | None -> fail "expected a listing tool"
  in
  match execute tool (names_input [ "atlassian_jira_search" ]) with
  | Error e -> failf "loading failed: %s" e.Agent_core.Types.message
  | Ok { content; _ } ->
    check bool "the whole answer survived encoding" true (valid_utf8 content);
    check bool "the summary was cut" false (contains content long);
    check bool "and what is left starts where the summary does" true
      (contains content (String.sub long 0 60))
;;

let discovery = Alcotest.testable
  (fun fmt -> function
    | Keeper_identity_tool_search.Listing_unused -> Format.fprintf fmt "Listing_unused"
    | Keeper_identity_tool_search.Loaded_and_used -> Format.fprintf fmt "Loaded_and_used"
    | Keeper_identity_tool_search.Loaded_unused names ->
      Format.fprintf fmt "Loaded_unused [%s]" (String.concat "; " names))
  ( = )
;;

(* Hiding the surface behind a name only pays off if the model finds what it
   needs through it. These three cases are what "it found something" and "it
   did not" look like from inside the turn. *)


let with_placement offering f =
  Eio_main.run
  @@ fun env ->
  let agent =
    Agent_core.Agent.create
      ~config:(Agent_core.Types.default_config ~model:"test-model")
      ~net:env#net
      ()
  in
  match placement ~agent_cell:(ref (Some agent)) offering with
  | None -> fail "expected a listing tool"
  | Some p -> f agent p
;;

let test_a_turn_that_never_asked_records_nothing () =
  with_placement (offered [ "jira_search", "Search" ]) (fun _agent p ->
    check discovery "the model never asked"
      Keeper_identity_tool_search.Listing_unused
      (p.Keeper_identity_tool_search.observe_turn ()))
;;

let test_a_turn_that_loaded_and_called_records_nothing () =
  with_placement (offered [ "jira_search", "Search" ]) (fun agent p ->
    (match
       execute p.Keeper_identity_tool_search.tool (names_input [ "atlassian_jira_search" ])
     with
     | Error e -> failf "loading failed: %s" e.Agent_core.Types.message
     | Ok _ -> ());
    (match Agent_core.Tool_set.find "atlassian_jira_search" (Agent_core.Agent.tools agent) with
     | None -> fail "the loaded tool is not callable"
     | Some (t : Agent_core.Tool.t) ->
       (match Agent_core.Tool.execute t (`Assoc []) with
        | Ok _ -> ()
        | Error e -> failf "the attached tool failed: %s" e.Agent_core.Types.message));
    check discovery "it asked and then called what it got"
      Keeper_identity_tool_search.Loaded_and_used
      (p.Keeper_identity_tool_search.observe_turn ()))
;;

(* The case the whole observation exists for. *)
let test_a_turn_that_loaded_and_called_nothing_names_what_it_loaded () =
  with_placement (offered [ "jira_search", "Search"; "page_create", "Create" ]) (fun _agent p ->
    (match
       execute
         p.Keeper_identity_tool_search.tool
         (names_input [ "atlassian_jira_search"; "atlassian_page_create" ])
     with
     | Error e -> failf "loading failed: %s" e.Agent_core.Types.message
     | Ok _ -> ());
    check discovery "it asked, got two, and used neither"
      (Keeper_identity_tool_search.Loaded_unused
         [ "atlassian_jira_search"; "atlassian_page_create" ])
      (p.Keeper_identity_tool_search.observe_turn ()))
;;


(* One assistant message calling [name], the shape the model leaves behind in
   history when it actually runs an attached tool. *)
let called tool_name_called =
  { Agent_core.Types.role = Agent_core.Types.Assistant
  ; content =
      [ Agent_core.Types.ToolUse
          { id = "toolu_fixture"; name = tool_name_called; input = `Assoc [] }
      ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

(* Asking for a tool through the listing, which is not the same as running it. *)
let asked_for names =
  { Agent_core.Types.role = Agent_core.Types.Assistant
  ; content =
      [ Agent_core.Types.ToolUse
          { id = "toolu_ask"
          ; name = Keeper_identity_tool_search.tool_name
          ; input = `Assoc [ "names", `List (List.map (fun n -> `String n) names) ]
          }
      ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

let already_used ?history offering =
  match placement ?history offering with
  | Some p ->
    List.map
      (fun (t : Agent_core.Tool.t) -> t.Agent_core.Tool.schema.name)
      p.Keeper_identity_tool_search.already_used
    |> List.sort String.compare
  | None -> fail "an attached service was offered and produced no placement"
;;

let two_offered =
  [ "jira_search", "Search issues"; "confluence_search", "Search pages" ]
;;

(* The turn that made a load is the only one it reaches, so a Keeper working
   on one thing across several turns re-asks every time. Live 2026-08-30: one
   Keeper asked for [github_issue_read] on five consecutive turns. *)
(* The listing's bytes are charged to every request of the turn, so a tool
   handed over with its schema must not also spend a line saying it exists.
   Measured over three days of live surfaces, that duplication was a median 7
   of the listed tools and reached 24 -- a third of one listing. *)
let test_a_carried_tool_is_not_also_named_in_the_listing () =
  let tool =
    match search ~history:[ called "atlassian_jira_search" ] (offered two_offered) with
    | Some tool -> tool
    | None -> fail "expected a listing tool"
  in
  let description = tool.Agent_core.Tool.schema.description in
  check bool "the carried tool is not listed again" false
    (contains description "atlassian_jira_search");
  check bool "the tool that was not carried is still listed" true
    (contains description "atlassian_confluence_search")
;;

(* Omitted from the prose, not from the surface: a model that names a tool it
   already has must be answered, not refused, or the omission would turn a
   redundant line into a dead end. *)
let test_a_carried_tool_can_still_be_named () =
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
    match
      search ~agent_cell ~history:[ called "atlassian_jira_search" ] (offered two_offered)
    with
    | Some tool -> tool
    | None -> fail "expected a listing tool"
  in
  match execute tool (names_input [ "atlassian_jira_search" ]) with
  | Ok _ -> ()
  | Error e ->
    failf "naming an already-carried tool was refused: %s" e.Agent_core.Types.message
;;

let test_a_tool_this_conversation_ran_comes_back_with_its_schema () =
  check
    (list string)
    "the tool this conversation ran is placed again"
    [ "atlassian_jira_search" ]
    (already_used ~history:[ called "atlassian_jira_search" ] (offered two_offered))
;;

(* The bound. Asking is not evidence of need: carrying every requested tool
   grows the surface back toward the full attached list, measured at 111 of a
   possible 133 an hour after that shipped. *)
let test_a_tool_only_asked_for_is_not_carried () =
  check
    (list string)
    "a tool the model asked for but never ran is not placed"
    []
    (already_used ~history:[ asked_for [ "atlassian_jira_search" ] ] (offered two_offered))
;;

let test_a_conversation_that_ran_nothing_carries_nothing () =
  check
    (list string)
    "a Keeper that never reached its services pays nothing for this"
    []
    (already_used (offered two_offered))
;;

(* Detached service, renamed tool: the name no longer matches an entry. Same
   answer the listing itself gives for it. *)
let test_a_name_no_longer_offered_is_not_placed () =
  check
    (list string)
    "a name that is no longer offered is dropped"
    []
    (already_used
       ~history:[ called "atlassian_jira_search" ]
       (offered [ "confluence_search", "Search pages" ]))
;;

let test_repeated_calls_place_the_tool_once () =
  check
    (list string)
    "running a tool twice does not place it twice"
    [ "atlassian_jira_search" ]
    (already_used
       ~history:[ called "atlassian_jira_search"; called "atlassian_jira_search" ]
       (offered two_offered))
;;

(* A built-in the model ran shares the history with the attached ones and must
   not be mistaken for one -- only offered names match an entry. *)
let test_a_builtin_call_is_not_mistaken_for_an_attached_one () =
  check
    (list string)
    "a built-in tool call places nothing"
    []
    (already_used ~history:[ called "Read" ] (offered two_offered))
;;

let () =
  run
    "keeper_identity_tool_search"
    [ ( "the listing"
      , [ test_case "is absent when nothing is attached" `Quick
            test_nothing_attached_offers_no_tool
        ; test_case "names every attached tool" `Quick
            test_the_listing_names_every_attached_tool
        ; test_case "carries the declared instructions" `Quick
            test_the_declared_prose_reaches_the_model
        ; test_case "costs less than the schemas" `Quick
            test_the_listing_costs_less_than_the_schemas
        ; test_case "cuts a long summary without breaking a character" `Quick
            test_a_long_summary_is_cut_without_breaking_a_character
        ] )
    ; ( "carried across turns"
      , [ test_case "a tool this conversation ran comes back with its schema" `Quick
            test_a_tool_this_conversation_ran_comes_back_with_its_schema
        ; test_case "a tool only asked for is not carried" `Quick
            test_a_tool_only_asked_for_is_not_carried
        ; test_case "a conversation that ran nothing carries nothing" `Quick
            test_a_conversation_that_ran_nothing_carries_nothing
        ; test_case "a name no longer offered is not placed" `Quick
            test_a_name_no_longer_offered_is_not_placed
        ; test_case "repeated calls place the tool once" `Quick
            test_repeated_calls_place_the_tool_once
        ; test_case "a built-in call is not mistaken for an attached one" `Quick
            test_a_builtin_call_is_not_mistaken_for_an_attached_one
        ; test_case "a carried tool is not also named in the listing" `Quick
            test_a_carried_tool_is_not_also_named_in_the_listing
        ; test_case "a carried tool can still be named" `Quick
            test_a_carried_tool_can_still_be_named
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
    ; ( "what the turn found"
      , [ test_case "nothing when the model never asked" `Quick
            test_a_turn_that_never_asked_records_nothing
        ; test_case "nothing when it called what it loaded" `Quick
            test_a_turn_that_loaded_and_called_records_nothing
        ; test_case "names what it loaded and never called" `Quick
            test_a_turn_that_loaded_and_called_nothing_names_what_it_loaded
        ] )
    ]
;;
