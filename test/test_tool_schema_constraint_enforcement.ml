(** Pre-dispatch enforcement of declared JSON-Schema range/length bounds.

    masc declares minimum/maximum/exclusiveMinimum/exclusiveMaximum/
    minLength/maxLength/minItems/maxItems across its tool schemas, but
    [Tool_bridge.params_of_json_schema] projects a schema onto the AGENT_CORE
    [tool_param] record (name/type/required), dropping every bound. Agent Core
    validation hook therefore never saw them, and a caller learned about an
    out-of-range value only if the handler happened to re-check it — which
    is how [keeper_artifact_read] answered [max_bytes=565244] with a message
    that named [sha256] first (2026-08-05 20:06:36).

    These tests pin that the bounds are read from the raw schema, that the
    rejection names the field and the bound, that a schema without a bound
    is unaffected, and that every declaration masc holds sits somewhere the
    enforcement walk actually reaches. *)

open Masc

let string_contains haystack needle =
  let needle_length = String.length needle in
  let haystack_length = String.length haystack in
  if needle_length > haystack_length
  then false
  else (
    let found = ref false in
    for index = 0 to haystack_length - needle_length do
      if (not !found) && String.equal (String.sub haystack index needle_length) needle
      then found := true
    done;
    !found)
;;

let error_message result =
  match Yojson.Safe.Util.member "error" (Tool_result.data result) with
  | `String message -> message
  | _ -> Yojson.Safe.to_string (Tool_result.data result)
;;

let expect_rejected ~label ~schema ~name ~args =
  match Tool_input_validation.validate_args ~schema ~name ~args () with
  | Ok forwarded ->
    Alcotest.failf
      "%s: expected a rejection, got %s"
      label
      (Yojson.Safe.to_string forwarded)
  | Error result -> error_message result
;;

let expect_accepted ~label ~schema ~name ~args =
  match Tool_input_validation.validate_args ~schema ~name ~args () with
  | Ok forwarded -> forwarded
  | Error result -> Alcotest.failf "%s: expected acceptance, got %s" label (error_message result)
;;

let check_names ~label ~message needles =
  List.iter
    (fun needle ->
       Alcotest.(check bool)
         (Printf.sprintf "%s names %S (got: %s)" label needle message)
         true
         (string_contains message needle))
    needles
;;

let object_schema ?(required = []) properties : Yojson.Safe.t =
  `Assoc
    [ "type", `String "object"
    ; "properties", `Assoc properties
    ; "required", `List (List.map (fun name -> `String name) required)
    ; "additionalProperties", `Bool false
    ]
;;

(* --- The production tool, through its real schema ------------------ *)

let find_schema_exn name schemas =
  match
    List.find_opt
      (fun (schema : Masc_domain.tool_schema) -> String.equal schema.name name)
      schemas
  with
  | Some schema -> schema.input_schema
  | None -> Alcotest.failf "missing schema: %s" name
;;

let all_masc_schemas =
  Config.raw_all_tool_schemas
  @ Keeper_schema.schemas
  @ Keeper_tool_descriptor.model_visible_schemas ()
;;

let keeper_artifact_read_schema = find_schema_exn "keeper_artifact_read" all_masc_schemas

let production_max_bytes = 565_244
let production_sha256 = "8ee32b2a47387c0d0f7d30f93f476843c0a1e8804907d83aacd7a3ebf5c8740c"

let test_artifact_read_rejects_the_production_max_bytes () =
  let message =
    expect_rejected
      ~label:"keeper_artifact_read max_bytes over maximum"
      ~schema:keeper_artifact_read_schema
      ~name:"keeper_artifact_read"
      ~args:
        (`Assoc
          [ "max_bytes", `Int production_max_bytes
          ; "offset", `Int 0
          ; "sha256", `String production_sha256
          ])
  in
  check_names
    ~label:"keeper_artifact_read max_bytes over maximum"
    ~message
    [ "max_bytes"
    ; string_of_int production_max_bytes
    ; string_of_int Keeper_artifact_read.maximum_max_bytes
    ]
;;

let test_artifact_read_accepts_an_in_range_max_bytes () =
  let args =
    `Assoc
      [ "sha256", `String production_sha256
      ; "offset", `Int 0
      ; "max_bytes", `Int 4096
      ]
  in
  let forwarded =
    expect_accepted
      ~label:"keeper_artifact_read in-range max_bytes"
      ~schema:keeper_artifact_read_schema
      ~name:"keeper_artifact_read"
      ~args
  in
  Alcotest.(check bool) "args forwarded unchanged" true (Yojson.Safe.equal args forwarded)
;;

let test_artifact_read_accepts_the_maximum_itself () =
  ignore
    (expect_accepted
       ~label:"keeper_artifact_read max_bytes at the maximum"
       ~schema:keeper_artifact_read_schema
       ~name:"keeper_artifact_read"
       ~args:
         (`Assoc
           [ "sha256", `String production_sha256
           ; "max_bytes", `Int Keeper_artifact_read.maximum_max_bytes
           ])
     : Yojson.Safe.t)
