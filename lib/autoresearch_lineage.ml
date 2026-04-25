(** Autoresearch_lineage — shared actor and tag contract for autoresearch
    feedback artifacts.

    Autoresearch failure lessons and finding records need to describe the same
    lineage consistently: which internal actor produced the record, which loop
    actor participated, and which baseline tags make the record discoverable. *)

type actor =
  | Lesson_reviewer
  | Cycle_runner

let actor_name = function
  | Lesson_reviewer -> "autoresearch-reviewer"
  | Cycle_runner -> "autoresearch_cycle"

let lesson_reviewer_actor_name = actor_name Lesson_reviewer

let cycle_runner_actor_name = actor_name Cycle_runner

let cycle_failure_participants =
  [
    lesson_reviewer_actor_name;
    cycle_runner_actor_name;
  ]

let domain_tag = "autoresearch"

let normalize_tag tag =
  match String.trim tag with
  | "" -> None
  | trimmed -> Some trimmed

let finding_tags ~target_file ~extra =
  [ Some domain_tag; normalize_tag target_file ]
  @ List.map normalize_tag extra
  |> List.filter_map (fun tag -> tag)
  |> List.fold_left
       (fun acc tag -> if List.mem tag acc then acc else tag :: acc)
       []
  |> List.rev
