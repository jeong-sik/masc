module Types = Masc_domain

(** Unit tests for Tool_input_validation — OAS-delegated validation with coercion.

    Tests the integration: MASC JSON Schema -> Tool_bridge.params_of_json_schema
    -> Agent_sdk.Tool_input_validation.validate -> pre_hook_action mapping. *)

open Masc_mcp

(** Simple substring check — avoids Astring dependency. *)
let string_contains haystack needle =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  if nlen > hlen then false
  else
    let found = ref false in
    for i = 0 to hlen - nlen do
      if not !found && String.sub haystack i nlen = needle then found := true
    done;
    !found

(* ================================================================ *)
(* Helper: validate via the same pipeline as the pre-hook            *)
(* ================================================================ *)

(** Reproduce the exact validation pipeline used in the pre-hook:
    JSON Schema -> params_of_json_schema -> OAS validate. *)
let validate_via_oas ~tool_name ~(schema : Yojson.Safe.t) ~(args : Yojson.Safe.t)
  : Tool_dispatch.pre_hook_action =
  let parameters = Tool_bridge.params_of_json_schema schema in
  if parameters = [] then Pass
  else
    let oas_schema : Agent_sdk.Types.tool_schema =
      { name = tool_name; description = ""; parameters }
    in
    match Agent_sdk.Tool_input_validation.validate oas_schema args with
    | Agent_sdk.Tool_input_validation.Valid coerced ->
      if Yojson.Safe.equal coerced args then Pass
      else Proceed coerced
    | Agent_sdk.Tool_input_validation.Invalid errors ->
      let msg =
        Agent_sdk.Tool_input_validation.format_errors ~tool_name errors
      in
      Reject {
        Tool_result.success = false;
        data = `Assoc [("error", `String msg)];
        legacy_message = msg;
        tool_name;
        duration_ms = 0.0;
      }