;;

let test_artifact_read_rejects_a_negative_offset () =
  let message =
    expect_rejected
      ~label:"keeper_artifact_read negative offset"
      ~schema:keeper_artifact_read_schema
      ~name:"keeper_artifact_read"
      ~args:
        (`Assoc [ "sha256", `String production_sha256; "offset", `Int (-1) ])
  in
  check_names
    ~label:"keeper_artifact_read negative offset"
    ~message
    [ "offset"; "-1"; "minimum 0" ]
;;

(* --- One test per keyword, on a minimal schema --------------------- *)

let count_schema =
  object_schema
    [ ( "count"
      , `Assoc [ "type", `String "integer"; "minimum", `Int 1; "maximum", `Int 10 ] )
    ]
;;

let test_minimum_rejects_and_names_the_field () =
  let message =
    expect_rejected
      ~label:"count below minimum"
      ~schema:count_schema
      ~name:"__constraint_minimum"
      ~args:(`Assoc [ "count", `Int 0 ])
  in
  check_names ~label:"count below minimum" ~message [ "count"; "0"; "minimum 1" ]
;;

let test_maximum_rejects_and_names_the_field () =
  let message =
    expect_rejected
      ~label:"count above maximum"
      ~schema:count_schema
      ~name:"__constraint_maximum"
      ~args:(`Assoc [ "count", `Int 11 ])
  in
  check_names ~label:"count above maximum" ~message [ "count"; "11"; "maximum 10" ]
;;

let test_inclusive_bounds_accept_their_endpoints () =
  List.iter
    (fun value ->
       ignore
         (expect_accepted
            ~label:(Printf.sprintf "count = %d" value)
            ~schema:count_schema
            ~name:"__constraint_endpoints"
            ~args:(`Assoc [ "count", `Int value ])
          : Yojson.Safe.t))
    [ 1; 5; 10 ]
;;

let timeout_schema =
  object_schema
    [ ( "timeout_sec"
      , `Assoc [ "type", `String "number"; "exclusiveMinimum", `Float 0.0 ] )
    ]
;;

let test_exclusive_minimum_rejects_the_bound_itself () =
  let message =
    expect_rejected
      ~label:"timeout_sec at exclusiveMinimum"
      ~schema:timeout_schema
      ~name:"__constraint_exclusive_minimum"
      ~args:(`Assoc [ "timeout_sec", `Float 0.0 ])
  in
  check_names
    ~label:"timeout_sec at exclusiveMinimum"
    ~message
    [ "timeout_sec"; "exclusiveMinimum" ]
;;

let test_exclusive_minimum_accepts_above_the_bound () =
  ignore
    (expect_accepted
       ~label:"timeout_sec above exclusiveMinimum"
       ~schema:timeout_schema
       ~name:"__constraint_exclusive_minimum_ok"
       ~args:(`Assoc [ "timeout_sec", `Float 0.5 ])
     : Yojson.Safe.t)
;;

let exclusive_maximum_schema =
  object_schema
    [ ( "ratio"
      , `Assoc [ "type", `String "number"; "exclusiveMaximum", `Float 1.0 ] )
    ]
;;

let test_exclusive_maximum_rejects_the_bound_itself () =
  let message =
    expect_rejected
      ~label:"ratio at exclusiveMaximum"
      ~schema:exclusive_maximum_schema
      ~name:"__constraint_exclusive_maximum"
      ~args:(`Assoc [ "ratio", `Float 1.0 ])
  in
  check_names ~label:"ratio at exclusiveMaximum" ~message [ "ratio"; "exclusiveMaximum" ]
;;

let large_integer_maximum_schema =
  object_schema
    [ ( "value"
      , `Assoc
          [ "type", `String "number"
          ; "maximum", `Float 9_007_199_254_740_992.0
          ] )
    ]
;;

let test_mixed_int_float_comparison_keeps_integer_precision () =
  let message =
    expect_rejected
      ~label:"integer one above a large float maximum"
      ~schema:large_integer_maximum_schema
      ~name:"__constraint_large_mixed_number"
      ~args:(`Assoc [ "value", `Int 9_007_199_254_740_993 ])
  in
  check_names
    ~label:"integer one above a large float maximum"
    ~message
    [ "value"; "maximum" ]
;;

let test_oversized_integer_literal_fails_closed () =
  let literal = "999999999999999999999999999999999999" in
  let message =
    expect_rejected
      ~label:"integer literal outside exact comparison range"
      ~schema:count_schema
      ~name:"__constraint_oversized_intlit"
      ~args:(`Assoc [ "count", `Intlit literal ])
  in
  check_names
    ~label:"integer literal outside exact comparison range"
    ~message
    [ "count"; literal; "exact-comparison range" ]
