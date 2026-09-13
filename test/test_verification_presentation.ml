open Masc
open Yojson.Safe.Util
module VAT = Verification_authority_tools

let read path = In_channel.with_open_bin path In_channel.input_all
let write path bytes = Out_channel.with_open_bin path (fun out -> output_string out bytes)
let sha bytes = Digestif.SHA256.(digest_string bytes |> to_hex)

let test_original_presentation () =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Fs_compat.set_fs env#fs;
  Masc_test_deps.init_eio_clock ~sw env;
  let temporary = match Sys.getenv_opt "RUNNER_TEMP" with
    | Some path -> path | None -> Filename.get_temp_dir_name () in
  let base = Filename.concat temporary "masc-presentation-verifier" in
  (* #9921 refuses a test workspace under $HOME so a run cannot write into a
     developer's real one. On a GitHub runner RUNNER_TEMP is
     /home/runner/work/_temp, so the prefix check reads this scratch directory
     as that developer's home. The base cannot move: scripts/ci/
     prepare-presentation-verifier.py installs the managed parser at
     base/.masc/runtime-tools/presentation, and the dispatch below resolves it
     from the workspace it was given. Locally RUNNER_TEMP is unset and the
     fallback temporary directory is outside $HOME, so this changes nothing
     there. *)
  Unix.putenv "MASC_TEST_ALLOW_HOME_BASE_PATH" "1";
  let inputs = Filename.concat base "inputs" in
  let original = read (Filename.concat inputs "presentation.pptx") in
  let expected = Yojson.Safe.from_string (read (Filename.concat inputs "expected.json")) in
  Alcotest.(check string) "fixture original hash" (member "sha256" expected |> to_string) (sha original);
  Process_eio.init ~cwd_default:Eio.Path.(env#fs / base)
    ~proc_mgr:env#process_mgr ~clock:env#clock;
  let config = Workspace_core.default_config base in
  ignore (Workspace_core.init config ~agent_name:(Some "presentation-verifier-test"));
  let producer = "presentation-producer" in
  let root = Filename.concat
    (Workspace_verification_store.project_root_of_base_path config.base_path)
    (Playground_paths.bundle_root producer) in
  Fs_compat.mkdir_p root;
  List.iter (fun name -> write (Filename.concat root name) (read (Filename.concat inputs name)))
    ["presentation.pptx";"broken.pptx";"external.pptx"];
  let task = VAT.create ~config ~producer ~submitted_evidence:[] |> Result.get_ok in
  let goal = VAT.create_goal_proof ~config ~submitted_evidence:[] |> Result.get_ok in
  let dispatch surface path extra = VAT.dispatch surface ~name:"tool_read_file"
    ~args:(`Assoc (("file_path",`String path) :: extra)) in
  List.iter (fun (surface,prefix) ->
    let result = dispatch surface (prefix ^ "presentation.pptx") [] in
    (match result with
     | Tool_result.Completed {data;content_blocks=Some blocks;_} ->
       Alcotest.(check string) "original PPTX hash" (sha original) (member "sha256" data |> to_string);
       Alcotest.(check int) "complete original byte count" (String.length original) (member "bytes" data |> to_int);
       Alcotest.(check int) "actual slide count" 2 (member "slide_count" data |> to_int);
       let slides = member "slides" data |> to_list in
       let titles = member "titles" expected |> to_list |> List.map to_string in
       let notes = member "notes" expected |> to_list |> List.map to_string in
       Alcotest.(check int) "both ordered source slides" 2 (List.length slides);
       List.iteri (fun i slide ->
         Alcotest.(check int) "slide order" (i+1) (member "slide" slide |> to_int);
         Alcotest.(check bool) "actual source title" true
           (String_util.contains_substring (member "text" slide |> to_string) (List.nth titles i));
         Alcotest.(check string) "actual speaker note" (List.nth notes i)
           (member "speaker_notes" slide |> to_string)) slides;
       Alcotest.(check bool) "first slide visible" true (member "visible" (List.hd slides) |> to_bool);
       Alcotest.(check bool) "hidden slide explicit" false (member "visible" (List.nth slides 1) |> to_bool);
       Alcotest.(check (list string)) "hyperlink destination" ["https://example.invalid/reference"]
         (member "hyperlinks" (List.hd slides) |> to_list |> List.map to_string);
       let second = List.nth slides 1 |> member "text" |> to_string in
       Alcotest.(check bool) "table text is included" true
         (String_util.contains_substring second "Leave" && String_util.contains_substring second "Take");
       let images = List.filter_map (function
         | Llm_provider.Types.Image {media_type="image/png";data;source_type=Base64} -> Some (Base64.decode_exn data)
         | _ -> None) blocks in
       let pages = member "rendered_slides" data |> to_list in
       Alcotest.(check int) "every slide becomes visual input" 2 (List.length images);
       List.iter (fun (page,png) ->
         Alcotest.(check string) "rendered image identity" (sha png) (member "rendered_sha256" page |> to_string);
         Alcotest.(check int) "rendered image bytes" (String.length png) (member "rendered_bytes" page |> to_int))
         (List.combine pages images);
       Alcotest.(check bool) "animation limitations are visible" true
         (List.mem (`String "animations") (member "not_inspected" data |> to_list));
       let bridged = Tool_bridge.to_agent_core_typed_result result |> Result.get_ok in
       Alcotest.(check bool) "typed model bridge retains visual blocks" true
         (match bridged.content_blocks with Some blocks ->
           List.length (List.filter (function Agent_core.Types.Image _ -> true | _ -> false) blocks) = 2
          | None -> false)
     | _ -> Alcotest.fail (Tool_result.message result));
    Alcotest.(check bool) "malformed PPTX is a producer rejection" true
      (Tool_result.failure_class (dispatch surface (prefix ^ "broken.pptx") []) = Some Tool_result.Workflow_rejection);
    Alcotest.(check bool) "external auto-loaded media is refused" true
      (Tool_result.failure_class (dispatch surface (prefix ^ "external.pptx") []) = Some Tool_result.Policy_rejection);
    Alcotest.(check bool) "line windows cannot claim complete presentation" true
      (Tool_result.failure_class (dispatch surface (prefix ^ "presentation.pptx") ["limit",`Int 1])
       = Some Tool_result.Workflow_rejection)) [task,"";goal,producer ^ "/"];
  let outside = Filename.concat base "outside.pptx" in
  write outside original;
  let escape = Filename.concat root "escape.pptx" in
  (try Unix.unlink escape with Unix.Unix_error (Unix.ENOENT,_,_) -> ());
  Unix.symlink outside escape;
  List.iter (fun (surface,path) -> Alcotest.(check bool) "same containment for PPTX" true
    (Tool_result.is_failed (dispatch surface path [])))
    [task,outside;goal,outside;task,"escape.pptx";goal,producer ^ "/escape.pptx"];
  let parser = Presentation_runtime_dependencies.parser_python ~base_path:base in
  let parked = parser ^ ".test-parked" in
  Unix.rename parser parked;
  Fun.protect ~finally:(fun () -> Unix.rename parked parser) (fun () ->
    let missing = dispatch task "presentation.pptx" [] in
    Alcotest.(check bool) "missing managed parser is an explicit failure" true
      (Tool_result.failure_class missing = Some Tool_result.Dependency_unavailable));
  (* A small valid source must not let a renderer output bypass the PDF
     source ceiling before the complete generated file is read. *)
  let fake_bin = Filename.concat base "oversized-renderer" in
  Fs_compat.mkdir_p fake_bin;
  Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree fake_bin);
  let fake_soffice = Filename.concat fake_bin "soffice" in
  write fake_soffice (Printf.sprintf {|#!/usr/bin/env python3
import pathlib, sys
if "--version" in sys.argv:
    print("bounded-output renderer fixture")
else:
    output = pathlib.Path(sys.argv[sys.argv.index("--outdir") + 1]) / "source.pdf"
    with output.open("wb") as stream:
        stream.write(b"%%PDF-")
        stream.truncate(%d)
|} (Verification_pdf_inspection.max_source_bytes + 1));
  Unix.chmod fake_soffice 0o700;
  let old_path = Sys.getenv "PATH" in
  Fun.protect ~finally:(fun () -> Unix.putenv "PATH" old_path) (fun () ->
    Unix.putenv "PATH" (fake_bin ^ ":" ^ old_path);
    match Verification_presentation_inspection.inspect ~base_path:base
      ~max_image_bytes:(Env_config_keeper.KeeperVision.max_image_bytes ()) ~bytes:original with
    | Error (Verification_presentation_inspection.Policy_rejected _) -> ()
    | Error error -> Alcotest.fail (Verification_presentation_inspection.error_to_string error)
    | Ok _ -> Alcotest.fail "oversized generated PDF escaped the source bound");
  Alcotest.(check string) "original source remains byte-for-byte unchanged" original
    (read (Filename.concat root "presentation.pptx"))

