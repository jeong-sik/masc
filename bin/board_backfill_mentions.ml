(* Offline board mention-id backfill.

   Usage: board_backfill_mentions [--base-path DIR] [--dry-run]

   Run while the masc server is stopped. *)

module Backfill = Masc_board_handlers.Board_mention_backfill

let print_report dry_run (report : Backfill.file_report) =
  Printf.printf "%s (%s): %d/%d line(s) %s\n" report.path
    (Backfill.target_to_string report.target)
    report.rewritten report.total_lines
    (if dry_run then "would be stamped" else "stamped")
;;

let print_error (error : Backfill.file_error) =
  let location =
    if error.line_no <= 0
    then error.path
    else Printf.sprintf "%s:%d" error.path error.line_no
  in
  Printf.eprintf "%s: %s\n" location error.message
;;

let () =
  let base_path = ref "." in
  let dry_run = ref false in
  let spec =
    [ ( "--base-path"
      , Arg.Set_string base_path
      , "DIR workspace base path (default: current directory)" )
    ; "--dry-run", Arg.Set dry_run, " report without rewriting"
    ]
  in
  Arg.parse spec
    (fun anon -> raise (Arg.Bad (Printf.sprintf "unexpected argument %S" anon)))
    "board_backfill_mentions [--base-path DIR] [--dry-run]";
  match Backfill.backfill_base_path ~dry_run:!dry_run !base_path with
  | Ok [] -> print_endline "no board JSONL files found"
  | Ok reports ->
    List.iter (print_report !dry_run) reports;
    let total =
      List.fold_left
        (fun acc (report : Backfill.file_report) -> acc + report.rewritten)
        0 reports
    in
    Printf.printf "total: %d line(s) %s\n" total
      (if !dry_run then "would be stamped" else "stamped")
  | Error errors ->
    List.iter print_error errors;
    exit 1
;;
