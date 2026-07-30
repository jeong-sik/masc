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
  match Keeper_metrics_record.kind_of_json json with
  | Some Keeper_metrics_record.Turn ->
      Json_util.get_string_list json "tools_used"
  | Some Keeper_metrics_record.Heartbeat | None -> []
;;

let collect_recent_tool_names ?(limit = 8) (lines : string list) =
  let parsed, _ =
    Fs_compat.parse_jsonl_lines
      ~source:"operator_tool_audit_keeper_metrics"
      lines
  in
  let ordered = List.rev parsed in
  let rec loop acc remaining = function
    | _ when remaining <= 0 -> List.rev acc
    | [] -> List.rev acc
    | json :: rest ->
        let tools = tool_names_of_recent_json json in
        let merged = merge_tool_name_lists (List.rev acc) tools in
        let capped =
          if List.length merged <= limit
          then merged
          else List.filteri (fun idx _ -> idx < limit) merged
        in
        loop (List.rev capped) (limit - List.length capped) rest
  in
  loop [] limit ordered
;;
