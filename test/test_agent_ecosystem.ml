(** Test Agent Ecosystem module *)

open Masc_mcp

let test_hash_generation () =
  let hash1 = Agent_ecosystem.hash_of_session_key "test-session-1" in
  let hash2 = Agent_ecosystem.hash_of_session_key "test-session-2" in
  (* Hash should be 12 characters *)
  Alcotest.(check int) "hash length" 12 (String.length hash1);
  Alcotest.(check int) "hash length" 12 (String.length hash2);
  (* Different sessions should have different hashes *)
  Alcotest.(check bool) "different hashes" true (hash1 <> hash2);
  (* Same session should produce same hash *)
  let hash1_again = Agent_ecosystem.hash_of_session_key "test-session-1" in
  Alcotest.(check string) "deterministic hash" hash1 hash1_again

let test_agent_type_conversion () =
  let open Agent_ecosystem in
  (* String to type *)
  Alcotest.(check bool) "resident" true (agent_type_of_string "resident" = Resident);
  Alcotest.(check bool) "daemon" true (agent_type_of_string "daemon" = Resident);
  Alcotest.(check bool) "visitor" true (agent_type_of_string "visitor" = Visitor);
  Alcotest.(check bool) "ephemeral" true (agent_type_of_string "ephemeral" = Ephemeral);
  Alcotest.(check bool) "unknown defaults to Visitor" true (agent_type_of_string "unknown" = Visitor);
  (* Type to string *)
  Alcotest.(check string) "Resident" "resident" (string_of_agent_type Resident);
  Alcotest.(check string) "Visitor" "visitor" (string_of_agent_type Visitor);
  Alcotest.(check string) "Ephemeral" "ephemeral" (string_of_agent_type Ephemeral)

let test_default_persona () =
  let persona = Agent_ecosystem.default_persona "test-agent" in
  Alcotest.(check string) "name" "test-agent" persona.name;
  Alcotest.(check string) "role" "general" persona.role;
  Alcotest.(check int) "no traits" 0 (List.length persona.traits);
  Alcotest.(check bool) "no avatar" true (persona.avatar = None)

let test_default_lineage () =
  let lineage = Agent_ecosystem.default_lineage in
  Alcotest.(check int) "generation 0" 0 lineage.generation;
  Alcotest.(check bool) "no parent" true (lineage.parent_hash = None);
  Alcotest.(check int) "no ancestors" 0 (List.length lineage.ancestors);
  Alcotest.(check int) "no mutations" 0 (List.length lineage.mutations)

let test_extend_identity () =
  let base = Agent_identity.from_agent_name "test-agent" in
  let ext = Agent_ecosystem.extend ~agent_type:Agent_ecosystem.Resident base in
  Alcotest.(check string) "same agent_name" "test-agent" ext.base.agent_name;
  Alcotest.(check bool) "is Resident" true (ext.agent_type = Agent_ecosystem.Resident);
  Alcotest.(check int) "hash length" 12 (String.length ext.hash)

let test_spawn_child () =
  let parent = Agent_ecosystem.from_agent_name ~agent_type:Agent_ecosystem.Visitor "parent-agent" in
  let child = Agent_ecosystem.spawn_child ~parent ~child_name:"child-agent" ~role:"subtask" in
  (* Child should have correct lineage *)
  Alcotest.(check int) "generation 1" 1 child.lineage.generation;
  Alcotest.(check bool) "has parent hash" true (child.lineage.parent_hash = Some parent.hash);
  Alcotest.(check int) "one ancestor" 1 (List.length child.lineage.ancestors);
  Alcotest.(check string) "ancestor is parent" parent.hash (List.hd child.lineage.ancestors);
  (* Child should be Ephemeral by default *)
  Alcotest.(check bool) "is Ephemeral" true (child.agent_type = Agent_ecosystem.Ephemeral);
  (* Child should have its own identity *)
  Alcotest.(check string) "child name" "child-agent" child.persona.name;
  Alcotest.(check string) "child role" "subtask" child.persona.role

