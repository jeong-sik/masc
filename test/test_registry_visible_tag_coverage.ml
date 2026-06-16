(* Boot-safety for the P0-1 ratchet wiring in [mcp_server_eio].

   The production boot block calls [Unified_tool_registry.register_all ()] and
   then [enforce_visible_tag_coverage ()], which raises [Failure] at boot if any
   LLM-visible schema lacks a dispatch tag. This test proves the precondition
   that makes the boot enforcement safe: after [register_all], zero visible
   schemas are missing a tag — so the enforcement converts a would-be
   first-call "unknown tool" failure into a no-op on a healthy tree, and only
   fires on real drift. *)

open Masc
open Alcotest

let test_no_visible_schema_missing_tag () =
  Unified_tool_registry.register_all ();
  let missing = Unified_tool_registry.visible_schemas_missing_tags () in
  check (list string)
    "no LLM-visible schema lacks a dispatch tag after register_all" [] missing

let test_enforce_does_not_raise_on_healthy_tree () =
  Unified_tool_registry.register_all ();
  (* enforce raises [Failure] on drift; reaching the assertion means it passed
     — this is exactly what the production boot block relies on. *)
  (try Unified_tool_registry.enforce_visible_tag_coverage ()
   with Failure m -> Alcotest.failf "enforce_visible_tag_coverage raised: %s" m);
  check bool "enforce_visible_tag_coverage passed" true true

let () =
  run "registry_visible_tag_coverage"
    [
      ( "boot_safety",
        [
          test_case "no visible schema missing tag" `Quick
            test_no_visible_schema_missing_tag;
          test_case "enforce does not raise on healthy tree" `Quick
            test_enforce_does_not_raise_on_healthy_tree;
        ] );
    ]
