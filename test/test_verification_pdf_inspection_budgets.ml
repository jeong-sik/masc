(* The two budgets [Verification_pdf_inspection.inspect] puts on submitted
   evidence. Evidence is not trusted input, and the per-page image limit does
   not bound a document: every page can sit under it while the pages together
   are far too large, because they are held in one list and base64-encoded into
   a single response.

   Needs pdftotext and pdftoppm. Without them [inspect] answers
   [Dependency_unavailable] before any budget is consulted, so those cases say
   they were skipped rather than report a budget they never reached. *)

open Alcotest
module Pdf = Masc.Verification_pdf_inspection

(* Two pages, 200x200 points, one word each. Written inline so the suite needs
   no fixture file, and kept minimal because the only thing read off it is the
   page count and two rendered PNGs. *)
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

(* Generous enough that no page of the fixture can reach it, so the per-page
   limit never explains a refusal these cases see. *)
let per_page_limit = 4 * 1024 * 1024

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
    (* A finally that raises would replace whatever the case was reporting,
       so cleanup failures are swallowed here. *)
    ~finally:(fun () ->
      try Fs_compat.remove_tree dir with
      | Sys_error _ | Unix.Unix_error _ -> ())
    (fun () -> f dir)

let skipped name =
  Printf.printf "%s: skipped, pdftotext/pdftoppm not installed\n" name

let test_a_document_over_the_page_budget_never_renders () =
  if not poppler_available then skipped "page budget"
  else
    with_base_path (fun base_path ->
      match
        Pdf.inspect ~max_pages:1 ~base_path ~max_image_bytes:per_page_limit
          ~bytes:two_page_pdf ()
      with
      | Ok _ -> fail "a document over the page budget must be refused"
      (* The constructor is the claim: [Too_many_pages] is only reachable
         before the render loop, so a document this large costs no render at
         all before it is turned away. *)
      | Error (Pdf.Too_many_pages { pages; limit }) ->
        check int "it reports the count it parsed" 2 pages;
        check int "against the limit it was given" 1 limit
      | Error other -> failf "unexpected refusal: %s" (Pdf.error_to_string other))

let test_pages_under_the_per_page_limit_can_still_exceed_the_total () =
  if not poppler_available then skipped "byte budget"
  else
    with_base_path (fun base_path ->
      match
        Pdf.inspect ~max_total_image_bytes:1 ~base_path ~max_image_bytes:per_page_limit
          ~bytes:two_page_pdf ()
      with
      | Ok _ -> fail "pages over the total byte budget must be refused"
      | Error (Pdf.Rendered_bytes_exceeded { bytes; limit; _ }) ->
        check int "the total it was given" 1 limit;
        (* The per-page limit above is generous and the first page alone passes
           the total, so it is the running sum that refused, not one page. *)
        check bool "and it counted what it had rendered" true (bytes > 1)
      | Error other -> failf "unexpected refusal: %s" (Pdf.error_to_string other))

let test_a_document_inside_both_budgets_is_inspected () =
  if not poppler_available then skipped "inside both budgets"
  else
    with_base_path (fun base_path ->
      match Pdf.inspect ~base_path ~max_image_bytes:per_page_limit ~bytes:two_page_pdf () with
      | Error error -> failf "the fixture must inspect: %s" (Pdf.error_to_string error)
      | Ok inspection -> check int "both pages came back" 2 (List.length inspection.pages))

(* Runs without Poppler, so the suite still pins something when the tools are
   absent. An operator reading the refusal has to be able to tell which budget
   stopped them; the exact wording belongs to [error_to_string] and may change,
   so what is pinned is that the two do not collapse into one sentence. *)
let test_the_two_refusals_do_not_read_alike () =
  let over_pages = Pdf.error_to_string (Pdf.Too_many_pages { pages = 90; limit = 64 }) in
  let over_bytes =
    Pdf.error_to_string (Pdf.Rendered_bytes_exceeded { pages = 4; bytes = 999; limit = 100 })
  in
  check bool "a count refusal and a byte refusal say different things" true
    (String.compare over_pages over_bytes <> 0)

let test_extracted_xml_is_bounded_before_parsing () =
  if not poppler_available then skipped "extracted text budget"
  else with_base_path (fun base_path ->
    match Pdf.inspect ~max_extracted_bytes:1 ~base_path
      ~max_image_bytes:(4 * 1024 * 1024) ~bytes:two_page_pdf () with
    | Error (Pdf.Payload_budget_exceeded { bytes; limit }) ->
      check int "extraction cap" 1 limit;
      check bool "XML is larger than cap" true (bytes > limit)
    | Error error -> fail (Pdf.error_to_string error)
    | Ok _ -> fail "oversized extracted XML was parsed")

