(** Deep coverage tests for Structured module.

    Targets uncovered branches in structured.ml.
    Focuses on schema property ordering and the JSON schema structure. *)

open Agent_core
open Types

(* ── Schema property ordering: fold_left + List.rev ─────────── *)

(** schema_to_json_schema uses fold_left then List.rev to preserve
    parameter declaration order in properties. Verify ordering. *)
let test_property_ordering_preserved () =
  let schema : unit Structured.schema =
    { params =
        [ { name = "first"; description = "1st"; param_type = String; required = true }
        ; { name = "second"; description = "2nd"; param_type = Integer; required = true }
        ; { name = "third"; description = "3rd"; param_type = Boolean; required = false }
        ]
    ; parse = (fun _ -> Ok ())
    }
  in
  let json = Structured.schema_to_json_schema schema in
  let open Yojson.Safe.Util in
  let prop_names = json |> member "properties" |> to_assoc |> List.map fst in
  Alcotest.(check (list string))
    "property order matches declaration"
    [ "first"; "second"; "third" ]
    prop_names
;;

(** Required list preserves filter_map order (declaration order). *)
let test_required_ordering () =
  let schema : unit Structured.schema =
    { params =
        [ { name = "z_last"; description = "Z"; param_type = String; required = true }
        ; { name = "a_first"; description = "A"; param_type = Integer; required = true }
        ; { name = "m_mid"; description = "M"; param_type = Number; required = false }
        ]
    ; parse = (fun _ -> Ok ())
    }
  in
  let json = Structured.schema_to_json_schema schema in
  let open Yojson.Safe.Util in
  let required = json |> member "required" |> to_list |> List.map to_string in
  (* filter_map preserves order: z_last first, a_first second *)
  Alcotest.(check (list string))
    "required in declaration order"
    [ "z_last"; "a_first" ]
    required
;;

(* ── Schema with all 6 param types ─────────────────────────── *)

let test_schema_all_six_param_types () =
  let schema : unit Structured.schema =
    { params =
        [ { name = "s"; description = "string"; param_type = String; required = true }
        ; { name = "i"; description = "integer"; param_type = Integer; required = true }
        ; { name = "n"; description = "number"; param_type = Number; required = true }
        ; { name = "b"; description = "boolean"; param_type = Boolean; required = true }
        ; { name = "a"; description = "array"; param_type = Array; required = true }
        ; { name = "o"; description = "object"; param_type = Object; required = true }
        ]
    ; parse = (fun _ -> Ok ())
    }
  in
  let json = Structured.schema_to_json_schema schema in
  let open Yojson.Safe.Util in
  let props = json |> member "properties" in
  Alcotest.(check string)
    "string"
    "string"
    (props |> member "s" |> member "type" |> to_string);
  Alcotest.(check string)
    "integer"
    "integer"
    (props |> member "i" |> member "type" |> to_string);
  Alcotest.(check string)
    "number"
    "number"
    (props |> member "n" |> member "type" |> to_string);
  Alcotest.(check string)
    "boolean"
    "boolean"
    (props |> member "b" |> member "type" |> to_string);
  Alcotest.(check string)
    "array"
    "array"
    (props |> member "a" |> member "type" |> to_string);
  Alcotest.(check string)
    "object"
    "object"
    (props |> member "o" |> member "type" |> to_string);
  let required = json |> member "required" |> to_list |> List.map to_string in
  Alcotest.(check int) "6 required" 6 (List.length required)
;;

(* ── Schema JSON structure validation ───────────────────────── *)

(** Verify the full provider-native JSON Schema structure. *)
let test_schema_json_full_structure () =
  let schema : string Structured.schema =
    { params =
        [ { name = "city"
          ; description = "City name"
          ; param_type = String
          ; required = true
          }
        ; { name = "unit"
          ; description = "Temperature unit"
          ; param_type = String
          ; required = false
          }
        ]
    ; parse =
        (fun json ->
          let open Yojson.Safe.Util in
          Ok (json |> member "city" |> to_string))
    }
  in
  let json = Structured.schema_to_json_schema schema in
  let open Yojson.Safe.Util in
  (* Top-level keys *)
  let keys = json |> to_assoc |> List.map fst in
  Alcotest.(check (list string))
    "top-level keys"
    [ "type"; "properties"; "required" ]
    keys;
  (* Property descriptions preserved *)
  let city_desc =
    json |> member "properties" |> member "city" |> member "description" |> to_string
  in
  Alcotest.(check string) "city description" "City name" city_desc
;;

let () =
  Alcotest.run
    "structured_deep"
    [ ( "schema_ordering"
      , [ Alcotest.test_case
            "property ordering preserved"
            `Quick
            test_property_ordering_preserved
        ; Alcotest.test_case "required ordering" `Quick test_required_ordering
        ] )
    ; ( "schema_structure"
      , [ Alcotest.test_case "all 6 param types" `Quick test_schema_all_six_param_types
        ; Alcotest.test_case "full JSON structure" `Quick test_schema_json_full_structure
        ] )
    ]
;;
