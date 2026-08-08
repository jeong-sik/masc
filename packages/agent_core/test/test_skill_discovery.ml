(** Tests for skill discovery vs runtime prompt separation (issue #520).

    Verifies that:
    - [with_skill_registry] does NOT inject skills into the system prompt.
    - [with_skill] / [with_skills] DOES inject skills into the system prompt.
    - Both paths coexist on the same agent without interference. *)

open Agent_sdk

let card_interfaces =
  Agent_card.create_supported_interface
    ~url:"https://test-agent.example/a2a"
    ~protocol_binding:"JSONRPC"
    ~protocol_version:"1.0"
    ()
  |> Result.get_ok
  |> fun interface -> Agent_card.supported_interfaces interface []
;;

let with_net f = Eio_main.run @@ fun env -> f (Eio.Stdenv.net env)

let contains ~needle haystack =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  if nlen = 0
  then true
  else (
    let rec loop i =
      if i + nlen > hlen
      then false
      else if String.sub haystack i nlen = needle
      then true
      else loop (i + 1)
    in
    loop 0)
;;

(* ── Helpers ─────────────────────────────────────────────── *)

let make_skill name body =
  Skill.of_markdown
    (Printf.sprintf "---\nname: %s\ndescription: %s skill\n---\n%s" name name body)
;;

let get_system_prompt agent = (Agent.state agent).config.system_prompt

(* ── 1. Registry skills do NOT appear in system prompt ──── *)

let test_registry_does_not_inject_prompt () =
  with_net
  @@ fun net ->
  let reg = Skill_registry.create () in
  Skill_registry.register reg (make_skill "discovery-only" "This is metadata content.");
  let agent =
    Builder.create ~net ~model:"claude-sonnet-4-6"
    |> Builder.with_system_prompt "Base prompt."
    |> Builder.with_skill_registry reg
    |> Builder.build_safe
    |> Result.get_ok
  in
  let prompt =
    match get_system_prompt agent with
    | Some p -> p
    | None -> Alcotest.fail "expected system prompt"
  in
  Alcotest.(check bool)
    "registry skill body absent from prompt"
    false
    (contains ~needle:"This is metadata content." prompt);
  Alcotest.(check bool)
    "registry skill label absent from prompt"
    false
    (contains ~needle:"[Skill: discovery-only]" prompt);
  (* But the skill is in the agent card *)
  let card = Agent.card ~supported_interfaces:card_interfaces agent in
  Alcotest.(check bool)
    "card has discovery-only skill"
    true
    (Agent_card.has_skill card "discovery-only")
;;

(* ── 2. Contract skills DO appear in system prompt ──────── *)

let test_contract_skill_injects_prompt () =
  with_net
  @@ fun net ->
  let skill = make_skill "runtime-skill" "Apply this rule at runtime." in
  let agent =
    Builder.create ~net ~model:"claude-sonnet-4-6"
    |> Builder.with_system_prompt "Base prompt."
    |> Builder.with_skill skill
    |> Builder.build_safe
    |> Result.get_ok
  in
  let prompt =
    match get_system_prompt agent with
    | Some p -> p
    | None -> Alcotest.fail "expected system prompt"
  in
  Alcotest.(check bool)
    "contract skill label present in prompt"
    true
    (contains ~needle:"[Skill: runtime-skill]" prompt);
  Alcotest.(check bool)
    "contract skill body present in prompt"
    true
    (contains ~needle:"Apply this rule at runtime." prompt)
;;

(* ── 3. with_skills (batch) also injects into prompt ────── *)

let test_with_skills_batch_injects_prompt () =
  with_net
  @@ fun net ->
  let s1 = make_skill "skill-a" "Content A." in
  let s2 = make_skill "skill-b" "Content B." in
  let agent =
    Builder.create ~net ~model:"claude-sonnet-4-6"
    |> Builder.with_system_prompt "Base."
    |> Builder.with_skills [ s1; s2 ]
    |> Builder.build_safe
    |> Result.get_ok
  in
  let prompt =
    match get_system_prompt agent with
    | Some p -> p
    | None -> Alcotest.fail "expected system prompt"
  in
  Alcotest.(check bool)
    "skill-a in prompt"
    true
    (contains ~needle:"[Skill: skill-a]" prompt);
  Alcotest.(check bool)
    "skill-b in prompt"
    true
    (contains ~needle:"[Skill: skill-b]" prompt)
;;

(* ── 4. Both paths coexist without interference ─────────── *)

let test_both_paths_coexist () =
  with_net
  @@ fun net ->
  let runtime_skill = make_skill "runtime" "Runtime behavior." in
  let reg = Skill_registry.create () in
  Skill_registry.register reg (make_skill "catalog" "Catalog description.");
  let agent =
    Builder.create ~net ~model:"claude-sonnet-4-6"
    |> Builder.with_system_prompt "Base prompt."
    |> Builder.with_skill runtime_skill
    |> Builder.with_skill_registry reg
    |> Builder.build_safe
    |> Result.get_ok
  in
  let prompt =
    match get_system_prompt agent with
    | Some p -> p
    | None -> Alcotest.fail "expected system prompt"
  in
  (* Runtime skill IS in the prompt *)
  Alcotest.(check bool)
    "runtime skill in prompt"
    true
    (contains ~needle:"[Skill: runtime]" prompt);
  Alcotest.(check bool)
    "runtime skill body in prompt"
    true
    (contains ~needle:"Runtime behavior." prompt);
  (* Registry skill is NOT in the prompt *)
  Alcotest.(check bool)
    "registry skill body absent from prompt"
    false
    (contains ~needle:"Catalog description." prompt);
  Alcotest.(check bool)
    "registry skill label absent from prompt"
    false
    (contains ~needle:"[Skill: catalog]" prompt);
  (* Agent card has the registry skill *)
  let card = Agent.card ~supported_interfaces:card_interfaces agent in
  Alcotest.(check bool) "card has catalog" true (Agent_card.has_skill card "catalog")
;;

(* ── 5. Registry-only agent: prompt unchanged ───────────── *)

let test_registry_only_preserves_base_prompt () =
  with_net
  @@ fun net ->
  let reg = Skill_registry.create () in
  Skill_registry.register reg (make_skill "meta" "Should not leak.");
  let agent =
    Builder.create ~net ~model:"claude-sonnet-4-6"
    |> Builder.with_system_prompt "Exactly this."
    |> Builder.with_skill_registry reg
    |> Builder.build_safe
    |> Result.get_ok
  in
  let prompt =
    match get_system_prompt agent with
    | Some p -> p
    | None -> Alcotest.fail "expected system prompt"
  in
  Alcotest.(check string) "base prompt preserved verbatim" "Exactly this." prompt
;;

(* ── Test runner ─────────────────────────────────────────── *)

let () =
  Alcotest.run
    "Skill discovery vs runtime"
    [ ( "separation"
      , [ Alcotest.test_case
            "registry does not inject into prompt"
            `Quick
            test_registry_does_not_inject_prompt
        ; Alcotest.test_case
            "contract skill injects into prompt"
            `Quick
            test_contract_skill_injects_prompt
        ; Alcotest.test_case
            "with_skills batch injects into prompt"
            `Quick
            test_with_skills_batch_injects_prompt
        ; Alcotest.test_case "both paths coexist" `Quick test_both_paths_coexist
        ; Alcotest.test_case
            "registry-only preserves base prompt"
            `Quick
            test_registry_only_preserves_base_prompt
        ] )
    ]
;;
