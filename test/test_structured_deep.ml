(** Deep coverage tests for Structured module.

    Targets uncovered branches in structured.ml.
    Focuses on schema property ordering, complex parse functions, and error
    path classification. *)

open Agent_sdk
open Types

(* ── Helpers ────────────────────────────────────────────────── *)

let make_response ?(usage = None) content : Types.api_response =
  { id = "m"; model = "m"; stop_reason = EndTurn; content; usage; telemetry = None }
;;

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

(* ── Complex parse functions ────────────────────────────────── *)

(** Schema with a parse that returns a nested record type. *)
let test_json_extractor_array () =
  let extract =
    Structured.json_extractor (fun json ->
      let open Yojson.Safe.Util in
      json |> to_list |> List.map to_int)
  in
  let resp = make_response [ Text {|[1, 2, 3]|} ] in
  match extract resp with
  | Ok v -> Alcotest.(check (list int)) "parsed array" [ 1; 2; 3 ] v
  | Error e -> Alcotest.fail e
;;

(** json_extractor with nested JSON. *)
let test_json_extractor_nested () =
  let extract =
    Structured.json_extractor (fun json ->
      let open Yojson.Safe.Util in
      json |> member "outer" |> member "inner" |> to_string)
  in
  let resp = make_response [ Text {|{"outer": {"inner": "deep"}}|} ] in
  match extract resp with
  | Ok v -> Alcotest.(check string) "nested value" "deep" v
  | Error e -> Alcotest.fail e
;;

(** json_extractor picks first text, ignoring ToolUse blocks. *)
let test_json_extractor_ignores_tool_use () =
  let extract =
    Structured.json_extractor (fun json ->
      let open Yojson.Safe.Util in
      json |> member "answer" |> to_int)
  in
  let resp =
    make_response
      [ ToolUse { id = "t1"; name = "tool"; input = `Assoc [ "answer", `Int 999 ] }
      ; Text {|{"answer": 42}|}
      ]
  in
  match extract resp with
  | Ok v -> Alcotest.(check int) "from text not tool_use" 42 v
  | Error e -> Alcotest.fail e
;;

(* ── text_extractor edge cases ──────────────────────────────── *)

(** text_extractor with multi-line text. *)
let test_text_extractor_multiline () =
  let extract =
    Structured.text_extractor (fun s ->
      let lines = String.split_on_char '\n' s in
      Some (List.length lines))
  in
  let resp = make_response [ Text "line1\nline2\nline3" ] in
  match extract resp with
  | Ok v -> Alcotest.(check int) "3 lines" 3 v
  | Error e -> Alcotest.fail e
;;

(** text_extractor with empty string text. *)
let test_text_extractor_empty_string () =
  let extract = Structured.text_extractor (fun s -> if s = "" then None else Some s) in
  let resp = make_response [ Text "" ] in
  match extract resp with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected None for empty string"
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
    ; ( "json_extractor_deep"
      , [ Alcotest.test_case "parse array" `Quick test_json_extractor_array
        ; Alcotest.test_case "parse nested" `Quick test_json_extractor_nested
        ; Alcotest.test_case
            "ignores tool_use"
            `Quick
            test_json_extractor_ignores_tool_use
        ] )
    ; ( "text_extractor_deep"
      , [ Alcotest.test_case "multiline" `Quick test_text_extractor_multiline
        ; Alcotest.test_case "empty string" `Quick test_text_extractor_empty_string
        ] )
    ; ( "schema_structure"
      , [ Alcotest.test_case "all 6 param types" `Quick test_schema_all_six_param_types
        ; Alcotest.test_case "full JSON structure" `Quick test_schema_json_full_structure
        ] )
    ]
;;
