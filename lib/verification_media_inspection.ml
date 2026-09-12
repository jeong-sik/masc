let is_pdf path bytes =
  String.equal (String.lowercase_ascii (Filename.extension path)) ".pdf"
  || String.starts_with ~prefix:"%PDF-" bytes

let is_mp4 path = String.equal (String.lowercase_ascii (Filename.extension path)) ".mp4"

let video_result ~base_path ~name ~path ~bytes ~start_time =
  match Verification_video_inspection.inspect ~base_path ~bytes with
  | Error error -> Tool_result.error ~failure_class:Tool_result.Runtime_failure
      ~tool_name:name ~start_time (Verification_video_inspection.error_to_string error)
  | Ok inspection ->
    let data = `Assoc ["path",`String path; "inspection",Verification_video_inspection.to_yojson inspection] in
    Tool_result.make_ok ~tool_name:name ~start_time ~data ()

let pdf_result ~base_path ~name ~path ~bytes ~start_time ~max_image_bytes =
  match Verification_pdf_inspection.inspect
    ~base_path ~max_image_bytes ~bytes () with
  | Error error ->
    let failure_class = match error with
      (* A document refused for its size is the submitter's to fix, the same as
         a page over the image limit, and not a fault of this runtime. *)
      | Verification_pdf_inspection.Image_policy_rejected _
      | Too_many_pages _ | Rendered_bytes_exceeded _ -> Tool_result.Policy_rejection
      | Dependency_unavailable _ | Command_failed _ | Invalid_output _ | Storage_failed _ ->
        Tool_result.Runtime_failure in
    Tool_result.error ~failure_class ~tool_name:name ~start_time
      (Verification_pdf_inspection.error_to_string error)
  | Ok inspection ->
    let page_count = List.length inspection.pages in
    let pages = List.map (fun (page : Verification_pdf_inspection.page) ->
      `Assoc ["page",`Int page.number;"width_points",`Float page.width_points;
              "height_points",`Float page.height_points;"text",`String page.text;
              "rendered_media_type",`String "image/png";
              "rendered_bytes",`Int (String.length page.png);
              "rendered_sha256",`String Digestif.SHA256.(digest_string page.png |> to_hex)]) inspection.pages in
    let data = `Assoc ["path",`String path;"media_type",`String "application/pdf";
      "bytes",`Int inspection.source_bytes;"sha256",`String inspection.source_sha256;
      "page_count",`Int page_count;"pages",`List pages;
      "inspection",`String "Poppler pdftotext XML and pdftoppm rendering of the same complete captured PDF";
      "diagnostics",`List (List.map (fun text -> `String text) inspection.diagnostics);
      "visual_input",`Bool true] in
    let content_blocks = Llm_provider.Types.Text (Yojson.Safe.to_string data) ::
      List.concat_map (fun (page : Verification_pdf_inspection.page) ->
        [Llm_provider.Types.Text (Printf.sprintf "PDF page %d of %d; source sha256=%s"
          page.number page_count inspection.source_sha256);
         Llm_provider.Types.image_block ~media_type:"image/png" ~data:(Base64.encode_exn page.png) ()]) inspection.pages in
    Tool_result.make_ok ~tool_name:name ~start_time ~data ~content_blocks ()

let is_presentation path =
  String.equal (String.lowercase_ascii (Filename.extension path)) ".pptx"

let presentation_result ~base_path ~name ~path ~bytes ~start_time ~max_image_bytes =
  match Verification_presentation_inspection.inspect
    ~base_path ~max_image_bytes ~bytes with
  | Error error ->
    let failure_class = match error with
      | Verification_presentation_inspection.Policy_rejected _
      | Pdf_inspection_failed (Verification_pdf_inspection.Image_policy_rejected _) ->
        Tool_result.Policy_rejection
      | Dependency_unavailable _ | Command_failed _ | Invalid_output _
      | Storage_failed _ | Pdf_inspection_failed _ -> Tool_result.Runtime_failure in
    Tool_result.error ~failure_class ~tool_name:name ~start_time
      (Verification_presentation_inspection.error_to_string error)
  | Ok inspection ->
    let slides = List.map (fun (slide : Verification_presentation_inspection.slide) ->
      `Assoc ["slide",`Int slide.number; "text",`String slide.text;
        "speaker_notes",(match slide.speaker_notes with None -> `Null | Some notes -> `String notes)])
      inspection.slides in
    let pages = List.map (fun (page : Verification_pdf_inspection.page) ->
      `Assoc ["slide",`Int page.number;"width_points",`Float page.width_points;
        "height_points",`Float page.height_points;"rendered_text",`String page.text;
        "rendered_bytes",`Int (String.length page.png);
        "rendered_sha256",`String Digestif.SHA256.(digest_string page.png |> to_hex)])
      inspection.rendered_pdf.pages in
    let data = `Assoc ["path",`String path;
      "media_type",`String "application/vnd.openxmlformats-officedocument.presentationml.presentation";
      "bytes",`Int inspection.source_bytes;"sha256",`String inspection.source_sha256;
      "slide_count",`Int (List.length inspection.slides);"slides",`List slides;
      "rendered_pdf_sha256",`String inspection.rendered_pdf.source_sha256;
      "rendered_pdf_bytes",`Int inspection.rendered_pdf.source_bytes;
      "rendered_slides",`List pages;"visual_input",`Bool true;
      "inspection",`String "python-pptx source parsing and LibreOffice PDF rendering of the same complete captured PPTX; every PDF page inspected with Poppler";
      "not_inspected",`List [ `String "animations";`String "embedded audio/video playback";`String "chart data";`String "accessibility verdict" ];
      "diagnostics",`List (List.map (fun text -> `String text) inspection.diagnostics)] in
    let content_blocks = Llm_provider.Types.Text (Yojson.Safe.to_string data) ::
      List.concat_map (fun (page : Verification_pdf_inspection.page) ->
        [ Llm_provider.Types.Text (Printf.sprintf "PPTX slide %d of %d; original sha256=%s"
            page.number (List.length inspection.slides) inspection.source_sha256);
          Llm_provider.Types.image_block ~media_type:"image/png"
            ~data:(Base64.encode_exn page.png) () ]) inspection.rendered_pdf.pages in
    Tool_result.make_ok ~tool_name:name ~start_time ~data ~content_blocks ()

type kind = Pdf | Presentation | Video

let detect ~path ~bytes =
  if is_presentation path then Some Presentation
  else if is_mp4 path then Some Video
  else if is_pdf path bytes then Some Pdf
  else None

let whole_file_label = function Pdf -> "PDFs" | Presentation -> "PPTX files" | Video -> "MP4 files"

let inspect kind ~base_path ~name ~path ~bytes ~start_time ~max_image_bytes =
  match kind with
  | Pdf -> pdf_result ~base_path ~name ~path ~bytes ~start_time ~max_image_bytes
  | Presentation -> presentation_result ~base_path ~name ~path ~bytes ~start_time ~max_image_bytes
  | Video -> video_result ~base_path ~name ~path ~bytes ~start_time
