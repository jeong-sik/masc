(** MCP prompt surface for canonical help and proof views. *)

type prompt_argument = {
  name : string;
  description : string;
  required : bool;
}

type prompt_def = {
  name : string;
  title : string;
  description : string;
  arguments : prompt_argument list;
}

let prompt_defs =
  [
    {
      name = "tool_help";
      title = "Tool Help";
      description = "Compose a grounded explanation for a specific MASC MCP tool.";
      arguments =
        [
          { name = "tool_name"; description = "Exact MCP tool name"; required = true };
          { name = "focus"; description = "Optional question or emphasis"; required = false };
        ];
    };
    {
      name = "team_session_proof";
      title = "Team Session Proof";
      description = "Summarize auditable collaboration evidence for a team session.";
      arguments =
        [
          { name = "session_id"; description = "Team session identifier"; required = true };
          { name = "operation_id"; description = "Optional managed operation identifier"; required = false };
        ];
    };
    {
      name = "command_truth";
      title = "Command Truth";
      description = "Summarize managed command-plane evidence for an operation or run.";
      arguments =
        [
          { name = "operation_id"; description = "Managed operation or trace identifier"; required = false };
          { name = "run_id"; description = "Optional swarm-live run identifier"; required = false };
        ];
    };
  ]

let prompt_json (prompt : prompt_def) =
  `Assoc
    [
      ("name", `String prompt.name);
      ("title", `String prompt.title);
      ("description", `String prompt.description);
      ( "arguments",
        `List
          (List.map
             (fun (arg : prompt_argument) ->
               `Assoc
                 [
                   ("name", `String arg.name);
                   ("description", `String arg.description);
                   ("required", `Bool arg.required);
                 ])
             prompt.arguments) );
    ]

let list_json () =
  `Assoc [ ("prompts", `List (List.map prompt_json prompt_defs)) ]

let lookup name =
  List.find_opt (fun (prompt : prompt_def) -> String.equal prompt.name name) prompt_defs

let assoc_string args key =
  match Yojson.Safe.Util.member key args with
  | `String value ->
      let trimmed = String.trim value in
      if trimmed = "" then None else Some trimmed
  | _ -> None

let message_json text =
  `Assoc
    [
      ("role", `String "user");
      ("content", `Assoc [ ("type", `String "text"); ("text", `String text) ]);
    ]

let tool_help_text ~tool_name ~focus schemas =
  match Tool_help_registry.find_entry schemas tool_name with
  | None -> Error (Printf.sprintf "unknown tool: %s" tool_name)
  | Some entry ->
      let focus_lines =
        match focus with
        | Some value -> [ "Focus: " ^ value; "" ]
        | None -> []
      in
      Ok
        (String.concat "\n"
           ([
              "Explain this MCP tool using only the grounded fields below.";
              "Do not invent extra workflow steps beyond the listed help.";
              "";
            ]
           @ focus_lines
           @
           [
             "Tool: " ^ entry.name;
             "Short description: " ^ entry.short_description;
             "When to use: " ^ entry.when_to_use;
             "Key constraints:";
           ]
           @ List.map (fun item -> "- " ^ item) entry.key_constraints
           @
           [
             "";
             "Details:";
             entry.details_markdown;
           ]
           @
           (if entry.doc_refs = [] then [] else "" :: "Docs:" :: List.map (fun item -> "- " ^ item) entry.doc_refs)))

let team_session_proof_text ~config ~session_id ~operation_id =
  let proof_json =
    Dashboard_proof.json ~config ~session_id ?operation_id ()
    |> Yojson.Safe.pretty_to_string
  in
  String.concat "\n"
    [
      "Summarize this team-session proof without exposing chain-of-thought.";
      "Report who collaborated, what evidence exists, and what is still missing.";
      "";
      proof_json;
    ]

let command_truth_text ~config ?operation_id ?run_id () =
  let summary = Cp_snapshot.summary_json config |> Yojson.Safe.pretty_to_string in
  let traces =
    Cp_snapshot.list_traces_json config ?operation_id ~limit:20 ()
    |> Yojson.Safe.pretty_to_string
  in
  String.concat "\n"
    [
      "Summarize the managed execution truth from the command-plane evidence below.";
      "Distinguish planned state from observed traces.";
      (match run_id with Some value -> "Focus run_id: " ^ value | None -> "");
      "";
      "Summary:";
      summary;
      "";
      "Recent traces:";
      traces;
    ]

let get_json ~config ~name ~arguments schemas =
  match lookup name with
  | None -> Error (Printf.sprintf "unknown prompt: %s" name)
  | Some prompt -> (
      let text_result =
        match name with
        | "tool_help" -> (
            match assoc_string arguments "tool_name" with
            | Some tool_name ->
                let focus = assoc_string arguments "focus" in
                tool_help_text ~tool_name ~focus schemas
            | None -> Error "tool_name is required")
        | "team_session_proof" -> (
            match assoc_string arguments "session_id" with
            | Some session_id ->
                let operation_id = assoc_string arguments "operation_id" in
                Ok (team_session_proof_text ~config ~session_id ~operation_id)
            | None -> Error "session_id is required")
        | "command_truth" ->
            let operation_id = assoc_string arguments "operation_id" in
            let run_id = assoc_string arguments "run_id" in
            Ok (command_truth_text ~config ?operation_id ?run_id ())
        | _ -> Error (Printf.sprintf "unsupported prompt: %s" name)
      in
      match text_result with
      | Error _ as err -> err
      | Ok text ->
          Ok
            (`Assoc
              [
                ("description", `String prompt.description);
                ("messages", `List [ message_json text ]);
              ]))
