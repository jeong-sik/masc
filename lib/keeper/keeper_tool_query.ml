(** Keeper_tool_query - keeper tool retrieval query projection. *)

let tool_query_text_of_user_message (text : string) : string =
  let allowed_sections =
    [ "### Pending Mentions"
    ; "### Scope Messages"
    ; "### Namespace State"
    ; "### Board Activity"
    ; "### Live Worktree Delta"
    ]
  in
  let is_allowed_section section =
    List.exists
      (fun allowed -> String.starts_with ~prefix:allowed section)
      allowed_sections
  in
  let lines = String.split_on_char '\n' text in
  let rec loop current_section kept = function
    | [] ->
      let filtered = List.rev kept |> String.concat "\n" |> String.trim in
      if filtered <> "" then filtered else String.trim text
    | line :: rest ->
      let trimmed = String.trim line in
      let current_section =
        if String.starts_with ~prefix:"### " trimmed
        then Some trimmed
        else current_section
      in
      let keep_line =
        match current_section with
        | None -> String.starts_with ~prefix:"## Current World State" trimmed
        | Some section -> is_allowed_section section
      in
      if keep_line
      then loop current_section (line :: kept) rest
      else loop current_section kept rest
  in
  loop None [] lines
;;
