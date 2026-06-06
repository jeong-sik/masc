let field_summary = "DONE, NEXT, Goal, Decisions, OpenQuestions, and Constraints"

let template_text =
  String.concat "\n"
    [
      "[STATE]";
      "DONE: what you accomplished this turn";
      "NEXT: what the next turn should do";
      "Goal: current active goal";
      "Decisions: key decisions (semicolon-separated)";
      "OpenQuestions: unresolved items (semicolon-separated)";
      "Constraints: active constraints (semicolon-separated)";
      "[/STATE]";
    ]

let instruction_text =
  String.concat "\n"
    [
      "For non-direct keeper turns, call the keeper_report_state tool at the end of your response to report your turn state for continuity. This is MANDATORY — do not skip it.";
      "The tool accepts: goal, progress, done_summary, next_summary, next_items, decisions, open_questions, constraints. All fields are optional but provide as many as you can.";
      Printf.sprintf "State block template: fields correspond to the legacy [STATE] block: %s." field_summary;
      "If the tool is unavailable for any reason, fall back to a [STATE]...[/STATE] text block:";
      template_text;
    ]
