open Alcotest

open Masc

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let test_meta_of_json_survives_deleted_cwd () =
  with_temp_dir "keeper-meta-cwd" @@ fun root ->
  let parent = Filename.concat root "parent" in
  let doomed = Filename.concat parent "doomed" in
  Unix.mkdir parent 0o755;
  Unix.mkdir doomed 0o755;
  let saved_cwd = Sys.getcwd () in
  Unix.chdir doomed;
  Fun.protect
    ~finally:(fun () -> Unix.chdir saved_cwd)
    (fun () ->
      Unix.rmdir (Filename.concat parent "doomed");
      let json =
        `Assoc
          [
            ("name", `String "sangsu");
            ("trace_id", `String "trace-sangsu-live");
          ]
      in
      match Masc_test_deps.meta_of_json_fixture json with
      | Ok meta -> check string "keeper name" "sangsu" meta.name
      | Error err -> fail ("meta_of_json failed under deleted cwd: " ^ err))

let () =
  run "Keeper meta cwd resilience"
    [
      ("meta_of_json", [ test_case "deleted cwd does not break parsing" `Quick test_meta_of_json_survives_deleted_cwd ]);
    ]
