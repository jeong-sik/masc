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
      ~question:(AR.Completion { completion_contract = None; required_evidence = [] })
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
           (Astring.String.is_infix ~affix:(marker "evidence_item") text))
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
let cancellation_prompt () =
  init ();
  match
    AR.build_prompt
      ~question:
        (AR.Cancellation
           { reason = marker "cancel_reason"
           ; contract_context = [ marker "contract_context_item" ]
           })
      ~lookup:AR.No_lookup_surface
      request
  with
  | Ok text -> text
  | Error detail -> failf "cancellation prompt render failed: %s" detail
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
    ; "the completion notes", marker "completion_notes"
    ; "avoidance as a rejection signal", "회피 패턴"
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
