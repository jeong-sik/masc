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

let lookup name =
  List.find_opt (fun (prompt : prompt_def) -> String.equal prompt.name name) prompt_defs

let assoc_string args key =
  match Json_util.assoc_member_opt key args with
  | Some (`String value) ->
      let trimmed = String.trim value in
      if trimmed = "" then None else Some trimmed
  | _ -> None

let message_json text =
  `Assoc
    [
      ("role", `String "user");
      ("content", `Assoc [ ("type", `String "text"); ("text", `String text) ]);
    ]

(* The instruction wording lives in the mcp.tool_help template; this function
   only pre-renders the grounded fields as data strings. A template that does
   not render is logged and falls back to the bare data, never to prose
   written here. *)
let tool_help_text ~tool_name ~focus schemas =
  match Tool_help_registry.find_entry schemas tool_name with
  | None -> Error (Printf.sprintf "unknown tool: %s" tool_name)
  | Some entry ->
    let bullet_lines items =
      String.concat "\n" (List.map (fun item -> "- " ^ item) items)
    in
    let focus_section =
      match focus with
      | Some value -> "Focus: " ^ value ^ "\n\n"
      | None -> ""
    in
    let docs_section =
      if entry.doc_refs = [] then "" else "\n\nDocs:\n" ^ bullet_lines entry.doc_refs
    in
    let key_constraints =
      (* The blank line before "Details:" rides on this variable so an empty
         constraint list does not leave a doubled blank line. *)
      match entry.key_constraints with
      | [] -> ""
      | items -> bullet_lines items ^ "\n"
    in
    let vars =
      [ "focus_section", focus_section
      ; "tool_name", entry.name
      ; "short_description", entry.short_description
      ; "when_to_use", entry.when_to_use
      ; "key_constraints", key_constraints
      ; "details_markdown", entry.details_markdown
      ; "docs_section", docs_section
      ]
    in
    (match Prompt_registry.render_prompt_template Prompt_names.mcp_tool_help vars with
     | Ok text ->
       (* The trim cancels the template file's trailing newline. It would also
          strip a details_markdown value ending in whitespace when no docs
          follow it; no current registry entry has one, so this stays latent. *)
       Ok (String.trim text)
     | Error detail ->
       Log.Misc.error
         "mcp tool_help prompt %s did not render, falling back to the bare data: %s"
         Prompt_names.mcp_tool_help
         detail;
       Ok
         (String.concat
            "\n"
            ((match focus with
              | Some value -> [ "Focus: " ^ value ]
              | None -> [])
             @ [ "Tool: " ^ entry.name
               ; entry.short_description
               ; entry.when_to_use
               ; bullet_lines entry.key_constraints
               ; entry.details_markdown
               ]
             @
             if entry.doc_refs = []
             then []
             else "Docs:" :: List.map (fun item -> "- " ^ item) entry.doc_refs)))
;;

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