;;

let title_schema =
  object_schema
    [ ( "title"
      , `Assoc
          [ "type", `String "string"; "minLength", `Int 5; "maxLength", `Int 10 ] )
    ]
;;

let test_min_length_rejects_and_names_the_field () =
  let message =
    expect_rejected
      ~label:"title below minLength"
      ~schema:title_schema
      ~name:"__constraint_min_length"
      ~args:(`Assoc [ "title", `String "abcd" ])
  in
  check_names ~label:"title below minLength" ~message [ "title"; "minLength 5" ]
;;

let test_max_length_rejects_and_names_the_field () =
  let message =
    expect_rejected
      ~label:"title above maxLength"
      ~schema:title_schema
      ~name:"__constraint_max_length"
      ~args:(`Assoc [ "title", `String "abcdefghijk" ])
  in
  check_names ~label:"title above maxLength" ~message [ "title"; "maxLength 10" ]
;;

(* JSON Schema counts characters, not bytes. Counting bytes would reject a
   Korean title well inside its declared maxLength. *)
let test_length_counts_characters_not_bytes () =
  let ten_hangul_characters = "가나다라마바사아자차" in
  Alcotest.(check int)
    "fixture is 30 bytes"
    30
    (String.length ten_hangul_characters);
  ignore
    (expect_accepted
       ~label:"ten Hangul characters within maxLength 10"
       ~schema:title_schema
       ~name:"__constraint_utf8_length"
       ~args:(`Assoc [ "title", `String ten_hangul_characters ])
     : Yojson.Safe.t);
  let message =
    expect_rejected
      ~label:"eleven Hangul characters above maxLength 10"
      ~schema:title_schema
      ~name:"__constraint_utf8_length_over"
      ~args:(`Assoc [ "title", `String (ten_hangul_characters ^ "카") ])
  in
  check_names
    ~label:"eleven Hangul characters above maxLength 10"
    ~message
    [ "title"; "11 character(s)"; "maxLength 10" ]
;;

let tags_schema =
  object_schema
    [ ( "tags"
      , `Assoc
          [ "type", `String "array"
          ; "items", `Assoc [ "type", `String "string" ]
          ; "minItems", `Int 1
          ; "maxItems", `Int 3
          ] )
    ]
;;

let test_min_items_rejects_and_names_the_field () =
  let message =
    expect_rejected
      ~label:"tags below minItems"
      ~schema:tags_schema
      ~name:"__constraint_min_items"
      ~args:(`Assoc [ "tags", `List [] ])
  in
  check_names ~label:"tags below minItems" ~message [ "tags"; "minItems 1" ]
