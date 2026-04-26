(** Prompt_composer — structured prompt assembly from typed sections.
    @since 3.0.0 *)

type section =
  | Identity of
      { name : string
      ; role : string
      ; model : string
      }
  | TeamContext of Team_context.team_context
  | AvailableTools of string list
  | Guidelines of string list
  | Task of string
  | FreeText of string

let render_section = function
  | Identity { name; role; model } ->
    Printf.sprintf "Agent: %s | Role: %s | Model: %s" name role model
  | TeamContext ctx -> Team_context.to_prompt_section ctx
  | AvailableTools tools ->
    if tools = []
    then ""
    else (
      let tool_list = tools |> List.map (fun name -> "- " ^ name) |> String.concat "\n" in
      Printf.sprintf "Available tools (use masc_tool_help for details):\n%s" tool_list)
  | Guidelines items ->
    if items = []
    then ""
    else (
      let numbered = List.mapi (fun i g -> Printf.sprintf "%d. %s" (i + 1) g) items in
      "Guidelines:\n" ^ String.concat "\n" numbered)
  | Task text -> if text = "" then "" else "Task:\n" ^ text
  | FreeText text -> text
;;

let compose sections =
  sections
  |> List.map render_section
  |> List.filter (fun s -> String.trim s <> "")
  |> String.concat "\n\n"
;;
