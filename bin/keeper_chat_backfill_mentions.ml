(* Offline mention backfill for keeper chat lanes (RFC-0232 P4).

   Usage: keeper_chat_backfill_mentions [--base-path DIR] [--dry-run]

   Stamps the [mentions] field onto pre-P4 user rows whose content
   parses to mention ids.  Run while the masc server is stopped: a
   concurrent appender can lose lines to the read-rewrite-rename
   window. *)

let () =
  let base_path = ref "." in
  let dry_run = ref false in
  let spec =
    [
      ( "--base-path",
        Arg.Set_string base_path,
        "DIR workspace base path (default: current directory)" );
      ("--dry-run", Arg.Set dry_run, " report without rewriting");
    ]
  in
  Arg.parse spec
    (fun anon -> raise (Arg.Bad (Printf.sprintf "unexpected argument %S" anon)))
    "keeper_chat_backfill_mentions [--base-path DIR] [--dry-run]";
  let reports =
    Masc.Keeper_chat_backfill.backfill_base_path ~dry_run:!dry_run !base_path
  in
  if reports = [] then print_endline "no keeper chat lanes found"
  else (
    List.iter
      (fun (r : Masc.Keeper_chat_backfill.file_report) ->
        Printf.printf "%s: %d/%d line(s) %s\n" r.path r.rewritten
          r.total_lines
          (if !dry_run then "would be stamped" else "stamped"))
      reports;
    let total = List.fold_left (fun acc r -> acc + r.Masc.Keeper_chat_backfill.rewritten) 0 reports in
    Printf.printf "total: %d line(s) %s\n" total
      (if !dry_run then "would be stamped" else "stamped"))