;;

let test_max_items_rejects_and_names_the_field () =
  let message =
    expect_rejected
      ~label:"tags above maxItems"
      ~schema:tags_schema
      ~name:"__constraint_max_items"
      ~args:
        (`Assoc
          [ ( "tags"
            , `List [ `String "a"; `String "b"; `String "c"; `String "d" ] )
          ])
  in
  check_names ~label:"tags above maxItems" ~message [ "tags"; "maxItems 3" ]
;;

(* --- A schema without bounds must be unaffected -------------------- *)

let unbounded_schema =
  object_schema
    [ "count", `Assoc [ "type", `String "integer" ]
    ; "title", `Assoc [ "type", `String "string" ]
    ; ( "tags"
      , `Assoc [ "type", `String "array"; "items", `Assoc [ "type", `String "string" ] ]
      )
    ]
;;

let test_absent_constraints_change_nothing () =
  let args =
    `Assoc
      [ "count", `Int (-999_999)
      ; "title", `String ""
      ; "tags", `List []
      ]
  in
  let forwarded =
    expect_accepted
      ~label:"schema without declared bounds"
      ~schema:unbounded_schema
      ~name:"__constraint_absent"
      ~args
  in
  Alcotest.(check bool) "args forwarded unchanged" true (Yojson.Safe.equal args forwarded)
;;

(* An absent optional field carries no value, so its bounds cannot apply. *)
let test_absent_field_is_not_range_checked () =
  ignore
    (expect_accepted
       ~label:"bounded field omitted"
       ~schema:count_schema
       ~name:"__constraint_absent_field"
       ~args:(`Assoc [])
     : Yojson.Safe.t)
;;

(* --- Nested declarations ------------------------------------------- *)

let nested_schema =
  object_schema
    [ ( "pipeline"
      , `Assoc
          [ "type", `String "array"
          ; ( "items"
            , object_schema
                [ ( "argv"
                  , `Assoc
                      [ "type", `String "array"
                      ; "items", `Assoc [ "type", `String "string" ]
                      ; "minItems", `Int 1
                      ] )
                ] )
          ] )
    ]
;;

let test_nested_item_constraint_is_enforced_with_its_path () =
  let message =
    expect_rejected
      ~label:"empty argv in the second pipeline stage"
      ~schema:nested_schema
      ~name:"__constraint_nested"
      ~args:
        (`Assoc
          [ ( "pipeline"
            , `List
                [ `Assoc [ "argv", `List [ `String "rg" ] ]
                ; `Assoc [ "argv", `List [] ]
                ] )
          ])
  in
  check_names
    ~label:"empty argv in the second pipeline stage"
    ~message
    [ "pipeline[1].argv"; "minItems 1" ]
;;

let test_nested_in_range_value_is_accepted () =
  ignore
    (expect_accepted
       ~label:"non-empty argv in every pipeline stage"
       ~schema:nested_schema
       ~name:"__constraint_nested_ok"
       ~args:
         (`Assoc
           [ ( "pipeline"
             , `List
                 [ `Assoc [ "argv", `List [ `String "rg" ] ]
                 ; `Assoc [ "argv", `List [ `String "head"; `String "-5" ] ]
                 ] )
           ])
     : Yojson.Safe.t)
;;

(* --- A bound masc cannot read is masc's defect, not the caller's ---- *)

let malformed_numeric_bound_schema =
  object_schema
    [ "count", `Assoc [ "type", `String "integer"; "maximum", `String "10" ] ]
;;

(* The count keywords are the other half of the same contract, and a
   different function reads their bound. A fixture that exercises only the
   numeric half leaves minLength/maxLength/minItems/maxItems free to fail
   open with every test still green. *)
let malformed_count_bound_schema =
  object_schema
    [ "title", `Assoc [ "type", `String "string"; "maxLength", `String "10" ] ]
;;

