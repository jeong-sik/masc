module Types = Masc_domain

open Alcotest

module Cases = Test_mcp_tool_matrix_cases

let result_prefix = "__MCP_TOOL_MATRIX_RESULT__"

let sorted_unique_strings values =
  values |> List.sort_uniq String.compare

let diff left right =
  List.filter (fun value -> not (List.mem value right)) left

let requested_tool_names () =
  match Sys.getenv_opt "MCP_TOOL_MATRIX_ONLY" with
  | None -> None
  | Some raw ->
      raw
      |> String.split_on_char ','
      |> List.map String.trim
      |> List.filter (fun value -> value <> "")
      |> function
      | [] -> None
      | names -> Some names

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
  match Sys.getenv_opt "MCP_TOOL_MATRIX_CASE_TIMEOUT_SEC" with
  | Some raw -> (
      match int_of_string_opt (String.trim raw) with
      | Some value when value > 0 -> value
      | _ -> 25)
  | None -> 25

let runner_path () =
  let exe_dir = Filename.dirname Sys.executable_name in
  let candidate = Filename.concat exe_dir "tool_matrix_case_runner.exe" in
  if Sys.file_exists candidate then
    candidate
  else
    failwith
      (Printf.sprintf
         "tool_matrix_case_runner.exe not found next to test executable (%s)"
         exe_dir)

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
      { base_path = None;
        outcome =
          Error
            (Printf.sprintf "%s missing runner result marker\n%s" tool_name output) }
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
                  { base_path; outcome = Error (Printf.sprintf "%s" message) }
              | _ ->
                  { base_path;
                    outcome =
                      Error
                        (Printf.sprintf
                           "%s returned malformed failure payload: %s"
                           tool_name raw) })
          | _ ->
              { base_path;
                outcome =
                  Error
                    (Printf.sprintf "%s returned malformed runner payload: %s"
                       tool_name raw) })
      | _ ->
          { base_path = None;
            outcome =
              Error
                (Printf.sprintf "%s returned non-object runner payload: %s"
                   tool_name raw) })

let run_tool_case_process tool_name =
  let out_file = Filename.temp_file "mcp-tool-matrix-out" ".txt" in
  let err_file = Filename.temp_file "mcp-tool-matrix-err" ".txt" in
  let timeout_prefix =
    match timeout_command () with
    | Some bin ->
        Printf.sprintf "%s -k 1s %ds " bin (tool_case_timeout_sec ())
    | None -> ""
  in
  let cmd =
    Printf.sprintf "%s%s %s" timeout_prefix (quote (runner_path ())) (quote tool_name)
  in
  let wrapped =
    Printf.sprintf "%s > %s 2> %s" cmd (quote out_file) (quote err_file)
  in
  let status = Sys.command wrapped in
  let output =
    String.concat "\n" [ read_file out_file; read_file err_file ]
  in
  Sys.remove out_file;
  Sys.remove err_file;
  let parsed = parse_case_result ~tool_name output in
  (match parsed.base_path with
  | Some path -> Cases.cleanup_dir path
  | None -> ());
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
            (Printf.sprintf "%s exited nonzero without failure payload\n%s"
               tool_name output)
      | Error message -> Error message)

let test_known_tool_inventory_matches_raw_schemas () =
  let schema_names =
    Masc_mcp.Config.raw_all_tool_schemas
    |> List.map (fun (schema : Types.tool_schema) -> schema.name)
    |> sorted_unique_strings
  in
  let known_names = sorted_unique_strings Cases.all_known_tool_names in
  let missing = diff schema_names known_names in
  let extra = diff known_names schema_names in
  match missing, extra with
  | [], [] -> ()
  | _ ->
      let render label values =
        if values = [] then
          ""
        else
          Printf.sprintf "%s:\n%s" label
            (values |> List.map (fun value -> "  - " ^ value) |> String.concat "\n")
      in
      failf "tool inventory drift detected\n%s\n%s"
        (render "missing contract entries" missing)
        (render "stale contract entries" extra)

let test_full_registry_tools_call_matrix () =
  let failures = ref [] in
  let requested = requested_tool_names () in
  Masc_mcp.Config.raw_all_tool_schemas
  |> (match requested with
     | None ->
         List.filter (fun (schema : Types.tool_schema) ->
             not (List.mem schema.name Cases.generic_matrix_excluded_names))
     | Some requested ->
         List.filter (fun (schema : Types.tool_schema) ->
             List.mem schema.name requested))
  |> List.sort (fun (left : Types.tool_schema) right ->
         String.compare left.name right.name)
  |> List.iter (fun (schema : Types.tool_schema) ->
         match run_tool_case_process schema.name with
         | Ok () -> ()
         | Error message ->
             failures := Printf.sprintf "- %s" message :: !failures);
  match List.rev !failures with
  | [] -> ()
  | failures ->
      failf "tool matrix failures (%d)\n%s" (List.length failures)
        (String.concat "\n" failures)

let () =
  run "mcp_tool_matrix"
    [
      ( "inventory",
        [
          test_case "known inventory matches raw schemas" `Quick
            test_known_tool_inventory_matches_raw_schemas;
        ] );
      ( "matrix",
        [
          test_case "full registry tools/call matrix" `Slow
            test_full_registry_tools_call_matrix;
        ] );
    ]
