type page =
  { number : int
  ; width_points : float
  ; height_points : float
  ; text : string
  ; png : string
  }

type t =
  { source_bytes : int
  ; source_sha256 : string
  ; pages : page list
  ; diagnostics : string list
  }

type error =
  | Dependency_unavailable of string list
  | Command_failed of { program : string; status : Unix.process_status; detail : string }
  | Invalid_output of string
  | Image_policy_rejected of { page : int; bytes : int; limit : int }
  | Too_many_pages of { pages : int; limit : int }
  | Rendered_bytes_exceeded of { pages : int; bytes : int; limit : int }
  | Storage_failed of string

let error_to_string = function
  | Dependency_unavailable programs ->
    "pdf_dependency_unavailable: open PDF tools in masc setup, or run masc prerequisite-actions pdf-tools; missing "
    ^ String.concat ", " programs
  | Command_failed {program;status;detail} ->
    let status = match status with
      | Unix.WEXITED code -> Printf.sprintf "exit=%d" code
      | Unix.WSIGNALED signal -> Printf.sprintf "signal=%d" signal
      | Unix.WSTOPPED signal -> Printf.sprintf "stopped=%d" signal in
    Printf.sprintf "pdf_inspection_failed: %s %s: %s" program status detail
  | Invalid_output detail -> "pdf_inspection_invalid_output: " ^ detail
  | Image_policy_rejected {page;bytes;limit} ->
    Printf.sprintf "PDF page %d image has %d bytes, exceeding configured image limit %d" page bytes limit
  | Too_many_pages {pages;limit} ->
    Printf.sprintf
      "pdf_page_budget_exceeded: %d pages, over the %d this verifier renders"
      pages limit
  | Rendered_bytes_exceeded {pages;bytes;limit} ->
    Printf.sprintf
      "pdf_render_budget_exceeded: %d pages rendered to %d bytes, over the %d one \
       response carries"
      pages bytes limit
  | Storage_failed detail -> "pdf_inspection_storage_failed: " ^ detail

let ( let* ) = Result.bind

let read_owned root path =
  match Fs_compat.load_owned_regular_file ~ownership_root:root path with
  | Ok (Some bytes) -> Ok bytes
  | Ok None -> Error (Invalid_output ("missing " ^ Filename.basename path))
  | Error error -> Error (Storage_failed (Fs_compat.owned_regular_file_read_error_to_string error))

let page_geometry node key =
  match Option.bind (Markup_document.attribute key node) float_of_string_opt with
  | Some value when Float.is_finite value && value > 0. -> Ok value
  | None | Some _ -> Error (Invalid_output ("invalid PDF page " ^ key))

let parsed_pages xml =
  let* tree = Markup_document.parse_xml xml |> Result.map_error (fun e -> Invalid_output e) in
  match Markup_document.elements_named "page" tree with
  | [] -> Error (Invalid_output "Poppler returned no document pages")
  | pages ->
    List.fold_left (fun acc node ->
      let* pages = acc in
      let* width_points = page_geometry node "width" in
      let* height_points = page_geometry node "height" in
      let text = Markup_document.elements_named "line" [node]
        |> List.map (fun line -> Markup_document.elements_named "word" [line]
          |> List.map Markup_document.text_content |> String.concat " ")
        |> String.concat "\n" in
      Ok ((width_points,height_points,text) :: pages)) (Ok []) pages
    |> Result.map List.rev

(* Submitted evidence is not trusted input. A malformed or deliberately
   expensive PDF can leave either Poppler command sitting there, and the
   completion verifier holds its review slot for as long as it waits, so one
   document would wedge Task and Goal verification. The bound is generous
   enough for a large scanned document on a loaded machine; a render that
   needs longer is reported as a failure rather than waited on. *)
let command_timeout_sec = 120.

(* Every page can sit under [max_image_bytes] and the document still be too
   large: the render loop holds each PNG and the result base64-encodes all of
   them into one response. Both the count and the total are capped, because
   either one alone lets the other run away. *)
let max_pages = 64
let max_total_image_bytes = 24 * 1024 * 1024

let inspect ?(max_pages = max_pages) ?(max_total_image_bytes = max_total_image_bytes)
      ~base_path ~max_image_bytes ~bytes () =
  let missing = Pdf_runtime_dependencies.missing () in
  if missing <> [] then Error (Dependency_unavailable missing)
  else
    Eio.Switch.run @@ fun sw ->
    let root = Filename.concat (Keeper_execute_output_files.capture_directory ~base_path)
        ("pdf-" ^ Random_id.uuid_v7 ()) in
    try
      Fs_compat.mkdir_p root;
      Unix.chmod root 0o700;
      Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree root);
      let source = Filename.concat root "source.pdf" in
      Auth.save_private_text_file source bytes;
      Unix.chmod source 0o400;
      let diagnostics = ref [] in
      let run program arguments =
        let status, _stdout, stderr = Process_eio.run_argv_with_status_split
            ~timeout_sec:command_timeout_sec
            ~env:(Env_keeper_scrub.filter_environment (Unix.environment ()))
            ~cwd:root (program :: arguments) in
        let detail = String.trim stderr in
        match status with
        | Unix.WEXITED 0 ->
          if detail <> "" then diagnostics := (program ^ ": " ^ detail) :: !diagnostics;
          Ok ()
        | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
          Error (Command_failed {program;status;detail}) in
      let xml_path = Filename.concat root "pages.xhtml" in
      let* () = run "pdftotext" ["-bbox-layout";"-enc";"UTF-8";source;xml_path] in
      let* xml = read_owned root xml_path in
      let* descriptions = parsed_pages xml in
      let page_count = List.length descriptions in
      let* () =
        if page_count > max_pages
        then Error (Too_many_pages {pages=page_count;limit=max_pages})
        else Ok () in
      let rec render number total acc = function
        | [] -> Ok (List.rev acc)
        | (width_points,height_points,text) :: rest ->
          let prefix = Filename.concat root (Printf.sprintf "page-%d" number) in
          (* Explicit single-page output gives the page its declared index,
             avoiding filename/count guesses and preserving all PDF pages. *)
          let* () = run "pdftoppm"
            ["-png";"-singlefile";"-f";string_of_int number;"-l";string_of_int number;source;prefix] in
          let* png = read_owned root (prefix ^ ".png") in
          let size = String.length png in
          let* () = if size > max_image_bytes then
              Error (Image_policy_rejected {page=number;bytes=size;limit=max_image_bytes})
            else match Keeper_vision_tool.sniff_image_media_type png with
              | Ok "image/png" -> Ok ()
              | Ok _ | Error _ -> Error (Invalid_output "Poppler page rendering is not a PNG") in
          let total = total + size in
          let* () =
            if total > max_total_image_bytes
            then Error (Rendered_bytes_exceeded
                          {pages=page_count;bytes=total;limit=max_total_image_bytes})
            else Ok () in
          render (number + 1) total ({number;width_points;height_points;text;png} :: acc) rest in
      let* pages = render 1 0 [] descriptions in
      let* retained = read_owned root source in
      if not (String.equal retained bytes) then Error (Invalid_output "captured PDF changed during inspection")
      else Ok {source_bytes=String.length bytes;source_sha256=Digestif.SHA256.(digest_string bytes |> to_hex);
               pages;diagnostics=List.rev !diagnostics}
    with
    | Sys_error detail -> Error (Storage_failed detail)
    | Unix.Unix_error (code,operation,_) ->
      Error (Storage_failed (operation ^ ": " ^ Unix.error_message code))