let check_unreadable_bound_fails_closed ~schema ~args ~label names =
  match
    Tool_input_validation.validate_args
      ~schema
      ~name:"__constraint_malformed_bound"
      ~args
      ()
  with
  | Ok forwarded ->
    Alcotest.failf
      "expected an unreadable bound to fail closed, got %s"
      (Yojson.Safe.to_string forwarded)
  | Error result ->
    let payload = Yojson.Safe.to_string (Tool_result.data result) in
    Alcotest.(check bool)
      "reason is malformed_schema"
      true
      (string_contains payload "malformed_schema");
    check_names ~label ~message:(error_message result) names
;;

let test_unreadable_numeric_bound_fails_closed_as_a_schema_defect () =
  check_unreadable_bound_fails_closed
    ~schema:malformed_numeric_bound_schema
    ~args:(`Assoc [ "count", `Int 5 ])
    ~label:"unreadable maximum"
    [ "count"; "maximum" ]
;;

let test_unreadable_count_bound_fails_closed_as_a_schema_defect () =
  check_unreadable_bound_fails_closed
    ~schema:malformed_count_bound_schema
    ~args:(`Assoc [ "title", `String "abc" ])
    ~label:"unreadable maxLength"
    [ "title"; "maxLength" ]
;;

let test_unreadable_optional_bound_fails_closed_when_field_is_absent () =
  check_unreadable_bound_fails_closed
    ~schema:malformed_numeric_bound_schema
    ~args:(`Assoc [])
    ~label:"unreadable optional maximum"
    [ "count"; "maximum" ]
;;

let test_non_finite_numeric_bound_fails_closed () =
  let schema =
    object_schema
      [ ( "ratio"
        , `Assoc [ "type", `String "number"; "maximum", `Float Float.nan ] )
      ]
  in
  check_unreadable_bound_fails_closed
    ~schema
    ~args:(`Assoc [])
    ~label:"non-finite maximum"
    [ "ratio"; "maximum" ]
;;

(* --- Every masc declaration must be reachable and readable ---------- *)

let constraint_keyword_names =
  [ "minimum"
  ; "maximum"
  ; "exclusiveMinimum"
  ; "exclusiveMaximum"
  ; "minLength"
  ; "maxLength"
  ; "minItems"
  ; "maxItems"
  ]
;;

(** Every constraint keyword anywhere in the schema JSON, regardless of
    where it sits. Compared against
    [Tool_input_validation.constraint_declaration_paths], which only sees
    the places enforcement descends into. *)
let rec raw_constraint_occurrences (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
    List.concat_map
      (fun (key, value) ->
         let here = if List.mem key constraint_keyword_names then [ key, value ] else [] in
         here @ raw_constraint_occurrences value)
      fields
  | `List items -> List.concat_map raw_constraint_occurrences items
  | _ -> []
;;

let test_every_declaration_is_reachable_by_enforcement () =
  List.iter
    (fun (schema : Masc_domain.tool_schema) ->
       let declared = List.length (raw_constraint_occurrences schema.input_schema) in
       let reachable =
         List.length
           (Tool_input_validation.constraint_declaration_paths schema.input_schema)
       in
       Alcotest.(check int)
         (Printf.sprintf
            "%s: every declared constraint is reachable by enforcement"
            schema.name)
         declared
         reachable)
    all_masc_schemas
;;

(* A bound that enforcement cannot read turns every call to that tool into a
   fail-closed rejection, so it must be caught here rather than in
   production. *)
let test_every_declared_bound_is_readable () =
  List.iter
    (fun (schema : Masc_domain.tool_schema) ->
       List.iter
         (fun (keyword, value) ->
            let readable =
              match keyword, value with
              | ("minimum" | "maximum" | "exclusiveMinimum" | "exclusiveMaximum"), _ ->
                (match value with
                 | `Int _ -> true
                 | `Float bound -> Float.is_finite bound
                 | `Intlit literal -> Option.is_some (int_of_string_opt literal)
                 | _ -> false)
              | ("minLength" | "maxLength" | "minItems" | "maxItems"), _ ->
                (match value with
                 | `Int bound -> bound >= 0
                 | `Float bound ->
                   Float.is_finite bound && Float.is_integer bound && bound >= 0.0
                 | `Intlit literal ->
                   (match int_of_string_opt literal with
                    | Some bound -> bound >= 0
                    | None -> false)
                 | _ -> false)
              | _, _ -> false
            in
            Alcotest.(check bool)
              (Printf.sprintf
                 "%s declares a readable %s (%s)"
                 schema.name
                 keyword
                 (Yojson.Safe.to_string value))
              true
              readable)
         (raw_constraint_occurrences schema.input_schema))
    all_masc_schemas
;;

let () =
  Alcotest.run
    "tool_schema_constraint_enforcement"
    [ ( "keeper_artifact_read"
      , [ Alcotest.test_case "production max_bytes is rejected pre-dispatch" `Quick
            test_artifact_read_rejects_the_production_max_bytes
        ; Alcotest.test_case "an in-range max_bytes still passes" `Quick
            test_artifact_read_accepts_an_in_range_max_bytes
        ; Alcotest.test_case "the maximum itself is accepted" `Quick
            test_artifact_read_accepts_the_maximum_itself
        ; Alcotest.test_case "a negative offset is rejected" `Quick
            test_artifact_read_rejects_a_negative_offset
        ] )
    ; ( "declared_keywords"
      , [ Alcotest.test_case "minimum" `Quick test_minimum_rejects_and_names_the_field
        ; Alcotest.test_case "maximum" `Quick test_maximum_rejects_and_names_the_field
        ; Alcotest.test_case "inclusive endpoints are accepted" `Quick
            test_inclusive_bounds_accept_their_endpoints
        ; Alcotest.test_case "exclusiveMinimum rejects its bound" `Quick
            test_exclusive_minimum_rejects_the_bound_itself
        ; Alcotest.test_case "exclusiveMinimum accepts above its bound" `Quick
            test_exclusive_minimum_accepts_above_the_bound
        ; Alcotest.test_case "exclusiveMaximum rejects its bound" `Quick
            test_exclusive_maximum_rejects_the_bound_itself
        ; Alcotest.test_case "mixed int/float comparison keeps integer precision" `Quick
            test_mixed_int_float_comparison_keeps_integer_precision
        ; Alcotest.test_case "oversized integer literal fails closed" `Quick
            test_oversized_integer_literal_fails_closed
        ; Alcotest.test_case "minLength" `Quick test_min_length_rejects_and_names_the_field
        ; Alcotest.test_case "maxLength" `Quick test_max_length_rejects_and_names_the_field
        ; Alcotest.test_case "length counts characters, not bytes" `Quick
            test_length_counts_characters_not_bytes
        ; Alcotest.test_case "minItems" `Quick test_min_items_rejects_and_names_the_field
        ; Alcotest.test_case "maxItems" `Quick test_max_items_rejects_and_names_the_field
        ] )
    ; ( "unconstrained_schemas"
      , [ Alcotest.test_case "no declared bounds, no new rejection" `Quick
            test_absent_constraints_change_nothing
        ; Alcotest.test_case "an omitted bounded field is not checked" `Quick
            test_absent_field_is_not_range_checked
        ] )
    ; ( "nested_declarations"
      , [ Alcotest.test_case "a nested item bound names its path" `Quick
            test_nested_item_constraint_is_enforced_with_its_path
        ; Alcotest.test_case "nested in-range values pass" `Quick
            test_nested_in_range_value_is_accepted
        ] )
    ; ( "schema_health"
      , [ Alcotest.test_case "an unreadable numeric bound fails closed" `Quick
            test_unreadable_numeric_bound_fails_closed_as_a_schema_defect
        ; Alcotest.test_case "an unreadable count bound fails closed" `Quick
            test_unreadable_count_bound_fails_closed_as_a_schema_defect
        ; Alcotest.test_case "an unreadable optional bound fails when omitted" `Quick
            test_unreadable_optional_bound_fails_closed_when_field_is_absent
        ; Alcotest.test_case "a non-finite numeric bound fails closed" `Quick
            test_non_finite_numeric_bound_fails_closed
        ; Alcotest.test_case "every masc declaration is reachable" `Quick
            test_every_declaration_is_reachable_by_enforcement
        ; Alcotest.test_case "every masc bound is readable" `Quick
            test_every_declared_bound_is_readable
        ] )
    ]
;;
