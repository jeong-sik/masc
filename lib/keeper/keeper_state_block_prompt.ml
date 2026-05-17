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
      "For non-direct keeper turns, end every response with a [STATE]...[/STATE] block unless a more specific turn-level output guard says continuity is runtime-managed:";
      template_text;
    ]
