open Alcotest

module L = Keeper_toml_loader

let doc =
  [ "keeper.name", L.Toml_string "alpha"
  ; "keeper.turns", L.Toml_int 7
  ; "keeper.temperature", L.Toml_float 0.2
  ; "keeper.enabled", L.Toml_bool true
  ; "keeper.models", L.Toml_string_array [ "fast"; "slow" ]
  ]
;;

let test_accessors () =
  check (option string) "string" (Some "alpha") (L.toml_string_opt doc "keeper.name");
  check (option int) "int" (Some 7) (L.toml_int_opt doc "keeper.turns");
  check bool "float from int"
    true
    (match L.toml_float_opt doc "keeper.turns" with
     | Some value -> Float.equal value 7.0
     | None -> false);
  check bool "bool"
    true
    (match L.toml_bool_opt doc "keeper.enabled" with
     | Some true -> true
     | _ -> false);
  check (list string) "array" [ "fast"; "slow" ]
    (L.toml_string_list doc "keeper.models")
;;

let test_update_field_in_content_preserves_table () =
  let content = "[keeper]\nname = \"old\"\n\n[other]\nname = \"keep\"\n" in
  match L.update_field_in_content ~table:"keeper" ~key:"name" ~value:"new" content with
  | Error msg -> fail msg
  | Ok updated ->
    check bool "updates target table" true
      (String.contains updated 'n'
       && String.starts_with ~prefix:"[keeper]\nname = \"new\"" updated);
    check bool "keeps other table" true
      (String.contains updated '['
       && String.ends_with ~suffix:"[other]\nname = \"keep\"\n" updated)
;;

let () =
  run
    "Keeper_toml_loader"
    [ ( "accessors", [ test_case "toml accessors" `Quick test_accessors ] )
    ; ( "writer"
      , [ test_case
            "update field in target table"
            `Quick
            test_update_field_in_content_preserves_table
        ] )
    ]
;;
