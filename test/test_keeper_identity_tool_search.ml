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

module Load_receipts = Keeper_tool_load_receipts

let trace_id value =
  match Keeper_id.Trace_id.of_string value with
  | Ok id -> id
  | Error reason -> fail reason
;;

let task_id value =
  match Keeper_id.Task_id.of_string value with
  | Ok id -> id
  | Error reason -> fail reason
;;

let receipt_surface offering =
  List.map
    (fun (offer : Keeper_identity_tools.offered_tool) ->
       { Load_receipts.source =
           Attached
             { provider_id = offer.provider.id
             ; endpoint = offer.provider.mcp_url
             ; remote_name = offer.remote_name
             }
       ; schema = offer.schema
       })
    offering
;;

let restored_receipts ~source ~target =
  match Load_receipts.restore ~source ~target with
  | Ok restored -> restored
  | Error error -> fail (Load_receipts.error_to_string error)
;;

let make_receipts ?(trace = "search-test") ?task ?current_task_id ~context offering =
  let current_task_id =
    match current_task_id with Some read -> read | None -> fun () -> Ok task
  in
  Load_receipts.create
    ~restored:(restored_receipts ~source:context ~target:context)
    ~trace_id:(trace_id trace)
    ~task_id:task
    ~current_task_id
    ~surface:(receipt_surface offering)
;;

let placement
      ?(agent_cell = ref None)
      ?(history = [])
      ?(carry_window = 0)
      ?receipts
      offering
  =
  let receipts =
    match receipts with
    | Some receipts -> receipts
    | None -> make_receipts ~context:(Agent_core.Context.create_sync ()) offering
  in
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
    ; carry_window
    ; receipts
    }
;;

let search ?agent_cell ?history ?carry_window ?receipts offering =
  Option.map
    (fun (p : Keeper_identity_tool_search.placement) ->
       p.Keeper_identity_tool_search.tool)
    (placement ?agent_cell ?history ?carry_window ?receipts offering)
;;

let the_tool offering =
  match search offering with
  | Some tool -> tool
  | None -> fail "an attached service was offered and produced no tool"
;;

let invocation ?(turn = 0) ?(planned_index = 0) id =
  Agent_core.Tool_contract.Invocation.create
    ~tool_use_id:id
    ~turn
    ~schedule:
      { planned_index
      ; batch_index = 0
      ; batch_size = 1
      ; execution_mode = Agent_core.Tool_contract.Concurrent
      }
    ~completion:Agent_core.Tool_contract.Continue_after_success
;;

let execute tool input =
  Agent_core.Tool.execute ~invocation:(invocation "toolu_execute") tool input
;;

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

let already_used ?history ?carry_window ?receipts offering =
  match placement ?history ?carry_window ?receipts offering with
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

let test_a_request_without_a_successful_load_grants_nothing () =
  check
    (list string)
    "a ToolUse request is not a successful load receipt"
    []
    (already_used
       ~history:[ asked_for [ "atlassian_jira_search" ] ]
       (offered two_offered))
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

(* [n] calls to a built-in, which advance the carry clock without being
   carried themselves -- the shape a Keeper leaves between two pieces of
   attached work. *)
let filler n = List.init n (fun _ -> called "Read")

let three_offered =
  [ "jira_search", "Search issues"
  ; "confluence_search", "Search pages"
  ; "jira_create", "Create an issue"
  ]
;;

(* Carrying everything ever run has no upper bound: measured over 19,100 turns
   2026-09-01..03 the per-keeper median carried was 32.1 KB of schema and
   reached 51.9 KB, while the median gap between two uses of one tool is 2
   turns. A tool whose last call is further back than the window is not
   placed. *)
let test_a_tool_outside_the_window_is_not_placed () =
  check
    (list string)
    "only the tool called inside the window is placed"
    [ "atlassian_confluence_search" ]
    (already_used
       ~carry_window:10
       ~history:
         ((called "atlassian_jira_search" :: filler 40)
          @ [ called "atlassian_confluence_search" ])
       (offered two_offered))
;;

(* A dropped tool is not stranded. The listing omits exactly the names placed
   with schemas, so dropping one puts it back into the listing on the same
   request, one load away. *)
