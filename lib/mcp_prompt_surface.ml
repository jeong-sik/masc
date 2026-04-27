(** MCP prompt surface for canonical help. *)

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

let get_json ~config:_ ~name ~arguments schemas =
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
