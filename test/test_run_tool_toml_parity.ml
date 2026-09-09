(** The publication order of [Tool_schemas_run.schemas].

    Everything else this suite held was a copy. The declarations live in
    [config/tools/*.toml], [Tool_schemas_run.schemas] is those files decoded, and the expected
    descriptions and schemas were literals read off that same list before the
    move -- one producer compared against a hand-written snapshot of itself.
    Those cases are gone.

    Order is not in the TOML. It is the order of the OCaml list above, and
    #34379 is the open question about what changed it, so it stays. *)

open Alcotest

let expected =
  [ "masc_run_init"
  ; "masc_run_plan"
  ; "masc_run_get"
  ; "masc_run_list"
  ]
;;

let published = Tool_schemas_run.schemas

let test_the_published_order_is_unchanged () =
  check
    (list string)
    "Tool_schemas_run.schemas in order"
    expected
    (List.map (fun (s : Masc_domain.tool_schema) -> s.name) published)
;;

let () =
  run
    "run_tool_toml_parity"
    [ ( "order"
      , [ test_case "the published order is unchanged" `Quick
            test_the_published_order_is_unchanged
        ] )
    ]
;;
