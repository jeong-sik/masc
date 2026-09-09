(** What the published surface says: that no agent tool appeared or vanished.

    The descriptions and input schemas this suite also pinned were literals
    read off the same published values before the declarations moved into
    [config/tools/*.toml] -- one producer against a snapshot of itself, so the
    only thing it could report was that someone edited a sentence. Those cases
    are gone; every case that stays reads the published value. *)

open Alcotest

let expected =
  [ "masc_agent_fitness"
  ; "masc_get_metrics"
  ; "masc_agent_card"
  ]
;;

let published = Tool_schemas_agent.schemas

(* The list is a published surface: a tool appearing or vanishing changes what
   a Keeper is offered. A count says that badly -- one name out and one in
   leaves the total unchanged -- so the names are compared, in order. *)
let test_no_extras () =
  check
    (list string)
    "published agent tools, in order"
    expected
    (List.map (fun (s : Masc_domain.tool_schema) -> s.name) published)
;;

let () =
  run
    "agent tool toml parity"
    [ ( "parity"
      , [ test_case "no tool appeared or vanished" `Quick test_no_extras
        ] )
    ]
;;
