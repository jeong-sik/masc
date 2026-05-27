(** Registry integrity checks that the OCaml type system cannot enforce.

    [Agent_tool_descriptor.runtime_handler] is a closed variant and
    every in-process dispatch site pattern-matches against it
    exhaustively, so the "descriptor registered without a dispatch
    handler" case is already caught at compile time. What is NOT
    caught:

    - duplicate [public_name] strings across descriptors
    - duplicate [internal_name] strings across descriptors
    - empty / whitespace-only name fields
    - [internal_name] format drift (non-snake_case, embedded spaces,
      etc.)

    These are exactly the failures a big-bang descriptor-add merge
    (e.g., RFC-0179 #18710, 38 descriptors) is most likely to
    introduce: typos in name fields propagate silently until a caller
    looks them up by string. *)

open Alcotest
module Descriptor = Masc_mcp.Agent_tool_descriptor
module Exec = Masc_mcp.Agent_tool_dispatch_runtime
module Registry = Masc_mcp.Keeper_tool_registry
module Tool_board_registry = Masc_mcp.Tool_board_registry

let all_descriptors () : Descriptor.t list = Descriptor.all_descriptors ()

let find_duplicates ~key (xs : Descriptor.t list) : (string * int) list =
  let counts = Hashtbl.create 64 in
  List.iter
    (fun d ->
      let k = key d in
      let prev = Option.value (Hashtbl.find_opt counts k) ~default:0 in
      Hashtbl.replace counts k (prev + 1))
    xs;
  Hashtbl.fold
    (fun k count acc -> if count > 1 then (k, count) :: acc else acc)
    counts
    []

let test_public_name_uniqueness () =
  let dups = find_duplicates ~key:(fun d -> d.Descriptor.public_name) (all_descriptors ()) in
  if dups <> []
  then
    Alcotest.failf
      "duplicate public_name(s) across Agent_tool_descriptor.all_descriptors: %s"
      (String.concat ", "
         (List.map (fun (n, c) -> Printf.sprintf "%S×%d" n c) dups))

let test_internal_name_uniqueness () =
  let dups = find_duplicates ~key:(fun d -> d.Descriptor.internal_name) (all_descriptors ()) in
  if dups <> []
  then
    Alcotest.failf
      "duplicate internal_name(s) across Agent_tool_descriptor.all_descriptors: %s"
      (String.concat ", "
         (List.map (fun (n, c) -> Printf.sprintf "%S×%d" n c) dups))

let is_blank s = String.trim s = ""

let test_no_blank_names () =
  List.iter
    (fun d ->
      if is_blank d.Descriptor.public_name
      then
        Alcotest.failf
          "descriptor with internal_name=%S has blank public_name"
          d.Descriptor.internal_name;
      if is_blank d.Descriptor.internal_name
      then
        Alcotest.failf
          "descriptor with public_name=%S has blank internal_name"
          d.Descriptor.public_name)
    (all_descriptors ())

let internal_name_charset_ok c =
  (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '_'

let test_internal_name_snake_case () =
  List.iter
    (fun d ->
      let n = d.Descriptor.internal_name in
      String.iter
        (fun c ->
          if not (internal_name_charset_ok c)
          then
            Alcotest.failf
              "internal_name %S contains non-snake_case character %C \
               (allowed: a-z, 0-9, _)"
              n
              c)
        n)
    (all_descriptors ())

let test_registry_not_empty () =
  if all_descriptors () = []
  then Alcotest.failf "Agent_tool_descriptor.all_descriptors () returned []"

let test_masc_board_registry_has_descriptor_projection () =
  List.iter
    (fun (schema : Masc_domain.tool_schema) ->
       match Descriptor.descriptors_for_internal schema.name with
       | [ descriptor ] ->
         let suffix =
           String.sub
             schema.name
             (String.length "masc_board_")
             (String.length schema.name - String.length "masc_board_")
         in
         Alcotest.(check string)
           (schema.name ^ " descriptor id")
           ("masc.board." ^ suffix)
           descriptor.Descriptor.id;
         Alcotest.(check string)
           (schema.name ^ " runtime handler")
           "tool_masc_board_dispatch"
           (Descriptor.runtime_handler_to_string descriptor.runtime_handler);
         Alcotest.(check bool)
           (schema.name ^ " schema projected")
           true
           (descriptor.input_schema = schema.input_schema)
       | [] -> Alcotest.failf "missing descriptor for %s" schema.name
       | _ :: _ :: _ -> Alcotest.failf "duplicate descriptor for %s" schema.name)
    Tool_board_registry.tools

let test_readonly_policy_projects_to_registry () =
  let projected = Descriptor.readonly_internal_names () in
  List.iter
    (fun d ->
      match d.Descriptor.policy.readonly with
      | Some true ->
        Alcotest.(check bool)
          (d.Descriptor.internal_name ^ " is in descriptor readonly projection")
          true
          (List.mem d.Descriptor.internal_name projected);
        Alcotest.(check bool)
          (d.Descriptor.internal_name ^ " is effectively read-only")
          true
          (Registry.is_effectively_read_only_tool d.Descriptor.internal_name)
      | Some false | None -> ())
    (all_descriptors ());
  Alcotest.(check bool)
    "tool_write_file is not descriptor read-only"
    false
    (List.mem "tool_write_file" projected)

let test_readonly_policy_projects_to_input_aware_registry () =
  let search_input = `Assoc [ "pattern", `String "Agent_tool_descriptor" ] in
  Alcotest.(check bool)
    "SearchFiles public alias is input-aware read-only"
    true
    (Registry.is_read_only_with_input ~tool_name:"SearchFiles" ~input:search_input);
  Alcotest.(check bool)
    "MCP-prefixed SearchFiles is input-aware read-only"
    true
    (Registry.is_read_only_with_input
       ~tool_name:"mcp__masc__SearchFiles"
       ~input:search_input);
  Alcotest.(check bool)
    "tool_search_files is descriptor read-only without legacy op"
    true
    (Registry.is_read_only_with_input ~tool_name:"tool_search_files" ~input:search_input);
  Alcotest.(check bool)
    "ReadFile public alias is input-aware read-only"
    true
    (Registry.is_read_only_with_input
       ~tool_name:"ReadFile"
       ~input:(`Assoc [ "file_path", `String "lib/keeper/keeper_tool_registry.ml" ]));
  Alcotest.(check bool)
    "WriteFile public alias remains mutating"
    false
    (Registry.is_read_only_with_input
       ~tool_name:"WriteFile"
       ~input:(`Assoc [ "file_path", `String "x"; "content", `String "y" ]));
  Alcotest.(check bool)
    "tool_write_file remains mutating"
    false
    (Registry.is_read_only_with_input
       ~tool_name:"tool_write_file"
       ~input:(`Assoc [ "path", `String "x"; "content", `String "y" ]))

