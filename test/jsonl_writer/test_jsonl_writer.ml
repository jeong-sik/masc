open Alcotest

let unique_temp_dir prefix =
  let base = Filename.get_temp_dir_name () in
  let suffix = Printf.sprintf "%s_%d_%d" prefix (Unix.getpid ()) (Random.bits ()) in
  let dir = Filename.concat base suffix in
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm_rf path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path
        |> Array.iter (fun name -> rm_rf (Filename.concat path name));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  try rm_rf dir with
  | _ -> ()

let read_lines path =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
    let rec loop acc =
      match input_line ic with
      | line -> loop (line :: acc)
      | exception End_of_file -> List.rev acc
    in
    loop [])

let test_utc_calendar_day_at_the_epoch () =
  check
    (triple int int int)
    "1970-01-01"
    (1970, 1, 1)
    (Jsonl_writer.utc_calendar_day ~ts:0.0)

let test_append_jsonl_writes_one_parseable_row () =
  let dir = unique_temp_dir "jsonl_writer_append" in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () ->
    let path = Filename.concat dir "rows.jsonl" in
    Jsonl_writer.append_jsonl ~path (`Assoc [ "kind", `String "adapter"; "n", `Int 1 ]);
    let lines = read_lines path in
    check int "one row" 1 (List.length lines);
    match lines with
    | [ line ] ->
      let json = Yojson.Safe.from_string line in
      check bool "round-trip"
        true
        (Yojson.Safe.equal
           (`Assoc [ "kind", `String "adapter"; "n", `Int 1 ])
           json)
    | _ -> fail "expected exactly one JSONL row")

let () =
  Random.self_init ();
  run
    "Jsonl_writer"
    [
      ( "writer",
        [ test_case "the UTC calendar day at the epoch" `Quick
            test_utc_calendar_day_at_the_epoch
        ; test_case "append_jsonl writes one parseable row" `Quick
            test_append_jsonl_writes_one_parseable_row
        ] );
    ]
