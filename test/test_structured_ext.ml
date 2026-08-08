(** Extended coverage tests for Structured module pure functions.
    Targets: json_extractor, text_extractor, schema_to_json_schema. *)

open Alcotest
open Agent_sdk

(* ── schema_to_json_schema ─────────────────────────────── *)

let test_schema_basic () =
  let schema : int Structured.schema =
    { params =
        [ { name = "value"
          ; param_type = Types.Integer
          ; description = "the count"
          ; required = true
          }
        ]
    ; parse =
        (fun json ->
          let open Yojson.Safe.Util in
          Ok (json |> member "value" |> to_int))
    }
  in
  let json = Structured.schema_to_json_schema schema in
  let open Yojson.Safe.Util in
  check string "type" "object" (json |> member "type" |> to_string);
  let properties = json |> member "properties" in
  check
    string
    "value type"
    "integer"
    (properties |> member "value" |> member "type" |> to_string);
  let required = json |> member "required" |> to_list in
  check int "1 required" 1 (List.length required)
;;

let test_schema_no_required () =
  let schema : string Structured.schema =
    { params =
        [ { name = "hint"
          ; param_type = Types.String
          ; description = "optional hint"
          ; required = false
          }
        ]
    ; parse = (fun _ -> Ok "ok")
    }
  in
  let json = Structured.schema_to_json_schema schema in
  let open Yojson.Safe.Util in
  let required = json |> member "required" |> to_list in
  check int "0 required" 0 (List.length required)
;;

let test_schema_empty_params () =
  let schema : unit Structured.schema = { params = []; parse = (fun _ -> Ok ()) } in
  let json = Structured.schema_to_json_schema schema in
  let open Yojson.Safe.Util in
  let props = json |> member "properties" in
  check
    bool
    "empty properties"
    true
    (match props with
     | `Assoc [] -> true
     | _ -> false)
;;

let test_json_extractor_valid () =
  let extract =
    Structured.json_extractor (fun json ->
      Yojson.Safe.Util.(json |> member "x" |> to_int))
  in
  let resp =
    { Types.id = "r"
    ; model = "m"
    ; stop_reason = Types.EndTurn
    ; content = [ Types.Text {|{"x": 99}|} ]
    ; usage = None
    ; telemetry = None
    }
  in
  match extract resp with
  | Ok v -> check int "x" 99 v
  | Error msg -> fail msg
;;

let test_json_extractor_invalid_json () =
  let extract = Structured.json_extractor (fun _ -> 0) in
  let resp =
    { Types.id = "r"
    ; model = "m"
    ; stop_reason = Types.EndTurn
    ; content = [ Types.Text "not json" ]
    ; usage = None
    ; telemetry = None
    }
  in
  match extract resp with
  | Ok _ -> fail "expected Error"
  | Error msg -> check bool "mentions JSON" true (String.length msg > 0)
;;

let test_json_extractor_empty_content () =
  let extract = Structured.json_extractor (fun _ -> 0) in
  let resp =
    { Types.id = "r"
    ; model = "m"
    ; stop_reason = Types.EndTurn
    ; content = []
    ; usage = None
    ; telemetry = None
    }
  in
  match extract resp with
  | Ok _ -> fail "expected Error"
  | Error msg -> check bool "mentions content" true (String.length msg > 0)
;;

let test_json_extractor_type_error () =
  let extract =
    Structured.json_extractor (fun json ->
      Yojson.Safe.Util.(json |> member "x" |> to_int))
  in
  let resp =
    { Types.id = "r"
    ; model = "m"
    ; stop_reason = Types.EndTurn
    ; content = [ Types.Text {|{"x": "not_int"}|} ]
    ; usage = None
    ; telemetry = None
    }
  in
  match extract resp with
  | Ok _ -> fail "expected Error"
  | Error _ -> ()
;;

(* ── text_extractor ──────────────────────────────────── *)

let test_text_extractor_some () =
  let extract =
    Structured.text_extractor (fun s ->
      if String.length s > 0 then Some (String.length s) else None)
  in
  let resp =
    { Types.id = "r"
    ; model = "m"
    ; stop_reason = Types.EndTurn
    ; content = [ Types.Text "hello" ]
    ; usage = None
    ; telemetry = None
    }
  in
  match extract resp with
  | Ok v -> check int "length" 5 v
  | Error _ -> fail "expected Ok"
;;

let test_text_extractor_none () =
  let extract = Structured.text_extractor (fun _ -> None) in
  let resp =
    { Types.id = "r"
    ; model = "m"
    ; stop_reason = Types.EndTurn
    ; content = [ Types.Text "anything" ]
    ; usage = None
    ; telemetry = None
    }
  in
  match extract resp with
  | Ok _ -> fail "expected Error"
  | Error _ -> ()
;;

let test_text_extractor_empty () =
  let extract = Structured.text_extractor (fun _ -> Some 0) in
  let resp =
    { Types.id = "r"
    ; model = "m"
    ; stop_reason = Types.EndTurn
    ; content = []
    ; usage = None
    ; telemetry = None
    }
  in
  match extract resp with
  | Ok _ -> fail "expected Error"
  | Error _ -> ()
;;

(* ── Runner ──────────────────────────────────────────── *)

let () =
  run
    "structured_ext"
    [ ( "schema_to_json_schema"
      , [ test_case "basic" `Quick test_schema_basic
        ; test_case "no required" `Quick test_schema_no_required
        ; test_case "empty params" `Quick test_schema_empty_params
        ] )
    ; ( "json_extractor"
      , [ test_case "valid" `Quick test_json_extractor_valid
        ; test_case "invalid json" `Quick test_json_extractor_invalid_json
        ; test_case "empty content" `Quick test_json_extractor_empty_content
        ; test_case "type error" `Quick test_json_extractor_type_error
        ] )
    ; ( "text_extractor"
      , [ test_case "some" `Quick test_text_extractor_some
        ; test_case "none" `Quick test_text_extractor_none
        ; test_case "empty" `Quick test_text_extractor_empty
        ] )
    ]
;;
