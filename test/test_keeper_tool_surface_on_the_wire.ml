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
    (fun (_ : Yojson.Safe.t) -> Ok { Agent_core.Types.content = ""; _meta = None })
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

let () =
  run
    "keeper tool surface on the wire"
    [ ( "on_the_wire"
      , [ test_case "no agent reports the built list" `Quick
            test_no_agent_reports_the_built_list
        ; test_case "agent surface wins over the built list" `Quick
            test_agent_surface_wins_over_the_built_list
        ; test_case "a mid-turn widening is visible" `Quick
            test_a_mid_turn_widening_is_visible
        ] )
    ]
;;
