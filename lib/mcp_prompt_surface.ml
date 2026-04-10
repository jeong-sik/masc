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
  icons : Mcp_server.mcp_icon list;
}

let prompt_defs =
  [
    {
      name = "tool_help";
      title = "Tool Help";
      description = "Compose a grounded explanation for a specific MASC MCP tool.";
      icons = [ Mcp_server.themed_icon ~label:"TH" ~bg:"#1D4ED8" ~fg:"#EFF6FF" ];
      arguments =
        [
          { name = "tool_name"; description = "Exact MCP tool name"; required = true };
          { name = "focus"; description = "Optional question or emphasis"; required = false };
        ];
    };
    {
      name = "team_session_proof";
      title = "Execution Session Proof";
      description = "Summarize auditable collaboration evidence for an execution session (deprecated: team session layer removed).";
      icons = [ Mcp_server.themed_icon ~label:"TP" ~bg:"#7C3AED" ~fg:"#F5F3FF" ];
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
      icons = [ Mcp_server.themed_icon ~label:"CT" ~bg:"#9A3412" ~fg:"#FFF7ED" ];
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
      ("icons", `List (List.map Mcp_server.icon_to_json prompt.icons));
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

let string_contains = Dashboard_utils.string_contains
let string_contains_ci = Dashboard_utils.string_contains_ci

let run_tokens run_id =
  let safe = Room_utils.safe_filename run_id |> String.lowercase_ascii in
  [ run_id; safe; "run_id=" ^ run_id; "run_id=" ^ safe; "swarm-live:" ^ run_id; "swarm-live:" ^ safe ]

let rec json_contains_run_tokens tokens = function
  | `String value -> List.exists (fun token -> string_contains_ci ~needle:token value) tokens
  | `Assoc fields -> List.exists (fun (_, value) -> json_contains_run_tokens tokens value) fields
  | `List items -> List.exists (json_contains_run_tokens tokens) items
  | _ -> false

let filter_traces_json_by_run_id run_id = function
  | `Assoc fields as json -> (
      match List.assoc_opt "events" fields with
      | Some (`List events) ->
          let filtered =
            events
            |> List.filter (json_contains_run_tokens (run_tokens run_id))
          in
          `Assoc (("events", `List filtered) :: List.remove_assoc "events" fields)
      | _ -> json)
  | json -> json

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

let team_session_proof_text ~config:_ ~session_id ~operation_id:_ =
  (* Dashboard_proof removed *)
  String.concat "\n"
    [
      "Team session proof is not available (team session layer removed).";
      Printf.sprintf "Session: %s" session_id;
    ]

let command_truth_text ~config ?operation_id ?run_id () =
  let summary_json =
    match run_id with
    | Some value ->
        `Assoc
          [
            ("scope", `String "run");
            ("run_id", `String value);
            ("operation_id", Json_util.string_opt_to_json operation_id);
            ("traces_filtered", `Bool true);
          ]
    | None -> Cp_snapshot.summary_json config
  in
  let summary = summary_json |> Yojson.Safe.pretty_to_string in
  let traces_json = Cp_snapshot.list_traces_json config ?operation_id ~limit:20 () in
  let traces =
    (match run_id with
    | Some value -> filter_traces_json_by_run_id value traces_json
    | None -> traces_json)
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
