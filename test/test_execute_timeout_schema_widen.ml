(* Issue #18472 surgical: pin the widened [type] of [tool_execute]'s
   [timeout_sec] field. The Anthropic SDK schema validator rejects a
   strict ["number"] when the LLM emits a JSON string (["30"]), routing
   the call through [correction_pipeline] for a silent coerce — 60
   events on 2026-05-29 in [/private/tmp/masc-server.log], 43% of that
   day's [correction_pipeline] load. Widening the advertised JSON
   Schema to [["number","string"]] lets the LLM's typical shape pass
   validation without correction. The downstream handler
   ([Agent_tool_execute_timeout.clamp_shell_timeout] →
   [Safe_ops.json_float]) already accepts both shapes, so there is no
   semantic change — only a wire-format widening. *)

open Alcotest
module S = Masc_mcp.Tool_shard_types_schemas_execute

(* Pull the JSON associated with the [timeout_sec] field's [type] key. *)
let type_value () =
  match S.tool_execute_timeout_sec_field with
  | _name, `Assoc fields ->
    (match List.assoc_opt "type" fields with
     | Some v -> v
     | None -> Alcotest.fail "timeout_sec field is missing the 'type' key")
  | _ -> Alcotest.fail "timeout_sec field is not a JSON object"

let type_accepts_number_and_string () =
  match type_value () with
  | `List xs ->
    let strings =
      List.map
        (function
          | `String s -> s
          | _ -> Alcotest.fail "timeout_sec type list contains a non-string element")
        xs
    in
    check (list string)
      "timeout_sec type accepts both number and string (in declared order)"
      [ "number"; "string" ]
      strings
  | `String single ->
    Alcotest.failf
      "timeout_sec type is still the strict scalar %S; widening regressed"
      single
  | other ->
    Alcotest.failf
      "timeout_sec type has unexpected JSON shape: %s"
      (Yojson.Safe.to_string other)

(* The widening must preserve the user-facing description so the LLM
   keepers' prompt context does not lose the default/max hint. *)
let description_mentions_default_and_max () =
  let _name, body = S.tool_execute_timeout_sec_field in
  let body = match body with `Assoc xs -> xs | _ -> Alcotest.fail "field not an object" in
  let desc =
    match List.assoc_opt "description" body with
    | Some (`String s) -> s
    | _ -> Alcotest.fail "timeout_sec description missing or not a string"
  in
  let contains hay needle =
    let nh = String.length hay
    and nn = String.length needle in
    let rec loop i =
      if i + nn > nh then false
      else if String.sub hay i nn = needle then true
      else loop (i + 1)
    in
    loop 0
  in
  check bool "description still mentions default 30" true (contains desc "default: 30");
  check bool "description still mentions max 180" true (contains desc "max: 180")

let () =
  run "execute_timeout_schema_widen"
    [ "type widening"
    , [ test_case "accepts number and string" `Quick type_accepts_number_and_string ]
    ; "description preserved"
    , [ test_case "default + max still documented" `Quick
          description_mentions_default_and_max
      ]
    ]
