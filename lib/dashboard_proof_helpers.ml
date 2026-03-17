(** Dashboard proof helpers — shared types and utility functions for
    evidence-first collaboration proof projection. *)

module U = Yojson.Safe.Util

type actor_acc = {
  actor : string;
  role : string option;
  mutable observed_event_count : int;
  mutable turn_count : int;
  mutable spawn_count : int;
  mutable tool_evidence_count : int;
  mutable interaction_count : int;
  mutable mention_count : int;
  mutable recent_input_preview : string option;
  mutable recent_output_preview : string option;
  mutable recent_event_summary : string option;
  mutable recent_tool_names : string list;
  mutable last_active_at : string option;
  mutable requested_by : string option;
  mutable recent_request_preview : string option;
  mutable recent_request_at : string option;
}

let option_or_else fallback opt =
  match opt with Some _ -> opt | None -> fallback ()

let option_first_some left right =
  match left with Some _ -> left | None -> right

let option_prefer_new current newer =
  match newer with Some _ -> newer | None -> current

let option_non_empty_trimmed = function
  | Some value ->
      let trimmed = String.trim value in
      if trimmed = "" then None else Some trimmed
  | None -> None

let truncate_preview ?(max_len = 160) text =
  let text =
    text
    |> String.split_on_char '\n'
    |> List.map String.trim
    |> List.filter (fun chunk -> chunk <> "")
    |> String.concat " "
  in
  if String.length text <= max_len then text else String.sub text 0 (max_len - 1) ^ "\xe2\x80\xa6"

let string_field key json =
  match U.member key json with
  | `String value ->
      let trimmed = String.trim value in
      if trimmed = "" then None else Some trimmed
  | _ -> None

let list_of_strings key json =
  match U.member key json with
  | `List items ->
      items
      |> List.filter_map (function
           | `String value ->
               let trimmed = String.trim value in
               if trimmed = "" then None else Some trimmed
           | _ -> None)
  | _ -> []

let unique_non_empty_strings values =
  let table = Hashtbl.create 16 in
  values
  |> List.filter (fun value ->
         let trimmed = String.trim value in
         if trimmed = "" then
           false
         else if Hashtbl.mem table trimmed then
           false
         else (
           Hashtbl.add table trimmed ();
           true))

let detail_of_event json =
  match U.member "detail" json with
  | `Assoc _ as detail -> detail
  | _ -> `Assoc []
