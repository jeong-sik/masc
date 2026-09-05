(** Every section a review prompt computes must be rendered by the template it
    renders into.

    [Prompt_registry.render_template] rejects a variable the template needs and
    the caller did not supply, but a variable the caller supplies and the
    template does not use is dropped without a word. So a computed section can
    stop reaching the model while every test still passes and the review still
    produces a verdict.

    That is not hypothetical. [lookup_section] carries the only description the
    evaluator gets of the filesystem tools it holds: which root they resolve
    against. A template that received it and rendered nothing left the verifier
    holding read tools it was never told about (masc #29250).

    Task and Goal render different templates from different variables. Each is
    checked against its own lane here; neither can shrink the other's prompt. *)

open Alcotest
module AR = Masc.Task.Anti_rationalization

let prompt_dir () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> Filename.concat root "config/prompts"
  | None -> Filename.concat (Sys.getcwd ()) "config/prompts"
;;

(* A value distinctive enough that finding it in the rendered prompt proves the
   template placed that variable, not that the word happened to appear in the
   template's own prose. *)
let marker name = Printf.sprintf "@@SECTION_%s_REACHED@@" (String.uppercase_ascii name)

let request : AR.review_request =
  { agent_name = "keeper-fixture-agent"
  ; task_title = marker "task_title"
  ; task_description = marker "task_description"
  ; completion_notes = marker "completion_notes"
  ; task_id = "task-403"
  ; evidence_refs = [ marker "evidence_refs" ]
  }
;;

let init () =
  Prompt_registry.set_markdown_dir (prompt_dir ());
  Masc.Prompt_defaults.init ()
;;

let schemas =
  [ { Types_core.name = "tool_read_file"; description = "read"; input_schema = `Assoc [] } ]
;;

let dispatch ~name:_ ~args:_ = Ok ""

let rendered_with_lookup () =
  let lookup =
    AR.Lookup_tools { schemas; dispatch; root_layout = [ marker "root_layout" ] }
  in
  match
    AR.build_prompt
      ~question:(AR.Completion { completion_contract = None; required_evidence = []; evidence_posture = AR.Note_only; few_shot_block = "" })
      ~lookup
      request
  with
  | Ok text -> text
  | Error detail -> failf "task prompt render failed: %s" detail
;;

let test_lookup_section_reaches_the_task_prompt () =
  init ();
  let text = rendered_with_lookup () in
  check bool "the lookup section is rendered" true
    (Astring.String.is_infix ~affix:"<live_lookup>" text);
  check bool "the root listing inside it is rendered" true
    (Astring.String.is_infix ~affix:(marker "root_layout") text)
;;

let test_supplied_evidence_refs_reach_the_task_prompt () =
  init ();
  check bool "the submitted evidence refs are rendered" true
    (Astring.String.is_infix ~affix:(marker "evidence_refs") (rendered_with_lookup ()))
;;

(* Every section template the code can select must exist and render. A section
   that cannot render is an error rather than an empty string, so a renamed or
   deleted template stops the review instead of quietly shrinking its prompt —
   but only if something exercises each branch. *)
let test_every_section_template_renders () =
  init ();
  let cases =
    (* Anchored on each fragment's own tag, not on a sentence inside it. The
       English sentences these once pinned stopped existing when the prompts
       were translated (#32133) and the check went silently stale: it had been
       asserting prose no template could produce. A tag is what the section is
       called, so it survives an edit to what the section says. *)
    [ "no lookup surface", AR.No_lookup_surface, "<no_lookup_surface>"
    ; "one producer tree",
      AR.Lookup_tools { schemas; dispatch; root_layout = [ "repos/masc" ] },
      "<live_lookup>"
    ]
  in
  List.iter
    (fun (label, lookup, affix) ->
       match
         AR.build_prompt
           ~lookup
           ~question:
             (AR.Completion
                { completion_contract = Some [ marker "contract_item" ]
                ; required_evidence = [ marker "evidence_item" ]
                ; evidence_posture = AR.Usable_artifacts 2
                ; few_shot_block = marker "few_shot_block"
                })
           request
       with
       | Error detail -> failf "%s: prompt render failed: %s" label detail
       | Ok text ->
         check bool (label ^ ": its lookup template rendered") true
           (Astring.String.is_infix ~affix text);
         check bool (label ^ ": the contract section rendered") true
           (Astring.String.is_infix ~affix:(marker "contract_item") text);
         check bool (label ^ ": the required-evidence section rendered") true
           (Astring.String.is_infix ~affix:(marker "evidence_item") text);
         (* The calibration slot. It rode as a separate argument and nothing
            pinned that it landed; a template that stopped naming the variable
            would have dropped it in silence. *)
         check bool (label ^ ": the calibration block rendered") true
           (Astring.String.is_infix ~affix:(marker "few_shot_block") text);
         check bool (label ^ ": the evidence posture tag rendered") true
           (Astring.String.is_infix ~affix:"<evidence_posture>" text);
         check bool (label ^ ": the evidence posture count reached the model")
           true (Astring.String.is_infix ~affix:"2개" text))
    cases
;;

(* The Goal proof template renders the goal's own declaration and the surface
   the judge holds. A variable it stops placing would leave the judge asked to
   compare a metric it was never shown, or holding read tools nobody described
   to it. *)
let test_goal_proof_prompt_renders_its_variables () =
  init ();
  match
    Prompt_registry.render_prompt_template
      Prompt_names.goal_verification_proof
      [ "goal_title", marker "goal_title"
      ; "metric", marker "metric"
      ; "target_value", marker "target_value"
      ; "lookup_section", marker "lookup_section"
      ]
  with
  | Error detail -> failf "goal proof prompt render failed: %s" detail
  | Ok text ->
    List.iter
      (fun name ->
         check bool (name ^ " is rendered") true
           (Astring.String.is_infix ~affix:(marker name) text))
      [ "goal_title"; "metric"; "target_value"; "lookup_section" ]
;;

(* The Goal lookup template describes the tools and the root they resolve
   against. It is the Goal's own: the task template's prose names a producer
   sandbox and a submitter, neither of which a Goal has. *)
let test_goal_lookup_template_renders_the_surface () =
  init ();
  match
    Prompt_registry.render_prompt_template
      Prompt_names.goal_verification_lookup
      [ "lookup_tools", marker "lookup_tools"
      ; "lookup_root_layout", marker "root_layout"
      ]
  with
  | Error detail -> failf "goal lookup prompt render failed: %s" detail
  | Ok text ->
    check bool "the tools are named" true
      (Astring.String.is_infix ~affix:(marker "lookup_tools") text);
    check bool "the root listing is placed" true
      (Astring.String.is_infix ~affix:(marker "root_layout") text)
;;

(* A stop is judged on its reason. The completion prompt asks the opposite
   question — did you finish, and can you evidence it — and a cancellation put
   through it is refused for having no artifacts and for reading as avoidance,
   which is exactly what a stop is. These pin that the branch renders the other
   prompt, not the same one with fields blanked (#33052). *)
let cancellation_prompt ?(lookup = AR.No_lookup_surface) () =
  init ();
  match
    AR.build_prompt
      ~question:
        (AR.Cancellation
           { reason = marker "cancel_reason"
           ; contract_context = [ marker "contract_context_item" ]
           })
      ~lookup
      request
  with
  | Ok text -> text
  | Error detail -> failf "cancellation prompt render failed: %s" detail
;;

(* The only shape [process_task_once] ever produces. Rendering a cancellation
   with [No_lookup_surface] alone left the production prompt unexercised, and
   the completion wording reached it through the shared lookup slot. *)
let cancellation_prompt_with_tools () =
  cancellation_prompt
    ~lookup:
      (AR.Lookup_tools { schemas; dispatch; root_layout = [ marker "root_layout" ] })
    ()
;;

let test_the_cancellation_prompt_carries_the_reason_and_the_contract () =
  let text = cancellation_prompt () in
  check
    bool
    "the stated reason is what the judge is given"
    true
    (Astring.String.is_infix ~affix:(marker "cancel_reason") text);
  check
    bool
    "the contract reaches it as context"
    true
    (Astring.String.is_infix ~affix:(marker "contract_context_item") text);
  check
    bool
    "the task it would stop is named"
    true
    (Astring.String.is_infix ~affix:(marker "task_title") text)
;;

(* The completion prompt rendered from the same request, so the assertions
   below can be made against text that demonstrably exists. A bare "the
   cancellation prompt does not contain X" passes for free the day someone
   rewords X; checking that the completion prompt still does keeps the needle
   real. *)
let completion_prompt () =
  init ();
  match
    AR.build_prompt
      ~question:
        (AR.Completion
           { completion_contract = Some [ marker "contract_item" ]
           ; required_evidence = [ marker "evidence_item" ]
           ; evidence_posture = AR.Note_only
           ; few_shot_block = ""
           })
      ~lookup:AR.No_lookup_surface
      request
  with
  | Ok text -> text
  | Error detail -> failf "completion prompt render failed: %s" detail
;;

(* The failure modes this branch exists to remove, read off the rendered text:
   the order to reject on unevidenced contract items, the submitted-evidence
   block, and the completion notes as the thing judged. Each is asserted
   present in the completion prompt and absent from the cancellation one, so
   neither half can pass vacuously. *)
let test_the_cancellation_prompt_does_not_demand_completion_evidence () =
  let cancellation = cancellation_prompt () in
  let completion = completion_prompt () in
  List.iter
    (fun (what, affix) ->
       check
         bool
         (what ^ ": the completion prompt still carries it")
         true
         (Astring.String.is_infix ~affix completion);
       check
         bool
         (what ^ ": a stop is not judged by it")
         false
         (Astring.String.is_infix ~affix cancellation))
    [ "the reject-on-unevidenced-contract order", "계약 항목 전부를 충족해야"
    ; "the submitted evidence block", "submitted_evidence_refs"
    ; "the completion notes value", marker "completion_notes"
    (* The identifier, not just the fixture value. The value's absence only
       says the variable was not substituted; the name's absence is what says
       the judge is not being pointed at a block it does not have. It reached
       the cancellation prompt through the shared lookup slot until the slots
       were split by question. *)
    ; "the completion notes identifier", "completion_notes"
    ; "avoidance as a rejection signal", "회피 패턴"
    ; "the evidence posture clause", "<evidence_posture>"
    ]
;;

(* The production shape. Both lookup surfaces are asserted, because the
   contradiction this closes lived in the text spliced at {{lookup_section}}:
   with tools it demanded submitted snapshots and execution receipts, without
   them it named completion_notes as the only place checkable evidence lives —
   in a prompt that carries neither. *)
let test_the_cancellation_lookup_is_written_for_a_stop () =
  let with_tools = cancellation_prompt_with_tools () in
  let without = cancellation_prompt () in
  (* The surface is still described, or the assertions below would pass on an
     empty slot. With tools that means the tool name and the root listing; with
     none it means the block that says so. *)
  List.iter
    (fun (what, affix) ->
       check bool ("with tools: " ^ what ^ " reaches the model") true
         (Astring.String.is_infix ~affix with_tools))
    [ "the tool name", "tool_read_file"; "the root layout", marker "root_layout" ];
  check bool "with no surface: the no-lookup block reaches the model" true
    (Astring.String.is_infix ~affix:"<no_lookup_surface>" without);
  (* The snapshot and receipt orders live only in the producer-tree slot, so
     only the with-tools render tests them; asserting them absent from the
     no-surface render would pass whether or not the split happened.
     completion_notes was in both, and is the one that works on both. *)
  List.iter
    (fun (what, affix) ->
       check bool ("with tools: " ^ what ^ " is not asked of a stop") false
         (Astring.String.is_infix ~affix with_tools))
    [ "the submitted snapshot", "제출될 때 참이었던"
    ; "an execution receipt", "실행 영수증"
    ];
  List.iter
    (fun (label, text) ->
       check bool (label ^ ": completion_notes is not asked of a stop") false
         (Astring.String.is_infix ~affix:"completion_notes" text))
    [ "with producer tools", with_tools; "with no lookup surface", without ]
;;

(* A cancellation is refused for want of a stated basis and for nothing else.
   The prompt body says so once. The lookup slot's job is to describe the
   tools, and when it also ordered a rejection — "사유가 가리키는 것이 지금
   트리에 그대로 있으면, 그 task는 아직 할 일이 남아 있다" — it contradicted
   that body: a producer stopping because the work belongs upstream leaves
   the code right where it is, and would have been refused for it. That is
   the failure #33052 removed, rewritten one slot over.

   The bare noun is not the test. This file writes the same act three ways —
   REJECT, 기각, 거절 — and both producer-tree slots legitimately say "거절
   사유에는" to mean "put this in the reason you write", while the body says
   "중단 사유입니다" to mean the opposite of a refusal. What is listed is the
   affirmative predicate: the verb forms, and the noun form that asserts
   something IS a ground. Each one's negation is a different string —
   "기각하지 않습니다" does not contain "기각합니다", and "기각 사유가
   아닙니다" does not contain "기각 사유입니다" — so the two separate without
   a negation rule.

   This is a substring list over prose and it does not close. A rewrite in a
   form nobody has written yet passes it. It is worth what it is: the three
   spellings this file actually uses, in the shapes it actually uses them, so
   the deleted sentence cannot return by changing its clothes. The check that
   would not have this hole is a harness one — put "the work was absorbed
   upstream" to the assembled cancellation prompt and measure whether the
   verdict comes back REJECT, which is the question task-1303 asked. If this
   guard is bypassed again, write that rather than lengthening this list. *)
let rejection_orders =
  [ "기각합니다"
  ; "기각한다"
  ; "기각 사유입니다"
  ; "거절합니다"
  ; "거절한다"
  ; "거절 사유입니다"
  ; "REJECT 합니다"
  ; "REJECT합니다"
  ; "REJECT 한다"
  ; "REJECT한다"
  ; "REJECT 사유입니다"
  ]
;;

let test_the_cancellation_lookup_orders_no_rejection () =
  init ();
  let slot_text key =
    let resolved = Prompt_registry.resolve_prompt key in
    if String.equal resolved.effective ""
    then failf "prompt %s resolved to nothing" key
    else resolved.effective
  in
  let states_an_order text =
    List.exists (fun affix -> Astring.String.is_infix ~affix text) rejection_orders
  in
  (* The needle, proven on the prompt body alone rather than on the assembled
     text. The assembly also carries lookup.none.cancellation, which says what
     is NOT a ground; reading the needle off the assembly would let a reword of
     the body pass on the slot's sentence. *)
  check bool "the cancellation prompt body states the order to refuse" true
    (states_an_order (slot_text Prompt_names.verification_cancellation));
  List.iter
    (fun (what, key) ->
       check bool (what ^ " orders no rejection") false
         (states_an_order (slot_text key)))
    [ "the cancellation producer-tree slot"
    , Prompt_names.verification_lookup_producer_tree_cancellation
    ; "the completion producer-tree slot"
    , Prompt_names.verification_lookup_producer_tree
    ; "the cancellation no-surface slot"
    , Prompt_names.verification_lookup_none_cancellation
    ; "the completion no-surface slot"
    , Prompt_names.verification_lookup_none
    ]
;;

(* Two code comments (completion_authority_agent.ml, workspace_verification_store.ml)
   cite the producer-tree slot as the place the judge is told to prefix a
   checkout-relative path before calling a file absent. There are two such
   slots now and the citation names one, so both carry the sentence or the
   comments are wrong about half the reviews. *)
let test_both_producer_tree_slots_teach_the_checkout_prefix () =
  init ();
  List.iter
    (fun (what, text) ->
       List.iter
         (fun (part, affix) ->
            check bool (what ^ ": " ^ part) true
              (Astring.String.is_infix ~affix text))
         [ "names the checkout prefix", "체크아웃의 접두 경로"
         ; "says the root is the sandbox root, not the repo", "저장소가 아니라"
         ])
    [ "with a completion", rendered_with_lookup ()
    ; "with a cancellation", cancellation_prompt_with_tools ()
    ]
;;

(* The completion prompt must keep every one of those, or the assertions above
   pass because the wording moved rather than because the split worked. *)
let test_the_completion_lookup_still_asks_for_evidence () =
  let text =
    match
      AR.build_prompt
        ~question:
          (AR.Completion { completion_contract = None; required_evidence = []; evidence_posture = AR.Note_only; few_shot_block = "" })
        ~lookup:
          (AR.Lookup_tools { schemas; dispatch; root_layout = [ marker "root_layout" ] })
        request
    with
    | Ok text -> text
    | Error detail -> failf "completion prompt render failed: %s" detail
  in
  List.iter
    (fun (what, affix) ->
       check bool (what ^ ": still asked of a completion") true
         (Astring.String.is_infix ~affix text))
    [ "the submitted snapshot", "제출될 때 참이었던"
    ; "an execution receipt", "실행 영수증"
    ]
;;

let () =
  Alcotest.run
    "review_prompt_sections"
    [ ( "sections reach the model"
      , [ test_case
            "lookup_section is rendered by the task review prompt"
            `Quick
            test_lookup_section_reaches_the_task_prompt
        ; test_case
            "evidence_refs is rendered where evidence is judged"
            `Quick
            test_supplied_evidence_refs_reach_the_task_prompt
        ; test_case
            "every section template renders"
            `Quick
            test_every_section_template_renders
        ; test_case
            "the cancellation prompt carries the reason and the contract"
            `Quick
            test_the_cancellation_prompt_carries_the_reason_and_the_contract
        ; test_case
            "the cancellation prompt does not demand completion evidence"
            `Quick
            test_the_cancellation_prompt_does_not_demand_completion_evidence
        ; test_case
            "the cancellation lookup is written for a stop"
            `Quick
            test_the_cancellation_lookup_is_written_for_a_stop
        ; test_case
            "the cancellation lookup orders no rejection"
            `Quick
            test_the_cancellation_lookup_orders_no_rejection
        ; test_case
            "both producer-tree slots teach the checkout prefix"
            `Quick
            test_both_producer_tree_slots_teach_the_checkout_prefix
        ; test_case
            "the completion lookup still asks for evidence"
            `Quick
            test_the_completion_lookup_still_asks_for_evidence
        ; test_case
            "the goal proof prompt renders its variables"
            `Quick
            test_goal_proof_prompt_renders_its_variables
        ; test_case
            "the goal lookup template renders the surface"
            `Quick
            test_goal_lookup_template_renders_the_surface
        ] )
    ]
;;