let test_spawn_grandchild () =
  let grandparent = Agent_ecosystem.from_agent_name "grandparent" in
  let parent = Agent_ecosystem.spawn_child ~parent:grandparent ~child_name:"parent" ~role:"task" in
  let child = Agent_ecosystem.spawn_child ~parent ~child_name:"child" ~role:"subtask" in
  (* Grandchild should have generation 2 *)
  Alcotest.(check int) "generation 2" 2 child.lineage.generation;
  (* Grandchild should have 2 ancestors *)
  Alcotest.(check int) "two ancestors" 2 (List.length child.lineage.ancestors);
  (* First ancestor is parent (most recent) *)
  Alcotest.(check string) "first ancestor is parent" parent.hash (List.hd child.lineage.ancestors)

let test_add_mutation () =
  let ext = Agent_ecosystem.from_agent_name "test-agent" in
  let ext_with_mutation = Agent_ecosystem.add_mutation ext "learned:ocaml" in
  Alcotest.(check int) "one mutation" 1 (List.length ext_with_mutation.lineage.mutations);
  Alcotest.(check string) "mutation value" "learned:ocaml" (List.hd ext_with_mutation.lineage.mutations);
  (* Original should be unchanged *)
  Alcotest.(check int) "original unchanged" 0 (List.length ext.lineage.mutations)

let test_metadata_roundtrip () =
  let original = Agent_ecosystem.from_agent_name ~agent_type:Agent_ecosystem.Resident ~role:"tester" "test-agent" in
  let original_with_traits = { original with
    persona = { original.persona with traits = ["curious"; "thorough"] };
    lineage = { original.lineage with mutations = ["learned:testing"] }
  } in
  (* Convert to base with metadata *)
  let base_with_meta = Agent_ecosystem.to_base_with_metadata original_with_traits in
  (* Restore from metadata *)
  let restored = Agent_ecosystem.from_base_with_metadata base_with_meta in
  (* Check roundtrip *)
  Alcotest.(check string) "hash preserved" original_with_traits.hash restored.hash;
  Alcotest.(check bool) "type preserved" true (original_with_traits.agent_type = restored.agent_type);
  Alcotest.(check string) "role preserved" "tester" restored.persona.role;
  Alcotest.(check int) "traits preserved" 2 (List.length restored.persona.traits);
  Alcotest.(check int) "mutations preserved" 1 (List.length restored.lineage.mutations)

let test_same_agent () =
  let ext1 = Agent_ecosystem.from_agent_name "agent-1" in
  let ext2 = Agent_ecosystem.from_agent_name "agent-2" in
  (* Same hash means same agent *)
  let ext1_copy = { ext1 with persona = { ext1.persona with role = "different" } } in
  Alcotest.(check bool) "same by hash" true (Agent_ecosystem.same_agent ext1 ext1_copy);
  (* Different agents *)
  Alcotest.(check bool) "different agents" false (Agent_ecosystem.same_agent ext1 ext2)

let test_display_string () =
  let ext = Agent_ecosystem.from_agent_name ~agent_type:Agent_ecosystem.Resident "pandora" in
  let display = Agent_ecosystem.to_display_string ext in
  (* Should not be empty *)
  Alcotest.(check bool) "non-empty display" true (String.length display > 0);
  (* Should contain the name *)
  Alcotest.(check bool) "contains name" true (
    try
      let _ = Str.search_forward (Str.regexp_string "pandora") display 0 in
      true
    with Not_found -> false
  )

let () =
  Alcotest.run "Agent_ecosystem" [
    "hash", [
      Alcotest.test_case "generation" `Quick test_hash_generation;
    ];
    "agent_type", [
      Alcotest.test_case "conversion" `Quick test_agent_type_conversion;
    ];
    "defaults", [
      Alcotest.test_case "persona" `Quick test_default_persona;
      Alcotest.test_case "lineage" `Quick test_default_lineage;
    ];
    "extend", [
      Alcotest.test_case "basic" `Quick test_extend_identity;
    ];
    "spawn", [
      Alcotest.test_case "child" `Quick test_spawn_child;
      Alcotest.test_case "grandchild" `Quick test_spawn_grandchild;
    ];
    "mutation", [
      Alcotest.test_case "add" `Quick test_add_mutation;
    ];
    "metadata", [
      Alcotest.test_case "roundtrip" `Quick test_metadata_roundtrip;
    ];
    "same_agent", [
      Alcotest.test_case "check" `Quick test_same_agent;
    ];
    "display", [
      Alcotest.test_case "string" `Quick test_display_string;
    ];
  ]