let test_large_geometry_has_bounded_raster_dimensions () =
  if not poppler_available then skipped "raster geometry"
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

let test_source_budget_precedes_dependency_or_process_lookup () =
  let bytes = String.make (Pdf.max_source_bytes + 1) 'x' in
  match Pdf.inspect ~base_path:"unused-no-process-should-start"
    ~max_image_bytes:1 ~bytes () with
  | Error (Pdf.Payload_budget_exceeded { bytes; limit }) ->
    check int "source size" (Pdf.max_source_bytes + 1) bytes;
    check int "source ceiling" Pdf.max_source_bytes limit
  | Error error -> fail (Pdf.error_to_string error)
  | Ok _ -> fail "oversized source reached inspection"

let test_poppler_calls_share_one_real_deadline () =
  with_base_path (fun base_path ->
    let bin = Filename.concat base_path "fake-poppler" in
    Unix.mkdir bin 0o700;
    let write name body =
      let path = Filename.concat bin name in
      let channel = open_out_bin path in
      output_string channel ("#!/bin/sh\nset -eu\n" ^ body);
      close_out channel;
      Unix.chmod path 0o700 in
    (* Each command finishes inside three seconds on its own. Together they
       cannot. Resetting the budget for pdftoppm must fail this assertion. *)
    write "pdftotext" {|/bin/sleep 2
for destination do :; done
printf '%s' '<doc><page width="200" height="200"/></doc>' > "$destination"
|};
    let started = Filename.concat base_path "render-started" in
    write "pdftoppm" (Printf.sprintf {|printf started > %s
/bin/sleep 2
for destination do :; done
printf '\211PNG\r\n\032\n' > "$destination.png"
|} (Filename.quote started));
    let original_path = Sys.getenv_opt "PATH" in
    Fun.protect ~finally:(fun () -> Unix.putenv "PATH" (Option.value ~default:"" original_path))
      (fun () ->
        Unix.putenv "PATH" (bin ^ ":" ^ Option.value ~default:"" original_path);
        match Pdf.For_testing.inspect_with_budget ~budget_sec:3. ~base_path
          ~max_image_bytes:per_page_limit ~bytes:two_page_pdf () with
        | Error (Pdf.Poppler_budget_spent {program;budget_sec}) ->
          check string "second tool spends remaining shared budget" "pdftoppm" program;
          check (float 0.) "one document budget" 3. budget_sec;
          check bool "renderer actually started" true (Sys.file_exists started)
        | Error error -> fail (Pdf.error_to_string error)
        | Ok _ -> fail "each Poppler command received a fresh budget"))

(* [extract_text] is the text half of [inspect]. These cases run it against
   fake Poppler tools so they do not depend on an installed Poppler. *)
let with_fake_poppler ~pdftotext ~pdftoppm f =
  with_base_path (fun base_path ->
    let bin = Filename.concat base_path "fake-poppler" in
    Unix.mkdir bin 0o700;
    let write name body =
      let path = Filename.concat bin name in
      let channel = open_out_bin path in
      output_string channel ("#!/bin/sh\nset -eu\n" ^ body);
      close_out channel;
      Unix.chmod path 0o700 in
    let text_started = Filename.concat base_path "pdftotext-started" in
    let render_started = Filename.concat base_path "pdftoppm-started" in
    write "pdftotext" (Printf.sprintf "printf started > %s\n%s" (Filename.quote text_started) pdftotext);
    write "pdftoppm" (Printf.sprintf "printf started > %s\n%s" (Filename.quote render_started) pdftoppm);
    let original_path = Sys.getenv_opt "PATH" in
    Fun.protect ~finally:(fun () -> Unix.putenv "PATH" (Option.value ~default:"" original_path))
      (fun () ->
        Unix.putenv "PATH" (bin ^ ":" ^ Option.value ~default:"" original_path);
        f ~base_path ~text_started ~render_started))

let leftover_capture_dirs base_path =
  let capture = Masc.Keeper_execute_output_files.capture_directory ~base_path in
  if not (Sys.file_exists capture) then []
  else
    Sys.readdir capture |> Array.to_list
    |> List.filter (fun name -> String.length name >= 4 && String.sub name 0 4 = "pdf-")

let two_page_xhtml = {|for destination do :; done
printf '%s' '<doc><page width="200" height="200"><line><word>Page</word><word>One</word></line></page><page width="200" height="200"><line><word>Page</word><word>Two</word></line></page></doc>' > "$destination"
|}

