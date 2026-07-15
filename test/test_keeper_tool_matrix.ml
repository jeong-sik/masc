module Types = Masc_domain

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

let read_file path =
  In_channel.with_open_bin path In_channel.input_all

let log_progress fmt =
  Printf.ksprintf
    (fun line ->
      Printf.eprintf "[keeper_tool_matrix] %s\n%!" line)
    fmt

let find_in_path executable =
  let path =
    Sys.getenv_opt "PATH" |> Option.value ~default:""
    |> String.split_on_char ':'
  in
  List.find_map
    (fun dir ->
      let candidate =
        Filename.concat (if dir = "" then "." else dir) executable
      in
      try
        Unix.access candidate [ Unix.X_OK ];
        Some candidate
      with Unix.Unix_error _ -> None)
    path

let timeout_command () =
  match find_in_path "timeout" with
  | Some _ as found -> found
  | None -> find_in_path "gtimeout"

(* Each case launches the full OAS handler path in a fresh process and may pay
   sandbox/config cold-start cost. Keep the default conservative while allowing
   local tightening through KEEPER_TOOL_MATRIX_CASE_TIMEOUT_SEC. *)
let default_tool_case_timeout_sec = 60

let tool_case_timeout_sec () =
  match Sys.getenv_opt "KEEPER_TOOL_MATRIX_CASE_TIMEOUT_SEC" with
  | Some raw -> (
      match int_of_string_opt (String.trim raw) with
      | Some value when value > 0 -> value
      | _ -> default_tool_case_timeout_sec)
  | None -> default_tool_case_timeout_sec

let runner_path () =
  let exe_dir = Filename.dirname Sys.executable_name in
  let candidate =
    Filename.concat exe_dir "keeper_tool_matrix_case_runner.exe"
  in
  if Sys.file_exists candidate then
    candidate
  else
    failwith
      (Printf.sprintf
         "keeper_tool_matrix_case_runner.exe not found next to test executable (%s)"
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

let env_array ?(unset = []) overrides =
  let env = Hashtbl.create 64 in
  Unix.environment ()
  |> Array.iter (fun binding ->
         match String.index_opt binding '=' with
         | Some index ->
             let key = String.sub binding 0 index in
             if not (List.mem key unset) then
               Hashtbl.replace env key
                 (String.sub binding (index + 1)
                    (String.length binding - index - 1))
         | None -> ());
  List.iter (fun key -> Hashtbl.remove env key) unset;
  List.iter (fun (key, value) -> Hashtbl.replace env key value) overrides;
  Hashtbl.fold
    (fun key value acc -> Printf.sprintf "%s=%s" key value :: acc)
    env []
  |> Array.of_list

let process_exit_code = function
  | Unix.WEXITED code -> code
  | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> 255

let run_capture_process ~env ~out_file ~err_file prog argv =
  let out_fd =
    Unix.openfile out_file [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600
  in
  Fun.protect
    ~finally:(fun () -> Unix.close out_fd)
    (fun () ->
      let err_fd =
        Unix.openfile err_file
          [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ]
          0o600
      in
      Fun.protect
        ~finally:(fun () -> Unix.close err_fd)
        (fun () ->
          let pid =
            Unix.create_process_env prog argv env Unix.stdin out_fd err_fd
          in
          let _, status = Unix.waitpid [] pid in
          process_exit_code status))

let isolated_child_env_unset =
  [ "MASC_BASE_PATH"
  ; "MASC_BASE_PATH_INPUT"
  ; "MASC_CONFIG_DIR"
  ; "MASC_TOKEN"
  ; "MASC_INTERNAL_MCP_TOKEN"
  ; "MASC_ADMIN_TOKEN"
  ; "MCP_SESSION_ID"
  ; "OPENAI_API_KEY"
  ; "ANTHROPIC_API_KEY"
  ; "GEMINI_API_KEY"
  ; "GOOGLE_API_KEY"
  ; "MISTRAL_API_KEY"
  ; "OPENROUTER_API_KEY"
  ; "ZAI_API_KEY"
  ; "DASHSCOPE_API_KEY"
  ; "OLLAMA_HOST"
  ]

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
  let env =
    env_array
      ~unset:isolated_child_env_unset
      [
        ("TMPDIR", tmp_root);
        ("TEMP", tmp_root);
        ("TMP", tmp_root);
        ("HOME", tmp_root);
        ("XDG_CONFIG_HOME", Filename.concat tmp_root "xdg-config");
        ("XDG_CACHE_HOME", Filename.concat tmp_root "xdg-cache");
      ]
  in
  let prog, argv =
    match timeout_command () with
    | Some bin ->
        ( bin,
          [|
            bin;
            "-k";
            "1s";
            Printf.sprintf "%ds" (tool_case_timeout_sec ());
            runner_path ();
            tool_name;
          |] )
    | None ->
        let runner = runner_path () in
        (runner, [| runner; tool_name |])
  in
  Fun.protect
    ~finally:(fun () ->
      cleanup_file out_file;
      cleanup_file err_file;
      cleanup_dir tmp_root)
    (fun () ->
      let status = run_capture_process ~env ~out_file ~err_file prog argv in
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

let test_keeper_inventory_materializes_masc_fusion_schema () =
  check bool "masc_fusion schema is materialized" true
    (List.mem "masc_fusion" Cases.all_keeper_tool_names)

(* Drift-guard: Fusion_tool.handle reads web_tools (Tool_args.get_bool args
   "web_tools") and fusion_orchestrator ORs it with the preset to inject
   web_search / web_fetch into the panel and judge. If the keeper-facing schema
   omits web_tools, the keeper LLM has no surfaced way to enable it (the field is
   only reachable by guessing the exact name). Assert the *materialized* schema —
   what the keeper actually receives — declares it as a boolean, so
   descriptor<->handler drift on this arg fails the build. *)
let test_masc_fusion_schema_declares_web_tools () =
  match
    List.find_opt
      (fun (schema : Masc_domain.tool_schema) ->
        String.equal schema.name "masc_fusion")
      (Cases.all_keeper_tool_schemas ())
  with
  | None -> fail "masc_fusion schema must be materialized"
  | Some schema ->
      let props =
        match schema.input_schema with
        | `Assoc fields -> (
            match List.assoc_opt "properties" fields with
            | Some (`Assoc props) -> props
            | _ -> [])
        | _ -> []
      in
      check bool
        "masc_fusion schema declares web_tools (descriptor<->handler parity)"
        true
        (List.mem_assoc "web_tools" props);
      let web_tools_type =
        match List.assoc_opt "web_tools" props with
        | Some (`Assoc fields) -> List.assoc_opt "type" fields
        | _ -> None
      in
      check (option string)
        "masc_fusion web_tools schema type matches handler bool parser"
        (Some "boolean")
        (match web_tools_type with
         | Some (`String value) -> Some value
         | _ -> None)