(** Build a JSON Schema object with given properties and required list. *)
let make_schema ?(required = []) (props : (string * string) list) : Yojson.Safe.t =
  let prop_entries =
    List.map (fun (name, type_str) ->
      (name, `Assoc [("type", `String type_str)])
    ) props
  in
  `Assoc [
    ("type", `String "object");
    ("properties", `Assoc prop_entries);
    ("required", `List (List.map (fun s -> `String s) required));
  ]

let run_registered_hook ?schema ~tool_name ~(args : Yojson.Safe.t) () =
  Tool_dispatch.clear_hooks ();
  (match schema with
   | Some input_schema ->
     let schema_def : Masc_domain.tool_schema =
       { name = tool_name; description = "test"; input_schema }
     in
     Tool_dispatch.register_module_tag ~schemas:[schema_def] ~tag:Mod_misc
   | None -> ());
  Tool_input_validation.register_pre_hook ();
  Tool_dispatch.run_pre_hooks ~name:tool_name ~args

(* ================================================================ *)
(* Test: required field validation                                   *)
(* ================================================================ *)

let test_required_present () =
  let schema = make_schema ~required:["name"] [("name", "string")] in
  let args = `Assoc [("name", `String "alice")] in
  match validate_via_oas ~tool_name:"test" ~schema ~args with
  | Pass -> ()
  | Proceed _ -> ()  (* coerced but still valid *)
  | Reject r -> Alcotest.fail (Printf.sprintf "Expected Pass, got Reject: %s"
      (Yojson.Safe.to_string r.data))

let test_required_missing () =
  let schema = make_schema ~required:["name"; "room"] [("name", "string"); ("room", "string")] in
  let args = `Assoc [("name", `String "alice")] in
  match validate_via_oas ~tool_name:"test" ~schema ~args with
  | Reject r ->
    let msg = Yojson.Safe.to_string r.data in
    Alcotest.(check bool) "mentions room" true (string_contains msg "room")
  | Pass | Proceed _ -> Alcotest.fail "Expected Reject for missing required field"

let test_required_missing_multiple () =
  let schema = make_schema ~required:["a"; "b"; "c"]
    [("a", "string"); ("b", "string"); ("c", "string")] in
  let args = `Assoc [("a", `String "ok")] in
  match validate_via_oas ~tool_name:"test" ~schema ~args with
  | Reject r ->
    let msg = Yojson.Safe.to_string r.data in
    Alcotest.(check bool) "mentions b" true (string_contains msg "b");
    Alcotest.(check bool) "mentions c" true (string_contains msg "c")
  | Pass | Proceed _ -> Alcotest.fail "Expected Reject for missing multiple fields"

let test_no_required_fields () =
  let schema = make_schema [("name", "string")] in
  let args = `Assoc [] in
  match validate_via_oas ~tool_name:"test" ~schema ~args with
  | Pass -> ()
  | Proceed _ -> ()
  | Reject r -> Alcotest.fail (Printf.sprintf "Expected Pass, got Reject: %s"
      (Yojson.Safe.to_string r.data))

(* ================================================================ *)
(* Test: type coercion (Samchon Harness Rank 1)                     *)
(* ================================================================ *)

let test_coerce_string_to_integer () =
  let schema = make_schema [("count", "integer")] in
  let args = `Assoc [("count", `String "42")] in
  match validate_via_oas ~tool_name:"test" ~schema ~args with
  | Proceed coerced ->
    let count = Yojson.Safe.Util.member "count" coerced in
    Alcotest.(check string) "coerced to int" "42"
      (match count with `Int i -> string_of_int i | _ -> "not_int")
  | Pass -> Alcotest.fail "Expected Proceed (coercion), got Pass"
  | Reject r -> Alcotest.fail (Printf.sprintf "Expected Proceed, got Reject: %s"
      (Yojson.Safe.to_string r.data))

let test_coerce_string_to_boolean () =
  let schema = make_schema [("flag", "boolean")] in
  let args = `Assoc [("flag", `String "true")] in
  match validate_via_oas ~tool_name:"test" ~schema ~args with
  | Proceed coerced ->
    let flag = Yojson.Safe.Util.member "flag" coerced in
    Alcotest.(check bool) "coerced to true" true
      (match flag with `Bool b -> b | _ -> false)
  | Pass -> Alcotest.fail "Expected Proceed (coercion), got Pass"
  | Reject r -> Alcotest.fail (Printf.sprintf "Expected Proceed, got Reject: %s"
      (Yojson.Safe.to_string r.data))

let test_coerce_string_to_number () =
  let schema = make_schema [("value", "number")] in
  let args = `Assoc [("value", `String "3.14")] in
  match validate_via_oas ~tool_name:"test" ~schema ~args with
  | Proceed coerced ->
    let v = Yojson.Safe.Util.member "value" coerced in
    (match v with
     | `Float f -> Alcotest.(check bool) "close to pi" true (Float.abs (f -. 3.14) < 0.001)
     | _ -> Alcotest.fail "Expected Float after coercion")
  | Pass -> Alcotest.fail "Expected Proceed (coercion), got Pass"
  | Reject r -> Alcotest.fail (Printf.sprintf "Expected Proceed, got Reject: %s"
      (Yojson.Safe.to_string r.data))

let test_coerce_int_to_number () =
  let schema = make_schema [("value", "number")] in
  let args = `Assoc [("value", `Int 42)] in
  match validate_via_oas ~tool_name:"test" ~schema ~args with
  | Pass -> ()  (* Int is valid Number, may not need coercion *)
  | Proceed _ -> ()  (* widened to Float, also ok *)
  | Reject r -> Alcotest.fail (Printf.sprintf "Expected Pass/Proceed, got Reject: %s"
      (Yojson.Safe.to_string r.data))

let test_coerce_intlit_to_integer () =
  let schema = make_schema [("count", "integer")] in
  let args = `Assoc [("count", `Intlit "123")] in
  match validate_via_oas ~tool_name:"test" ~schema ~args with
  | Proceed coerced ->
    let count = Yojson.Safe.Util.member "count" coerced in
    Alcotest.(check string) "normalized to Int" "123"
      (match count with `Int i -> string_of_int i | _ -> "not_int")
  | Pass -> ()  (* some impls may consider Intlit valid *)
  | Reject r -> Alcotest.fail (Printf.sprintf "Expected Proceed/Pass, got Reject: %s"
      (Yojson.Safe.to_string r.data))

let test_invalid_string_to_integer () =
  let schema = make_schema ~required:["count"] [("count", "integer")] in
  let args = `Assoc [("count", `String "not_a_number")] in
  match validate_via_oas ~tool_name:"test" ~schema ~args with
  | Reject r ->
    let msg = Yojson.Safe.to_string r.data in
    Alcotest.(check bool) "mentions count" true (string_contains msg "count")
  | Pass | Proceed _ -> Alcotest.fail "Expected Reject for non-coercible string"

(* ================================================================ *)
(* Test: correct types pass without coercion                        *)
(* ================================================================ *)

let test_correct_string () =
  let schema = make_schema [("name", "string")] in
  let args = `Assoc [("name", `String "alice")] in
  match validate_via_oas ~tool_name:"test" ~schema ~args with
  | Pass -> ()
  | Proceed _ -> Alcotest.fail "Expected Pass (no coercion needed)"
  | Reject r -> Alcotest.fail (Yojson.Safe.to_string r.data)

let test_correct_integer () =
  let schema = make_schema [("count", "integer")] in
  let args = `Assoc [("count", `Int 5)] in
  match validate_via_oas ~tool_name:"test" ~schema ~args with
  | Pass -> ()
  | Proceed _ -> ()  (* normalization is acceptable *)
  | Reject r -> Alcotest.fail (Yojson.Safe.to_string r.data)

let test_correct_boolean () =
  let schema = make_schema [("flag", "boolean")] in
  let args = `Assoc [("flag", `Bool true)] in
  match validate_via_oas ~tool_name:"test" ~schema ~args with
  | Pass -> ()
  | Proceed _ -> Alcotest.fail "Expected Pass (no coercion needed)"
  | Reject r -> Alcotest.fail (Yojson.Safe.to_string r.data)

(* ================================================================ *)
(* Test: edge cases                                                  *)
(* ================================================================ *)

let test_null_args_no_required () =
  let schema = make_schema [("optional", "string")] in
  let args = `Null in
  match validate_via_oas ~tool_name:"test" ~schema ~args with
  | Pass -> ()
  | Proceed _ -> ()
  | Reject r -> Alcotest.fail (Yojson.Safe.to_string r.data)

let test_null_args_with_required () =
  let schema = make_schema ~required:["name"] [("name", "string")] in
  let args = `Null in
  match validate_via_oas ~tool_name:"test" ~schema ~args with
  | Reject _ -> ()
  | Pass | Proceed _ -> Alcotest.fail "Expected Reject for null args with required fields"

let test_extra_fields_allowed () =
  let schema = make_schema ~required:["name"] [("name", "string")] in
  let args = `Assoc [("name", `String "alice"); ("extra", `Int 42)] in
  match validate_via_oas ~tool_name:"test" ~schema ~args with
  | Pass -> ()
  | Proceed _ -> ()
  | Reject r -> Alcotest.fail (Yojson.Safe.to_string r.data)

let test_empty_schema_passes () =
  let schema = `Assoc [] in
  let args = `Assoc [("anything", `String "goes")] in
  match validate_via_oas ~tool_name:"test" ~schema ~args with
  | Pass -> ()  (* empty params -> Pass *)
  | Proceed _ -> Alcotest.fail "Empty schema should Pass"
  | Reject r -> Alcotest.fail (Yojson.Safe.to_string r.data)

(* ================================================================ *)
(* Test: registered pre-hook path                                    *)
(* ================================================================ *)

let test_registered_hook_coerces_args () =
  let args = `Assoc [("count", `String "42")] in
  let blocked, forwarded =
    run_registered_hook
      ~schema:(make_schema [("count", "integer")])
      ~tool_name:"__tool_input_validation_registered_coerce"
      ~args
      ()
  in
  Alcotest.(check bool) "not blocked" true (Option.is_none blocked);
  Alcotest.(check bool) "coercion changed args" false
    (Yojson.Safe.equal forwarded args);
  match Yojson.Safe.Util.member "count" forwarded with
  | `Int 42 -> ()
  | _ -> Alcotest.fail "expected integer coercion through registered pre-hook"

let test_registered_hook_keeps_noop_as_pass () =
  let args = `Assoc [("count", `Int 42)] in
  let blocked, forwarded =
    run_registered_hook
      ~schema:(make_schema [("count", "integer")])
      ~tool_name:"__tool_input_validation_registered_noop"
      ~args
      ()
  in
  Alcotest.(check bool) "not blocked" true (Option.is_none blocked);
  Alcotest.(check bool) "args unchanged" true
    (Yojson.Safe.equal forwarded args)

let test_registered_hook_bypasses_unknown_tool () =
  let args = `Assoc [("count", `String "42")] in
  let blocked, forwarded =
    run_registered_hook
      ~tool_name:"__tool_input_validation_registered_unknown"
      ~args
      ()
  in
  Alcotest.(check bool) "not blocked" true (Option.is_none blocked);
  Alcotest.(check bool) "args unchanged" true
    (Yojson.Safe.equal forwarded args)

let test_registered_hook_bypasses_empty_schema () =
  let args = `Assoc [("anything", `String "goes")] in
  let blocked, forwarded =
    run_registered_hook
      ~schema:(`Assoc [])
      ~tool_name:"__tool_input_validation_registered_empty"
      ~args
      ()
  in
  Alcotest.(check bool) "not blocked" true (Option.is_none blocked);
  Alcotest.(check bool) "args unchanged" true
    (Yojson.Safe.equal forwarded args)

let find_schema_exn name schemas =
  match List.find_opt (fun (schema : Masc_domain.tool_schema) -> String.equal schema.name name) schemas with
  | Some schema -> schema.input_schema
  | None -> failwith ("missing schema: " ^ name)

let masc_transition_schema =
  find_schema_exn "masc_transition" Tool_task_schemas.schemas

let assoc_string key json =
  match Yojson.Safe.Util.member key json with
  | `String value -> value
  | _ -> failwith ("expected string field: " ^ key)

let test_registered_hook_transition_compat_to_and_note () =
  let args =
    `Assoc
      [
        ("agent_name", `String "codex-local-admin");
        ("task_id", `String "task-239");
        ("to", `String "claimed");
        ("note", `String "PR #8308 Draft");
      ]
  in
  let blocked, forwarded =
    run_registered_hook
      ~schema:masc_transition_schema
      ~tool_name:"masc_transition"
      ~args
      ()
  in
  Alcotest.(check bool) "not blocked" true (Option.is_none blocked);
  Alcotest.(check string) "to -> action, value preserved for handler" "claimed"
    (assoc_string "action" forwarded);
  Alcotest.(check string) "note -> notes" "PR #8308 Draft"
    (assoc_string "notes" forwarded);
  Alcotest.(check bool) "to removed" true
    (Yojson.Safe.Util.member "to" forwarded = `Null);
  Alcotest.(check bool) "note removed" true
    (Yojson.Safe.Util.member "note" forwarded = `Null)

let test_registered_hook_transition_compat_status_action () =
  let args =
    `Assoc
      [
        ("agent_name", `String "keeper-ani1999-agent");
        ("task_id", `String "task-193");
        ("action", `String "claimed");
      ]
  in
  let blocked, forwarded =
    run_registered_hook
      ~schema:masc_transition_schema
      ~tool_name:"masc_transition"
      ~args
      ()
  in
  Alcotest.(check bool) "not blocked" true (Option.is_none blocked);
  Alcotest.(check string) "status-like action value preserved for handler" "claimed"
    (assoc_string "action" forwarded)

let test_registered_hook_transition_strips_internal_agent_marker () =
  let args =
    `Assoc
      [
        ("_agent_name", `String "codex-local-admin");
        ("agent_name", `String "codex-local-admin");
        ("task_id", `String "task-216");
        ("action", `String "done");
      ]
  in
  let blocked, forwarded =
    run_registered_hook
      ~schema:masc_transition_schema
      ~tool_name:"masc_transition"
      ~args
      ()
  in
  Alcotest.(check bool) "not blocked" true (Option.is_none blocked);
  Alcotest.(check bool) "_agent_name removed before schema validation" true
    (Yojson.Safe.Util.member "_agent_name" forwarded = `Null);
  Alcotest.(check string) "agent_name preserved" "codex-local-admin"
    (assoc_string "agent_name" forwarded)

(* ================================================================ *)
(* Runner                                                            *)
(* ================================================================ *)

let () =
  Alcotest.run "Tool_input_validation (OAS delegation)" [
    ("required", [
      Alcotest.test_case "present" `Quick test_required_present;
      Alcotest.test_case "missing" `Quick test_required_missing;
      Alcotest.test_case "missing multiple" `Quick test_required_missing_multiple;
      Alcotest.test_case "no required fields" `Quick test_no_required_fields;
    ]);
    ("coercion", [
      Alcotest.test_case "string -> integer" `Quick test_coerce_string_to_integer;
      Alcotest.test_case "string -> boolean" `Quick test_coerce_string_to_boolean;
      Alcotest.test_case "string -> number" `Quick test_coerce_string_to_number;
      Alcotest.test_case "int -> number (widening)" `Quick test_coerce_int_to_number;
      Alcotest.test_case "Intlit -> Int (normalize)" `Quick test_coerce_intlit_to_integer;
      Alcotest.test_case "non-coercible string -> reject" `Quick test_invalid_string_to_integer;
    ]);
    ("correct_types", [
      Alcotest.test_case "string passes" `Quick test_correct_string;
      Alcotest.test_case "integer passes" `Quick test_correct_integer;
      Alcotest.test_case "boolean passes" `Quick test_correct_boolean;
    ]);
    ("edge_cases", [
      Alcotest.test_case "null args no required" `Quick test_null_args_no_required;
      Alcotest.test_case "null args with required" `Quick test_null_args_with_required;
      Alcotest.test_case "extra fields allowed" `Quick test_extra_fields_allowed;
      Alcotest.test_case "empty schema passes" `Quick test_empty_schema_passes;
    ]);
    ("registered_hook", [
      Alcotest.test_case "coercion flows through registered hook" `Quick
        test_registered_hook_coerces_args;
      Alcotest.test_case "no-op coercion stays pass" `Quick
        test_registered_hook_keeps_noop_as_pass;
      Alcotest.test_case "unknown tool bypasses validation" `Quick
        test_registered_hook_bypasses_unknown_tool;
      Alcotest.test_case "empty schema bypasses validation" `Quick
        test_registered_hook_bypasses_empty_schema;
      Alcotest.test_case "masc_transition compat: to/note keys" `Quick
        test_registered_hook_transition_compat_to_and_note;
      Alcotest.test_case "masc_transition compat: status-like action value" `Quick
        test_registered_hook_transition_compat_status_action;
      Alcotest.test_case "masc_transition strips internal markers" `Quick
        test_registered_hook_transition_strips_internal_agent_marker;
    ]);
  ]