let test_a_dropped_tool_returns_to_the_listing () =
  let tool =
    match
      search
        ~carry_window:10
        ~history:
          ((called "atlassian_jira_search" :: filler 40)
           @ [ called "atlassian_confluence_search" ])
        (offered two_offered)
    with
    | Some tool -> tool
    | None -> fail "expected a listing tool"
  in
  let description = tool.Agent_core.Tool.schema.description in
  check bool "the dropped tool is named again" true
    (contains description "atlassian_jira_search");
  check bool "the carried tool is still not named" false
    (contains description "atlassian_confluence_search")
;;

(* The window is not read at the end of the fold. Nothing grows the carry
   after the one call here, so the tool is still placed 40 calls later even
   though the window is 10. *)
let test_the_carry_is_not_cut_without_a_new_tool () =
  check
    (list string)
    "a tool stays placed while nothing new is loaded"
    [ "atlassian_jira_search" ]
    (already_used
       ~carry_window:10
       ~history:(called "atlassian_jira_search" :: filler 40)
       (offered three_offered))
;;

(* The cut rides a change the request was already paying for. A call to a name
   the carry already holds only moves that name's ordinal, so the tool array
   is byte-identical and cutting there would forfeit the provider's cache
   prefix for a change nothing asked for.

   [A; B; 40 fillers; A] at a window of 10: the second A is already carried,
   so no cut runs and B stays placed 41 calls after its own last use. This is
   the freeze [carry_window] documents -- a cut on every call would drop B
   here. *)
let test_a_call_to_a_carried_tool_does_not_cut () =
  check
    (list string)
    "a tool stale past the window stays placed while the carry does not grow"
    [ "atlassian_confluence_search"; "atlassian_jira_search" ]
    (already_used
       ~carry_window:10
       ~history:
         ([ called "atlassian_jira_search"; called "atlassian_confluence_search" ]
          @ filler 40
          @ [ called "atlassian_jira_search" ])
       (offered three_offered))
;;

(* The cut measures the whole carry, not only the name that arrives. A tool
   the window dropped and the model then called again re-enters the carry, and
   that re-entry grows the array exactly as a name new to the conversation
   does -- so it is cut on, and whatever went stale while it was away leaves.

   Cutting only at a name's first use in the conversation instead would let
   the carry regrow to every tool the conversation ever ran, with no later
   call able to cut it: once every name has been seen once, no call is a first
   use. That is the unbounded set the window replaces, so this is the case
   that separates the two rules.

   [A; 40 fillers; B; 40 fillers; A] at a window of 10: B is 41 calls stale
   when A returns, so only A is placed. *)
let test_a_returning_tool_is_cut_on_like_a_new_one () =
  check
    (list string)
    "what went stale while the returning tool was away is not placed"
    [ "atlassian_jira_search" ]
    (already_used
       ~carry_window:10
       ~history:
         ((called "atlassian_jira_search" :: filler 40)
          @ (called "atlassian_confluence_search" :: filler 40)
          @ [ called "atlassian_jira_search" ])
       (offered three_offered))
;;

(* The array is keyed by its exact bytes in the exact order sent, so a tool
   that leaves the window and comes back must come back in the slot it left
   rather than at the head of the carry. Here the carry order is the reverse
   of the offering order. *)
let test_a_returning_tool_keeps_its_place () =
  match
    placement
      ~carry_window:10
      ~history:
        ((called "atlassian_jira_create" :: filler 40)
         @ [ called "atlassian_jira_search"; called "atlassian_jira_create" ])
      (offered three_offered)
  with
  | None -> fail "an attached service was offered and produced no placement"
  | Some p ->
    check
      (list string)
      "the returning tool is placed in offering order"
      [ "atlassian_jira_search"; "atlassian_jira_create" ]
      (List.map
         (fun (t : Agent_core.Tool.t) -> t.Agent_core.Tool.schema.name)
         p.Keeper_identity_tool_search.already_used)
;;

