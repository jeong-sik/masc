type slide = { number : int; text : string; speaker_notes : string option; visible : bool; hyperlinks : string list }

type t =
  { source_bytes : int
  ; source_sha256 : string
  ; slides : slide list
  ; rendered_pdf : Verification_pdf_inspection.t
  ; diagnostics : string list
  }

type error =
  | Dependency_unavailable of string list
  | Command_failed of { program : string; status : Unix.process_status; detail : string }
  | Invalid_output of string
  | Invalid_document of string
  | Policy_rejected of string
  | Storage_failed of string
  | Pdf_inspection_failed of Verification_pdf_inspection.error

let error_to_string = function
  | Dependency_unavailable details ->
    "presentation_dependency_unavailable: open presentation tools in masc setup, or run masc prerequisite-actions presentation-tools; "
    ^ String.concat "; " details
  | Command_failed {program;status;detail} ->
    let status = match status with
      | Unix.WEXITED code -> Printf.sprintf "exit=%d" code
      | Unix.WSIGNALED signal -> Printf.sprintf "signal=%d" signal
      | Unix.WSTOPPED signal -> Printf.sprintf "stopped=%d" signal in
    Printf.sprintf "presentation_inspection_failed: %s %s: %s" program status detail
  | Invalid_document detail -> "presentation_invalid_document: " ^ detail
  | Invalid_output detail -> "presentation_inspection_invalid_output: " ^ detail
  | Policy_rejected detail -> "presentation_inspection_policy_rejected: " ^ detail
  | Storage_failed detail -> "presentation_inspection_storage_failed: " ^ detail
  | Pdf_inspection_failed error -> Verification_pdf_inspection.error_to_string error

let ( let* ) = Result.bind

let read_owned root path =
  match Fs_compat.load_owned_regular_file ~ownership_root:root path with
  | Ok (Some bytes) -> Ok bytes
  | Ok None -> Error (Invalid_output ("missing " ^ Filename.basename path))
  | Error error -> Error (Storage_failed (Fs_compat.owned_regular_file_read_error_to_string error))

let field key fields = List.assoc_opt key fields

let parse_hyperlinks = function
  | `List rows ->
    List.fold_right (fun row result ->
      let* rest = result in
      match row with `String target -> Ok (target :: rest)
      | _ -> Error (Invalid_output "invalid hyperlink")) rows (Ok [])
  | _ -> Error (Invalid_output "invalid hyperlinks")

