open Alcotest

let read ~status ~headers ~body ~decode =
  Masc_tui_workspace_read.read_json
    ~kept_reads:(Masc_tui_kept_reads.create ())
    ~address_of:(fun ~path -> path)
    ~send:(fun ~path:_ ~headers:_ -> Ok Masc_http_client.{status;headers;body})
    ~decode ~host:"127.0.0.1" ~port:1 ~path:"/fixture"

let response_routing () =
  let marker = "decoder received the response" in
  let decode ~allow_empty:_ ~status_code:_ ~body:_ = Error marker in
  let html = "<!doctype html><html><body><div>upstream unavailable</div></body></html>" in
  let call status headers body = read ~status ~headers ~body ~decode in
  let html_headers = ["Content-Type", "Text/HTML; Charset=\"utf-8\""] in
  check bool "HTML refusal is handled without the JSON decoder" true
    (match call 502 html_headers html with Error error -> error <> marker | Ok _ -> false);
  let json = "{\"error\":\"fixture\",\"auth_error_code\":\"token_expired\"}" in
  check (result unit string) "mislabelled JSON reaches the existing refusal decoder"
    (Error marker) (Result.map (fun _ -> ()) (call 401 html_headers json));
  check (result unit string) "BOM-prefixed JSON also reaches the existing decoder"
    (Error marker) (Result.map (fun _ -> ()) (call 401 html_headers ("\xEF\xBB\xBF" ^ json)));
  let large_json = "{\"error\":\"" ^ String.make 5000 'x' ^ "\"}" in
  check (result unit string) "large JSON is left to the existing decoder"
    (Error marker) (Result.map (fun _ -> ()) (call 401 html_headers large_json));
  check bool "a comment-only response remains a failed read" true
    (Result.is_error (call 502 html_headers "/* comment */"));
  List.iter (fun headers ->
    check (result unit string) "non-HTML or ambiguous Content-Type reaches the decoder"
      (Error marker) (Result.map (fun _ -> ()) (call 502 headers html)))
    [[]; ["Content-Type", "text/plain"];
     ["Content-Type", "text/html"; "content-type", "application/json"];
     ["Content-Type", "text/html; charset=utf-8, application/json"];
     ["Content-Type", "text/html; charset=shift_jis"];
     ["Content-Type", "text/html; charset=utf-8; charset=windows-1252"]];
  check (result unit string) "a successful response keeps the normal decoder"
    (Error marker) (Result.map (fun _ -> ()) (call 200 html_headers html))

let terminal_and_resource_boundary () =
  let decode ~allow_empty:_ ~status_code:_ ~body:_ = Error "fallback" in
  let headers = ["content-type", "text/html; charset=utf-8"] in
  let html = "<body><p>error &#27;[2J \226\128\174</p></body>" in
  (match read ~status:502 ~headers ~body:html ~decode with
   | Ok _ -> fail "error response was accepted"
   | Error error ->
       check bool "terminal controls cannot escape the error" false
         (String.exists (fun ch -> Char.code ch < 0x20 || Char.code ch = 0x7f) error);
       check bool "the error stays valid UTF-8" true (String.is_valid_utf_8 error));
  let controls = String.concat "" (List.init 39 (fun _ -> "\226\128\174")) in
  let joined = String.concat "" (List.init 30 (fun _ -> "👩‍💻")) in
  let reason = "fixture source reason" in
  let composed = "<title>" ^ controls ^ joined ^ "</title><body>" ^ reason ^ "</body>" in
  (match read ~status:502 ~headers ~body:composed ~decode with
   | Ok _ -> fail "error response was accepted"
   | Error error ->
       check bool "the source reason survives an expanded title" true
         (String_util.contains_substring error reason);
       check bool "truncation leaves no newly unescaped terminal controls" true
         (String.equal error (Masc.Tui_terminal_text.sanitize_terminal_text error)));
  let deeply_nested = "<body><b>" ^ String.concat "" (List.init 2000 (fun _ -> "<div>")) in
  check bool "deep buffered HTML remains a failed read" true
    (Result.is_error (read ~status:502 ~headers ~body:deeply_nested ~decode));
  let utf16be text =
    let buffer = Buffer.create (2 * String.length text) in
    String.iter (fun c -> Buffer.add_char buffer '\000'; Buffer.add_char buffer c) text;
    Buffer.contents buffer in
  let large_utf16 = utf16be ("<body><p>problem</p>" ^ String.make 3000 ' ') in
  check bool "large UTF-16 HTML reaches the HTML response handler" true
    (match read ~status:502 ~headers:["Content-Type", "text/html; charset=utf-16be"]
       ~body:large_utf16 ~decode with Error error -> error <> "fallback" | Ok _ -> false);
  let windows = "<body><p>caf\233</p></body>" in
  check bool "declared Windows-1252 text yields valid terminal UTF-8" true
    (match read ~status:502 ~headers:["Content-Type", "text/html; charset=windows-1252"]
       ~body:windows ~decode with Error error -> String.is_valid_utf_8 error | Ok _ -> false)

let () = run "workspace HTTP error admission" ["responses", [
  test_case "content type and status routing" `Quick response_routing;
  test_case "terminal and resource boundary" `Quick terminal_and_resource_boundary]]
