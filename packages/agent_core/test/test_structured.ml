(** Unit tests for Structured output module. *)

open Agent_sdk
open Types

(* --- Test schema --- *)

let person_schema : (string * int) Structured.schema =
  { params =
      [ { name = "name"
        ; description = "Person name"
        ; param_type = String
        ; required = true
        }
      ; { name = "age"
        ; description = "Person age"
        ; param_type = Integer
        ; required = true
        }
      ]
  ; parse =
      (fun json ->
        let open Yojson.Safe.Util in
        try
          let name = json |> member "name" |> to_string in
          let age = json |> member "age" |> to_int in
          Ok (name, age)
        with
        | exn -> Error (Printexc.to_string exn))
  }
;;

(* --- schema_to_json_schema --- *)

let test_schema_to_json_structure () =
  let json = Structured.schema_to_json_schema person_schema in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "type is object" "object" (json |> member "type" |> to_string);
  let props = json |> member "properties" in
  Alcotest.(check string)
    "name prop type"
    "string"
    (props |> member "name" |> member "type" |> to_string);
  Alcotest.(check string)
    "age prop type"
    "integer"
    (props |> member "age" |> member "type" |> to_string);
  let required = json |> member "required" |> to_list |> List.map to_string in
  Alcotest.(check bool) "name required" true (List.mem "name" required);
  Alcotest.(check bool) "age required" true (List.mem "age" required)
;;

