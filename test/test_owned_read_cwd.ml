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

(* Issue #28950: when the tool caller omits cwd and the ownership root
   contains exactly one sub-directory whose name matches the first segment
   of the path, the sub-directory is the repository checkout and the read
   must resolve inside it, not at the ownership root (where the file does
   not exist). *)
let test_omitted_cwd_reads_single_sub_repo () =
  with_ownership_root (fun root ->
    let sub = Filename.concat root "repo" in
    Unix.mkdir sub 0o755;
    write_file (Filename.concat sub "hello.txt") "hello from the sub-repo";
    read_via_tool ~ownership_root:root
      (`Assoc [ "path", `String "repo/hello.txt" ])
    |> expect_read_success ~what:"omitted cwd + single sub-repo"
         ~expected_content:"hello from the sub-repo")

(* Pin the helper's fallback: zero sub-directories means the ownership root
   itself is the repository; the bare path must still resolve. *)
let test_omitted_cwd_reads_root_when_no_sub_repo () =
  with_ownership_root (fun root ->
    write_file (Filename.concat root "hello.txt") "hello from the root";
    let cwd_abs, target_path =
      Masc.Keeper_tool_filesystem_runtime.default_owned_target
        ~ownership_root:root
        ~path:"hello.txt"
    in
    Alcotest.(check string) "no sub-repo resolves to root" root cwd_abs;
    Alcotest.(check string) "no sub-repo leaves path alone" "hello.txt"
      target_path;
    read_via_tool ~ownership_root:root (`Assoc [ "path", `String "hello.txt" ])
    |> expect_read_success ~what:"omitted cwd + no sub-repo"
         ~expected_content:"hello from the root")

(* Pin the helper's no-guess behaviour: several sub-directories means the
   implicit choice would be a lie, so the helper falls back to the
   ownership root. The bare path must then resolve at the root, not in any
   particular sub-directory. *)
let test_omitted_cwd_does_not_guess_among_several_sub_repos () =
  with_ownership_root (fun root ->
    let a = Filename.concat root "a" in
    let b = Filename.concat root "b" in
    Unix.mkdir a 0o755;
    Unix.mkdir b 0o755;
    write_file (Filename.concat root "root_only.txt") "only at root";
    let cwd_abs, target_path =
      Masc.Keeper_tool_filesystem_runtime.default_owned_target
        ~ownership_root:root
        ~path:"root_only.txt"
    in
    Alcotest.(check string) "several sub-repos -> ownership_root" root
      cwd_abs;
    Alcotest.(check string) "several sub-repos leave path alone"
      "root_only.txt" target_path;
    read_via_tool ~ownership_root:root
      (`Assoc [ "path", `String "root_only.txt" ])
    |> expect_read_success ~what:"omitted cwd + several sub-repos"
         ~expected_content:"only at root")

(* Pin the helper's strip behaviour: a relative path that names the
   single sub-repo as its first segment has that segment stripped, so
   the subsequent [cwd_abs ++ target_path] does not overshoot. *)
let test_helper_strips_sub_repo_prefix () =
  with_ownership_root (fun root ->
    let sub = Filename.concat root "repo" in
    Unix.mkdir sub 0o755;
    let cwd_abs, target_path =
      Masc.Keeper_tool_filesystem_runtime.default_owned_target
        ~ownership_root:root
        ~path:"repo/hello.txt"
    in
    Alcotest.(check string) "single sub-repo resolves to sub" sub cwd_abs;
    Alcotest.(check string) "single sub-repo strips prefix" "hello.txt"
      target_path)

(* Pin the no-strip behaviour when the single sub-repo's name does not
   match the first segment of [path] — the helper must fall back to
   [ownership_root] and leave the path alone. *)
let test_helper_does_not_strip_when_first_segment_mismatches () =
  with_ownership_root (fun root ->
    let sub = Filename.concat root "repo" in
    Unix.mkdir sub 0o755;
    let cwd_abs, target_path =
      Masc.Keeper_tool_filesystem_runtime.default_owned_target
        ~ownership_root:root
        ~path:"other/hello.txt"
    in
    Alcotest.(check string) "mismatched first segment -> ownership_root" root
      cwd_abs;
    Alcotest.(check string) "mismatched first segment leaves path alone"
      "other/hello.txt" target_path)

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
        ; Alcotest.test_case
            "omitted cwd reads single sub-repo (issue #28950)" `Quick
            test_omitted_cwd_reads_single_sub_repo
        ; Alcotest.test_case "omitted cwd + no sub-repo falls back to root"
            `Quick test_omitted_cwd_reads_root_when_no_sub_repo
        ; Alcotest.test_case
            "omitted cwd + several sub-repos falls back to root" `Quick
            test_omitted_cwd_does_not_guess_among_several_sub_repos
        ; Alcotest.test_case
            "helper strips sub-repo prefix when first segment matches" `Quick
            test_helper_strips_sub_repo_prefix
        ; Alcotest.test_case
            "helper falls back to root when first segment does not match"
            `Quick test_helper_does_not_strip_when_first_segment_mismatches
        ] )
    ]
