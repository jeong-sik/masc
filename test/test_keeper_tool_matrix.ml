open Alcotest

module Cases = Test_keeper_tool_matrix_cases

let result_prefix = "__KEEPER_TOOL_MATRIX_RESULT__"

let requested_tool_names () =
  match Sys.getenv_opt "KEEPER_TOOL_MATRIX_ONLY" with
  | None -> None
  | Some raw ->
      raw
      |> String.split_on_char ','
      |> List.map String.trim
      |> List.filter (fun value -> value <> "")
      |> function
      | [] -> None
      | names -> Some names

let has_repo_root root =
  Sys.file_exists (Filename.concat root "dune-project")
  && Sys.file_exists (Filename.concat root "test/dune")

let rec ascend_repo_root dir =
  if has_repo_root dir then
    Some dir
  else
    let parent = Filename.dirname dir in
    if String.equal parent dir then None else ascend_repo_root parent

let executable_repo_root () =
  ascend_repo_root (Filename.dirname Sys.executable_name)

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when String.trim root <> "" && has_repo_root root -> root
  | _ -> (
      match
        try Some (Sys.getcwd ()) with
        | Sys_error _ -> None
      with
      | Some cwd -> (
          match ascend_repo_root cwd with
          | Some root -> root
          | None -> (
              match executable_repo_root () with
              | Some root -> root
              | None -> cwd))
      | None -> (
          match executable_repo_root () with
          | Some root -> root
          | None -> Filename.current_dir_name))

let path_is_within ~parent ~child =
  try
    let parent = Unix.realpath parent in
    let child = Unix.realpath child in
    let prefix =
      if String.ends_with ~suffix:"/" parent then parent else parent ^ "/"
    in
    String.starts_with ~prefix child
  with _ -> false

let quote = Filename.quote

let read_file path =
  In_channel.with_open_bin path In_channel.input_all

let timeout_command () =
  if Sys.command "command -v timeout >/dev/null 2>&1" = 0 then
    Some "timeout"
  else if Sys.command "command -v gtimeout >/dev/null 2>&1" = 0 then
    Some "gtimeout"
  else
    None

let tool_case_timeout_sec () =
  match Sys.getenv_opt "KEEPER_TOOL_MATRIX_CASE_TIMEOUT_SEC" with
  | Some raw -> (
      match int_of_string_opt (String.trim raw) with
      | Some value when value > 0 -> value
      | _ -> 25)
  | None -> 25

let runner_path () =
  let candidate =
    Filename.concat (Filename.dirname Sys.executable_name)
      "keeper_tool_matrix_case_runner.exe"
  in
  if Sys.file_exists candidate
     && path_is_within ~parent:(source_root ()) ~child:candidate
  then
    candidate
  else
    Filename.concat (source_root ())
      "_build/default/test/keeper_tool_matrix_case_runner.exe"

let find_result_line output =
  output
  |> String.split_on_char '\n'
  |> List.find_map (fun line ->
         if String.starts_with ~prefix:result_prefix line then
           Some
             (String.sub line (String.length result_prefix)
                (String.length line - String.length result_prefix))
         else
           None)

type case_process_result = {
  base_path : string option;
  outcome : (unit, string) result;
}

