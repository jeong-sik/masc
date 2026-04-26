type t =
  | Mechanical
  | Cognitive

let equal a b =
  match a, b with
  | Mechanical, Mechanical | Cognitive, Cognitive -> true
  | _ -> false
;;

let to_string = function
  | Mechanical -> "mechanical"
  | Cognitive -> "cognitive"
;;

(* Mechanical tools: predictable-shape dispatch, no open-ended reasoning needed.
   When a keeper turn invokes only tools in this set, skipping thinking is safe
   and saves ~50% wall-clock per empirical measurements on qwen3.5-35b-a3b.

   Future: move to attribute on Tool_dispatch registry entries
   (is_mechanical : bool) so categorization lives next to the tool definition
   instead of being duplicated here. *)
let mechanical_tools =
  [ "board_list"
  ; "board_show"
  ; "board_comment"
  ; "task_claim"
  ; "task_update"
  ; "task_done"
  ; "fs_read"
  ; "fs_list"
  ; "grep"
  ; "shell"
  ; "agent_timeline"
  ; "heartbeat"
  ; "stay_silent"
  ; "context_status"
  ; "tool_search"
  ]
;;

let mechanical_set =
  List.fold_left (fun s t -> s |> fun acc -> t :: acc) [] mechanical_tools
  |> List.sort_uniq String.compare
;;

let is_mechanical name = List.exists (fun m -> String.equal m name) mechanical_set

(* Keywords whose presence in the last user/system message signals a cognitive
   turn. Matches against lowercased substrings to handle "plan this" /
   "why did that fail" / "explain the error" forms. *)
let cognitive_keywords =
  [ "plan"; "why"; "explain"; "critique"; "design"; "debug"; "decide"; "rethink" ]
;;

let contains_keyword ~haystack ~needle =
  let h = String.lowercase_ascii haystack in
  let n = String.lowercase_ascii needle in
  let hlen = String.length h
  and nlen = String.length n in
  if nlen = 0 || nlen > hlen
  then false
  else (
    let rec scan i =
      if i + nlen > hlen
      then false
      else if String.sub h i nlen = n
      then true
      else scan (i + 1)
    in
    scan 0)
;;

let message_is_cognitive = function
  | None -> false
  | Some msg ->
    List.exists (fun kw -> contains_keyword ~haystack:msg ~needle:kw) cognitive_keywords
;;

let classify ~last_tool_calls ~last_user_message ~retry_count =
  if retry_count > 0
  then Cognitive
  else if message_is_cognitive last_user_message
  then Cognitive
  else (
    match last_tool_calls with
    | [] ->
      (* Idle/stuck keeper — allow thinking to break out of the null turn. *)
      Cognitive
    | _ -> if List.for_all is_mechanical last_tool_calls then Mechanical else Cognitive)
;;
