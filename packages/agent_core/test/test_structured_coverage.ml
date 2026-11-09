(** Additional coverage tests for Structured module.

    Targets uncovered schema_to_json_schema cases not covered by
    test_structured.ml. *)

open Agent_core
open Types

(* ── Helpers ────────────────────────────────────────────────────── *)

let check_string = Alcotest.(check string)

let test_schema_array_object_param_types () =
  let schema : unit Structured.schema =
    { params =
        [ { name = "items"
          ; description = "An array"
          ; param_type = Array
          ; required = true
          }
        ; { name = "config"
          ; description = "An object"
          ; param_type = Object
          ; required = false
          }
        ]
    ; parse = (fun _ -> Ok ())
    }
  in
  let json = Structured.schema_to_json_schema schema in
  let open Yojson.Safe.Util in
  let props = json |> member "properties" in
  check_string "array type" "array" (props |> member "items" |> member "type" |> to_string);
  check_string
    "object type"
    "object"
    (props |> member "config" |> member "type" |> to_string)
;;

(* ── schema_to_json_schema: single required param ─────────────────── *)

let test_schema_single_required () =
  let schema : string Structured.schema =
    { params =
        [ { name = "value"
          ; description = "The value"
          ; param_type = String
          ; required = true
          }
        ]
    ; parse =
        (fun json ->
          let open Yojson.Safe.Util in
          try Ok (json |> member "value" |> to_string) with
          | exn -> Error (Printexc.to_string exn))
    }
  in
  let json = Structured.schema_to_json_schema schema in
  let open Yojson.Safe.Util in
  let required = json |> member "required" |> to_list |> List.map to_string in
  Alcotest.(check int) "1 required" 1 (List.length required);
  check_string "required name" "value" (List.hd required)
;;

(* ── schema_to_json_schema: all optional params ───────────────────── *)

let test_schema_all_optional () =
  let schema : unit Structured.schema =
    { params =
        [ { name = "a"; description = "A"; param_type = String; required = false }
        ; { name = "b"; description = "B"; param_type = Integer; required = false }
        ]
    ; parse = (fun _ -> Ok ())
    }
  in
  let json = Structured.schema_to_json_schema schema in
  let open Yojson.Safe.Util in
  let required = json |> member "required" |> to_list in
  Alcotest.(check int) "0 required" 0 (List.length required)
;;

let () =
  Alcotest.run
    "structured_coverage"
    [ ( "schema_to_json_schema"
      , [ Alcotest.test_case
            "array/object types"
            `Quick
            test_schema_array_object_param_types
        ; Alcotest.test_case "single required" `Quick test_schema_single_required
        ; Alcotest.test_case "all optional" `Quick test_schema_all_optional
        ] )
    ]
;;
