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

(* The walk stops as soon as [limit] names are collected, which the newest
   rows usually supply, but every row in the window used to be parsed before
   the walk began. Measured 2026-09-07 on a live server: those trees were
   4.40 GB, 5.3% of the process's allocation, and the caller hands in 120
   rows per Keeper on every operator snapshot.

   Rows are now parsed one at a time, newest first, and a row the walk never
   reaches is never parsed. A malformed row it does reach still warns exactly
   as before - same message, same printed row number - because
   [Fs_compat.parse_jsonl_line] is what the whole-window parse uses too. A
   malformed row past the stopping point no longer warns; this function
   reports the recent tool names and is not the ledger's validator. *)
let collect_recent_tool_names ?(limit = 8) (lines : string list) =
  let newest_first = List.rev (Fs_compat.number_jsonl_lines lines) in
  let rec loop acc remaining = function
    | _ when remaining <= 0 -> List.rev acc
    | [] -> List.rev acc
    | (line_no, row) :: rest ->
        let tools =
          match
            Fs_compat.parse_jsonl_line
              ~source:"operator_tool_audit_keeper_metrics"
              ~line_no
              row
          with
          | Some json -> tool_names_of_recent_json json
          | None -> []
        in
        let merged = merge_tool_name_lists (List.rev acc) tools in
        let capped =
          if List.length merged <= limit
          then merged
          else List.filteri (fun idx _ -> idx < limit) merged
        in
        loop (List.rev capped) (limit - List.length capped) rest
  in
  loop [] limit newest_first
;;
