(** The publication order of the tools this suite covers.

    Everything else it held was a copy. The declarations live in
    [config/tools/*.toml], the published values are those files decoded, and
    the expected descriptions and schemas were literals read off the same
    values before the move -- one producer compared against a hand-written
    snapshot of itself. Those cases are gone.

    Order is not in the TOML. It is the order of the OCaml list below, and
    #34379 is the open question about what changed it, so it stays. *)

open Alcotest

let expected =
  [ "masc_status"
  ; "masc_check"
  ; "masc_heartbeat"
  ]
;;

let published = Tool_schemas_workspace_core.schemas

let test_the_published_order_is_unchanged () =
  check
    (list string)
    "published order"
    expected
    (List.map (fun (s : Masc_domain.tool_schema) -> s.name) published)
;;

let () =
  run
    "workspace_core_toml_parity"
    [ ( "order"
      , [ test_case "the published order is unchanged" `Quick
            test_the_published_order_is_unchanged
        ] )
    ]
;;
