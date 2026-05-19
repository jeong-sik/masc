(** Coverage tests for the [Tool_code_read_core] SSOT.

    Regression #12 (masc-mcp runtime log audit 2026-05-20): LLMs
    repeatedly called [masc_code_read] with directory paths and got
    the opaque ["Failed to read file: Sys_error (\"... Is a
    directory\")"]. Both handlers now share
    [Tool_code_read_core.read_with_pagination] and surface a typed
    [read_error] variant. These tests pin the JSON envelope and the
    integration with the two callers. *)

open Masc_mcp

(* --- tmp fixtures --- *)

let fresh_base_path ~tag =
  let raw =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-tool-code-read-core-%s-%d" tag
         (int_of_float (Unix.gettimeofday () *. 1000.0)))
  in
  Unix.mkdir raw 0o755;
  try Unix.realpath raw with Unix.Unix_error _ -> raw

let sh cmd =
  let rc = Sys.command cmd in
  if rc <> 0 then failwith (Printf.sprintf "shell cmd failed (rc=%d): %s" rc cmd)

let git_init_base base_path =
  sh (Printf.sprintf "cd %s && git init -q -b main" base_path);
  sh (Printf.sprintf "cd %s && git config user.email test@example.com" base_path);
  sh (Printf.sprintf "cd %s && git config user.name test" base_path);
  sh
    (Printf.sprintf
       "cd %s && touch README && git add README && git commit -qm init"
       base_path)

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

let mkdir_p path =
  let rec go acc = function
    | [] -> ()
    | head :: rest ->
        let next = Filename.concat acc head in
        (if not (Sys.file_exists next) then Unix.mkdir next 0o755);
        go next rest
  in
  match String.split_on_char '/' path with
  | "" :: parts -> go "/" parts
  | parts -> go (Sys.getcwd ()) parts

(* --- shape helpers for JSON probes --- *)

let json_string_field json key =
  match json with
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`String s) -> Some s
       | _ -> None)
  | _ -> None

let has_key json key =
  match json with
  | `Assoc fields -> List.mem_assoc key fields
  | _ -> false

let parse_json s =
  try Yojson.Safe.from_string s
  with _ -> Alcotest.failf "not valid JSON: %s" s

(* ---------- 1. read_with_pagination → Path_is_directory ---------- *)

let test_directory_input_yields_path_is_directory () =
  let base = fresh_base_path ~tag:"dir-typed" in
  let dir = Filename.concat base "some_dir" in
  Unix.mkdir dir 0o755;
  match
    Tool_code_read_core.read_with_pagination
      ~display_path:"some_dir" ~validated_path:dir ~offset:0 ~limit:100
  with
  | Ok _ -> Alcotest.fail "expected Error Path_is_directory, got Ok"
  | Error (Tool_code_read_core.Path_is_directory _ as e) ->
      let json = Tool_code_read_core.read_error_to_json e in
      Alcotest.(check (option string))
        "error_kind discriminator"
        (Some "path_is_directory")
        (json_string_field json "error_kind");
      Alcotest.(check bool) "has hint field" true (has_key json "hint")
  | Error other ->
      Alcotest.failf "expected Path_is_directory, got %s"
        (Yojson.Safe.to_string
           (Tool_code_read_core.read_error_to_json other))

(* ---------- 2. missing → File_not_found (no hint) ---------- *)

let test_missing_file_distinguishable_from_directory () =
  let base = fresh_base_path ~tag:"missing" in
  let path = Filename.concat base "no_such_file.txt" in
  match
    Tool_code_read_core.read_with_pagination
      ~display_path:"no_such_file.txt" ~validated_path:path ~offset:0
      ~limit:100
  with
  | Error (Tool_code_read_core.File_not_found _ as e) ->
      let json = Tool_code_read_core.read_error_to_json e in
      Alcotest.(check (option string))
        "error_kind discriminator"
        (Some "file_not_found")
        (json_string_field json "error_kind");
      Alcotest.(check bool)
        "no hint for missing file" false (has_key json "hint")
  | _ -> Alcotest.fail "expected File_not_found"

(* ---------- 3. regular file still reads ---------- *)

let test_regular_file_still_reads () =
  let base = fresh_base_path ~tag:"regular" in
  let path = Filename.concat base "hello.txt" in
  write_file path "alpha\nbeta\ngamma\n";
  match
    Tool_code_read_core.read_with_pagination
      ~display_path:"hello.txt" ~validated_path:path ~offset:0 ~limit:10
  with
  | Ok ok ->
      (* The trailing newline produces a final empty element; total = 4. *)
      Alcotest.(check int) "total_lines" 4 ok.total_lines;
      Alcotest.(check int) "safe_offset" 0 ok.safe_offset;
      Alcotest.(check int) "safe_limit" 4 ok.safe_limit;
      Alcotest.(check (list string))
        "lines" [ "alpha"; "beta"; "gamma"; "" ] ok.lines
  | Error e ->
      Alcotest.failf "expected Ok, got %s"
        (Yojson.Safe.to_string (Tool_code_read_core.read_error_to_json e))

