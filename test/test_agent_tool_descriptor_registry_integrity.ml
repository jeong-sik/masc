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
module Policy = Masc_mcp.Keeper_tool_policy
module Exec = Masc_mcp.Agent_tool_dispatch_runtime
module Registry = Masc_mcp.Keeper_tool_registry
module Resolution = Masc_mcp.Agent_tool_descriptor_resolution
module Tool_board_registry = Masc_mcp.Tool_board_registry

let all_descriptors () : Descriptor.t list = Descriptor.all_descriptors ()

(* RFC-0190 — Descriptor as Visibility/Metadata SSOT.

   [Tool_catalog_surfaces.public_mcp_surface_tools] is the operator-facing
   MCP surface set. Its end-state under RFC-0190 P4 is to be computed as
   [filter (visibility = Public_mcp) all_descriptors], deleting the hand
   list entirely.

   Until RFC-0190 P1-P3 land, 9 surface entries have no descriptor at all
   because their handlers live in [Tool_inline_dispatch] (MCP server-level
   inline path), not in the [runtime_handler] enum the descriptor system
   dispatches through.  These 9 are enumerated below as the
   [rfc_0190_pending_inline_migration] allowlist.

   This invariant test exists to ratchet that allowlist toward empty:
   - Adding a new surface entry without a descriptor fails the test.
   - Adding a descriptor for any of the 9 allowlist entries fails the
     test (allowlist must shrink), forcing the allowlist edit to live in
     the same PR as the descriptor add.

   When the allowlist hits zero, RFC-0190 P4 lands [public_mcp_surface_tools]
   as a function over [all_descriptors] and this test is rewritten to
   forbid any pending entries. *)
let rfc_0190_pending_inline_migration =
  [ "masc_start"
  ; "masc_join"
  ; "masc_leave"
  ; "masc_broadcast"
  ; "masc_messages"
  ; "masc_who"
  ; "masc_keeper_sandbox_status"
  ; "masc_persona_generate"
  ; "masc_keeper_create_from_persona"
  ]
;;

let descriptor_internal_name_set () =
  let tbl = Hashtbl.create 256 in
  List.iter
    (fun d -> Hashtbl.replace tbl d.Descriptor.internal_name ())
    (all_descriptors ());
  tbl
;;

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
      match Descriptor.readonly_static_hint d with
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

let test_readonly_policy_is_descriptor_input_aware () =
  let public_input =
    `Assoc [ "pattern", `String "Agent_tool_descriptor"; "op", `String "rm" ]
  in
  let internal_input = `Assoc [ "op", `String "rm"; "pattern", `String "x" ] in
  let descriptor =
    match Descriptor.find_public "SearchFiles" with
    | Some descriptor -> descriptor
    | None -> Alcotest.fail "missing SearchFiles descriptor"
  in
  Alcotest.(check (option bool))
    "static readonly hint stays available for schema/evidence"
    (Some true)
    (Descriptor.readonly_static_hint descriptor);
  Alcotest.(check (option bool))
    "raw public-shaped input is not an internal readonly decision"
    None
    (Descriptor.readonly_for_input descriptor ~input:public_input);
  Alcotest.(check (option bool))
    "public input is translated before readonly policy evaluation"
    (Some true)
    (Resolution.readonly_for_tool_call ~tool_name:"SearchFiles" ~input:public_input);
  Alcotest.(check (option bool))
    "MCP-prefixed public input follows the same descriptor policy"
    (Some true)
    (Resolution.readonly_for_tool_call
       ~tool_name:"mcp__masc__SearchFiles"
       ~input:public_input);
  Alcotest.(check (option bool))
    "unknown internal op falls back to static read-only hint"
    (Some true)
    (Resolution.readonly_for_tool_call
       ~tool_name:"tool_search_files"
       ~input:internal_input)

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

