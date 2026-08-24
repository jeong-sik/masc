type row =
  | Family of {
      name : string;
      count : int;
    }
  | Tool of Masc.Tui_decode.tool_entry

let family_of name =
  match String.split_on_char '_' name with
  | first :: second :: _ :: _ -> Some (first ^ "_" ^ second)
  | _ -> None

(* A filter matches where an operator looks: the name, and the description
   the row does not show but the tool carries. Case-blind, substring, so
   [task] gathers the masc_task_* family, the family-less [masc_tasks] and
   [masc_transition] whose description says task, and keeper_task_* -- the
   tools spelling scattered, found anyway. *)
let matches ~filter (tool : Masc.Tui_decode.tool_entry) =
  let open Masc.Tui_decode in
  String.length filter = 0
  || String_util.contains_substring_ci tool.tl_name filter
     || String_util.contains_substring_ci tool.tl_description filter

let rows ?(filter = "") tools =
  let tools =
    if String.length filter = 0 then tools
    else List.filter (matches ~filter) tools
  in
  let counts = Hashtbl.create 32 in
  List.iter
    (fun (tool : Masc.Tui_decode.tool_entry) ->
      match family_of tool.Masc.Tui_decode.tl_name with
      | None -> ()
      | Some family ->
          Hashtbl.replace counts family
            (1 + Option.value ~default:0 (Hashtbl.find_opt counts family)))
    tools;
  (* A prefix one tool has is not a family; a heading over a single row says
     nothing the row does not. *)
  let family_of_tool (tool : Masc.Tui_decode.tool_entry) =
    match family_of tool.Masc.Tui_decode.tl_name with
    | Some family when Option.value ~default:0 (Hashtbl.find_opt counts family) >= 2
      -> Some family
    | Some _ | None -> None
  in
  let rec walk current acc = function
    | [] -> List.rev acc
    | tool :: rest -> (
        match family_of_tool tool with
        | Some family when current <> Some family ->
            let count = Option.value ~default:0 (Hashtbl.find_opt counts family) in
            walk (Some family) (Tool tool :: Family { name = family; count } :: acc) rest
        | Some family -> walk (Some family) (Tool tool :: acc) rest
        | None -> walk None (Tool tool :: acc) rest)
  in
  walk None [] tools

let tool_count rows =
  List.fold_left
    (fun total row -> match row with Tool _ -> total + 1 | Family _ -> total)
    0 rows
