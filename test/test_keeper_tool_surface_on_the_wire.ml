(** [Keeper_agent_tool_surface.on_the_wire] answers what a request carried, not
    what the turn was built with.

    Four observation points used to read the built list — wire capture, the
    wake payload, and the turn record's two ctx-composition sites — so the
    attached-service listing and every mid-turn widening were invisible to all
    of them at once. These cases pin the two ways the answers differ. *)

open Alcotest
open Masc

let tool name =
  Agent_core.Tool.create
    ~name
    ~description:("fixture tool " ^ name)
    ~parameters:[]
    (fun (_ : Yojson.Safe.t) -> Ok { Agent_core.Types.content = ""; content_blocks = None; _meta = None })
;;

let names tools =
  List.map (fun (t : Agent_core.Tool.t) -> t.Agent_core.Tool.schema.name) tools
  |> List.sort String.compare
;;

let with_agent ~tools f =
  Eio_main.run
  @@ fun env ->
  let agent =
    Agent_core.Agent.create
      ~net:(Eio.Stdenv.net env)
      ~config:(Agent_core.Types.default_config ~model:"fixture-model")
      ~tools
      ()
  in
  f agent
;;

(* An official-client lane never creates an agent: it pins its tool set at
   process spawn, so the built list is the whole truth there. *)
let test_no_agent_reports_the_built_list () =
  let built = [ tool "Read"; tool "keeper_tool_search" ] in
  let observed =
    Keeper_agent_tool_surface.on_the_wire ~agent_cell:(ref None) ~built
  in
  check (list string) "built list passes through" (names built) (names observed)
;;

(* The Agent Core lane is handed the listing, not the attached schemas.  Report
   what it holds, not the flat list the official-client lanes were given. *)
let test_agent_surface_wins_over_the_built_list () =
  with_agent ~tools:[ tool "Read"; tool "keeper_tool_search" ] (fun agent ->
    let built = [ tool "Read"; tool "github_get_me"; tool "github_list_branches" ] in
    let observed =
      Keeper_agent_tool_surface.on_the_wire ~agent_cell:(ref (Some agent)) ~built
    in
    check
      (list string)
      "the agent's own set is the answer"
      [ "Read"; "keeper_tool_search" ]
      (names observed))
;;

(* The case every observation point got wrong: from the round after a load the
   built list is short by exactly the tools the model just asked for. *)
let test_a_mid_turn_widening_is_visible () =
  with_agent ~tools:[ tool "Read"; tool "keeper_tool_search" ] (fun agent ->
    let built = [ tool "Read"; tool "keeper_tool_search" ] in
    Agent_core.Agent.extend_tools agent [ tool "github_get_me" ];
    let observed =
      Keeper_agent_tool_surface.on_the_wire ~agent_cell:(ref (Some agent)) ~built
    in
    check
      (list string)
      "the loaded tool is counted"
      [ "Read"; "github_get_me"; "keeper_tool_search" ]
      (names observed);
    check
      bool
      "and the built list still does not carry it"
      false
      (List.mem "github_get_me" (names built)))
;;

let test_request_context_references_require_callable_tools () =
  let built = [tool "keeper_artifact_read"; tool "Read"] in
  let surface ~enabled ~tool_choice ~schema_names =
    Keeper_agent_tool_surface.for_request ~enabled ~tool_choice ~schema_names
      ~checkpoint_owner:(Some Runtime_execution.Official_client)
      ~agent_cell:(ref None) ~built |> names in
  check (list string) "disabled surface offers no reader" []
    (surface ~enabled:false ~tool_choice:None ~schema_names:["keeper_artifact_read"]);
  check (list string) "explicit text-only request offers no reader" []
    (surface ~enabled:true ~tool_choice:(Some Agent_core.Types.None_)
       ~schema_names:["keeper_artifact_read"]);
  check (list string) "filtered reader stays unavailable" ["Read"]
    (surface ~enabled:true ~tool_choice:(Some Agent_core.Types.Auto) ~schema_names:["Read"]);
  check (list string) "callable reader is offered" ["keeper_artifact_read"]
    (surface ~enabled:true ~tool_choice:None ~schema_names:["keeper_artifact_read"])
;;

let test_failover_uses_current_owner_without_clearing_agent () =
  let loader = tool "keeper_tool_search" in
  let reader_name = "keeper_workspace_memory_read" in
  with_agent ~tools:[tool "Read"; loader] (fun agent ->
    let agent_cell = ref (Some agent) in
    let built = [tool "Read"; loader; tool "keeper_memory_search"] in
    let checkpoint_owner = ref (Some Runtime_execution.Masc_agent_core) in
    let surface () = Keeper_agent_tool_surface.for_attempt
        ~checkpoint_owner:!checkpoint_owner ~agent_cell ~built in
    let request () =
      let active = surface () in
      let offered = Keeper_agent_tool_surface.for_request
          ~checkpoint_owner:!checkpoint_owner ~enabled:true ~tool_choice:None
          ~schema_names:(names active.tools) ~agent_cell ~built in
      offered, Keeper_request_tool_access.create ~offered
        ~deferred_names:[reader_name] ~loader_alive:active.loader_alive in
    let _, access = request () in
    check bool "Agent Core's live loader offers deferred recall" true
      (Keeper_request_tool_access.route access ~name:reader_name = Discoverable);
    Agent_core.Agent.extend_tools agent [tool reader_name];
    let widened, access = request () in
    check bool "same attempt observes dynamic widening" true
      (List.mem reader_name (names widened));
    check bool "loaded reader becomes directly callable" true
      (Keeper_request_tool_access.route access ~name:reader_name = Direct);
    checkpoint_owner := Some Runtime_execution.Official_client;
    let official, access = request () in
    check (list string) "official failover uses its built schemas, not the old agent"
      (names built) (names official);
    check bool "the old live loader cannot advertise recall in the official attempt" true
      (Keeper_request_tool_access.route access ~name:reader_name = Unavailable);
    check bool "official built tools survive the schema filter" true
      (Keeper_request_tool_access.route access ~name:"keeper_memory_search" = Direct);
    check bool "official attempt has no in-process deferred loader" false
      (surface ()).loader_alive;
    check bool "ownership selection leaves the previous agent intact" true
      (match !agent_cell with Some retained -> retained == agent | None -> false);
    checkpoint_owner := None;
    check bool "an unowned stale cell does not promise a loader" false
      (surface ()).loader_alive;
    check (list string) "before dispatch only the built surface is known"
      (names built) (names (surface ()).tools))
;;

let () =
  run
    "keeper tool surface on the wire"
    [ ( "on_the_wire"
      , [ test_case "no agent reports the built list" `Quick
            test_no_agent_reports_the_built_list
        ; test_case "agent surface wins over the built list" `Quick
            test_agent_surface_wins_over_the_built_list
        ; test_case "context references require callable tools" `Quick
            test_request_context_references_require_callable_tools
        ; test_case "failover uses current owner with a retained agent cell" `Quick
            test_failover_uses_current_owner_without_clearing_agent
        ; test_case "a mid-turn widening is visible" `Quick
            test_a_mid_turn_widening_is_visible
        ] )
    ]
;;