let test_keeper_oas_bundle_materializes_masc_fusion_tool () =
  let marker = Filename.temp_file "keeper-fusion-schema-" ".tmp" in
  Sys.remove marker;
  Unix.mkdir marker 0o700;
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists marker then Cases.cleanup_dir marker)
    (fun () ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      let config = Masc.Workspace.default_config marker in
      let meta = Cases.make_meta ~name:"keeper-fusion-schema" () in
      let ctx_snapshot =
        Masc.Keeper_context_runtime.create
          ~eio:false
          ~system_prompt:"keeper fusion schema regression"
          ~max_tokens:4000
      in
      Masc_test_deps.with_publication_recovery_registry
        ~sw
        ~fs:(Eio.Stdenv.fs env)
        ~registry_root:marker
      @@ fun publication_recovery_registry ->
      let publication_recovery =
        Masc.Keeper_publication_recovery_availability.
          { provider =
              Masc_test_deps.publication_recovery_provider
                publication_recovery_registry
          ; keeper_name = meta.name
          }
      in
      let tools =
        Masc.Keeper_tools_oas_bundle.make_tools
          ~config ~meta ~publication_recovery ~ctx_snapshot ()
      in
      let names =
        List.map (fun (tool : Agent_sdk.Tool.t) -> tool.schema.name) tools
      in
      check bool "masc_fusion Tool.t is materialized" true
        (List.mem "masc_fusion" names))

let selected_schemas () =
  let requested = requested_tool_names () in
  match requested with
  | None -> Cases.all_keeper_tool_schemas ()
  | Some requested ->
      Cases.all_keeper_tool_schemas ()
      |> List.filter (fun (schema : Masc_domain.tool_schema) ->
             List.mem schema.name requested)

let run_tool_case_or_fail tool_name () =
  match run_tool_case_process tool_name with
  | Ok () -> ()
  | Error message -> failf "%s" message

let matrix_test_cases () =
  let schemas = selected_schemas () in
  let total = List.length schemas in
  let timeout_sec = tool_case_timeout_sec () in
  log_progress "registering %d matrix cases, per-case timeout=%ds"
    total timeout_sec;
  schemas
  |> List.mapi (fun index (schema : Masc_domain.tool_schema) ->
         let case_name =
           Printf.sprintf "%03d_%s" (index + 1) schema.name
         in
         test_case case_name `Slow (run_tool_case_or_fail schema.name))

let () =
  let matrix_cases = matrix_test_cases () in
  run "keeper_tool_matrix"
    [
      ( "inventory",
        [
          test_case "keeper inventory is unique" `Quick
            test_keeper_inventory_is_unique;
          test_case "keeper inventory has case contracts" `Quick
            test_keeper_inventory_has_cases;
          test_case "keeper inventory materializes masc_fusion schema" `Quick
            test_keeper_inventory_materializes_masc_fusion_schema;
          test_case "masc_fusion schema declares web_tools" `Quick
            test_masc_fusion_schema_declares_web_tools;
          test_case "keeper OAS bundle materializes masc_fusion tool" `Quick
            test_keeper_oas_bundle_materializes_masc_fusion_tool;
        ] );
      ("matrix", matrix_cases);
    ]
