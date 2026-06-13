let field_summary = "DONE, NEXT, Goal, Decisions, OpenQuestions, and Constraints"

let template_text =
  String.concat "\n"
    [
      "[STATE]";
      "DONE: what you accomplished this turn";
      "NEXT: what the next turn should do";
      (* The post-turn sanitizer validates this field against
         meta.active_goal_ids (keeper_post_turn); prose here is cleared every
         turn, so the template must demand the id, not a description (#20937). *)
      "Goal: active goal id from <available_goals> verbatim (e.g. goal-123-04af), never prose; omit this line when no goal id applies";
      "Decisions: key decisions (semicolon-separated)";
      "OpenQuestions: unresolved items (semicolon-separated)";
      "Constraints: active constraints (semicolon-separated)";
      "[/STATE]";
    ]

let instruction_text =
  String.concat "\n"
    [
      Printf.sprintf
        "State block template: for non-direct keeper turns, report continuity \
         using the [STATE] block at the end of your response. Fields: %s. All \
         fields are optional but provide as many as you can."
        field_summary;
      template_text;
    ]
