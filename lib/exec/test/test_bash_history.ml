open Alcotest

let remove_tree path =
  if Sys.file_exists path then ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote path)))
;;

let with_temp_dir f =
  let path = Filename.temp_file "bash-history" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  Fun.protect ~finally:(fun () -> remove_tree path) (fun () -> f path)
;;

let test_append_preserves_exact_command_and_status () =
  with_temp_dir (fun base_path ->
    let command = "printf '%s' 'literal | argv'" in
    let entry =
      Masc_exec.Bash_history.
        { ts = 42.0
        ; command
        ; duration_ms = 17
        ; status = process_status_of_unix (Unix.WEXITED 3)
        }
    in
    (match Masc_exec.Bash_history.append ~base_path ~keeper_name:"k" entry with
     | Ok () -> ()
     | Error exn -> fail (Printexc.to_string exn));
    let path =
      Filename.concat
        (Common.masc_dir_from_base_path ~base_path)
        "keeper/k/bash_history.jsonl"
    in
    let ic = open_in path in
    let json = Fun.protect ~finally:(fun () -> close_in ic) (fun () -> input_line ic) in
    let json = Yojson.Safe.from_string json in
    check string
      "command"
      command
      (Yojson.Safe.Util.member "command" json |> Yojson.Safe.Util.to_string);
    check string
      "status kind"
      "exit"
      (Yojson.Safe.Util.member "status" json
       |> Yojson.Safe.Util.member "kind"
       |> Yojson.Safe.Util.to_string);
    check int
      "exit code"
      3
      (Yojson.Safe.Util.member "status" json
       |> Yojson.Safe.Util.member "code"
       |> Yojson.Safe.Util.to_int))
;;

let () =
  run
    "bash_history"
    [ ( "append_only"
      , [ test_case "preserves command and status" `Quick test_append_preserves_exact_command_and_status ]
      )
    ]
;;
