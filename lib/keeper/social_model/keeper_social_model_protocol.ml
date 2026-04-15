let parse_header_line line =
  match String.index_opt line ':' with
  | None -> None
  | Some idx ->
      let key = String.sub line 0 idx |> String.trim in
      let value =
        String.sub line (idx + 1) (String.length line - idx - 1) |> String.trim
      in
      if key = "" then None else Some (key, value)

let is_social_header_key = function
  | "SOCIAL_MODEL"
  | "BELIEF_SUMMARY"
  | "ACTIVE_DESIRE"
  | "CURRENT_INTENTION"
  | "BLOCKER"
  | "NEED"
  | "CLAIM_KIND"
  | "CLAIM_SUBJECT"
  | "CLAIM_TASK_ID"
  | "EVIDENCE_REFS"
  | "SPEECH_ACT"
  | "DELIVERY_SURFACE" ->
      true
  | _ -> false

let parse_header_block raw =
  let lines = String.split_on_char '\n' raw in
  let rec consume acc = function
    | line :: rest -> (
        match parse_header_line line with
        | Some (key, value) when is_social_header_key key ->
            consume ((key, value) :: acc) rest
        | _ -> (List.rev acc, line :: rest))
    | [] -> (List.rev acc, [])
  in
  let headers, body_lines = consume [] lines in
  (headers, String.concat "\n" body_lines |> String.trim)

let header_assoc_opt headers key =
  headers
  |> List.find_map (fun (header_key, value) ->
         if String.equal header_key key then Some value else None)

let nonempty_header_opt headers key =
  match header_assoc_opt headers key with
  | Some value -> (
      match String.lowercase_ascii (String.trim value) with
      | "" | "none" | "null" -> None
      | _ -> Some (String.trim value))
  | None -> None

let comma_list_header_opt headers key =
  match nonempty_header_opt headers key with
  | Some value ->
      value
      |> String.split_on_char ','
      |> List.map String.trim
      |> List.filter (fun item -> item <> "")
      |> List.sort_uniq String.compare
  | None -> []
