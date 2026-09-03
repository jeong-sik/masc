(** Which lane is handed the attached-tool listing.

    The listing is only useful to a lane that can widen a running turn, and
    exactly one can: {!Agent_core.Agent.extend_tools} reaches the agent that
    {!Runtime_agent} publishes, and nothing publishes one on the
    official-client lanes. Claude Code fixes its tool set in the spawn argv,
    Codex in [thread/start], Antigravity at turn start, and on all three the
    surface digest is part of a resumable session's identity.

    So a Keeper on one of those lanes that was handed the listing would read a
    tool name and be told there is no agent to make it callable in — with no
    other way to reach the service it attached. The bundle therefore carries
    both shapes and the lane picks. *)

open Alcotest
open Masc

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

let offered names =
  let catalog =
    { Keeper_identity_tools.provider_id = "atlassian"
    ; provider_label = "Atlassian"
    ; discovered_at = 0.0
    ; tools =
        List.map
          (fun name ->
             { Mcp_client.name
             ; description = "Does one thing for Atlassian."
             ; input_schema = `Assoc [ "type", `String "object" ]
             ; read_only = Some true
             })
          names
    }
  in
  (Keeper_identity_tools.agent_tools ~provider:(provider ()) catalog)
    .Keeper_identity_tools.offered
;;

let make_meta () : Keeper_meta_contract.keeper_meta =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
          [ "name", `String "lane-scope"
          ; "trace_id", `String "test-trace-lane-scope"
          ])
  with
  | Ok meta -> meta
  | Error e -> failf "make_meta failed: %s" e
;;

let tool_names tools =
  List.map (fun (tool : Agent_core.Tool.t) -> tool.Agent_core.Tool.schema.name) tools
;;

(* No descriptors, so the only difference between the two shapes is the one
   under test. *)
let with_bundle ?(history = []) ?(attached = true) f =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let dir = Filename.temp_file "masc_lane_scope" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Masc_test_deps.with_publication_recovery_registry
    ~sw
    ~fs:(Eio.Stdenv.fs env)
    ~registry_root:dir
  @@ fun registry ->
  let meta = make_meta () in
  (* No skills, so the bundle carries no composition tools and the only
     difference between the two shapes is the one under test. *)
  let snapshot =
    match Skill_source_config.parse_text "" with
    | Error _ -> failf "an empty skill source config must parse"
    | Ok config ->
      (match Skill_catalog_snapshot.configured ~config [] with
       | Ok snapshot -> snapshot
       | Error _ -> failf "an empty skill snapshot must build")
  in
  let capability_surface =
    Keeper_capability_surface.create
      ~skill_names:None
      ~global_skill_catalog:Keeper_skill_catalog.empty
      ~skill_inventory:(Keeper_skill_inventory.of_snapshot snapshot)
      ~task_skills:[]
  in
  let bundle =
    Keeper_tools_agent_core_bundle.make_tool_bundle_for_capability_surface
      ~config:(Workspace.default_config dir)
      ~meta
      ~publication_recovery:
        Keeper_publication_recovery_availability.
          { provider = Masc_test_deps.publication_recovery_provider registry
          ; keeper_name = meta.Keeper_meta_contract.name
          }
      ~ctx_snapshot:(Keeper_context_runtime.create ~eio:false ~system_prompt:"test")
      ~identity_surface:
        { Keeper_tools_agent_core.offered =
            offered (if attached then [ "jira_search"; "confluence_search" ] else [])
        ; agent_cell = ref None
        ; history
        }
      ~capability_surface
      ()
  in
  Fun.protect ~finally:bundle.Keeper_tools_agent_core.cleanup (fun () -> f bundle)
;;

