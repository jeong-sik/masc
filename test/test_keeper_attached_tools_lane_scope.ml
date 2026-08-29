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
let with_bundle f =
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
        { Keeper_identity_tool_search.offered =
            offered [ "jira_search"; "confluence_search" ]
        ; agent_cell = ref None
        }
      ~capability_surface
      ()
  in
  Fun.protect ~finally:bundle.Keeper_tools_agent_core.cleanup (fun () -> f bundle)
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
    (* Both shapes carry the same built-ins, so what the lane view drops is
       exactly the attached tools and what it gains is the listing. *)
    let dropped = List.filter (fun n -> not (List.mem n listed)) sent in
    check
      (list string)
      "the lane view drops the attached tools and nothing else"
      [ "atlassian_confluence_search"; "atlassian_jira_search" ]
      (List.sort String.compare dropped);
    let gained = List.filter (fun n -> not (List.mem n sent)) listed in
    check int "and gains exactly one tool in their place" 1 (List.length gained))
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
        ] )
    ]
;;
