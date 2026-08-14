(* Feature: a keeper reads files inside its sandbox through
   [handle_owned_read_file_with_outcome] using the natural cwd spellings a
   model produces. [cwd:"."] names the ownership root itself and must
   resolve, not be rejected as an escape; [cwd:".."] genuinely leaves the
   root and must stay rejected. Live failure: verification runs died on
   {"error":"path <root>/. is outside ownership root <root>"} (issue
   #28721). *)

let rec rm_rf path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
    Unix.rmdir path
  | _ -> Sys.remove path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_ownership_root f =
  let root = Filename.temp_file "owned_read_cwd" "" in
  Sys.remove root;
  Unix.mkdir root 0o755;
  Fun.protect
    ~finally:(fun () -> try rm_rf root with _ -> ())
    (fun () -> f root)

let write_file path content =
  let oc = open_out_bin path in
  output_string oc content;
  close_out oc

let read_via_tool ~ownership_root args =
  Masc.Keeper_tool_filesystem_runtime.handle_owned_read_file_with_outcome
    ~ownership_root
    ~args

let content_of_execution (execution : Masc.Keeper_tool_execution.t) =
  match Yojson.Safe.from_string execution.raw_output with
  | `Assoc fields ->
    (match List.assoc_opt "content" fields with
     | Some (`String content) -> Some content
     | _ -> None)
  | _ -> None
  | exception _ -> None

let expect_read_success ~what ~expected_content execution =
  match execution.Masc.Keeper_tool_execution.disposition with
  | Tool_result.Completed () ->
    (match content_of_execution execution with
     | Some content ->
       Alcotest.(check string) (what ^ " content") expected_content content
     | None ->
       Alcotest.failf "%s: completed without a string content field: %s" what
         execution.raw_output)
  | Tool_result.Deferred () -> Alcotest.failf "%s: unexpectedly deferred" what
  | Tool_result.Failed _ ->
    Alcotest.failf "%s: read failed: %s" what execution.raw_output

let expect_read_failure ~what execution =
  match execution.Masc.Keeper_tool_execution.disposition with
  | Tool_result.Failed _ -> ()
  | Tool_result.Completed () | Tool_result.Deferred () ->
    Alcotest.failf "%s: expected a failure, got: %s" what execution.raw_output

let test_dot_cwd_reads_root_file () =
  with_ownership_root (fun root ->
    write_file (Filename.concat root "hello.txt") "hello from the root";
    read_via_tool ~ownership_root:root
      (`Assoc [ "path", `String "hello.txt"; "cwd", `String "." ])
    |> expect_read_success ~what:"cwd:\".\"" ~expected_content:"hello from the root")

let test_omitted_cwd_reads_root_file () =
  with_ownership_root (fun root ->
    write_file (Filename.concat root "hello.txt") "hello from the root";
    read_via_tool ~ownership_root:root (`Assoc [ "path", `String "hello.txt" ])
    |> expect_read_success ~what:"omitted cwd" ~expected_content:"hello from the root")

let test_dot_slash_subdirectory_cwd () =
  with_ownership_root (fun root ->
    let sub = Filename.concat root "sub" in
    Unix.mkdir sub 0o755;
    write_file (Filename.concat sub "inner.txt") "inner payload";
    read_via_tool ~ownership_root:root
      (`Assoc [ "path", `String "inner.txt"; "cwd", `String "./sub" ])
    |> expect_read_success ~what:"cwd:\"./sub\"" ~expected_content:"inner payload")

let test_parent_cwd_stays_rejected () =
  with_ownership_root (fun root ->
    write_file (Filename.concat root "hello.txt") "hello from the root";
    read_via_tool ~ownership_root:root
      (`Assoc [ "path", `String "hello.txt"; "cwd", `String ".." ])
    |> expect_read_failure ~what:"cwd:\"..\"")

let () =
  Alcotest.run "owned_read_cwd"
    [ ( "cwd resolution"
      , [ Alcotest.test_case "cwd \".\" reads a root file" `Quick
            test_dot_cwd_reads_root_file
        ; Alcotest.test_case "omitted cwd reads a root file" `Quick
            test_omitted_cwd_reads_root_file
        ; Alcotest.test_case "cwd \"./sub\" reads inside a subdirectory" `Quick
            test_dot_slash_subdirectory_cwd
        ; Alcotest.test_case "cwd \"..\" stays rejected" `Quick
            test_parent_cwd_stays_rejected
        ] )
    ]