(* 0 places every tool the conversation has run, which is what shipped before
   the window. The knob's off position, not a special case in the fold. *)
let test_a_zero_window_places_everything () =
  check
    (list string)
    "an unbounded window places both"
    [ "atlassian_confluence_search"; "atlassian_jira_search" ]
    (already_used
       ~carry_window:0
       ~history:
         ((called "atlassian_jira_search" :: filler 40)
          @ [ called "atlassian_confluence_search" ])
       (offered two_offered))
;;

let loaded_output result =
  match result with
  | Ok output -> output
  | Error error -> fail error.Agent_core.Types.message
;;

let placed_names (p : Keeper_identity_tool_search.placement) =
  List.map (fun (tool : Agent_core.Tool.t) -> tool.schema.name) p.already_used
;;

let require_placement value =
  match value with
  | Some placement -> placement
  | None -> fail "expected the deferred-tool listing"
;;

let with_receipt_fixture ?(task = Some (task_id "task-901")) ?current_task_id offering f =
  Eio_main.run
  @@ fun env ->
  let context = Agent_core.Context.create () in
  let receipts = make_receipts ?task ?current_task_id ~context offering in
  let agent =
    Agent_core.Agent.create
      ~context
      ~config:(Agent_core.Types.default_config ~model:"test-model")
      ~net:env#net
      ()
  in
  let p =
    placement ~receipts ~agent_cell:(ref (Some agent)) offering |> require_placement
  in
  f env context receipts agent p
;;

let test_successful_sibling_loads_survive_and_consume_individually () =
  let offering =
    offered [ "jira_search", "Search"; "page_create", "Create"; "page_read", "Read" ]
  in
  with_receipt_fixture offering (fun _env context _receipts _agent p ->
    Eio.Fiber.List.iter
      (fun (index, name) ->
         Agent_core.Tool.execute
           ~invocation:(invocation ~turn:7 ~planned_index:index ("load-" ^ name))
           p.tool
           (names_input [ name ])
         |> loaded_output
         |> ignore)
      [ 2, "atlassian_page_read"; 0, "atlassian_jira_search"; 1, "atlassian_page_create" ];
    (* Repeating a successful load replaces its receipt; it does not grow the set. *)
    execute p.tool (names_input [ "atlassian_jira_search" ]) |> loaded_output |> ignore;
    let restored = make_receipts ~task:(task_id "task-901") ~context offering in
    let next =
      placement ~receipts:restored ~history:[ called "keeper_status" ] offering
      |> require_placement
    in
    check
      (list string)
      "all sibling loads reach the next request, in catalog order"
      [ "atlassian_jira_search"; "atlassian_page_create"; "atlassian_page_read" ]
      (placed_names next);
    let tool =
      List.find
        (fun (tool : Agent_core.Tool.t) -> tool.schema.name = "atlassian_jira_search")
        next.already_used
    in
    execute tool (`Assoc []) |> loaded_output |> ignore;
    check
      (list string)
      "dispatch consumes its own grant only"
      [ "atlassian_page_create"; "atlassian_page_read" ]
      (Load_receipts.pending_names restored);
    let after =
      placement ~receipts:restored ~history:[ called "atlassian_jira_search" ] offering
      |> require_placement
    in
    let wire p =
      p.Keeper_identity_tool_search.tool :: p.already_used
      |> List.map (fun (tool : Agent_core.Tool.t) ->
        Agent_core.Tool.wire_json_of_schema tool.schema)
      |> fun schemas -> Yojson.Safe.to_string (`List schemas)
    in
    check
      string
      "consuming a load into ordinary carry preserves the tool prefix bytes"
      (wire next)
      (wire after);
    let next_restored = make_receipts ~task:(task_id "task-901") ~context offering in
    check
      (list string)
      "consumption reaches the persisted Context snapshot"
      [ "atlassian_page_create"; "atlassian_page_read" ]
      (Load_receipts.pending_names next_restored))
;;

let test_sibling_load_waits_for_atomic_publication () =
  let offering = offered two_offered in
  with_receipt_fixture offering (fun _env context receipts agent p ->
    Eio.Switch.run (fun sw ->
      let entered, enter = Eio.Promise.create () in
      let release, finish = Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun () ->
        Load_receipts.loaded
          receipts
          ~invocation:(invocation "first-load")
          ~names:[ "atlassian_jira_search" ]
          ~apply:(fun () ->
            Eio.Promise.resolve enter ();
            Eio.Promise.await release;
            Agent_core.Agent.extend_tools agent [ build (List.hd offering) ])
        |> function Ok () -> () | Error error -> fail (Load_receipts.error_to_string error));
      Eio.Promise.await entered;
      Eio.Fiber.fork ~sw (fun () ->
        execute p.tool (names_input [ "atlassian_confluence_search" ])
        |> loaded_output
        |> ignore);
      Eio.Fiber.yield ();
      Eio.Promise.resolve finish ());
    let restored = make_receipts ~task:(task_id "task-901") ~context offering in
    check
      (list string)
      "a sibling blocked on publication does not overwrite the first load"
      [ "atlassian_confluence_search"; "atlassian_jira_search" ]
      (Load_receipts.pending_names restored);
    let before = Agent_core.Context.to_json context in
    let failure = Failure "extension failed before installation" in
    (try
       Load_receipts.loaded
         restored
         ~invocation:(invocation "failed-load")
         ~names:[ "atlassian_jira_search" ]
         ~apply:(fun () -> raise failure)
       |> ignore;
       fail "the extension failure was swallowed"
     with
     | Failure _ as observed ->
       check bool "the original extension exception propagates" true (observed == failure));
    check
      string
      "a failed extension cannot replace a successful receipt"
      (Yojson.Safe.to_string before)
      (Yojson.Safe.to_string (Agent_core.Context.to_json context));
    check (list string) "the same receipt state remains readable after the failure"
      [ "atlassian_confluence_search"; "atlassian_jira_search" ]
      (Load_receipts.pending_names restored);
    let retry =
      placement ~receipts:restored ~agent_cell:(ref (Some agent)) offering
      |> require_placement
    in
    execute retry.tool (names_input [ "atlassian_jira_search" ])
    |> loaded_output |> ignore;
    let reloaded =
      match List.find_opt
              (fun (tool : Agent_core.Tool.t) -> tool.schema.name = "atlassian_jira_search")
              retry.already_used with
      | Some tool -> tool
      | None -> fail "a load after the failed extension did not place its tool"
    in
    execute reloaded (`Assoc []) |> loaded_output |> ignore;
    check (list string) "later load and dispatch use the same unpoisoned receipt state"
      [ "atlassian_confluence_search" ] (Load_receipts.pending_names restored))
;;

let test_failed_and_unknown_loads_do_not_grant () =
  let offering = offered two_offered in
  with_receipt_fixture offering (fun _env _context receipts _agent p ->
    let refused label result =
      match result with
      | Error _ -> ()
      | Ok _ -> fail (label ^ " unexpectedly loaded a tool")
    in
    let no_agent = placement ~receipts offering |> require_placement in
    refused
      "missing agent"
      (execute no_agent.tool (names_input [ "atlassian_jira_search" ]));
    refused "unknown-only request" (execute p.tool (names_input [ "atlassian_typo" ]));
    refused "malformed request" (execute p.tool (`Assoc [ "names", `Int 1 ]));
    refused
      "missing invocation"
      (Agent_core.Tool.execute p.tool (names_input [ "atlassian_jira_search" ]));
    check
      (list string)
      "no unsuccessful request creates a receipt"
      []
      (Load_receipts.pending_names receipts);
    execute p.tool (names_input [ "atlassian_jira_search"; "atlassian_typo" ])
    |> loaded_output
    |> ignore;
    check
      (list string)
      "a partial load records only tools actually installed"
      [ "atlassian_jira_search" ]
      (Load_receipts.pending_names receipts))
;;

let test_load_survives_purge_checkpoint_and_resume () =
  let offering = offered two_offered in
  with_receipt_fixture offering (fun env _context _receipts agent p ->
    let output =
      Agent_core.Tool.execute
        ~invocation:(invocation "toolu_ask")
        p.tool
        (names_input [ "atlassian_jira_search" ])
      |> loaded_output
    in
    let checkpoint = Agent_core.Agent.checkpoint agent in
    let checkpoint =
      { checkpoint with
        messages =
          [ asked_for [ "atlassian_jira_search" ]
          ; Agent_core.Types.tool_result_msg
              ~tool_use_id:"toolu_ask"
              ~content:output.content
              ()
          ]
      }
    in
    let checkpoint =
      match
        Keeper_checkpoint_purge.purge
          ~config:{ Keeper_checkpoint_purge.default_config with keep_recent_messages = 0 }
          checkpoint
      with
      | Ok (checkpoint, report) ->
        check
          int
          "the successful result body was really purged"
          1
          report.tool_results_cleared;
        checkpoint
      | Error _ -> fail "purge rejected the closed successful load cycle"
    in
    let checkpoint =
      match Agent_core.Checkpoint.of_json (Agent_core.Checkpoint.to_json checkpoint) with
      | Ok checkpoint -> checkpoint
      | Error error -> fail (Agent_core.Error.to_string error)
    in
    let fresh_context = Agent_core.Context.create () in
    Agent_core.Context.set fresh_context "unrelated-live-context" (`String "keep");
    let restored = restored_receipts ~source:checkpoint.context ~target:fresh_context in
    check
      (option string)
      "restoration preserves unrelated live Context"
      (Some "keep")
      (match Agent_core.Context.get fresh_context "unrelated-live-context" with
       | Some (`String value) -> Some value
       | _ -> None);
    let receipts =
      Load_receipts.create
        ~restored
        ~trace_id:(trace_id "search-test")
        ~task_id:(Some (task_id "task-901"))
        ~current_task_id:(fun () -> Ok (Some (task_id "task-901")))
        ~surface:(receipt_surface offering)
    in
    let agent_cell = ref None in
    let next =
      placement ~receipts ~agent_cell ~history:checkpoint.messages offering
      |> require_placement
    in
    let resumed =
      Agent_core.Agent.resume
        ~net:env#net
        ~checkpoint
        ~context:fresh_context
        ~tools:(next.tool :: next.already_used)
        ()
    in
    agent_cell := Some resumed;
    let tool =
      match
        Agent_core.Tool_set.find "atlassian_jira_search" (Agent_core.Agent.tools resumed)
      with
      | Some tool -> tool
      | None -> fail "restart lost the successful outstanding load"
    in
    execute tool (`Assoc []) |> loaded_output |> ignore;
    check
      (list string)
      "the resumed invocation consumes the grant"
      []
      (Load_receipts.pending_names receipts))
;;

let test_same_turn_claim_owns_its_successful_load () =
  let offering = offered (two_offered @ [ "page_read", "Read" ]) in
  let current = ref (Ok None) in
  with_receipt_fixture ~task:None ~current_task_id:(fun () -> !current) offering
    (fun _env context receipts agent p ->
      execute p.tool (names_input [ "atlassian_jira_search" ]) |> loaded_output |> ignore;
      current := Ok (Some (task_id "task-902"));
      execute p.tool (names_input [ "atlassian_confluence_search" ]) |> loaded_output |> ignore;
      check (list string) "the new Task owns only loads made for that Task"
        [ "atlassian_confluence_search" ] (Load_receipts.pending_names receipts);
      let before = Agent_core.Context.to_json context in
      current := Error "owner metadata temporarily unavailable";
      (match execute p.tool (names_input [ "atlassian_page_read" ]) with
       | Ok _ -> fail "unknown work ownership installed a deferred tool"
       | Error error ->
         check bool "work lookup failure can be retried" true error.recoverable;
         check bool "work lookup failure is infrastructure, not an argument error"
           true (error.error_class = Some Agent_core.Types.Transient));
      check bool "failed work lookup did not install its requested tool" false
        (Agent_core.Tool_set.mem "atlassian_page_read" (Agent_core.Agent.tools agent));
      check string "failed work lookup preserves existing receipts"
        (Yojson.Safe.to_string before) (Yojson.Safe.to_string (Agent_core.Context.to_json context));
      let next = make_receipts ~task:(task_id "task-902") ~context offering in
      check (list string) "the next turn retains the load made after the claim"
        [ "atlassian_confluence_search" ] (Load_receipts.pending_names next))
;;

let test_runtime_attempt_keeps_the_expanded_tool_set () =
  let offering = offered two_offered in
  with_receipt_fixture offering (fun env context receipts agent p ->
    execute p.tool (names_input [ "atlassian_jira_search" ]) |> loaded_output |> ignore;
    let tools = Keeper_agent_tool_surface.on_the_wire
        ~agent_cell:(ref (Some agent)) ~built:[ p.tool ] in
    let replacement = Agent_core.Agent.create ~net:env#net ~context ~tools
        ~config:(Agent_core.Types.default_config ~model:"another-runtime") () in
    let tool = match Agent_core.Tool_set.find "atlassian_jira_search" (Agent_core.Agent.tools replacement) with
      | Some tool -> tool
      | None -> fail "the next runtime attempt dropped the tool the prior attempt loaded"
    in
    execute tool (`Assoc []) |> loaded_output |> ignore;
    check (list string) "replacement runtime uses the same receipt authority" []
      (Load_receipts.pending_names receipts))
;;

let test_work_and_surface_changes_retire_loads () =
  let offering = offered two_offered in
  with_receipt_fixture offering (fun _env context _receipts _agent p ->
    execute p.tool (names_input [ "atlassian_jira_search" ]) |> loaded_output |> ignore;
    let initial = Agent_core.Context.copy context in
    let changed label ?(trace = "search-test") ?(task = Some (task_id "task-901")) surface
      =
      let target = Agent_core.Context.create () in
      let receipts =
        Load_receipts.create
          ~restored:(restored_receipts ~source:initial ~target)
          ~trace_id:(trace_id trace)
          ~task_id:task
          ~current_task_id:(fun () -> Ok task)
          ~surface
      in
      check (list string) label [] (Load_receipts.pending_names receipts);
      let returned =
        Load_receipts.create
          ~restored:(restored_receipts ~source:target ~target)
          ~trace_id:(trace_id "search-test")
          ~task_id:(Some (task_id "task-901"))
          ~current_task_id:(fun () -> Ok (Some (task_id "task-901")))
          ~surface:(receipt_surface offering)
      in
      check
        (list string)
        "returning to an old scope does not revive retired loads"
        []
        (Load_receipts.pending_names returned)
    in
    changed "Task switched" ~task:(Some (task_id "task-902")) (receipt_surface offering);
    changed "Task ended" ~task:None (receipt_surface offering);
    changed "trace changed" ~trace:"next-conversation" (receipt_surface offering);
    changed
      "catalog changed"
      (receipt_surface (offered (two_offered @ [ "typo", "Now present" ])));
    changed
      "input schema changed"
      (receipt_surface
         (offered ~input_schema:(`Assoc [ "type", `String "object" ]) two_offered));
    let moved =
      receipt_surface offering
      |> List.map (fun (entry : Load_receipts.surface_entry) ->
        match entry.source with
        | Builtin -> entry
        | Attached attached ->
          { entry with
            source = Attached { attached with endpoint = "https://other.example/mcp" }
          })
    in
    changed "same named service moved endpoints" moved)
;;

let test_invalid_restore_does_not_replace_live_state () =
  let source = Agent_core.Context.create_sync () in
  Agent_core.Context.set_scoped
    source
    Agent_core.Context.Session
    "keeper_tool_load_receipts"
    (`Assoc [ "pending", `List [] ]);
  let target = Agent_core.Context.create_sync () in
  let _ = make_receipts ~context:target (offered two_offered) in
  let before = Agent_core.Context.to_json target in
  (match Load_receipts.restore ~source ~target with
   | Error (Load_receipts.Invalid_snapshot _) -> ()
   | Error (Load_receipts.Work_scope_unavailable _) -> fail "restoration queried live work"
   | Ok _ -> fail "an incomplete snapshot was accepted as empty");
  check
    string
    "a malformed source leaves target state byte-for-byte unchanged"
    (Yojson.Safe.to_string before)
    (Yojson.Safe.to_string (Agent_core.Context.to_json target))
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
        ; test_case "a request without a successful load grants nothing" `Quick
            test_a_request_without_a_successful_load_grants_nothing
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
    ; ( "successful load continuity"
      , [ test_case "sibling loads survive and consume individually" `Quick
            test_successful_sibling_loads_survive_and_consume_individually
        ; test_case "sibling load waits for atomic publication" `Quick
            test_sibling_load_waits_for_atomic_publication
        ; test_case "failed and unknown loads grant nothing" `Quick
            test_failed_and_unknown_loads_do_not_grant
        ; test_case "load survives purge checkpoint and resume" `Quick
            test_load_survives_purge_checkpoint_and_resume
        ; test_case "a same-turn claim owns its successful load" `Quick
            test_same_turn_claim_owns_its_successful_load
        ; test_case "runtime attempt retains the expanded tool set" `Quick
            test_runtime_attempt_keeps_the_expanded_tool_set
        ; test_case "work and surface changes retire loads" `Quick
            test_work_and_surface_changes_retire_loads
        ; test_case "invalid restore preserves live state" `Quick
            test_invalid_restore_does_not_replace_live_state
        ] )
    ; ( "the carry window"
      , [ test_case "drops a tool whose last call is outside it" `Quick
            test_a_tool_outside_the_window_is_not_placed
        ; test_case "returns a dropped tool to the listing" `Quick
            test_a_dropped_tool_returns_to_the_listing
        ; test_case "does not cut without a new tool" `Quick
            test_the_carry_is_not_cut_without_a_new_tool
        ; test_case "does not cut on a call to a tool it already carries" `Quick
            test_a_call_to_a_carried_tool_does_not_cut
        ; test_case "cuts on a returning tool as it does on a new one" `Quick
            test_a_returning_tool_is_cut_on_like_a_new_one
        ; test_case "keeps a returning tool in offering order" `Quick
            test_a_returning_tool_keeps_its_place
        ; test_case "places everything when it is zero" `Quick
            test_a_zero_window_places_everything
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