let test_mcp_context_policy_uses_descriptor_resolution () =
  Alcotest.(check bool)
    "approval_pending does not require MCP session"
    false
    (Policy.is_keeper_mcp_context_required "masc_approval_pending");
  Alcotest.(check bool)
    "mcp-prefixed approval_pending keeps inline exemption"
    false
    (Policy.is_keeper_mcp_context_required "mcp__masc__masc_approval_pending");
  Alcotest.(check bool)
    "approval_get still requires MCP session"
    true
    (Policy.is_keeper_mcp_context_required "masc_approval_get");
  Alcotest.(check bool)
    "mcp-prefixed approval_get still requires MCP session"
    true
    (Policy.is_keeper_mcp_context_required "mcp__masc__masc_approval_get")
;;

let test_public_name_projection_uses_descriptor_resolution () =
  Alcotest.(check (list string))
    "tool_execute public projection"
    [ "Execute" ]
    (Resolution.public_names_for_internal "tool_execute");
  Alcotest.(check (option string))
    "tool_write_file preferred public projection"
    (Some "WriteFile")
    (Resolution.public_name_for_internal "tool_write_file");
  Alcotest.(check (list string))
    "allowed internal routes project to public names"
    [ "Execute"; "SearchFiles" ]
    (Resolution.public_names_for_allowed_internal_names
       [ "tool_execute"; "tool_search_files" ])
;;

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
       ~input:(`Assoc [ "file_path", `String "x"; "content", `String "y" ]));
  Alcotest.(check bool)
    "WriteFile public alias follows descriptor checkpoint policy"
    true
    (Registry.is_main_worktree_boundary_exempt_with_input
       ~tool_name:"WriteFile"
       ~input:(`Assoc [ "file_path", `String "x"; "content", `String "y" ]));
  Alcotest.(check bool)
    "Execute public alias follows descriptor checkpoint policy"
    true
    (Registry.is_main_worktree_boundary_exempt_with_input
       ~tool_name:"Execute"
       ~input:(`Assoc [ "executable", `String "git"; "argv", `List [ `String "status" ] ]))

(* RFC-0182 §3.1 — verify the 21 new tool_shard / approval / persona /
   keeper / surface_audit descriptors all project from name → descriptor
   via [descriptors_for_internal] with the expected [runtime_handler].

   This catches future typos in the [~name:"masc_X"] strings (which the
   compiler cannot see) and missing cluster builder calls in
   [internal_descriptors]. *)
let cluster_projection_table =
  [ "masc_tool_list", "tool_masc_tool_shard_dispatch"
  ; "masc_tool_grant", "tool_masc_tool_shard_dispatch"
  ; "masc_tool_revoke", "tool_masc_tool_shard_dispatch"
  ; "masc_approval_pending", "tool_masc_approval_dispatch"
  ; "masc_approval_get", "tool_masc_approval_dispatch"
  ; "masc_approval_resolve", "tool_masc_approval_dispatch"
  ; "masc_persona_list", "tool_masc_persona_dispatch"
  ; "masc_persona_schema", "tool_masc_persona_dispatch"
  ; "masc_persona_save", "tool_masc_persona_dispatch"
  ; "masc_keeper_list", "tool_masc_keeper_dispatch"
  ; "masc_keeper_msg_result", "tool_masc_keeper_dispatch"
  ; "masc_keeper_compact", "tool_masc_keeper_dispatch"
  ; "masc_keeper_clear", "tool_masc_keeper_dispatch"
  ; "masc_keeper_sandbox_start", "tool_masc_keeper_dispatch"
  ; "masc_keeper_sandbox_stop", "tool_masc_keeper_dispatch"
  ; "masc_keeper_reset", "tool_masc_keeper_dispatch"
  ; "masc_keeper_persona_audit", "tool_masc_keeper_dispatch"
  ; "masc_keeper_status", "tool_masc_keeper_dispatch"
  ; "masc_keeper_repair", "tool_masc_keeper_dispatch"
  ; "masc_keeper_down", "tool_masc_keeper_dispatch"
  ; "masc_keeper_msg", "tool_masc_keeper_dispatch"
  ; "masc_keeper_up", "tool_masc_keeper_dispatch"
  ; "masc_surface_audit", "tool_masc_surface_audit"
  ]
