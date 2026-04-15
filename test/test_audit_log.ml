open Alcotest
open Masc_mcp

let temp_dir () =
  let dir = Filename.temp_file "test_audit_log_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else
        Unix.unlink path
  in
  try rm dir with _ -> ()

let assoc_key_count key = function
  | `Assoc fields ->
      List.length (List.filter (fun (field, _) -> String.equal field key) fields)
  | _ -> 0

let test_system_internal_details_deduplicate_canonical_keys () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      Audit_log.log_system_internal_tool_call config ~agent_id:"codex"
        ~tool_name:"masc_status" ~success:true ~error_msg:None
        ~details:
          (`Assoc
             [
               ("surface", `String "overridden");
               ("tool_name", `String "wrong_name");
               ("source", `String "unit_test");
             ])
        ();
      let entry =
        match Audit_log.read_entries ~n:10 config with
        | [ entry ] -> entry
        | _ -> fail "expected one audit entry"
      in
      check string "canonical surface wins" "system_internal"
        Yojson.Safe.Util.(entry.details |> member "surface" |> to_string);
      check string "canonical tool name wins" "masc_status"
        Yojson.Safe.Util.(entry.details |> member "tool_name" |> to_string);
      check int "surface appears once" 1 (assoc_key_count "surface" entry.details);
      check int "tool_name appears once" 1
        (assoc_key_count "tool_name" entry.details);
      check string "keeps non-canonical fields" "unit_test"
        Yojson.Safe.Util.(entry.details |> member "source" |> to_string))

let () =
  run "Audit_log"
    [
      ( "audit_log",
        [
          test_case "system_internal details deduplicate canonical keys" `Quick
            test_system_internal_details_deduplicate_canonical_keys;
        ] );
    ]
