(** test_keeper_bash_descriptor_variant — RFC-0091 PR-3 gate.

    Asserts the two descriptor variants of the [keeper_bash] tool schema:

    - [Legacy_v0] still advertises the [cmd] field, keeps the 4-branch
      [oneOf] discriminator, and emits no top-level [required].
    - [Typed_v1] removes [cmd] from [properties], drops the [cmd] branch
      from [oneOf] (3 branches remain), and adds top-level
      [required: ["executable"]].

    Both variants share the same [keeper_bash_output] and
    [keeper_bash_kill] schemas — only [keeper_bash] differs. The test
    pins those invariants so future edits cannot reintroduce [cmd]
    under the typed variant or accidentally drop it from the legacy
    variant without an explicit RFC-tracked change. *)

open Masc_mcp
module Variant = Tool_shard_types_schemas_bash

let pp_json = Yojson.Safe.to_string

let find_bash_schema tools =
  List.find
    (fun (t : Masc_domain.tool_schema) -> String.equal t.name "keeper_bash")
    tools
;;

let assoc_field_opt (json : Yojson.Safe.t) key =
  match json with
  | `Assoc kvs -> List.assoc_opt key kvs
  | _ -> None
;;

let property_names (input_schema : Yojson.Safe.t) =
  match assoc_field_opt input_schema "properties" with
  | Some (`Assoc props) -> List.map fst props
  | _ -> Alcotest.failf "properties missing or wrong shape: %s" (pp_json input_schema)
;;

let one_of_required_names (input_schema : Yojson.Safe.t) =
  match assoc_field_opt input_schema "oneOf" with
  | Some (`List branches) ->
    List.map
      (fun branch ->
        match assoc_field_opt branch "required" with
        | Some (`List names) ->
          List.map (function `String s -> s | _ -> "<non-string>") names
          |> String.concat ","
        | _ -> "<no-required>")
      branches
  | _ -> Alcotest.failf "oneOf missing or wrong shape: %s" (pp_json input_schema)
;;

let top_level_required (input_schema : Yojson.Safe.t) =
  match assoc_field_opt input_schema "required" with
  | Some (`List names) ->
    Some
      (List.map (function `String s -> s | _ -> "<non-string>") names
       |> String.concat ",")
  | _ -> None
;;

let test_legacy_v0_keeps_cmd () =
  let tools =
    Variant.coding_keeper_bridge_tools_for_variant
      ~variant:Variant.Legacy_v0
  in
  let bash = find_bash_schema tools in
  let props = property_names bash.input_schema in
  Alcotest.(check bool) "legacy_v0: cmd present in properties" true
    (List.mem "cmd" props);
  Alcotest.(check bool) "legacy_v0: executable present in properties" true
    (List.mem "executable" props);
  let branches = one_of_required_names bash.input_schema in
  Alcotest.(check int) "legacy_v0: 4 oneOf branches" 4 (List.length branches);
  Alcotest.(check bool) "legacy_v0: cmd branch present" true (List.mem "cmd" branches);
  Alcotest.(check (option string))
    "legacy_v0: no top-level required" None
    (top_level_required bash.input_schema)
;;

let test_typed_v1_drops_cmd () =
  let tools =
    Variant.coding_keeper_bridge_tools_for_variant
      ~variant:Variant.Typed_v1
  in
  let bash = find_bash_schema tools in
  let props = property_names bash.input_schema in
  Alcotest.(check bool) "typed_v1: cmd absent from properties" false
    (List.mem "cmd" props);
  Alcotest.(check bool) "typed_v1: executable present in properties" true
    (List.mem "executable" props);
  Alcotest.(check bool) "typed_v1: pipeline present in properties" true
    (List.mem "pipeline" props);
  Alcotest.(check bool) "typed_v1: stages present in properties" true
    (List.mem "stages" props);
  let branches = one_of_required_names bash.input_schema in
  Alcotest.(check int) "typed_v1: 3 oneOf branches (cmd dropped)" 3 (List.length branches);
  Alcotest.(check bool) "typed_v1: cmd branch absent" false (List.mem "cmd" branches);
  Alcotest.(check (option string))
    "typed_v1: top-level required = executable" (Some "executable")
    (top_level_required bash.input_schema)
;;

let test_description_changes_with_variant () =
  let legacy =
    Variant.coding_keeper_bridge_tools_for_variant
      ~variant:Variant.Legacy_v0
    |> find_bash_schema
  in
  let typed =
    Variant.coding_keeper_bridge_tools_for_variant
      ~variant:Variant.Typed_v1
    |> find_bash_schema
  in
  Alcotest.(check bool) "legacy_v0 description mentions cmd" true
    (String.length legacy.description > 0
     && Astring.String.is_infix ~affix:"Legacy cmd remains accepted" legacy.description);
  Alcotest.(check bool) "typed_v1 description rejects cmd" true
    (Astring.String.is_infix
       ~affix:"legacy 'cmd' string field is no longer accepted"
       typed.description);
  Alcotest.(check bool) "typed_v1 description does NOT advertise cmd as field" false
    (Astring.String.is_infix ~affix:"Good: cmd=" typed.description)
;;

let test_sibling_schemas_invariant_across_variants () =
  let legacy_tools =
    Variant.coding_keeper_bridge_tools_for_variant
      ~variant:Variant.Legacy_v0
  in
  let typed_tools =
    Variant.coding_keeper_bridge_tools_for_variant
      ~variant:Variant.Typed_v1
  in
  let by_name (name : string) tools =
    List.find
      (fun (t : Masc_domain.tool_schema) -> String.equal t.name name)
      tools
  in
  let names = [ "keeper_bash_output"; "keeper_bash_kill" ] in
  List.iter
    (fun name ->
      let l = by_name name legacy_tools in
      let t = by_name name typed_tools in
      Alcotest.(check string)
        (name ^ " description identical across variants")
        l.description t.description;
      Alcotest.(check string)
        (name ^ " input_schema identical across variants")
        (pp_json l.input_schema) (pp_json t.input_schema))
    names
;;

let () =
  Alcotest.run
    "keeper_bash_descriptor_variant"
    [ ( "rfc-0091-pr-3"
      , [ Alcotest.test_case "legacy_v0 keeps cmd" `Quick test_legacy_v0_keeps_cmd
        ; Alcotest.test_case "typed_v1 drops cmd" `Quick test_typed_v1_drops_cmd
        ; Alcotest.test_case "description changes with variant" `Quick
            test_description_changes_with_variant
        ; Alcotest.test_case "sibling schemas invariant" `Quick
            test_sibling_schemas_invariant_across_variants
        ] )
    ]
;;
