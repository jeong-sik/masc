(** The page and byte budgets [Verification_pdf_inspection.inspect] applies to
    submitted evidence. Evidence is not trusted input: every page can sit under
    the per-page image limit and the document still be too large, because the
    pages are held together and base64-encoded into one response.

    Needs pdftotext and pdftoppm. Without them [inspect] answers
    [Dependency_unavailable] before any budget is consulted, and these cases say
    so rather than reporting a budget they never reached. *)

open Alcotest
module Pdf = Masc.Verification_pdf_inspection

(* Two pages, 200x200, one word each. Written out rather than fetched so the
   suite needs no fixture file, and kept minimal so pdftotext's page count is
   the only thing it is relied on for. *)
let two_page_pdf = {|%PDF-1.4
1 0 obj
<< /Type /Catalog /Pages 2 0 R >>
endobj
2 0 obj
<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>
endobj
3 0 obj
<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 4 0 R /Resources << /Font << /F1 7 0 R >> >> >>
endobj
4 0 obj
<< /Length 39 >>
stream
BT /F1 12 Tf 20 100 Td (Page One) Tj ET
endstream
endobj
5 0 obj
<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 6 0 R /Resources << /Font << /F1 7 0 R >> >> >>
endobj
6 0 obj
<< /Length 39 >>
stream
BT /F1 12 Tf 20 100 Td (Page Two) Tj ET
endstream
endobj
7 0 obj
<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>
endobj
xref
0 8
0000000000 65535 f 
0000000009 00000 n 
0000000058 00000 n 
0000000121 00000 n 
0000000247 00000 n 
0000000336 00000 n 
0000000462 00000 n 
0000000551 00000 n 
trailer
<< /Size 8 /Root 1 0 R >>
startxref
621
%%EOF
|}

let poppler_available =
  List.for_all Executable_path.command_available [ "pdftotext"; "pdftoppm" ]

(* [inspect] opens an Eio switch for the capture directory, so it needs a
   context to open it in. *)
let with_base_path f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = Filename.temp_file "pdf-budget-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () -> f dir)

let skip_without_poppler name =
  Printf.printf "%s: skipped, pdftotext/pdftoppm not installed\n" name

let test_a_document_over_the_page_budget_is_refused () =
  if not poppler_available then skip_without_poppler "page budget"
  else
    with_base_path (fun base_path ->
      match
        Pdf.inspect ~max_pages:1 ~base_path ~max_image_bytes:(4 * 1024 * 1024)
          ~bytes:two_page_pdf ()
      with
      | Ok _ -> fail "a document over the page budget must be refused"
      | Error (Pdf.Page_budget_exceeded { pages; page_limit; bytes; byte_limit = _ }) ->
        check int "the count it found" 2 pages;
        check int "against the limit it was given" 1 page_limit;
        (* Refused before rendering, so there are no bytes to report. *)
        check int "and nothing was rendered" 0 bytes
      | Error other -> failf "unexpected refusal: %s" (Pdf.error_to_string other))

let test_pages_over_the_total_byte_budget_are_refused () =
  if not poppler_available then skip_without_poppler "byte budget"
  else
    with_base_path (fun base_path ->
      match
        Pdf.inspect ~max_total_image_bytes:1 ~base_path
          ~max_image_bytes:(4 * 1024 * 1024) ~bytes:two_page_pdf ()
      with
      | Ok _ -> fail "pages over the total byte budget must be refused"
      | Error (Pdf.Page_budget_exceeded { bytes; byte_limit; _ }) ->
        check int "the limit it was given" 1 byte_limit;
        (* The first rendered page already passes it, and the per-page limit
           above is generous, so this is the aggregate talking. *)
        check bool "and it counted what was rendered" true (bytes > 1)
      | Error other -> failf "unexpected refusal: %s" (Pdf.error_to_string other))

let test_the_document_passes_inside_both_budgets () =
  if not poppler_available then skip_without_poppler "inside budgets"
  else
    with_base_path (fun base_path ->
      match
        Pdf.inspect ~base_path ~max_image_bytes:(4 * 1024 * 1024) ~bytes:two_page_pdf ()
      with
      | Error error -> failf "the fixture must inspect: %s" (Pdf.error_to_string error)
      | Ok inspection -> check int "both pages came back" 2 (List.length inspection.pages))

let test_extracted_xml_is_bounded_before_parsing () =
  if not poppler_available then skip_without_poppler "extracted text budget"
  else with_base_path (fun base_path ->
    match Pdf.inspect ~max_extracted_bytes:1 ~base_path
      ~max_image_bytes:(4 * 1024 * 1024) ~bytes:two_page_pdf () with
    | Error (Pdf.Payload_budget_exceeded { bytes; limit }) ->
      check int "extraction cap" 1 limit;
      check bool "XML is larger than cap" true (bytes > limit)
    | Error error -> fail (Pdf.error_to_string error)
    | Ok _ -> fail "oversized extracted XML was parsed")

let test_large_geometry_has_bounded_raster_dimensions () =
  if not poppler_available then skip_without_poppler "raster geometry"
  else with_base_path (fun base_path ->
    let bytes = Astring.String.cuts ~sep:"200 200" two_page_pdf
      |> String.concat "20000 20000" in
    match Pdf.inspect ~base_path ~max_image_bytes:(4 * 1024 * 1024) ~bytes () with
    | Error error -> fail (Pdf.error_to_string error)
    | Ok inspection ->
      List.iter (fun (page : Pdf.page) ->
        let uint32 offset =
          let value = ref 0 in
          for i = offset to offset + 3 do
            value := (!value lsl 8) lor Char.code page.png.[i]
          done;
          !value
        in
        check bool "original geometry retained" true (page.width_points > 2000.);
        check bool "PNG width bounded before render" true (uint32 16 <= Pdf.max_page_pixels);
        check bool "PNG height bounded before render" true (uint32 20 <= Pdf.max_page_pixels))
        inspection.pages)

let test_each_refusal_says_which_budget () =
  let counted =
    Pdf.error_to_string
      (Pdf.Page_budget_exceeded { pages = 90; page_limit = 64; bytes = 0; byte_limit = 1 })
  in
  check bool "a page-count refusal names the pages" true
    (Astring.String.is_infix ~affix:"90 pages" counted);
  check bool "and does not claim rendered bytes" false
    (Astring.String.is_infix ~affix:"bytes" counted);
  let rendered =
    Pdf.error_to_string
      (Pdf.Page_budget_exceeded { pages = 4; page_limit = 64; bytes = 999; byte_limit = 100 })
  in
  check bool "a byte refusal names what was rendered" true
    (Astring.String.is_infix ~affix:"999 bytes" rendered)

let () =
  run "verification pdf budgets"
    [ ( "budgets"
      , [ test_case "a document over the page budget" `Quick
            test_a_document_over_the_page_budget_is_refused
        ; test_case "pages over the total byte budget" `Quick
            test_pages_over_the_total_byte_budget_are_refused
        ; test_case "inside both budgets" `Quick
            test_the_document_passes_inside_both_budgets
        ; test_case "extracted XML is bounded before parsing" `Quick
            test_extracted_xml_is_bounded_before_parsing
        ; test_case "large page geometry has bounded raster dimensions" `Quick
            test_large_geometry_has_bounded_raster_dimensions
        ; test_case "each refusal says which budget" `Quick
            test_each_refusal_says_which_budget
        ] )
    ]
