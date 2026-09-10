let () =
  let argv = Array.to_list Sys.argv |> List.tl in
  let result = Masc.Prerequisite_terminal_runner.capture argv in
  let reaped = try ignore (Unix.waitpid [Unix.WNOHANG] (-1)); false
    with Unix.Unix_error (Unix.ECHILD, _, _) -> true in
  if not reaped then exit 42;
  match result with Ok output -> print_string output | Error () -> exit 1
