(** Exact current-schema Keeper meta decoding. *)

open Alcotest
open Masc

let replace_field name value = function
  | `Assoc fields -> `Assoc ((name, value) :: List.remove_assoc name fields)
  | _ -> Alcotest.fail "current fixture must be an object"

let remove_field name = function
  | `Assoc fields -> `Assoc (List.remove_assoc name fields)
  | _ -> Alcotest.fail "current fixture must be an object"

let expect_rejected label json =
  match Keeper_meta_json_parse.meta_of_json json with
  | Error detail ->
    check bool (label ^ " requires reset") true
      (Astring.String.is_infix ~affix:"runtime reset required" detail)
  | Ok _ -> Alcotest.failf "%s unexpectedly decoded" label

let current_json () = Masc_test_deps.current_meta_json_fixture ~name:"current-meta" ()

let test_current_roundtrip () =
  match Keeper_meta_json_parse.meta_of_json (current_json ()) with
  | Error detail -> Alcotest.fail detail
  | Ok meta ->
    (match Keeper_meta_json.meta_to_json meta |> Keeper_meta_json_parse.meta_of_json with
     | Ok _ -> ()
     | Error detail -> Alcotest.fail detail)

let test_missing_and_wrong_current_fields_rejected () =
  expect_rejected "missing generation" (current_json () |> remove_field "generation");
  expect_rejected
    "wrong paused type"
    (current_json () |> replace_field "paused" (`String "false"))

let test_retired_config_fields_rejected () =
  List.iter
    (fun key ->
       expect_rejected
         ("retired " ^ key)
         (current_json () |> replace_field key `Null))
    Keeper_meta_json_scrub.toml_only_field_names

let () =
  run
    "keeper_meta_json_current_schema"
    [ ( "current-schema"
      , [ test_case "current writer roundtrip" `Quick test_current_roundtrip
        ; test_case "missing and wrong current fields reject" `Quick
            test_missing_and_wrong_current_fields_rejected
        ; test_case "retired config fields reject" `Quick
            test_retired_config_fields_rejected
        ] )
    ]