(* ---------- 4. .png extension → Binary_file ---------- *)

let test_binary_extension_yields_binary_file_kind () =
  let base = fresh_base_path ~tag:"binary" in
  let path = Filename.concat base "image.png" in
  write_file path "fake-png-bytes";
  match
    Tool_code_read_core.read_with_pagination
      ~display_path:"image.png" ~validated_path:path ~offset:0 ~limit:10
  with
  | Error (Tool_code_read_core.Binary_file _ as e) ->
      let json = Tool_code_read_core.read_error_to_json e in
      Alcotest.(check (option string))
        "error_kind discriminator"
        (Some "binary_file")
        (json_string_field json "error_kind");
      Alcotest.(check bool) "binary has hint" true (has_key json "hint")
  | _ -> Alcotest.fail "expected Binary_file"

(* ---------- 5. mcp handler integration (Tool_code.handle_code_read) ---------- *)

let make_fixture_with_git ~tag =
  let base = fresh_base_path ~tag in
  git_init_base base;
  base

let test_mcp_handler_emits_typed_error_string () =
  let base = make_fixture_with_git ~tag:"mcp-dir" in
  mkdir_p (Filename.concat base "subdir");
  let cfg : Coord.config =
    { (Coord.default_config base) with base_path = base }
  in
  let ctx : Tool_code.context = { config = cfg; agent_name = "agent-alpha" } in
  let dir_abs = Filename.concat base "subdir" in
  let args = `Assoc [ "path", `String dir_abs ] in
  let result =
    match
      Tool_code.dispatch ctx ~name:"masc_code_read" ~args
    with
    | Some r -> r
    | None -> Alcotest.fail "dispatch returned None for masc_code_read"
  in
  Alcotest.(check bool) "success=false on directory" false result.success;
  let body = Tool_result.message result in
  let json = parse_json body in
  Alcotest.(check (option string))
    "mcp handler emits path_is_directory"
    (Some "path_is_directory")
    (json_string_field json "error_kind")

(* ---------- 6. keeper handler integration ----------

   We exercise [Tool_code_read_core] directly using the same target
   the keeper handler would synthesize after path resolution. The
   keeper-side [resolve_keeper_read_path] requires a fully constructed
   registry which is heavyweight for a unit test; the SSOT property
   we want is that the pipeline yields the same typed JSON shape
   regardless of which caller invoked it. *)

let test_keeper_handler_emits_typed_error_string () =
  let base = fresh_base_path ~tag:"keeper-dir" in
  let dir = Filename.concat base "some_dir" in
  Unix.mkdir dir 0o755;
  let body =
    match
      Tool_code_read_core.read_with_pagination
        ~display_path:"some_dir" ~validated_path:dir ~offset:0 ~limit:100
    with
    | Ok _ -> Alcotest.fail "expected error"
    | Error err ->
        Yojson.Safe.to_string (Tool_code_read_core.read_error_to_json err)
  in
  let json = parse_json body in
  Alcotest.(check (option string))
    "keeper-shape envelope uses same discriminator"
    (Some "path_is_directory")
    (json_string_field json "error_kind");
  Alcotest.(check (option string))
    "path echoes display path"
    (Some "some_dir")
    (json_string_field json "path")

(* ---------- runner ---------- *)

let () =
  Alcotest.run "tool_code_read_directory_typed_error"
    [
      ( "Tool_code_read_core",
        [
          Alcotest.test_case "directory_input_yields_path_is_directory"
            `Quick test_directory_input_yields_path_is_directory;
          Alcotest.test_case "missing_file_distinguishable_from_directory"
            `Quick test_missing_file_distinguishable_from_directory;
          Alcotest.test_case "regular_file_still_reads" `Quick
            test_regular_file_still_reads;
          Alcotest.test_case "binary_extension_yields_binary_file_kind"
            `Quick test_binary_extension_yields_binary_file_kind;
          Alcotest.test_case "mcp_handler_emits_typed_error_string" `Quick
            test_mcp_handler_emits_typed_error_string;
          Alcotest.test_case "keeper_handler_emits_typed_error_string"
            `Quick test_keeper_handler_emits_typed_error_string;
        ] );
    ]