let test_extract_text_returns_pages_without_rendering () =
  with_fake_poppler ~pdftotext:two_page_xhtml ~pdftoppm:"exit 1\n"
    (fun ~base_path ~text_started:_ ~render_started ->
      match
        Pdf.extract_text ~deadline:(Monotonic_deadline.after ~seconds:30.) ~budget_sec:30.
          ~base_path ~bytes:two_page_pdf ()
      with
      | Error error -> failf "extract_text must succeed: %s" (Pdf.error_to_string error)
      | Ok pages ->
        check (list string) "one text per page" [ "Page One"; "Page Two" ] pages;
        check bool "the renderer was never started" false (Sys.file_exists render_started);
        check (list string) "the capture directory was removed" [] (leftover_capture_dirs base_path))

let test_extract_text_does_not_start_after_the_deadline () =
  with_fake_poppler ~pdftotext:two_page_xhtml ~pdftoppm:"exit 1\n"
    (fun ~base_path ~text_started ~render_started:_ ->
      match
        Pdf.extract_text ~deadline:(Monotonic_deadline.after ~seconds:0.) ~budget_sec:7.
          ~base_path ~bytes:two_page_pdf ()
      with
      | Error (Pdf.Poppler_budget_spent { program; budget_sec }) ->
        check string "the first tool is the one refused" "pdftotext" program;
        check (float 0.) "the budget reported is the one the caller gave" 7. budget_sec;
        check bool "no process was started" false (Sys.file_exists text_started);
        check (list string) "the capture directory was removed" [] (leftover_capture_dirs base_path)
      | Error error -> fail (Pdf.error_to_string error)
      | Ok _ -> fail "a spent deadline must not extract")

let test_extract_text_stops_a_slow_tool_at_the_callers_deadline () =
  with_fake_poppler ~pdftotext:("/bin/sleep 5\n" ^ two_page_xhtml) ~pdftoppm:"exit 1\n"
    (fun ~base_path ~text_started:_ ~render_started:_ ->
      let started = Unix.gettimeofday () in
      (match
         Pdf.extract_text ~deadline:(Monotonic_deadline.after ~seconds:0.5) ~budget_sec:0.5
           ~base_path ~bytes:two_page_pdf ()
       with
       | Error (Pdf.Poppler_budget_spent { program; _ }) ->
         check string "the slow tool is named" "pdftotext" program
       | Error error -> fail (Pdf.error_to_string error)
       | Ok _ -> fail "a tool that outlives the deadline must not answer");
      check bool "it returned well before the tool would have" true
        (Unix.gettimeofday () -. started < 4.);
      check (list string) "the capture directory was removed" [] (leftover_capture_dirs base_path))

(* H5-S2 through the production document reader: a PDF-only fact reaches the
   projection by way of [extract_text]. Poppler is faked, so this proves the
   wiring and the failure mapping, not extraction of a real PDF. *)
let h5_pdf_block () =
  Agent_core.Types.document_block
    ~media_type:"application/pdf"
    ~data:(Base64.encode_string two_page_pdf)
    ~source_type:Agent_core.Types.Base64
    ()

let project_pdf ~base_path ~budget_sec =
  Masc.Keeper_media_reading.project_blocks
    ~base_path ~keeper_name:"h5-pdf" ~needs_projection:(fun _ -> true)
    ~deadline:(Monotonic_deadline.after ~seconds:budget_sec)
    ~read:(Masc.Keeper_media_reading.production_reader ~base_path ~budget_sec)
    [ h5_pdf_block () ]

let text_of = function
  | [ Agent_core.Types.Text text ], _ -> text
  | _ -> fail "expected one projected text block"

let contains ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec loop i = i + n <= h && (String.sub haystack i n = needle || loop (i + 1)) in
  n = 0 || loop 0

let test_h5_production_pdf_reader_projects_the_document_text () =
  with_fake_poppler ~pdftotext:two_page_xhtml ~pdftoppm:"exit 1\n"
    (fun ~base_path ~text_started:_ ~render_started ->
      let text = text_of (project_pdf ~base_path ~budget_sec:30.) in
      check bool "the page text reached the projection" true (contains ~needle:"Page One" text);
      check bool "status is read" true (contains ~needle:"status=read" text);
      check bool "nothing was rendered" false (Sys.file_exists render_started))

let test_h5_production_pdf_reader_marks_a_spent_budget_unavailable () =
  with_fake_poppler ~pdftotext:("/bin/sleep 5\n" ^ two_page_xhtml) ~pdftoppm:"exit 1\n"
    (fun ~base_path ~text_started:_ ~render_started:_ ->
      let text = text_of (project_pdf ~base_path ~budget_sec:0.5) in
      check bool "marked unavailable" true (contains ~needle:"status=unavailable" text);
      check bool "with the budget reason" true (contains ~needle:"budget_spent" text);
      check bool "no extracted text invented" false (contains ~needle:"Page One" text))

(* H5-S2, real Poppler. One page, one fact that exists only in the PDF text:
   "The ledger year is 1987." Runs for real wherever pdftotext/pdftoppm are
   installed (the Test workflow installs poppler-utils); otherwise it says it was
   skipped, as the other Poppler cases here do. A skip is not a pass. *)
