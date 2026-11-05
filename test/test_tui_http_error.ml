open Alcotest

(* A named reference is part of each page: the first one Markup reads builds
   a table, and that first use must be safe on any domain. *)
let page index =
  Printf.sprintf
    "<html><head><title>429 Too Many Requests &amp; retry %d</title></head>\
     <body><h1>Too Many Requests</h1></body></html>" index

let summarize ~body content_type =
  Masc_tui_http_error.html_response ~status_code:429
    ~headers:["Content-Type", content_type] ~body

let parallel_content_types =
  [| "text/html; charset=utf-8"; "text/html"; "TEXT/HTML; Charset=\"UTF-8\"";
     "text/html;charset=windows-1252" |]

(* The TUI decodes failed reads on several CPU-pool domains at once. A rate
   limit fails every read of a surface together, so the error pages are
   parsed in parallel; a parser with process-wide state crashed the TUI with
   SIGSEGV here. This case runs first so nothing parses before the domains
   start, and each domain reads its own page so an answer taken from another
   domain shows as a difference. *)
let test_parallel_domains () =
  let calls_per_domain = 20_000 in
  let worker index () =
    let body = page index and content_type = parallel_content_types.(index) in
    let first = summarize ~body content_type in
    let differed = ref 0 in
    for _ = 2 to calls_per_domain do
      if summarize ~body content_type <> first then incr differed
    done;
    first, !differed
  in
  let domains =
    List.init (Array.length parallel_content_types) (fun index -> Domain.spawn (worker index)) in
  List.iteri (fun index domain ->
      let first, differed = Domain.join domain in
      let content_type = parallel_content_types.(index) in
      check bool (content_type ^ " is summarized") true (Option.is_some first);
      check (option string) (content_type ^ " matches a single-domain read")
        (summarize ~body:(page index) content_type) first;
      check int (content_type ^ " repeats its first answer") 0 differed)
    domains

(* Whether a response takes the HTML route or falls back to the JSON decoder
   is decided by the Content-Type grammar (RFC 9110 §8.3.1). *)
let test_content_type_decides_route () =
  List.iter (fun (content_type, summarized) ->
      check bool content_type summarized
        (Option.is_some (summarize ~body:(page 0) content_type)))
    [ "text/html", true;
      "TEXT/HTML; Charset=\"UTF-8\"", true;
      "text/html ; charset=utf-8 ;", true;
      "text/html; charset=\"utf\\-8\"", true;
      "text/html; charset=utf-8; charset=utf-16", false;
      "text/html; charset=koi8-r", false;
      "text/html; charset = utf-8", false;
      "text / html", false;
      "text/html, application/json", false;
      "application/json", false ]

let () =
  run "tui_http_error"
    [ "html_response",
      [ test_case "parallel domains" `Quick test_parallel_domains;
        test_case "content type decides route" `Quick test_content_type_decides_route ] ]