let parse_slides = function
  | `List (_ :: _ as rows) ->
    let rec loop number acc = function
      | [] -> Ok (List.rev acc)
      | `Assoc fields :: rest ->
        (match field "number" fields, field "text" fields, field "speaker_notes" fields, field "visible" fields, field "hyperlinks" fields with
         | Some (`Int actual), Some (`String text), Some notes, Some (`Bool visible), Some links when actual = number ->
           let* hyperlinks = parse_hyperlinks links in
           let* speaker_notes = match notes with
             | `Null -> Ok None
             | `String text -> Ok (Some text)
             | _ -> Error (Invalid_output "invalid speaker notes") in
           loop (number + 1) ({number;text;speaker_notes;visible;hyperlinks} :: acc) rest
         | _ -> Error (Invalid_output "invalid or out-of-order slide"))
      | _ -> Error (Invalid_output "invalid slide object") in
    loop 1 [] rows
  | _ -> Error (Invalid_output "parser returned no slides")

let parse_strings = function
  | `List rows ->
    List.fold_right (fun row result ->
      let* rest = result in
      match row with
      | `String text -> Ok (text :: rest)
      | _ -> Error (Invalid_output "invalid parser diagnostics")) rows (Ok [])
  | _ -> Error (Invalid_output "missing parser diagnostics")

let parse_result ~bytes ~sha256 content =
  let* json = try Ok (Yojson.Safe.from_string content)
    with Yojson.Json_error detail -> Error (Invalid_output detail) in
  match json with
  | `Assoc fields ->
    (match field "schema" fields, field "ok" fields with
     | Some (`String "masc.presentation-inspection.v1"), Some (`Bool true) ->
       (match field "source_bytes" fields, field "source_sha256" fields,
              field "slides" fields, field "diagnostics" fields with
        | Some (`Int source_bytes), Some (`String source_sha256), Some slides, Some diagnostics
          when source_bytes = String.length bytes && String.equal source_sha256 sha256 ->
          let* slides = parse_slides slides in
          let* diagnostics = parse_strings diagnostics in
          Ok (slides,diagnostics)
        | _ -> Error (Invalid_output "parser source identity or payload does not match captured PPTX"))
     | Some (`String "masc.presentation-inspection.v1"), Some (`Bool false) ->
       (match field "kind" fields, field "detail" fields with
        | Some (`String "dependency"), Some (`String detail) -> Error (Dependency_unavailable [detail])
        | Some (`String "policy"), Some (`String detail) -> Error (Policy_rejected detail)
        | Some (`String "invalid_document"), Some (`String detail) -> Error (Invalid_document detail)
        | _ -> Error (Invalid_output "invalid parser failure"))
     | _ -> Error (Invalid_output "invalid parser envelope"))
  | _ -> Error (Invalid_output "parser response is not an object")

(* LibreOffice documents UserInstallation isolation and explicit PDF export
   properties here. Hidden slides must remain in the ordered page inventory.
   https://help.libreoffice.org/latest/en-US/text/shared/guide/start_parameters.html
   https://help.libreoffice.org/latest/en-US/text/shared/guide/pdf_params.html *)
let pdf_filter =
  "pdf:impress_pdf_Export:{\"ExportHiddenSlides\":{\"type\":\"boolean\",\"value\":\"true\"},\"ExportNotesPages\":{\"type\":\"boolean\",\"value\":\"false\"}}"

let inspect ~base_path ~max_image_bytes ~bytes =
  let python = Presentation_runtime_dependencies.parser_python ~base_path in
  let missing = List.filter (fun program -> not (Executable_path.command_available program))
      [python; "soffice"] in
  if missing <> [] then Error (Dependency_unavailable missing)
  else Eio.Switch.run @@ fun sw ->
    let root = Filename.concat (Keeper_execute_output_files.capture_directory ~base_path)
        ("presentation-" ^ Random_id.uuid_v7 ()) in
    try
      Fs_compat.mkdir_p root;
      Unix.chmod root 0o700;
      Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree root);
      let source = Filename.concat root "source.pptx" in
      Auth.save_private_text_file source bytes;
      Unix.chmod source 0o400;
      let sha256 = Digestif.SHA256.(digest_string bytes |> to_hex) in
      (* Untrusted document decoders have a per-process safety deadline; this
         does not expire the verification task or its evidence. *)
      let run program arguments =
        match Process_eio.run_argv_with_status_split_or_refusal
            ~env:(Env_keeper_scrub.filter_environment (Unix.environment ()))
            ~timeout_sec:120. ~cwd:root (program :: arguments) with
        | Error (Process_eio.Executable_not_found missing) -> Error (Dependency_unavailable [missing])
        | Error refusal -> Error (Storage_failed (Process_eio.spawn_refusal_to_string refusal))
        | Ok (status,stdout,stderr) ->
          let detail = String.trim (stdout ^ "\n" ^ stderr) in
          match status with
          | Unix.WEXITED 0 -> Ok detail
          | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
            Error (Command_failed {program;status;detail}) in
      let parsed_path = Filename.concat root "inspection.json" in
      let* parser_output = run python
          ["-I"; "-B"; "-c"; Verification_presentation_inspection_parser.source;
           source; Presentation_runtime_dependencies.environment_dir ~base_path; parsed_path] in
      let* parsed = read_owned root parsed_path in
      let* slides, parser_diagnostics = parse_result ~bytes ~sha256 parsed in
      let* after_parse = read_owned root source in
      let* () = if String.equal bytes after_parse then Ok ()
        else Error (Invalid_output "captured PPTX changed during parsing") in
      let profile = Filename.concat root "office-profile" in
      Fs_compat.mkdir_p profile;
      let profile_uri = Uri.make ~scheme:"file" ~host:"" ~path:(Unix.realpath profile) () |> Uri.to_string in
      let* renderer_version = run "soffice" ["--headless"; "--version"] in
      let* renderer_output = run "soffice"
          ["-env:UserInstallation=" ^ profile_uri; "--headless"; "--nologo";
           "--nodefault"; "--norestore"; "--convert-to"; pdf_filter; "--outdir"; root; source] in
      let* pdf_bytes = read_owned root (Filename.concat root "source.pdf") in
      let* rendered_pdf = Verification_pdf_inspection.inspect ~base_path ~max_image_bytes ~bytes:pdf_bytes
        |> Result.map_error (fun error -> Pdf_inspection_failed error) in
      let* () = if List.length slides = List.length rendered_pdf.pages then Ok ()
        else Error (Invalid_output (Printf.sprintf "PPTX has %d slides but rendering has %d PDF pages"
          (List.length slides) (List.length rendered_pdf.pages))) in
      let* retained = read_owned root source in
      if not (String.equal retained bytes) then Error (Invalid_output "captured PPTX changed during rendering")
      else Ok {source_bytes=String.length bytes; source_sha256=sha256; slides; rendered_pdf;
        diagnostics=parser_diagnostics @ rendered_pdf.diagnostics @ List.filter (fun text -> text <> "")
          [parser_output; renderer_version; renderer_output]}
    with
    | Sys_error detail -> Error (Storage_failed detail)
    | Unix.Unix_error (code,operation,_) ->
      Error (Storage_failed (operation ^ ": " ^ Unix.error_message code))