let h5_ledger_pdf = {hpdf|%PDF-1.4
1 0 obj
<< /Type /Catalog /Pages 2 0 R >>
endobj
2 0 obj
<< /Type /Pages /Kids [3 0 R] /Count 1 >>
endobj
3 0 obj
<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 200] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>
endobj
4 0 obj
<< /Length 67 >>
stream
BT /F1 12 Tf 20 100 Td (H5 fixture. The ledger year is 1987.) Tj ET
endstream
endobj
5 0 obj
<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>
endobj
xref
0 6
0000000000 65535 f 
0000000009 00000 n 
0000000058 00000 n 
0000000115 00000 n 
0000000241 00000 n 
0000000358 00000 n 
trailer
<< /Size 6 /Root 1 0 R >>
startxref
428
%%EOF
|hpdf}

let test_h5_real_poppler_extracts_the_pdf_only_fact () =
  if not poppler_available then skipped "H5 real extraction"
  else
    with_base_path (fun base_path ->
      match
        Pdf.extract_text ~deadline:(Monotonic_deadline.after ~seconds:60.) ~budget_sec:60.
          ~base_path ~bytes:h5_ledger_pdf ()
      with
      | Error error -> failf "the fixture must extract: %s" (Pdf.error_to_string error)
      | Ok pages ->
        check int "one page" 1 (List.length pages);
        check bool "the PDF-only fact came back" true
          (contains ~needle:"ledger year is 1987" (List.hd pages));
        check (list string) "the capture directory was removed" [] (leftover_capture_dirs base_path))

let test_h5_real_poppler_reaches_the_projection () =
  if not poppler_available then skipped "H5 real projection"
  else
    with_base_path (fun base_path ->
      let blocks =
        Masc.Keeper_media_reading.project_blocks
          ~base_path ~keeper_name:"h5-real-pdf" ~needs_projection:(fun _ -> true)
          ~deadline:(Monotonic_deadline.after ~seconds:60.)
          ~read:(Masc.Keeper_media_reading.production_reader ~base_path ~budget_sec:60.)
          [ Agent_core.Types.document_block ~media_type:"application/pdf"
              ~data:(Base64.encode_string h5_ledger_pdf)
              ~source_type:Agent_core.Types.Base64 () ]
      in
      let text = text_of blocks in
      check bool "status is read" true (contains ~needle:"status=read" text);
      check bool "the fact is in the projection" true
        (contains ~needle:"ledger year is 1987" text);
      check bool "bound to the source bytes" true
        (contains ~needle:("sha256:" ^ Masc.Keeper_media_reading.source_sha256 h5_ledger_pdf) text))

let () =
  run "verification pdf inspection budgets"
    [ ( "budgets"
      , [ test_case "Poppler calls share one real deadline" `Quick
            test_poppler_calls_share_one_real_deadline
        ; test_case "a document over the page budget never renders" `Quick
            test_a_document_over_the_page_budget_never_renders
        ; test_case "pages under the per-page limit can still exceed the total" `Quick
            test_pages_under_the_per_page_limit_can_still_exceed_the_total
        ; test_case "a document inside both budgets is inspected" `Quick
            test_a_document_inside_both_budgets_is_inspected
        ; test_case "extracted XML is bounded before parsing" `Quick
            test_extracted_xml_is_bounded_before_parsing
        ; test_case "large geometry is raster bounded" `Quick
            test_large_geometry_has_bounded_raster_dimensions
        ; test_case "source cap precedes dependency lookup" `Quick
            test_source_budget_precedes_dependency_or_process_lookup
        ; test_case "the two refusals do not read alike" `Quick
            test_the_two_refusals_do_not_read_alike
        ; test_case "extract_text returns pages without rendering" `Quick
            test_extract_text_returns_pages_without_rendering
        ; test_case "extract_text does not start after the deadline" `Quick
            test_extract_text_does_not_start_after_the_deadline
        ; test_case "extract_text stops a slow tool at the caller's deadline" `Quick
            test_extract_text_stops_a_slow_tool_at_the_callers_deadline
        ; test_case "H5 production PDF reader projects the document text" `Quick
            test_h5_production_pdf_reader_projects_the_document_text
        ; test_case "H5 production PDF reader marks a spent budget unavailable" `Quick
            test_h5_production_pdf_reader_marks_a_spent_budget_unavailable
        ; test_case "H5 real Poppler extracts the PDF-only fact" `Quick
            test_h5_real_poppler_extracts_the_pdf_only_fact
        ; test_case "H5 real Poppler reaches the projection" `Quick
            test_h5_real_poppler_reaches_the_projection
        ] )
    ]