let called name =
  { Agent_core.Types.role = Agent_core.Types.Assistant
  ; content =
      [ Agent_core.Types.ToolUse
          { id = "toolu_fixture"
          ; name
          ; input = `Assoc []
          }
      ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

(* Every tool in this bundle whose own file declares [defer_loading = true],
   whether or not the turn ended up placing it. *)
(* The two halves of [listing], for a bundle a case already has in hand. *)
let listing_placed bundle =
  match bundle.Keeper_tools_agent_core.listing with
  | Keeper_tools_agent_core.No_listing -> false
  | Keeper_tools_agent_core.Listing _ -> true
;;

let listing_deferred_names bundle =
  match bundle.Keeper_tools_agent_core.listing with
  | Keeper_tools_agent_core.No_listing -> []
  | Keeper_tools_agent_core.Listing { deferred_builtin_names } -> deferred_builtin_names
;;

let declared_deferrable bundle =
  List.filter
    (fun name ->
       match Tool_loading_declarations.loading_of_tool name with
       | Tool_definition_toml.Deferrable -> true
       | Tool_definition_toml.Always_loaded -> false)
    (tool_names bundle.Keeper_tools_agent_core.tools)
;;

let test_the_official_client_lanes_get_the_tools_themselves () =
  with_bundle (fun bundle ->
    let names = tool_names bundle.Keeper_tools_agent_core.tools in
    List.iter
      (fun name ->
         check
           bool
           (Printf.sprintf "%s is sent to a lane that cannot widen a turn" name)
           true
           (List.mem name names))
      [ "atlassian_jira_search"; "atlassian_confluence_search" ])
;;

let test_the_agent_core_lane_gets_the_listing_instead () =
  with_bundle (fun bundle ->
    let listed = tool_names bundle.Keeper_tools_agent_core.agent_core_tools in
    let sent = tool_names bundle.Keeper_tools_agent_core.tools in
    List.iter
      (fun name ->
         check
           bool
           (Printf.sprintf "%s is not sent as a schema on this lane" name)
           false
           (List.mem name listed))
      [ "atlassian_jira_search"; "atlassian_confluence_search" ];
    (* What the lane view drops is every tool held back, whatever its source:
       the attached ones, which are held by default, and the built-ins whose
       own tool file declares [defer_loading = true]. What it gains in their
       place is one listing. *)
    let dropped = List.filter (fun n -> not (List.mem n listed)) sent in
    check
      bool
      "the attached tools are among what the lane view drops"
      true
      (List.for_all
         (fun n -> List.mem n dropped)
         [ "atlassian_confluence_search"; "atlassian_jira_search" ]);
    check
      (list string)
      "and every other dropped tool is one that declared itself deferrable"
      []
      (List.filter
         (fun n ->
            (not (List.mem n [ "atlassian_confluence_search"; "atlassian_jira_search" ]))
            &&
            match Tool_loading_declarations.loading_of_tool n with
            | Tool_definition_toml.Deferrable -> false
            | Tool_definition_toml.Always_loaded -> true)
         dropped);
    let gained = List.filter (fun n -> not (List.mem n sent)) listed in
    check int "and gains exactly one tool in their place" 1 (List.length gained))
;;

(* The axis this change adds: a built-in leaves the request because its own
   file says so, not because of where it came from. Of 89 built-ins on one
   Keeper, 33 went a whole day uncalled -- 21,601 bytes on every request of
   every turn, and a turn is many requests. *)
let test_a_builtin_that_declares_deferral_leaves_the_request () =
  with_bundle (fun bundle ->
    let listed = tool_names bundle.Keeper_tools_agent_core.agent_core_tools in
    let sent = tool_names bundle.Keeper_tools_agent_core.tools in
    let declared_deferrable = declared_deferrable bundle in
    check
      bool
      "at least one built-in declares deferral, or this proves nothing"
      true
      (declared_deferrable <> []);
    check
      (list string)
      "no tool that declared deferral is sent as a schema on this lane"
      []
      (List.filter (fun n -> List.mem n listed) declared_deferrable);
    (* And the lanes that cannot widen a turn still get every one of them:
       a name they cannot load is a name they cannot reach. *)
    check
      bool
      "the lanes that cannot widen a turn still get them as schemas"
      true
      (List.for_all (fun n -> List.mem n sent) declared_deferrable))
;;

(* [Keeper_run_tools_setup] compares the bundle against what the descriptor
   projection says the surface should hold, and logs [Log.Error] every turn
   when they disagree. There are two surfaces now and they name the attached
   tools differently, so a check written for one of them passes while the
   other drifts. This pins the shape the Agent Core lane is checked against;
   [test_keeper_tool_bundle_classifiable] pins the other. *)
let test_the_agent_core_shape_is_what_the_projection_expects () =
  with_bundle (fun bundle ->
    let expected =
      Keeper_run_tools_setup.expected_model_tool_names
        ~deferred_names:(listing_deferred_names bundle)
        ~skill_catalog:Keeper_skill_catalog.empty
        ~identity_names:[ Keeper_identity_tool_search.tool_name ]
        ~model_visible_descriptors:(Keeper_tool_descriptor.model_visible_descriptors ())
        ()
    in
    check
      (list string)
      "the listing stands for every attached tool and nothing else moved"
      expected
      (List.sort_uniq
         String.compare
         (tool_names bundle.Keeper_tools_agent_core.agent_core_tools)))
;;

let test_a_carried_tool_is_part_of_the_agent_core_identity_projection () =
  let jira = "atlassian_jira_search" in
  with_bundle ~history:[ called jira ] (fun bundle ->
    let actual = tool_names bundle.Keeper_tools_agent_core.agent_core_tools in
    let identity_names =
      Keeper_run_tools_setup.agent_core_identity_names
        ~listed:true
        ~attached_names:[ jira; "atlassian_confluence_search" ]
        ~actual_names:actual
    in
    check
      (list string)
      "the listing and the carried schema are both projected"
      [ jira; Keeper_identity_tool_search.tool_name ]
      identity_names;
    let expected =
      Keeper_run_tools_setup.expected_model_tool_names
        (* Same rule the setup uses: declared and not on the surface. A
           declared tool that is present -- because this conversation ran it --
           must not be subtracted, or the check expects it gone. *)
        ~deferred_names:
          (Keeper_run_tools_setup.deferred_names_absent_from
             ~declared_names:(declared_deferrable bundle)
             ~actual_names:actual)
        ~skill_catalog:Keeper_skill_catalog.empty
        ~identity_names
        ~model_visible_descriptors:(Keeper_tool_descriptor.model_visible_descriptors ())
        ()
    in
    check
      (list string)
      "the carried surface no longer produces a false projection mismatch"
      expected
      (List.sort_uniq String.compare actual))
;;

let test_an_unknown_actual_tool_stays_out_of_the_identity_expectation () =
  let jira = "atlassian_jira_search" in
  check
    (list string)
    "a configured carried tool is expected, an unknown actual tool is not"
    [ jira; Keeper_identity_tool_search.tool_name ]
    (Keeper_run_tools_setup.agent_core_identity_names
       ~listed:true
       ~attached_names:[ jira ]
       ~actual_names:[ jira; "unconfigured_service_tool" ])
;;

(* The two axes meet here. A built-in can declare [defer_loading = true] and
   still be on the surface, because this conversation has run it and a tool it
   has run is placed with its schema again.

   Live on 2026-08-31 this cost 60 [keeper_model_tool_projection_mismatch]
   errors in an hour: the bundle reported what declared itself deferrable, so
   the projection check expected [keeper_ide_annotate] to be gone from a
   Keeper that had called it the day before. What the check needs is what is
   actually missing. *)
let test_a_declared_tool_this_conversation_ran_is_not_reported_as_held () =
  let ran_a_declared_builtin =
    { Agent_core.Types.role = Agent_core.Types.Assistant
    ; content =
        [ Agent_core.Types.ToolUse
            { id = "toolu_fixture"; name = "keeper_ide_annotate"; input = `Assoc [] }
        ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  with_bundle ~history:[ ran_a_declared_builtin ] (fun bundle ->
    let listed = tool_names bundle.Keeper_tools_agent_core.agent_core_tools in
    check
      bool
      "the tool this conversation ran is on the surface despite its declaration"
      true
      (List.mem "keeper_ide_annotate" listed);
    (* Which is the whole point: the projection check subtracts what is
       missing from the surface, so a declared tool that is present must not
       be subtracted. *)
    let expected =
      Keeper_run_tools_setup.expected_model_tool_names
        ~deferred_names:
          (Keeper_run_tools_setup.deferred_names_absent_from
             ~declared_names:(declared_deferrable bundle)
             ~actual_names:listed)
        ~skill_catalog:Keeper_skill_catalog.empty
        ~identity_names:
          (Keeper_run_tools_setup.agent_core_identity_names
       ~listed:true
             ~attached_names:[ "atlassian_jira_search"; "atlassian_confluence_search" ]
             ~actual_names:listed)
        ~model_visible_descriptors:(Keeper_tool_descriptor.model_visible_descriptors ())
        ()
    in
    check
      (list string)
      "so the projection check agrees with the surface"
      expected
      (List.sort_uniq String.compare listed))
;;

(* A Keeper with nothing attached still gets a listing, because a built-in can
   declare its own deferral. Deriving "is there a listing" from "is anything
   attached" left code-reviewer -- no attachment, declared built-ins -- logging
   keeper_tool_search as a tool the projection did not expect, twice in the
   two minutes after the fix for the previous mismatch went live. *)
let test_a_keeper_with_nothing_attached_still_gets_a_listing () =
  with_bundle ~attached:false (fun bundle ->
    let listed = tool_names bundle.Keeper_tools_agent_core.agent_core_tools in
    check
      bool
      "the bundle reports that it placed a listing"
      true
      (listing_placed bundle);
    check
      bool
      "and the listing is on the surface"
      true
      (List.mem Keeper_identity_tool_search.tool_name listed);
    let expected =
      Keeper_run_tools_setup.expected_model_tool_names
        ~deferred_names:
          (Keeper_run_tools_setup.deferred_names_absent_from
             ~declared_names:(declared_deferrable bundle)
             ~actual_names:listed)
        ~skill_catalog:Keeper_skill_catalog.empty
        ~identity_names:
          (Keeper_run_tools_setup.agent_core_identity_names
             ~listed:(listing_placed bundle)
             ~attached_names:[]
             ~actual_names:listed)
        ~model_visible_descriptors:(Keeper_tool_descriptor.model_visible_descriptors ())
        ()
    in
    check
      (list string)
      "so the projection check does not report the listing as unexpected"
      expected
      (List.sort_uniq String.compare listed))
;;

(* And the thing the [listed] flag must not become: read back off the surface,
   it would expect the listing exactly when the listing is there. *)
let test_a_missing_listing_is_still_caught () =
  check
    (list string)
    "a listing the turn placed but the surface lost is still expected"
    [ "atlassian_jira_search"; Keeper_identity_tool_search.tool_name ]
    (Keeper_run_tools_setup.agent_core_identity_names
       ~listed:true
       ~attached_names:[ "atlassian_jira_search" ]
       ~actual_names:[ "atlassian_jira_search" ])
;;

(* The order the agent_core lane sends its tools in is the order the provider
   caches, and a prefix is reusable only byte-for-byte. The bundle states that
   order: the always-loaded tools first, then the listing, then the attached
   tools this conversation has already run. A set comparison does not see a
   reordering, and a reordering costs the whole prefix. *)
let test_the_agent_core_order_is_stated_by_the_bundle () =
  let jira = "atlassian_jira_search" in
  with_bundle (fun bundle ->
    let sent = tool_names bundle.Keeper_tools_agent_core.agent_core_tools in
    check
      bool
      "with nothing carried, the listing is last"
      true
      (match List.rev sent with
       | last :: _ -> String.equal last Keeper_identity_tool_search.tool_name
       | [] -> false);
    check
      bool
      "no tool is sent twice"
      true
      (List.length (List.sort_uniq String.compare sent) = List.length sent));
  with_bundle ~history:[ called jira ] (fun bundle ->
    let sent = tool_names bundle.Keeper_tools_agent_core.agent_core_tools in
    check
      (list string)
      "a carried tool follows the listing"
      [ Keeper_identity_tool_search.tool_name; jira ]
      (let rec from_listing = function
         | [] -> []
         | name :: rest
           when String.equal name Keeper_identity_tool_search.tool_name ->
           name :: rest
         | _ :: rest -> from_listing rest
       in
       from_listing sent))
;;

let () =
  run
    "attached tools lane scope"
    [ ( "the bundle"
      , [ test_case
            "hands the official-client lanes the tools themselves"
            `Quick
            test_the_official_client_lanes_get_the_tools_themselves
        ; test_case
            "hands the agent core lane the listing instead"
            `Quick
            test_the_agent_core_lane_gets_the_listing_instead
        ; test_case
            "holds back a built-in that declares deferral"
            `Quick
            test_a_builtin_that_declares_deferral_leaves_the_request
        ; test_case
            "does not report a declared tool this conversation ran as held"
            `Quick
            test_a_declared_tool_this_conversation_ran_is_not_reported_as_held
        ; test_case
            "builds the agent core shape the projection expects"
            `Quick
            test_the_agent_core_shape_is_what_the_projection_expects
        ; test_case
            "projects an attached tool carried from history"
            `Quick
            test_a_carried_tool_is_part_of_the_agent_core_identity_projection
        ; test_case
            "gives a Keeper with nothing attached a listing"
            `Quick
            test_a_keeper_with_nothing_attached_still_gets_a_listing
        ; test_case
            "still expects a listing the surface lost"
            `Quick
            test_a_missing_listing_is_still_caught
        ; test_case
            "states the agent_core tool order"
            `Quick
            test_the_agent_core_order_is_stated_by_the_bundle
        ; test_case
            "does not explain an unknown actual tool"
            `Quick
            test_an_unknown_actual_tool_stays_out_of_the_identity_expectation
        ] )
    ]
;;