let parse_case_result ~tool_name output =
  match find_result_line output with
  | None ->
      {
        base_path = None;
        outcome =
          Error
            (Printf.sprintf "%s missing runner result marker\n%s" tool_name
               output);
      }
  | Some raw -> (
      match Yojson.Safe.from_string raw with
      | `Assoc fields -> (
          let base_path =
            match List.assoc_opt "base_path" fields with
            | Some (`String value) when value <> "" -> Some value
            | _ -> None
          in
          match List.assoc_opt "ok" fields with
          | Some (`Bool true) -> { base_path; outcome = Ok () }
          | Some (`Bool false) -> (
              match List.assoc_opt "message" fields with
              | Some (`String message) ->
                  { base_path; outcome = Error message }
              | _ ->
                  {
                    base_path;
                    outcome =
                      Error
                        (Printf.sprintf
                           "%s returned malformed failure payload: %s"
                           tool_name raw);
                  })
          | _ ->
              {
                base_path;
                outcome =
                  Error
                    (Printf.sprintf "%s returned malformed runner payload: %s"
                       tool_name raw);
              })
      | _ ->
          {
            base_path = None;
            outcome =
              Error
                (Printf.sprintf
                   "%s returned non-object runner payload: %s"
                   tool_name raw);
          })

let run_tool_case_process tool_name =
  let tmp_root = Filename.temp_file "keeper-tool-matrix-base" "" in
  Sys.remove tmp_root;
  Unix.mkdir tmp_root 0o700;
  let out_file = Filename.temp_file "keeper-tool-matrix-out" ".txt" in
  let err_file = Filename.temp_file "keeper-tool-matrix-err" ".txt" in
  let cleanup_file path =
    if Sys.file_exists path then Sys.remove path
  in
  let cleanup_dir path =
    if Sys.file_exists path then Cases.cleanup_dir path
  in
  let timeout_prefix =
    match timeout_command () with
    | Some bin ->
        Printf.sprintf "%s -k 1s %ds " bin (tool_case_timeout_sec ())
    | None -> ""
  in
  let env_prefix =
    Printf.sprintf "TMPDIR=%s TEMP=%s TMP=%s " (quote tmp_root)
      (quote tmp_root) (quote tmp_root)
  in
  let cmd =
    Printf.sprintf "%s%s%s %s" env_prefix timeout_prefix
      (quote (runner_path ())) (quote tool_name)
  in
  let wrapped =
    Printf.sprintf "%s > %s 2> %s" cmd (quote out_file) (quote err_file)
  in
  Fun.protect
    ~finally:(fun () ->
      cleanup_file out_file;
      cleanup_file err_file;
      cleanup_dir tmp_root)
    (fun () ->
      let status = Sys.command wrapped in
      let output =
        String.concat "\n" [ read_file out_file; read_file err_file ]
      in
      let parsed = parse_case_result ~tool_name output in
      (match parsed.base_path with
      | Some path when path <> tmp_root -> cleanup_dir path
      | Some _ | None -> ());
      match status with
      | 0 -> parsed.outcome
      | 124 ->
          Error
            (Printf.sprintf "%s timed out after %ds\n%s" tool_name
               (tool_case_timeout_sec ()) output)
      | _ -> (
          match parsed.outcome with
          | Ok () ->
              Error
                (Printf.sprintf
                   "%s exited nonzero without failure payload\n%s"
                   tool_name output)
          | Error message -> Error message))

let test_keeper_inventory_is_unique () =
  let names = Cases.all_keeper_tool_names in
  let counts = Hashtbl.create (max 16 (List.length names)) in
  List.iter
    (fun name ->
      let count =
        match Hashtbl.find_opt counts name with
        | Some n -> n
        | None -> 0
      in
      Hashtbl.replace counts name (count + 1))
    names;
  let duplicates =
    Hashtbl.fold
      (fun name count acc -> if count > 1 then (name, count) :: acc else acc)
      counts []
    |> List.sort (fun (left, _) (right, _) -> String.compare left right)
  in
  if duplicates <> [] then
    failf "keeper inventory contains duplicate tool names:\n%s"
      (duplicates
      |> List.map (fun (name, count) -> Printf.sprintf "  - %s (%d)" name count)
      |> String.concat "\n")

let test_keeper_inventory_has_cases () =
  let names = Cases.all_keeper_tool_names in
  let missing =
    List.filter
      (fun name ->
        try
          ignore (Cases.case_for_name name);
          false
        with Failure _ -> true)
      names
  in
  if missing <> [] then
    failf "keeper matrix missing contracts:\n%s"
      (missing |> List.map (fun name -> "  - " ^ name) |> String.concat "\n")

let test_full_keeper_tools_call_matrix () =
  let requested = requested_tool_names () in
  let failures = ref [] in
  let schemas =
    match requested with
    | None -> Cases.all_keeper_tool_schemas ()
    | Some requested ->
        Cases.all_keeper_tool_schemas ()
        |> List.filter (fun (schema : Types.tool_schema) ->
               List.mem schema.name requested)
  in
  List.iter
    (fun (schema : Types.tool_schema) ->
      match run_tool_case_process schema.name with
      | Ok () -> ()
      | Error message -> failures := ("- " ^ message) :: !failures)
    schemas;
  match List.rev !failures with
  | [] -> ()
  | failures ->
      failf "keeper tool matrix failures (%d)\n%s" (List.length failures)
        (String.concat "\n" failures)

let () =
  run "keeper_tool_matrix"
    [
      ( "inventory",
        [
          test_case "keeper inventory is unique" `Quick
            test_keeper_inventory_is_unique;
          test_case "keeper inventory has case contracts" `Quick
            test_keeper_inventory_has_cases;
        ] );
      ( "matrix",
        [
          test_case "full keeper tool matrix" `Slow
            test_full_keeper_tools_call_matrix;
        ] );
    ]
