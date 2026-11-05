open Alcotest

let page =
  "<html><head><title>429 Too Many Requests</title></head>"
  ^ "<body><h1>Too Many Requests</h1></body></html>"

let summarize content_type =
  Masc_tui_http_error.html_response ~status_code:429
    ~headers:["Content-Type", content_type] ~body:page

(* The TUI decodes failed reads on several CPU-pool domains at once. A rate
   limit fails every read of a surface together, so the Content-Type parser
   runs in parallel; a parser with process-wide state crashed the TUI with
   SIGSEGV here. *)
let test_parallel_domains () =
  let content_type = "text/html; charset=utf-8" in
  let expected = summarize content_type in
  check bool "the page is summarized" true (Option.is_some expected);
  let calls_per_domain = 20_000 in
  let worker () =
    let differed = ref 0 in
    for _ = 1 to calls_per_domain do
      if summarize content_type <> expected then incr differed
    done;
    !differed
  in
  let domains = List.init 4 (fun _ -> Domain.spawn worker) in
  let differed = List.fold_left (fun total domain -> total + Domain.join domain) 0 domains in
  check int "every parallel call matches the single-domain answer" 0 differed

(* Whether a response takes the HTML route or falls back to the JSON decoder
   is decided by the Content-Type grammar (RFC 9110 §8.3.1). *)
let test_content_type_decides_route () =
  List.iter (fun (content_type, summarized) ->
      check bool content_type summarized (Option.is_some (summarize content_type)))
    [ "text/html", true;
      "TEXT/HTML; Charset=\"UTF-8\"", true;
      "text/html ; charset=utf-8 ;", true;
      "text/html; charset=utf-8; charset=utf-16", false;
      "text/html; charset=koi8-r", false;
      "text/html; charset = utf-8", false;
      "text/html, application/json", false;
      "application/json", false ]

let () =
  run "tui_http_error"
    [ "html_response",
      [ test_case "parallel domains" `Quick test_parallel_domains;
        test_case "content type decides route" `Quick test_content_type_decides_route ] ]
