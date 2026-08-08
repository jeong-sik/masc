(** Contract carries prompt/context composition only; it never filters tools or
    allocates execution budgets. *)

open Agent_sdk

let tc name f = Alcotest.test_case name `Quick f

let test_empty () =
  let contract = Contract.empty in
  Alcotest.(check bool) "empty" true (Contract.is_empty contract);
  Alcotest.(check int) "layers" 0 (List.length contract.instruction_layers);
  Alcotest.(check int) "skills" 0 (List.length contract.skills);
  Alcotest.(check (option string)) "prompt" None (Contract.compose_system_prompt contract)
;;

let test_prompt_composition () =
  let contract =
    Contract.empty
    |> Contract.with_runtime_awareness "  explicit runtime context  "
    |> Contract.with_trigger
         ~source:"typed-source"
         ~reason:"typed-reason"
         ~payload:(`Assoc [ "id", `String "event-1" ])
         "typed-event"
    |> Contract.add_instruction_layer ~label:"role" "Be precise."
  in
  match Contract.compose_system_prompt ~base:"Base prompt." contract with
  | None -> Alcotest.fail "expected composed prompt"
  | Some prompt ->
    List.iter
      (fun expected ->
         Alcotest.(check bool)
           expected
           true
           (Util.string_contains ~needle:expected prompt))
      [ "Base prompt."
      ; "explicit runtime context"
      ; "typed-event"
      ; "typed-source"
      ; "typed-reason"
      ; "event-1"
      ; "Be precise."
      ]
;;

let test_skill_deduplication () =
  let skill =
    Skill.of_markdown
      "---\nname: review\ndescription: Review skill\n---\nReview carefully."
  in
  let contract =
    Contract.empty |> Contract.with_skill skill |> Contract.with_skill skill
  in
  Alcotest.(check int) "deduplicated" 1 (List.length contract.skills)
;;

let test_merge () =
  let left =
    Contract.empty
    |> Contract.with_runtime_awareness "left"
    |> Contract.add_instruction_layer "first"
  in
  let right =
    Contract.empty
    |> Contract.with_runtime_awareness "right"
    |> Contract.add_instruction_layer "second"
  in
  let merged = Contract.merge left right in
  Alcotest.(check (option string))
    "right awareness"
    (Some "right")
    merged.runtime_awareness;
  Alcotest.(check int) "layers append" 2 (List.length merged.instruction_layers)
;;

let test_json_has_only_composition_fields () =
  let json =
    Contract.empty |> Contract.with_runtime_awareness "context" |> Contract.to_json
  in
  let fields = Yojson.Safe.Util.to_assoc json |> List.map fst in
  Alcotest.(check (list string))
    "exact fields"
    [ "runtime_awareness"; "trigger"; "instruction_layers"; "skills" ]
    fields
;;

let test_context_projection_preserves_identity () =
  let context = Context.create_sync () in
  Context.set context "caller" (`String "preserved");
  let contract = Contract.with_runtime_awareness "context" Contract.empty in
  match Contract.context_with_contract ~context contract with
  | None -> Alcotest.fail "expected context"
  | Some projected ->
    Context.set projected "projection" (`Bool true);
    Alcotest.(check bool)
      "same context"
      true
      (Context.get context "projection" = Some (`Bool true));
    Alcotest.(check bool)
      "contract stored"
      true
      (Context.get context Contract.context_key <> None)
;;

let () =
  Alcotest.run
    "Contract"
    [ ( "composition"
      , [ tc "empty" test_empty
        ; tc "prompt" test_prompt_composition
        ; tc "skill deduplication" test_skill_deduplication
        ; tc "merge" test_merge
        ; tc "json shape" test_json_has_only_composition_fields
        ; tc "context projection" test_context_projection_preserves_identity
        ] )
    ]
;;
