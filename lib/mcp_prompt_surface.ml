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

(* The catalogue prose (names, titles, descriptions, argument prose) lives in
   config/mcp/prompts.toml, decoded once at module init by
   [Mcp_surface_toml]. Icons stay here: they are generated SVG data, not
   prose — one themed badge per prompt name. *)
let icons_of_prompt_name = function
  | "tool_help" ->
    [ Mcp_server.themed_icon ~label:"TH" ~bg:"#1D4ED8" ~fg:"#EFF6FF" ]
  | _ -> []

let prompt_def_of_entry (entry : Mcp_surface_toml.prompt_entry) : prompt_def =
  {
    name = entry.prompt_name;
    title = entry.prompt_title;
    description = entry.prompt_description;
    icons = icons_of_prompt_name entry.prompt_name;
    arguments =
      List.map
        (fun (arg : Mcp_surface_toml.prompt_argument) ->
          {
            name = arg.argument_name;
            description = arg.argument_description;
            required = arg.argument_required;
          })
        entry.prompt_arguments;
  }

let prompt_defs = List.map prompt_def_of_entry Mcp_surface_toml.prompts

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

(* The body wording renders through the prompt registry at prompts/get time
   from config/prompts/mcp.tool_help.md; the condition (which rows, which
   order) stays here. A render failure logs and falls back to the bare data —
   the keeper.world event_rows precedent: losing the wording is recoverable,
   losing the fact is not. The loader trims slot paragraphs, so the joins
   below own the separating newlines, and the rendered text is used verbatim:
   a [String.trim] here would eat edge whitespace that is part of the
   substituted data (details_markdown), not of the template. *)
let slot_text key vars ~fallback =
  match Prompt_registry.render_prompt_template key vars with
  | Ok text -> text
  | Error detail ->
      Log.Misc.warn "mcp tool_help prompt %s did not render: %s" key detail;
      fallback

let tool_help_text ~tool_name ~focus schemas =
  match Tool_help_registry.find_entry schemas tool_name with
  | None -> Error (Printf.sprintf "unknown tool: %s" tool_name)
  | Some entry ->
      let focus_lines =
        match focus with
        | Some value ->
            [
              slot_text Prompt_names.mcp_tool_help_focus_row
                [ ("focus", value) ]
                ~fallback:value;
              "";
            ]
        | None -> []
      in
      let docs_lines =
        if entry.doc_refs = [] then []
        else
          ""
          :: slot_text Prompt_names.mcp_tool_help_docs_heading [] ~fallback:""
          :: List.map
               (fun item ->
                 slot_text Prompt_names.mcp_tool_help_doc_ref_row
                   [ ("item", item) ]
                   ~fallback:item)
               entry.doc_refs
      in
      Ok
        (String.concat "\n"
           ([
              slot_text Prompt_names.mcp_tool_help_intro [] ~fallback:"";
              "";
            ]
           @ focus_lines
           @ [
               slot_text Prompt_names.mcp_tool_help_tool_section
                 [
                   ("name", entry.name);
                   ("short_description", entry.short_description);
                   ("when_to_use", entry.when_to_use);
                 ]
                 ~fallback:
                   (String.concat
                      "\n"
                      [
                        entry.name;
                        entry.short_description;
                        entry.when_to_use;
                      ]);
             ]
           @ List.map
               (fun item ->
                 slot_text Prompt_names.mcp_tool_help_constraint_row
                   [ ("item", item) ]
                   ~fallback:item)
               entry.key_constraints
           @ [
               "";
               slot_text Prompt_names.mcp_tool_help_details_section
                 [ ("details_markdown", entry.details_markdown) ]
                 ~fallback:entry.details_markdown;
             ]
           @ docs_lines))

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
