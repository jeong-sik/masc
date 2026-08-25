(** The skill line in the current-task block, and its absence.

    The absence is the load-bearing half. This change adds a field to every
    task in the backlog, and the claim that earns it is that a task naming no
    skill is prompted exactly as it was before the field existed. Asserting
    "no skill line appears" would pass on a block that gained a blank line or
    a header with nothing under it, so the two renderings are compared
    directly: the only difference between a task with one skill and the same
    task without may be that one line. *)

open Alcotest
module Domain = Masc_domain
module KUP = Masc.Keeper_unified_prompt

let task ~skills : Domain.task =
  { id = "task-001"
  ; title = "probe"
  ; description = "probe"
  ; task_status = Domain.InProgress { assignee = "kappa"; started_at = "2026-08-25T00:00:00Z" }
  ; priority = 3
  ; files = []
  ; created_at = "2026-08-25T00:00:00Z"
  ; created_by = Some "operator"
  ; predecessor_task_id = None
  ; contract = None
  ; execution_links = Domain.no_execution_links
  ; handoff_context = None
  ; cycle_count = 0
  ; reclaim_policy = None
  ; do_not_reclaim_reason = None
  ; skills
  }
;;

let contains ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  let rec scan i = i + nl <= hl && (String.sub haystack i nl = needle || scan (i + 1)) in
  nl = 0 || scan 0
;;

let lines s = String.split_on_char '\n' s

let test_no_skills_adds_nothing () =
  let rendered = KUP.format_current_task (task ~skills:[]) in
  check bool "no skill line" false (contains ~needle:"Skills named" rendered)
;;

let test_one_skill_is_named_with_its_path () =
  let rendered = KUP.format_current_task (task ~skills:[ "humanize-korean" ]) in
  check bool "the skill is named" true (contains ~needle:"humanize-korean" rendered);
  (* The keeper is told where to read it, not handed the body: a skill can run
     to tens of kilobytes and would otherwise land on every turn. *)
  check
    bool
    "the path is given"
    true
    (contains ~needle:".masc/skills/<name>/SKILL.md" rendered);
  let rendered_skill_line =
    lines rendered
    |> List.find_opt (contains ~needle:"Skills named by this task")
    |> Option.value ~default:""
  in
  check
    string
    "the complete instruction is unchanged"
    "- Skills named by this task: humanize-korean. Each one is at \
     .masc/skills/<name>/SKILL.md — read it before you use it."
    rendered_skill_line
;;

let test_several_skills_are_listed () =
  let rendered = KUP.format_current_task (task ~skills:[ "first-skill"; "second-skill" ]) in
  check bool "first" true (contains ~needle:"first-skill" rendered);
  check bool "second" true (contains ~needle:"second-skill" rendered)
;;

let test_the_only_difference_is_that_one_line () =
  (* The claim the new field has to earn. Every task in the backlog now carries
     [skills]; a task that names none must render as it did before the field
     existed, and "one added line" says that in a way a missing assertion
     cannot fake. *)
  let without = lines (KUP.format_current_task (task ~skills:[])) in
  let with_one = lines (KUP.format_current_task (task ~skills:[ "humanize-korean" ])) in
  check int "exactly one line added" (List.length without + 1) (List.length with_one);
  let added = List.filter (fun l -> not (List.mem l without)) with_one in
  check int "and it is a single distinct line" 1 (List.length added);
  check
    bool
    "which is the skill line"
    true
    (contains ~needle:"Skills named by this task" (List.hd added))
;;

let () =
  run
    "keeper_task_skill_block"
    [ ( "current task block"
      , [ test_case "a task naming no skill adds nothing" `Quick test_no_skills_adds_nothing
        ; test_case
            "a named skill comes with its path"
            `Quick
            test_one_skill_is_named_with_its_path
        ; test_case "several skills are all listed" `Quick test_several_skills_are_listed
        ; test_case
            "naming a skill adds exactly one line"
            `Quick
            test_the_only_difference_is_that_one_line
        ] )
    ]
;;
