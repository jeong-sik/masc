(** Extended coverage tests for Structured module pure functions.
    Targets: schema_to_json_schema. *)

open Alcotest
open Agent_core

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

(* ── Runner ──────────────────────────────────────────── *)

let () =
  run
    "structured_ext"
    [ ( "schema_to_json_schema"
      , [ test_case "basic" `Quick test_schema_basic
        ; test_case "no required" `Quick test_schema_no_required
        ; test_case "empty params" `Quick test_schema_empty_params
        ] )
    ]
;;
