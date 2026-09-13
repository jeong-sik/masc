let environment_dir ~base_path =
  Filename.concat (Filename.concat base_path Common.masc_dirname) "runtime-tools/presentation"
let parser_python ~base_path = Filename.concat (environment_dir ~base_path) "bin/python3"
let parser_install_commands ~base_path =
  [["python3"; "-I"; "-m"; "venv"; "--copies"; environment_dir ~base_path];
   [parser_python ~base_path; "-I"; "-m"; "pip"; "--isolated"; "install";
    "--require-virtualenv"; "python-pptx"]]

type check = Missing of string | Started of {command:string; output:string}
  | Failed of {command:string; status:Unix.process_status; detail:string}
  | Refused of {command:string; detail:string}
type t = {base_path:string; parser:check; renderer:check; pdf:Pdf_runtime_dependencies.t}
let parser_probe =
  "import json,sys,pathlib,pptx; from pptx import Presentation; expected=pathlib.Path(sys.argv[1]).resolve(); assert pathlib.Path(sys.prefix).resolve()==expected and sys.prefix!=sys.base_prefix, 'managed presentation virtual environment required'; assert pathlib.Path(pptx.__file__).resolve().is_relative_to(expected), 'python-pptx must belong to the managed environment'; p=Presentation(); print(json.dumps({'module':'pptx','version':pptx.__version__,'module_file':pptx.__file__,'empty_slide_count':len(p.slides)}))"
let observe_command argv =
  match argv with
  | [] -> invalid_arg "dependency probe requires an executable"
  | command :: _ ->
    if not (Executable_path.command_available command) then Missing command
    else match Process_eio.run_argv_with_status_split_or_refusal
      ~env:(Env_keeper_scrub.filter_environment (Unix.environment ())) argv with
    | Error refusal -> Refused {command;detail=Process_eio.spawn_refusal_to_string refusal}
    | Ok (status,stdout,stderr) ->
      let output = String.trim (stdout ^ "\n" ^ stderr) in
      match status with
      | Unix.WEXITED 0 -> Started {command;output}
      | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> Failed {command;status;detail=output}
let observe ~base_path () =
  {base_path; parser=observe_command [parser_python ~base_path; "-I"; "-B"; "-c"; parser_probe; environment_dir ~base_path];
   renderer=observe_command ["soffice"; "--headless"; "--version"]; pdf=Pdf_runtime_dependencies.observe ()}
let started = function Started _ -> true | Missing _ | Failed _ | Refused _ -> false
let parser_available checks = started checks.parser
let renderer_available checks = started checks.renderer
(* Every PPTX inspection renders to PDF and reads the pages with Poppler, so a
   host with the parser and LibreOffice but without pdftotext/pdftoppm cannot
   inspect a single deck. Reporting it available sent operators to a tool that
   fails after parsing and rendering. *)
let pdf_available checks = Pdf_runtime_dependencies.available checks.pdf
let available checks = parser_available checks && renderer_available checks && pdf_available checks
let check_json component = function
  | Missing command -> `Assoc ["component",`String component;"command",`String command;"status",`String "missing"]
  | Started {command;output} -> `Assoc ["component",`String component;"command",`String command;
      "status",`String "started";"output",`String output]
  | Refused {command;detail} -> `Assoc ["component",`String component;"command",`String command;
      "status",`String "failed";"detail",`String detail;"process",`Null]
  | Failed {command;status;detail} ->
    let process = match status with
      | Unix.WEXITED code -> `Assoc ["exit_code",`Int code]
      | Unix.WSIGNALED signal -> `Assoc ["signal",`Int signal]
      | Unix.WSTOPPED signal -> `Assoc ["stopped_signal",`Int signal] in
    `Assoc ["component",`String component;"command",`String command;"status",`String "failed";
      "process",process;"detail",`String detail]
let to_json checks = `Assoc ["schema",`String "masc.presentation_tools_readiness.v1";
  "status",`String (if available checks then "tools_available" else "unavailable");
  "scope",`String "workspace_host_runtime";"base_path",`String checks.base_path;
  "checks",`List [check_json "python_pptx" checks.parser;check_json "libreoffice" checks.renderer];
  "pdf_tools",Pdf_runtime_dependencies.to_json checks.pdf;
  "presentation_inspection",`String "not_run"]
