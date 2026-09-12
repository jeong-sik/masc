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
  "import json,sys,pathlib,pptx; from pptx import Presentation; expected=pathlib.Path(sys.argv[1]).resolve(); assert pathlib.Path(sys.prefix).resolve()==expected and sys.prefix!=sys.base_prefix, 'managed presentation virtual environment required'; pathlib.Path(pptx.__file__).resolve().relative_to(expected); p=Presentation(); print(json.dumps({'module':'pptx','version':pptx.__version__,'module_file':pptx.__file__,'empty_slide_count':len(p.slides)}))"
let observe_command argv =
  match argv with
  | [] -> invalid_arg "dependency probe requires an executable"
  | command :: _ ->
    if not (Executable_path.command_available command) then Missing command
    else match Process_eio.run_argv_with_status_split_or_refusal
      ~timeout_sec:(Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Env_config_sandbox.Shell_timeout.Read ())
      ~env:(Env_keeper_scrub.filter_environment (Unix.environment ())) argv with
    | Error refusal -> Refused {command;detail=Process_eio.spawn_refusal_to_string refusal}
    | Ok (status,stdout,stderr) ->
      let output = String.trim (stdout ^ "\n" ^ stderr) in
      match status with
      | Unix.WEXITED 0 -> Started {command;output}
      | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> Failed {command;status;detail=output}
(* A core-only LibreOffice install can answer --version but cannot render
   presentations. Convert an owned one-slide fixture using the Impress filter. *)
let renderer_probe () =
  if not (Executable_path.command_available "soffice") then Missing "soffice"
  else
    let directory = Filename.temp_dir ~perms:0o700 "masc-impress-probe-" "" in
    Eio.Switch.run (fun sw ->
      Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree directory);
      let source = Filename.concat directory "probe.fodp" in
      Out_channel.with_open_bin source (fun out -> output_string out
        {|<?xml version="1.0" encoding="UTF-8"?>
<office:document xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" office:version="1.2" office:mimetype="application/vnd.oasis.opendocument.presentation"><office:body><office:presentation><draw:page draw:name="Probe"/></office:presentation></office:body></office:document>|});
      let profile = Uri.make ~scheme:"file" ~path:(Filename.concat directory "profile") () |> Uri.to_string in
      match observe_command ["soffice"; "-env:UserInstallation=" ^ profile;
          "--headless"; "--convert-to"; "pdf:impress_pdf_Export";
          "--outdir"; directory; source] with
      | Started {command;output} ->
        let pdf = Filename.concat directory "probe.pdf" in
        if Sys.file_exists pdf && In_channel.with_open_bin pdf
            (fun input -> In_channel.really_input_string input 5 = Some "%PDF-")
        then Started {command;output}
        else Refused {command;detail="LibreOffice did not produce the Impress probe PDF"}
      | (Missing _ | Failed _ | Refused _) as failure -> failure)

let observe ~base_path () =
  {base_path; parser=observe_command [parser_python ~base_path; "-I"; "-B"; "-c"; parser_probe; environment_dir ~base_path];
   renderer=renderer_probe (); pdf=Pdf_runtime_dependencies.observe ()}
let started = function Started _ -> true | Missing _ | Failed _ | Refused _ -> false
let parser_available checks = started checks.parser
let renderer_available checks = started checks.renderer
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
