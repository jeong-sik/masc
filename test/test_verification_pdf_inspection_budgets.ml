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

let () =
  run "verification pdf inspection budgets"
    [ ( "budgets"
      , [ test_case "a document over the page budget never renders" `Quick
            test_a_document_over_the_page_budget_never_renders
        ; test_case "pages under the per-page limit can still exceed the total" `Quick
            test_pages_under_the_per_page_limit_can_still_exceed_the_total
        ; test_case "a document inside both budgets is inspected" `Quick
            test_a_document_inside_both_budgets_is_inspected
        ; test_case "the two refusals do not read alike" `Quick
            test_the_two_refusals_do_not_read_alike
        ] )
    ]
