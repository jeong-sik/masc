(** Tool-name extraction + dedupe helpers for operator control snapshot,
    extracted from operator_control_snapshot.ml.

    Pure JSON/string helpers used to surface the recent tools a keeper
    has called in the operator's "recent" view. *)

module U = Yojson.Safe.Util

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
  let tools_used =
    match U.member "tools_used" json with
    | `List items ->
      List.filter_map
        (function
          | `String value ->
            let trimmed = String.trim value in
            if trimmed = "" then None else Some trimmed
          | _ -> None)
        items
    | _ -> []
  in
  let single_tool =
    match U.member "tool" json with
    | `String value ->
      let trimmed = String.trim value in
      if trimmed = "" then [] else [ trimmed ]
    | _ -> []
  in
  merge_tool_name_lists single_tool tools_used
;;

let collect_recent_tool_names ?(limit = 8) (lines : string list) =
  let ordered = List.rev lines in
  let rec loop acc remaining = function
    | _ when remaining <= 0 -> List.rev acc
    | [] -> List.rev acc
    | line :: rest ->
      (try
         let json = Yojson.Safe.from_string line in
         let tools = tool_names_of_recent_json json in
         let merged = merge_tool_name_lists (List.rev acc) tools in
         let capped =
           if List.length merged <= limit
           then merged
           else List.filteri (fun idx _ -> idx < limit) merged
         in
         loop (List.rev capped) (limit - List.length capped) rest
       with
       | Yojson.Json_error _ -> loop acc remaining rest)
  in
  loop [] limit ordered
;;