;;

let test_rfc_0182_clusters_have_descriptor_projection () =
  List.iter
    (fun (tool_name, expected_handler) ->
       match Descriptor.descriptors_for_internal tool_name with
       | [ descriptor ] ->
         Alcotest.(check string)
           (tool_name ^ " runtime handler")
           expected_handler
           (Descriptor.runtime_handler_to_string descriptor.runtime_handler)
       | [] -> Alcotest.failf "missing descriptor for %s" tool_name
       | _ :: _ :: _ -> Alcotest.failf "duplicate descriptor for %s" tool_name)
    cluster_projection_table
;;

(* RFC-0190 — every entry of [public_mcp_surface_tools] must either have
   a descriptor or be on the [rfc_0190_pending_inline_migration]
   allowlist. New surface additions without a descriptor are rejected. *)
let test_rfc_0190_surface_covered_by_descriptor_or_allowlist () =
  let descriptor_names = descriptor_internal_name_set () in
  let allowlist =
    let tbl = Hashtbl.create 16 in
    List.iter (fun n -> Hashtbl.replace tbl n ()) rfc_0190_pending_inline_migration;
    tbl
  in
  let surface = Tool_catalog_surfaces.public_mcp_surface_tools in
  let missing =
    List.filter
      (fun name ->
         (not (Hashtbl.mem descriptor_names name))
         && not (Hashtbl.mem allowlist name))
      surface
  in
  if missing <> []
  then
    Alcotest.failf
      "public_mcp_surface_tools has %d entries with no descriptor and no \
       RFC-0190 allowlist slot: %s. Either add a descriptor (preferred, \
       see RFC-0190 P1-P3) or extend [rfc_0190_pending_inline_migration] \
       with explicit justification."
      (List.length missing)
      (String.concat ", " missing)
;;

(* RFC-0190 — the allowlist is the *missing* set, not a permanent
   carve-out.  When a descriptor lands for an allowlist entry, the
   allowlist edit must land in the same PR.  This test catches the
   stale-allowlist case. *)
let test_rfc_0190_allowlist_has_no_descriptor () =
  let descriptor_names = descriptor_internal_name_set () in
  let stale =
    List.filter (Hashtbl.mem descriptor_names) rfc_0190_pending_inline_migration
  in
  if stale <> []
  then
    Alcotest.failf
      "rfc_0190_pending_inline_migration lists %d entries that now have \
       descriptors and must be removed from the allowlist: %s"
      (List.length stale)
      (String.concat ", " stale)
;;

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
    ; ( "rfc-0182-clusters"
      , [ test_case
            "tool_shard/approval/persona/keeper/surface_audit project to descriptors"
            `Quick
            test_rfc_0182_clusters_have_descriptor_projection
        ] )
    ; ( "rfc-0190-surface-projection"
      , [ test_case
            "public_mcp_surface_tools is descriptor-backed or allowlisted"
            `Quick
            test_rfc_0190_surface_covered_by_descriptor_or_allowlist
        ; test_case
            "rfc_0190_pending_inline_migration shrinks when a descriptor lands"
            `Quick
            test_rfc_0190_allowlist_has_no_descriptor
        ] )
    ; ( "policy-projection"
      , [ test_case
            "descriptor read-only policy projects to registry"
            `Quick
            test_readonly_policy_projects_to_registry
        ; test_case
            "descriptor read-only policy evaluates tool input"
            `Quick
            test_readonly_policy_is_descriptor_input_aware
        ; test_case
            "descriptor read-only policy projects to input-aware registry"
            `Quick
            test_readonly_policy_projects_to_input_aware_registry
        ; test_case
            "MCP context policy uses descriptor resolution"
            `Quick
            test_mcp_context_policy_uses_descriptor_resolution
        ; test_case
            "public names project through descriptor resolution"
            `Quick
            test_public_name_projection_uses_descriptor_resolution
        ; test_case
            "mutation boundary delegates to descriptor policy"
            `Quick
            test_mutation_boundary_delegates_to_descriptor_policy
        ] )
    ]