let test_source_limit_before_dependencies () =
  let base_path = Filename.concat (Filename.get_temp_dir_name ()) "masc-no-presentation-runtime" in
  let bytes = String.make (Verification_pdf_inspection.max_source_bytes + 1) 'x' in
  match Verification_presentation_inspection.inspect ~base_path ~max_image_bytes:1 ~bytes with
  | Error (Policy_rejected _) -> ()
  | Error error -> Alcotest.fail (Verification_presentation_inspection.error_to_string error)
  | Ok _ -> Alcotest.fail "oversized source cannot be inspected"

let () =
  let temporary = Option.value ~default:(Filename.get_temp_dir_name ()) (Sys.getenv_opt "RUNNER_TEMP") in
  let base = Filename.concat temporary "masc-presentation-verifier" in
  let ready = List.for_all Sys.file_exists (List.map (Filename.concat (Filename.concat base "inputs"))
      ["presentation.pptx"; "expected.json"; "broken.pptx"; "external.pptx"])
    && Executable_path.command_available "soffice"
    && Sys.file_exists (Presentation_runtime_dependencies.parser_python ~base_path:base) in
  if not ready then Printf.eprintf "SKIP presentation integration: run scripts/ci/prepare-presentation-verifier.py and install LibreOffice\n%!"
  ;
  Alcotest.run "independent presentation verification"
    (["Source safety", [Alcotest.test_case "reject oversized source before dependency lookup"
      `Quick test_source_limit_before_dependencies]] @
     if ready then ["Task and Goal",[Alcotest.test_case
       "parse original slides and notes, render every slide, preserve authority"
       `Quick test_original_presentation]] else [])