let test_mutation_boundary_delegates_to_descriptor_policy () =
  let search_input = `Assoc [ "pattern", `String "Agent_tool_descriptor" ] in
  Alcotest.(check bool)
    "SearchFiles public alias is not mutating"
    false
    (Exec.has_mutating_side_effect_with_input ~tool_name:"SearchFiles" ~input:search_input);
  Alcotest.(check bool)
    "MCP-prefixed SearchFiles is not mutating"
    false
    (Exec.has_mutating_side_effect_with_input
       ~tool_name:"mcp__masc__SearchFiles"
       ~input:search_input);
  Alcotest.(check bool)
    "tool_search_files without legacy op is not mutating"
    false
    (Exec.has_mutating_side_effect_with_input
       ~tool_name:"tool_search_files"
       ~input:search_input);
  Alcotest.(check bool)
    "WriteFile public alias remains mutating"
    true
    (Exec.has_mutating_side_effect_with_input
       ~tool_name:"WriteFile"
       ~input:(`Assoc [ "file_path", `String "x"; "content", `String "y" ]))

let () =
  Alcotest.run
    "agent_tool_descriptor_registry_integrity"
    [ ( "uniqueness"
      , [ test_case "registry not empty" `Quick test_registry_not_empty
        ; test_case "public_name is unique" `Quick test_public_name_uniqueness
        ; test_case "internal_name is unique" `Quick test_internal_name_uniqueness
        ] )
    ; ( "format"
      , [ test_case "no blank name fields" `Quick test_no_blank_names
        ; test_case "internal_name is snake_case" `Quick test_internal_name_snake_case
        ] )
    ; ( "masc-board"
      , [ test_case
            "Tool_board_registry has descriptor projection"
            `Quick
            test_masc_board_registry_has_descriptor_projection
        ] )
    ; ( "policy-projection"
      , [ test_case
            "descriptor read-only policy projects to registry"
            `Quick
            test_readonly_policy_projects_to_registry
        ; test_case
            "descriptor read-only policy projects to input-aware registry"
            `Quick
            test_readonly_policy_projects_to_input_aware_registry
        ; test_case
            "mutation boundary delegates to descriptor policy"
            `Quick
            test_mutation_boundary_delegates_to_descriptor_policy
        ] )
    ]
