(** Tool-name extraction + dedupe helpers for operator control snapshot,
    extracted from operator_control_snapshot.ml.

    Pure JSON/string helpers used to surface the recent tools a keeper
    has called in the operator's "recent" view. *)

let merge_tool_name_lists primary secondary =
  let seen = Hashtbl.create 16 in
  let add acc raw_name =
    let name = String.trim raw_name in
    if name = "" || Hashtbl.mem seen name
    then acc
    else (
      Hashtbl.replace seen name ();
      name :: acc)
  in
  List.rev (List.fold_left add [] (List.concat [ primary; secondary ]))
;;

let tool_names_of_recent_json (json : Yojson.Safe.t) =
  let tools_used = Json_util.get_string_list json "tools_used" in
  let single_tool =
    match Json_util.get_string json "tool" with
    | Some value when String.trim value <> "" -> [ value ]
    | _ -> []
  in
  merge_tool_name_lists single_tool tools_used
;;

type recent_tool_name_parse_error =
  { line_index : int
  ; message : string
  }

let recent_tool_name_parse_error_to_json ~source ?keeper ?path
      { line_index; message }
  =
  `Assoc
    ([
       "source", `String source;
       "line_index", `Int line_index;
       "message", `String message;
     ]
     @ (match keeper with
        | Some keeper_name -> [ "keeper", `String keeper_name ]
        | None -> [])
     @
     match path with
     | Some source_path -> [ "path", `String source_path ]
     | None -> [])
;;

let parse_recent_tool_line line_index line =
  match Yojson.Safe.from_string line with
  | `Assoc _ as json -> Ok json
  | other ->
    Error
      { line_index
      ; message =
          Printf.sprintf
            "operator tool-audit JSONL row must be object, got %s"
            (Json_util.kind_name other)
      }
  | exception Yojson.Json_error message -> Error { line_index; message }
;;

let collect_recent_tool_names_with_errors ?(limit = 8) (lines : string list) =
  let ordered =
    lines
    |> List.mapi (fun line_index line -> line_index, line)
    |> List.rev
  in
  let rec loop acc errors remaining = function
    | [] -> List.rev acc, List.rev errors
    | (line_index, line) :: rest ->
      (match parse_recent_tool_line line_index line with
       | Ok json ->
         if remaining <= 0
         then loop acc errors remaining rest
         else (
           let tools = tool_names_of_recent_json json in
           let merged = merge_tool_name_lists (List.rev acc) tools in
           let capped =
             if List.length merged <= limit
             then merged
             else List.filteri (fun idx _ -> idx < limit) merged
           in
           loop (List.rev capped) errors (limit - List.length capped) rest)
       | Error error -> loop acc (error :: errors) remaining rest)
  in
  loop [] [] limit ordered
;;

let collect_recent_tool_names ?(limit = 8) (lines : string list) =
  fst (collect_recent_tool_names_with_errors ~limit lines)
;;
