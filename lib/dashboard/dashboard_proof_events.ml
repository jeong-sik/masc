(** Dashboard proof events — event parsing functions for evidence-first
    collaboration proof projection. *)

include Dashboard_proof_helpers

let event_actor json =
  let detail = detail_of_event json in
  match string_field "actor" detail with
  | Some actor -> Some actor
  | None ->
      string_field "runtime_actor" detail
      |> option_or_else (fun () -> string_field "agent" detail)

let event_related_actor json =
  let detail = detail_of_event json in
  string_field "runtime_actor" detail
  |> option_or_else (fun () -> string_field "supervisor_actor" detail)
  |> option_or_else (fun () -> string_field "target_actor" detail)

let event_summary json =
  let detail = detail_of_event json in
  let candidates =
    [
      string_field "message" detail;
      string_field "summary" detail;
      string_field "title" detail;
      string_field "reason" detail;
      string_field "result" detail;
      string_field "output_preview" detail;
      string_field "content" detail;
      string_field "task_description" detail;
      string_field "goal" detail;
      string_field "vote_topic" detail;
    ]
  in
  match List.find_opt Option.is_some candidates with
  | Some (Some value) -> truncate_preview value
  | _ ->
      string_field "event_type" json
      |> Option.value ~default:"event"

let event_input_preview json =
  let detail = detail_of_event json in
  let candidates =
    [
      string_field "task_description" detail;
      string_field "goal" detail;
      string_field "vote_topic" detail;
      string_field "reason" detail;
      string_field "title" detail;
    ]
  in
  match List.find_opt Option.is_some candidates with
  | Some (Some value) -> Some (truncate_preview value)
  | _ -> None

let event_output_preview json =
  let detail = detail_of_event json in
  let candidates =
    [
      string_field "message" detail;
      string_field "summary" detail;
      string_field "content" detail;
      string_field "result" detail;
      string_field "output_preview" detail;
    ]
  in
  match List.find_opt Option.is_some candidates with
  | Some (Some value) -> Some (truncate_preview value)
  | _ -> None

let event_tool_names json =
  let detail = detail_of_event json in
  let plural = list_of_strings "tool_names" detail in
  if plural <> [] then plural
  else
    match string_field "tool_name" detail with
    | Some value -> [ value ]
    | None -> []

let is_mention_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' -> true
  | _ -> false

let mention_names_of_text text =
  let len = String.length text in
  let rec scan idx acc =
    if idx >= len then
      List.rev acc
    else if Char.equal text.[idx] '@' then
      let start = idx + 1 in
      let rec advance j =
        if j < len && is_mention_char text.[j] then advance (j + 1) else j
      in
      let stop = advance start in
      if stop > start then
        scan stop (String.sub text start (stop - start) :: acc)
      else
        scan (idx + 1) acc
    else
      scan (idx + 1) acc
  in
  scan 0 [] |> unique_non_empty_strings

let mentioned_actors_of_event json =
  let detail = detail_of_event json in
  let texts =
    [
      string_field "message" detail;
      string_field "summary" detail;
      string_field "content" detail;
      string_field "title" detail;
      string_field "task_description" detail;
    ]
  in
  texts
  |> List.filter_map Fun.id
  |> List.concat_map mention_names_of_text
  |> unique_non_empty_strings
