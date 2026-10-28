(* route_auth_codemod [--write] [--strict] [--allow-early-evaluation] FILE...

   Rewrites the route registrations of each FILE to the typed form of
   Server_route (see route_auth_rewrite.mli). Without --write nothing is
   changed: each file gets a summary line, and every registration the tool leaves
   alone, or converts with an argument that is now evaluated once, gets a line
   with its position, path and the reason or the expression.

   Exit code: 0 on success, 1 when a file cannot be read, parsed or written,
   2 when --strict is given and a registration was left alone. *)

let usage = "route_auth_codemod [--write] [--strict] [--allow-early-evaluation] FILE..."
let exit_failure = 1
let exit_unhandled = 2

let read_file file =
  match In_channel.with_open_bin file In_channel.input_all with
  | source -> Ok source
  | exception Sys_error message -> Error message
;;

let write_file file text =
  match
    Out_channel.with_open_bin file (fun channel -> Out_channel.output_string channel text)
  with
  | () -> Ok ()
  | exception Sys_error message -> Error message
;;

let process ~write ~early file =
  let ( let* ) = Result.bind in
  let* source = read_file file in
  let* rewritten, report = Route_auth_rewrite.rewrite ~early ~file source in
  let* () =
    if write && not (String.equal rewritten source)
    then write_file file rewritten
    else Ok ()
  in
  Ok report
;;

let print_report file (report : Route_auth_rewrite.report) =
  Printf.printf
    "%s: converted %d, left alone %d, evaluated once %d\n"
    file
    report.converted
    (List.length report.unhandled)
    (List.length report.early);
  let print_sites label (sites : Route_auth_rewrite.site list) =
    List.iter
      (fun (site : Route_auth_rewrite.site) ->
        Printf.printf "%s:%d\t%s\t%s: %s\n" file site.line site.path label site.note)
      sites
  in
  print_sites "left alone" report.unhandled;
  print_sites "evaluated once" report.early
;;

let () =
  let write = ref false in
  let strict = ref false in
  let early = ref false in
  let files = ref [] in
  Arg.parse
    [ "--write", Arg.Set write, " rewrite the files in place"
    ; "--strict", Arg.Set strict, " exit with 2 when a registration is left alone"
    ; ( "--allow-early-evaluation"
      , Arg.Set early
      , " convert registrations whose ~permission or ~tool_name is computed, and list them"
      )
    ]
    (fun file -> files := file :: !files)
    usage;
  let files = List.rev !files in
  if files = []
  then (
    prerr_endline usage;
    exit exit_failure);
  let failed = ref false in
  let converted = ref 0 in
  let left_alone = ref 0 in
  let evaluated_once = ref 0 in
  List.iter
    (fun file ->
      match process ~write:!write ~early:!early file with
      | Ok report ->
        converted := !converted + report.converted;
        left_alone := !left_alone + List.length report.unhandled;
        evaluated_once := !evaluated_once + List.length report.early;
        print_report file report
      | Error message ->
        failed := true;
        prerr_endline message)
    files;
  Printf.printf
    "total: converted %d, left alone %d, evaluated once %d, in %d files\n"
    !converted
    !left_alone
    !evaluated_once
    (List.length files);
  if !failed
  then exit exit_failure
  else if !strict && !left_alone > 0
  then exit exit_unhandled
;;
