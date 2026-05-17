module H = Masc_mcp.Cdal_runtime_health

let mkdir_p path =
  let rec loop current parts =
    match parts with
    | [] -> ()
    | part :: rest ->
      let next = if String.equal current "" then part else Filename.concat current part in
      (try Unix.mkdir next 0o755 with
       | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
      loop next rest
  in
  let parts = String.split_on_char '/' path |> List.filter (fun s -> not (String.equal s "")) in
  match Filename.is_relative path with
  | true -> loop "" parts
  | false -> loop "/" parts
;;

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then begin
      Array.iter (fun name -> rm_rf (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    end
    else Sys.remove path
;;

let with_temp_dir f =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-cdal-runtime-health-%06x" (Random.bits ()))
  in
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> try rm_rf dir with _ -> ()) (fun () -> f dir)
;;

let write_ledger_row ~base_dir ?mtime row =
  let month_dir = Filename.concat base_dir "2026-05" in
  mkdir_p month_dir;
  let path = Filename.concat month_dir "17.jsonl" in
  let oc = open_out_gen [ Open_creat; Open_text; Open_append ] 0o644 path in
  output_string oc (Yojson.Safe.to_string row ^ "\n");
  close_out oc;
  Option.iter (fun ts -> Unix.utimes path ts ts) mtime;
  path
;;

let make_proof_root ?mtime root =
  let proofs_dir = Filename.concat root "proofs" in
  mkdir_p proofs_dir;
  Option.iter (fun ts -> Unix.utimes proofs_dir ts ts) mtime;
  proofs_dir
;;

let member_string key json =
  match Yojson.Safe.Util.member key json with
  | `String value -> value
  | other ->
    Alcotest.failf
      "expected string field %s, got %s"
      key
      (Yojson.Safe.to_string other)
;;

let nested key json = Yojson.Safe.Util.member key json

let test_missing_writer_status () =
  with_temp_dir @@ fun dir ->
  let base_dir = Filename.concat dir "cdal_verdicts" in
  let proof_root = Filename.concat dir ".oas" in
  let json =
    H.snapshot_json
      ~base_dir
      ~proof_root
      ~now:1000.0
      ~stale_age_seconds:60.0
      ~recent_limit:20
      ()
  in
  Alcotest.(check string) "writer_status" "missing" (member_string "writer_status" json);
  Alcotest.(check string)
    "ledger status"
    "missing"
    (member_string "status" (nested "verdict_ledger" json))
;;

let test_missing_task_scope_status () =
  with_temp_dir @@ fun dir ->
  let base_dir = Filename.concat dir "cdal_verdicts" in
  let proof_root = Filename.concat dir ".oas" in
  ignore (write_ledger_row ~base_dir (`Assoc [ "run_id", `String "run-no-task" ]));
  ignore (make_proof_root proof_root);
  let json =
    H.snapshot_json
      ~base_dir
      ~proof_root
      ~now:(Time_compat.now ())
      ~stale_age_seconds:60.0
      ~recent_limit:20
      ()
  in
  Alcotest.(check string)
    "writer_status"
    "missing_task_scope"
    (member_string "writer_status" json);
  Alcotest.(check string)
    "task scope status"
    "missing_task_scope"
    (member_string "status" (nested "task_scope" json))
;;

let test_active_writer_status () =
  with_temp_dir @@ fun dir ->
  let base_dir = Filename.concat dir "cdal_verdicts" in
  let proof_root = Filename.concat dir ".oas" in
  ignore
    (write_ledger_row
       ~base_dir
       (`Assoc [ "_task_id", `String "task-15748"; "run_id", `String "run-task" ]));
  ignore (make_proof_root proof_root);
  let json =
    H.snapshot_json
      ~base_dir
      ~proof_root
      ~now:(Time_compat.now ())
      ~stale_age_seconds:60.0
      ~recent_limit:20
      ()
  in
  Alcotest.(check string) "writer_status" "active" (member_string "writer_status" json);
  Alcotest.(check string)
    "task scope status"
    "present"
    (member_string "status" (nested "task_scope" json))
;;

let test_dormant_writer_status () =
  with_temp_dir @@ fun dir ->
  let base_dir = Filename.concat dir "cdal_verdicts" in
  let proof_root = Filename.concat dir ".oas" in
  ignore
    (write_ledger_row
       ~base_dir
       ~mtime:100.0
       (`Assoc [ "_task_id", `String "task-old"; "run_id", `String "run-old" ]));
  ignore (make_proof_root ~mtime:100.0 proof_root);
  let json =
    H.snapshot_json
      ~base_dir
      ~proof_root
      ~now:1000.0
      ~stale_age_seconds:60.0
      ~recent_limit:20
      ()
  in
  Alcotest.(check string) "writer_status" "dormant" (member_string "writer_status" json);
  Alcotest.(check string)
    "ledger status"
    "dormant"
    (member_string "status" (nested "verdict_ledger" json))
;;

let () =
  Alcotest.run
    "cdal_runtime_health_15748"
    [ ( "writer_status"
      , [ Alcotest.test_case "missing" `Quick test_missing_writer_status
        ; Alcotest.test_case "missing task scope" `Quick test_missing_task_scope_status
        ; Alcotest.test_case "active" `Quick test_active_writer_status
        ; Alcotest.test_case "dormant" `Quick test_dormant_writer_status
        ] )
    ]
;;
