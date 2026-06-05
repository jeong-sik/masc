open Alcotest

module P = Keeper_toml_parser

let test_parse_table_values () =
  let input =
    {|
[keeper]
name = "alpha"
turns = 7
enabled = true
models = ["fast", "slow"]
|}
  in
  match P.parse_toml input with
  | Error msg -> fail msg
  | Ok doc ->
    check bool "name"
      true
      (match List.assoc_opt "keeper.name" doc with
       | Some (P.Toml_string "alpha") -> true
       | _ -> false);
    check bool "turns"
      true
      (match List.assoc_opt "keeper.turns" doc with
       | Some (P.Toml_int 7) -> true
       | _ -> false);
    check bool "models"
      true
      (match List.assoc_opt "keeper.models" doc with
       | Some (P.Toml_string_array [ "fast"; "slow" ]) -> true
       | _ -> false)
;;

let test_parse_reports_syntax_error () =
  check bool "syntax error"
    true
    (match P.parse_toml "[keeper" with
     | Error _ -> true
     | Ok _ -> false)
;;

let () =
  run
    "Keeper_toml_parser"
    [ ( "parse"
      , [ test_case "table values" `Quick test_parse_table_values
        ; test_case "syntax error" `Quick test_parse_reports_syntax_error
        ] )
    ]
;;