let test_schema_to_json_schema_structure () =
  let json = Structured.schema_to_json_schema person_schema in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "type" "object" (json |> member "type" |> to_string);
  Alcotest.(check bool)
    "no tool wrapper name"
    true
    (match member "name" json with
     | `Null -> true
     | _ -> false);
  let props = json |> member "properties" in
  Alcotest.(check string)
    "name prop type"
    "string"
    (props |> member "name" |> member "type" |> to_string)
;;

let test_schema_optional_params () =
  let schema : unit Structured.schema =
    { params =
        [ { name = "required_f"; description = "R"; param_type = String; required = true }
        ; { name = "optional_f"
          ; description = "O"
          ; param_type = String
          ; required = false
          }
        ]
    ; parse = (fun _ -> Ok ())
    }
  in
  let json = Structured.schema_to_json_schema schema in
  let open Yojson.Safe.Util in
  let required = json |> member "required" |> to_list |> List.map to_string in
  Alcotest.(check bool) "required_f in list" true (List.mem "required_f" required);
  Alcotest.(check bool) "optional_f not in list" false (List.mem "optional_f" required)
;;

let test_schema_empty_params () =
  let schema : unit Structured.schema = { params = []; parse = (fun _ -> Ok ()) } in
  let json = Structured.schema_to_json_schema schema in
  let open Yojson.Safe.Util in
  let props = json |> member "properties" |> to_assoc in
  Alcotest.(check int) "no properties" 0 (List.length props);
  let required = json |> member "required" |> to_list in
  Alcotest.(check int) "no required" 0 (List.length required)
;;

let test_schema_all_param_types () =
  let schema : unit Structured.schema =
    { params =
        [ { name = "s"; description = "string"; param_type = String; required = true }
        ; { name = "i"; description = "integer"; param_type = Integer; required = true }
        ; { name = "n"; description = "number"; param_type = Number; required = false }
        ; { name = "b"; description = "boolean"; param_type = Boolean; required = false }
        ]
    ; parse = (fun _ -> Ok ())
    }
  in
  let json = Structured.schema_to_json_schema schema in
  let open Yojson.Safe.Util in
  let props = json |> member "properties" in
  Alcotest.(check string)
    "string type"
    "string"
    (props |> member "s" |> member "type" |> to_string);
  Alcotest.(check string)
    "integer type"
    "integer"
    (props |> member "i" |> member "type" |> to_string);
  Alcotest.(check string)
    "number type"
    "number"
    (props |> member "n" |> member "type" |> to_string);
  Alcotest.(check string)
    "boolean type"
    "boolean"
    (props |> member "b" |> member "type" |> to_string);
  let required = json |> member "required" |> to_list |> List.map to_string in
  Alcotest.(check int) "2 required" 2 (List.length required);
  Alcotest.(check bool) "s required" true (List.mem "s" required);
  Alcotest.(check bool) "i required" true (List.mem "i" required);
  Alcotest.(check bool) "n not required" false (List.mem "n" required);
  Alcotest.(check bool) "b not required" false (List.mem "b" required)
;;

let test_param_description_preserved () =
  let schema : unit Structured.schema =
    { params =
        [ { name = "x"
          ; description = "field X description"
          ; param_type = String
          ; required = true
          }
        ]
    ; parse = (fun _ -> Ok ())
    }
  in
  let json = Structured.schema_to_json_schema schema in
  let open Yojson.Safe.Util in
  let x_desc =
    json |> member "properties" |> member "x" |> member "description" |> to_string
  in
  Alcotest.(check string) "param desc" "field X description" x_desc
;;

let test_schema_mixed_required () =
  let schema : unit Structured.schema =
    { params =
        [ { name = "a"; description = "A"; param_type = String; required = true }
        ; { name = "b"; description = "B"; param_type = String; required = false }
        ; { name = "c"; description = "C"; param_type = Integer; required = true }
        ; { name = "d"; description = "D"; param_type = Boolean; required = false }
        ; { name = "e"; description = "E"; param_type = Number; required = true }
        ]
    ; parse = (fun _ -> Ok ())
    }
  in
  let json = Structured.schema_to_json_schema schema in
  let open Yojson.Safe.Util in
  let required = json |> member "required" |> to_list |> List.map to_string in
  Alcotest.(check int) "3 required" 3 (List.length required);
  Alcotest.(check bool) "a required" true (List.mem "a" required);
  Alcotest.(check bool) "c required" true (List.mem "c" required);
  Alcotest.(check bool) "e required" true (List.mem "e" required)
;;

(* --- Extractors --- *)

let make_response content : Types.api_response =
  { id = "m"
  ; model = "m"
  ; stop_reason = EndTurn
  ; content
  ; usage = None
  ; telemetry = None
  }
;;

let test_json_extractor_success () =
  let extract =
    Structured.json_extractor (fun json ->
      Yojson.Safe.Util.(json |> member "value" |> to_int))
  in
  let resp = make_response [ Text {|{"value": 42}|} ] in
  match extract resp with
  | Ok v -> Alcotest.(check int) "extracted value" 42 v
  | Error e -> Alcotest.fail e
;;

let test_json_extractor_invalid_json () =
  let extract = Structured.json_extractor (fun _ -> 0) in
  let resp = make_response [ Text "not json" ] in
  match extract resp with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected parse error"
;;

let test_json_extractor_no_text () =
  let extract = Structured.json_extractor (fun _ -> 0) in
  let resp = make_response [] in
  match extract resp with
  | Error msg -> Alcotest.(check bool) "mentions no text" true (String.length msg > 0)
  | Ok _ -> Alcotest.fail "expected error"
;;

let test_response_json_extractor_object_success () =
  let extract = Structured.response_json_extractor ~shape:Structured.Object_json () in
  let resp = make_response [ Text {|{"value": 42}|} ] in
  match extract resp with
  | Ok (`Assoc fields) ->
    Alcotest.(check bool) "value field present" true (List.mem_assoc "value" fields)
  | Ok _ -> Alcotest.fail "expected JSON object"
  | Error e -> Alcotest.fail e
;;

let test_response_json_extractor_rejects_fenced_object () =
  let extract = Structured.response_json_extractor ~shape:Structured.Object_json () in
  let resp = make_response [ Text "```json\n{\"ok\":true}\n```" ] in
  match extract resp with
  | Error e -> Alcotest.(check bool) "has parse error text" true (String.length e > 0)
  | Ok _ -> Alcotest.fail "expected fenced JSON rejection"
;;

