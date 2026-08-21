(** Every section [Task.Anti_rationalization.build_prompt] computes must be
    rendered by every template it renders into.

    [build_prompt] hands one variable list to three templates: task
    verification, Goal criterion review, and Goal proof review.
    [Prompt_registry.render_template] rejects a variable the template needs and
    the caller did not supply, but a variable the caller supplies and the
    template does not use is dropped without a word. So a computed section can
    stop reaching the model while every test still passes and the review still
    produces a verdict.

    That is not hypothetical. [lookup_section] carries the only description the
    evaluator gets of the filesystem tools it holds: which root they resolve
    against, and — for a Goal proof spanning several performers — that a
    producer argument is required at all. Both Goal templates received it and
    rendered neither, so the Goal verifier held read tools it was never told
    about (masc #29254 built that forest surface; #29250 found the drop). *)

open Alcotest
module AR = Masc.Task.Anti_rationalization

let prompt_dir () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> Filename.concat root "config/prompts"
  | None -> Filename.concat (Sys.getcwd ()) "config/prompts"
;;

(* The templates [build_prompt] renders into. Kept as a literal list so adding
   a fourth review prompt without adding it here is a visible omission rather
   than a silently unchecked template. *)
let review_prompt_keys =
  [ Prompt_names.verification
  ; Prompt_names.goal_verification_criterion
  ; Prompt_names.goal_verification_proof
  ]
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

let rendered_with_lookup key =
  let lookup =
    AR.Lookup_tools
      { schemas =
          [ { Types_core.name = "tool_read_file"
            ; description = "read"
            ; input_schema = `Assoc []
            }
          ]
      ; dispatch = (fun ~name:_ ~args:_ -> Ok "")
      ; scope = AR.Producer_tree
      ; root_layout = [ marker "root_layout" ]
      }
  in
  match AR.build_prompt ~lookup ~prompt_name:key request with
  | Ok text -> text
  | Error detail -> failf "%s: prompt render failed: %s" key detail
;;

let test_lookup_section_reaches_every_review_prompt () =
  Prompt_registry.set_markdown_dir (prompt_dir ());
  Masc.Prompt_defaults.init ();
  List.iter
    (fun key ->
       let text = rendered_with_lookup key in
       check
         bool
         (key ^ ": the lookup section is rendered")
         true
         (Astring.String.is_infix ~affix:"<live_lookup>" text);
       check
         bool
         (key ^ ": the root listing inside it is rendered")
         true
         (Astring.String.is_infix ~affix:(marker "root_layout") text))
    review_prompt_keys
;;

(* Every section template the code can select must exist and render. A section
   that cannot render is now an error rather than an empty string, so a renamed
   or deleted template stops the review instead of quietly shrinking its
   prompt — but only if something exercises each branch. *)
let test_every_section_template_renders () =
  Prompt_registry.set_markdown_dir (prompt_dir ());
  Masc.Prompt_defaults.init ();
  let schemas =
    [ { Types_core.name = "tool_read_file"; description = "read"; input_schema = `Assoc [] } ]
  in
  let dispatch ~name:_ ~args:_ = Ok "" in
  let cases =
    [ ( "no lookup surface"
      , AR.No_lookup_surface
      , "You have no tool that opens anything else" )
    ; ( "one producer tree"
      , AR.Lookup_tools
          { schemas; dispatch; scope = AR.Producer_tree; root_layout = [ "repos/masc" ] }
      , "pointed at the producer's sandbox root" )
    ; ( "a producer forest"
      , AR.Lookup_tools
          { schemas
          ; dispatch
          ; scope = AR.Producer_forest { producers = [ "keeper-a"; "keeper-b" ] }
          ; root_layout = [ "keeper-a: repos/masc" ]
          }
      , "closed producer set is: keeper-a, keeper-b" )
    ]
  in
  List.iter
    (fun (label, lookup, affix) ->
       match
         AR.build_prompt
           ~lookup
           ~completion_contract:[ marker "contract_item" ]
           ~required_evidence:[ marker "evidence_item" ]
           ~prompt_name:Prompt_names.verification
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

let test_supplied_evidence_refs_reach_every_review_prompt () =
  Prompt_registry.set_markdown_dir (prompt_dir ());
  Masc.Prompt_defaults.init ();
  List.iter
    (fun key ->
       let text = rendered_with_lookup key in
       check
         bool
         (key ^ ": the submitted evidence refs are rendered")
         true
         (Astring.String.is_infix ~affix:(marker "evidence_refs") text))
    (* The criterion review judges a Goal record rather than submitted
       evidence, so it is the one template that legitimately does not carry
       evidence refs. *)
    [ Prompt_names.verification; Prompt_names.goal_verification_proof ]
;;

let () =
  Alcotest.run
    "review_prompt_sections"
    [ ( "sections reach the model"
      , [ test_case
            "lookup_section is rendered by every review prompt"
            `Quick
            test_lookup_section_reaches_every_review_prompt
        ; test_case
            "evidence_refs is rendered where evidence is judged"
            `Quick
            test_supplied_evidence_refs_reach_every_review_prompt
        ; test_case
            "every section template renders"
            `Quick
            test_every_section_template_renders
        ] )
    ]
;;
