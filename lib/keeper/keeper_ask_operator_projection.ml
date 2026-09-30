let ask_choice_json (choice : Keeper_ask.choice) =
  `Assoc
    [
      ("choice_id", `String choice.choice_id);
      ("label", `String choice.label);
      ( "description",
        match choice.description with None -> `Null | Some text -> `String text );
    ]

let ask_question_json (question : Keeper_ask.question) =
  `Assoc
    [
      ("question_id", `String question.question_id);
      ("header", `String question.header);
      ("prompt", `String question.prompt);
      ( "mode",
        `String (match question.mode with Keeper_ask.Single -> "single" | Keeper_ask.Multi -> "multi") );
      ( "free_text",
        (* This is the operator's answer capability; the stored author form
           remains Choices_only when only choices were originally offered. *)
        match question.free_text with
        | Keeper_ask.Choices_only -> `Assoc [ ("allowed", `Bool true) ]
        | Keeper_ask.Free_text_allowed { hint } ->
            `Assoc
              [
                ("allowed", `Bool true);
                ("hint", match hint with None -> `Null | Some text -> `String text);
              ] );
      ("choices", `List (List.map ask_choice_json question.choices));
    ]

let ask_resolution_json = function
  | Keeper_ask.Open -> `Assoc [ ("state", `String "open") ]
  | Keeper_ask.Answered_by { answers; answered_at; _ } ->
      `Assoc
        [
          ("state", `String "answered");
          ("answered_at", `Float answered_at);
          ( "answered_question_ids",
            `List
              (List.map
                 (fun (answer : Keeper_ask.answer) -> `String answer.question_id)
                 answers) );
        ]
  | Keeper_ask.Withdrawn_because { reason; withdrawn_at } ->
      `Assoc
        [
          ("state", `String "withdrawn");
          ("reason", `String reason);
          ("withdrawn_at", `Float withdrawn_at);
        ]

let ask_row_is_open = function
  | Keeper_ask.Open -> true
  | Keeper_ask.Answered_by _ | Keeper_ask.Withdrawn_because _ -> false

let ask_row_json ~keeper_name (ask_id, ((a : Keeper_ask.ask), resolution)) =
  `Assoc
    [
      ("keeper", `String keeper_name);
      ("ask_id", `String ask_id);
      ("asked_at", `Float a.asked_at);
      ("context", match a.context with None -> `Null | Some text -> `String text);
      ("questions", `List (List.map ask_question_json a.questions));
      ("resolution", ask_resolution_json resolution);
    ]