let test_response_json_extractor_any_accepts_array () =
  let extract = Structured.response_json_extractor () in
  let resp = make_response [ Text "[1,2,3]" ] in
  match extract resp with
  | Ok (`List values) -> Alcotest.(check int) "array length" 3 (List.length values)
  | Ok _ -> Alcotest.fail "expected JSON array"
  | Error e -> Alcotest.fail e
;;

let test_response_json_extractor_object_rejects_array () =
  let extract = Structured.response_json_extractor ~shape:Structured.Object_json () in
  let resp = make_response [ Text "[1,2,3]" ] in
  match extract resp with
  | Error e -> Alcotest.(check bool) "has error text" true (String.length e > 0)
  | Ok _ -> Alcotest.fail "expected object shape error"
;;

let test_text_extractor_success () =
  let extract =
    Structured.text_extractor (fun s ->
      if String.length s > 0 then Some (String.length s) else None)
  in
  let resp = make_response [ Text "hello world" ] in
  match extract resp with
  | Ok v -> Alcotest.(check int) "text length" 11 v
  | Error e -> Alcotest.fail e
;;

let test_text_extractor_none () =
  let extract = Structured.text_extractor (fun _ -> None) in
  let resp = make_response [ Text "anything" ] in
  match extract resp with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected error"
;;

let test_schema_extractor_success () =
  let extract = Structured.schema_extractor person_schema in
  let resp = make_response [ Text "{\"name\":\"Dana\",\"age\":42}" ] in
  match extract resp with
  | Ok (name, age) ->
    Alcotest.(check string) "name" "Dana" name;
    Alcotest.(check int) "age" 42 age
  | Error e -> Alcotest.fail e
;;

let test_schema_extractor_parse_failure () =
  let extract = Structured.schema_extractor person_schema in
  let resp = make_response [ Text "{\"name\":123}" ] in
  match extract resp with
  | Error e -> Alcotest.(check bool) "has error text" true (String.length e > 0)
  | Ok _ -> Alcotest.fail "expected schema parse error"
;;

let test_schema_extractor_parser_json_error () =
  let schema : unit Structured.schema =
    { params = []
    ; parse =
        (fun json ->
          let open Yojson.Safe.Util in
          let nested = json |> member "nested" |> to_string in
          ignore (Yojson.Safe.from_string nested : Yojson.Safe.t);
          Ok ())
    }
  in
  let extract = Structured.schema_extractor schema in
  let resp = make_response [ Text {|{"nested":"{"}|} ] in
  match extract resp with
  | Error e -> Alcotest.(check bool) "has json error text" true (String.length e > 0)
  | Ok _ -> Alcotest.fail "expected parser json error"
;;

(* --- Runner --- *)

let () =
  Alcotest.run
    "structured"
    [ ( "schema_to_json_schema"
      , [ Alcotest.test_case "structure" `Quick test_schema_to_json_structure
        ; Alcotest.test_case "optional params" `Quick test_schema_optional_params
        ; Alcotest.test_case
            "json schema structure"
            `Quick
            test_schema_to_json_schema_structure
        ; Alcotest.test_case "empty params" `Quick test_schema_empty_params
        ; Alcotest.test_case "all param types" `Quick test_schema_all_param_types
        ; Alcotest.test_case
            "parameter description preserved"
            `Quick
            test_param_description_preserved
        ; Alcotest.test_case "mixed required" `Quick test_schema_mixed_required
        ] )
    ; ( "extractors"
      , [ Alcotest.test_case "json_extractor success" `Quick test_json_extractor_success
        ; Alcotest.test_case
            "json_extractor invalid"
            `Quick
            test_json_extractor_invalid_json
        ; Alcotest.test_case "json_extractor no text" `Quick test_json_extractor_no_text
        ; Alcotest.test_case
            "response_json_extractor object"
            `Quick
            test_response_json_extractor_object_success
        ; Alcotest.test_case
            "response_json_extractor rejects fenced object"
            `Quick
            test_response_json_extractor_rejects_fenced_object
        ; Alcotest.test_case
            "response_json_extractor any array"
            `Quick
            test_response_json_extractor_any_accepts_array
        ; Alcotest.test_case
            "response_json_extractor object rejects array"
            `Quick
            test_response_json_extractor_object_rejects_array
        ; Alcotest.test_case "text_extractor success" `Quick test_text_extractor_success
        ; Alcotest.test_case "text_extractor none" `Quick test_text_extractor_none
        ; Alcotest.test_case
            "schema_extractor success"
            `Quick
            test_schema_extractor_success
        ; Alcotest.test_case
            "schema_extractor parse failure"
            `Quick
            test_schema_extractor_parse_failure
        ; Alcotest.test_case
            "schema_extractor parser json error"
            `Quick
            test_schema_extractor_parser_json_error
        ] )
    ]
;;
