open Alcotest

let handle ?(extract_mode = "markdown") ?(max_chars = 5_000) url =
  Eio_main.run @@ fun _env ->
  Masc.Tool_misc_web_fetch.handle ~tool_name:"masc_web_fetch"
    ~start_time:(Unix.gettimeofday ())
    (`Assoc
       [
         ("url", `String url);
         ("extractMode", `String extract_mode);
         ("maxChars", `Int max_chars);
       ])

let success_json result =
  if not (Tool_result.is_success result) then
    fail ("unexpected failure: " ^ Tool_result.message result);
  Yojson.Safe.from_string (Tool_result.message result)

let test_html_metadata_and_article_extraction () =
  let html =
    {|
<!doctype html>
<html>
  <head>
    <title>Fetch Title &amp; Proof</title>
    <meta property="og:description" content="Fetch description &amp; detail">
  </head>
  <body>
    <nav>drop me</nav>
    <article>
      <h1>Primary Article</h1>
      <p>Readable <b>content</b> &amp; links <a href="https://example.com/ref">ref</a>.</p>
    </article>
  </body>
</html>|}
  in
  Masc.Tool_misc_web_fetch.with_http_fetch_for_test
    (fun ~timeout_sec:_ ~headers:_ ~max_response_bytes:_ url ->
      check string "requested url" "https://example.com/start" url;
      Ok
        { Masc.Tool_misc_web_fetch.http_status = Some 200
        ; final_url = "https://example.com/final"
        ; redirect_count = 1
        ; content_type = Some "text/html; charset=utf-8"
        ; downloaded_bytes = Some (String.length html)
        ; body = html
        })
    (fun () ->
      let json = success_json (handle "https://example.com/start") in
      let open Yojson.Safe.Util in
      check string "final url" "https://example.com/final"
        (json |> member "final_url" |> to_string);
      check int "redirect count" 1 (json |> member "redirect_count" |> to_int);
      check string "content kind" "html" (json |> member "content_kind" |> to_string);
      check string "source" "article"
        (json |> member "extraction_source" |> to_string);
      check string "title" "Fetch Title & Proof" (json |> member "title" |> to_string);
      check string "description" "Fetch description & detail"
        (json |> member "description" |> to_string);
      check string "content type" "text/html; charset=utf-8"
        (json |> member "content_type" |> to_string);
      check int "downloaded bytes" (String.length html)
        (json |> member "downloaded_bytes" |> to_int);
      let text = json |> member "text" |> to_string in
      check bool "heading rendered" true (String_util.contains_substring text "# Primary Article");
      check bool "link rendered" true
        (String_util.contains_substring text "[ref](https://example.com/ref)");
      check bool "nav dropped" false (String_util.contains_substring text "drop me"))

(* Title, description and the markdown rendering run as one job on the
   domain pool when one is installed. The same document must extract to the
   same fields inline and pooled; two urls keep the response cache out of it. *)
let test_extraction_matches_on_the_pool () =
  let html =
    {|<!doctype html>
<html>
  <head>
    <title>Pooled &amp; Inline</title>
    <meta property="og:description" content="Same document, two lanes">
  </head>
  <body>
    <nav>drop me</nav>
    <article>
      <h1>Heading</h1>
      <p>Body <b>text</b> with a <a href="https://example.com/ref">ref</a>.</p>
    </article>
  </body>
</html>|}
  in
  let fields url =
    Masc.Tool_misc_web_fetch.with_http_fetch_for_test
      (fun ~timeout_sec:_ ~headers:_ ~max_response_bytes:_ _url ->
        Ok
          { Masc.Tool_misc_web_fetch.http_status = Some 200
          ; final_url = "https://example.com/final"
          ; redirect_count = 0
          ; content_type = Some "text/html; charset=utf-8"
          ; downloaded_bytes = Some (String.length html)
          ; body = html
          })
      (fun () ->
        let call () =
          Masc.Tool_misc_web_fetch.handle
            ~tool_name:"masc_web_fetch"
            ~start_time:(Unix.gettimeofday ())
            (`Assoc
               [ "url", `String url
               ; "extractMode", `String "markdown"
               ; "maxChars", `Int 5_000
               ])
        in
        let result =
          Eio_main.run
          @@ fun env ->
          if String.equal url "https://example.com/pooled"
          then
            Eio.Switch.run (fun sw ->
              let pool =
                Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env)
              in
              Domain_pool_ref.set pool;
              Fun.protect ~finally:Domain_pool_ref.clear_for_tests call)
          else call ()
        in
        let json = success_json result in
        let open Yojson.Safe.Util in
        ( json |> member "title" |> to_string
        , json |> member "description" |> to_string
        , json |> member "extraction_source" |> to_string
        , json |> member "text" |> to_string ))
  in
  let inline_title, inline_description, inline_source, inline_text =
    fields "https://example.com/inline"
  in
  let pooled_title, pooled_description, pooled_source, pooled_text =
    fields "https://example.com/pooled"
  in
  check string "title" "Pooled & Inline" inline_title;
  check string "pooled title" inline_title pooled_title;
  check string "pooled description" inline_description pooled_description;
  check string "pooled extraction source" inline_source pooled_source;
  check string "pooled text" inline_text pooled_text;
  check bool "heading rendered" true (String_util.contains_substring inline_text "# Heading")
;;

let test_plain_text_preserves_angle_brackets () =
  let body = "Keep <literal> tokens\nand second line." in
  Masc.Tool_misc_web_fetch.with_http_fetch_for_test
    (fun ~timeout_sec:_ ~headers:_ ~max_response_bytes:_ _url ->
      Ok
        { Masc.Tool_misc_web_fetch.http_status = Some 200
        ; final_url = "https://example.com/plain.txt"
        ; redirect_count = 0
        ; content_type = Some "text/plain"
        ; downloaded_bytes = Some (String.length body)
        ; body
        })
    (fun () ->
      let json = success_json (handle "https://example.com/plain.txt") in
      let open Yojson.Safe.Util in
      check string "content kind" "text" (json |> member "content_kind" |> to_string);
      check string "source" "raw_text"
        (json |> member "extraction_source" |> to_string);
      let text = json |> member "text" |> to_string in
      check bool "literal brackets preserved" true
        (String_util.contains_substring text "<literal>"))

let test_invalid_redirect_is_workflow_rejection () =
  Masc.Tool_misc_web_fetch.with_http_fetch_for_test
    (fun ~timeout_sec:_ ~headers:_ ~max_response_bytes:_ _url ->
      Error
        (Masc.Tool_misc_web_fetch.Invalid_redirect
           "redirect target must be a valid http or https URL"))
    (fun () ->
      let result = handle "https://example.com/redirects-local" in
      check bool "failed" false (Tool_result.is_success result);
      check
        (option string)
        "failure class"
        (Some "workflow_rejection")
        (Tool_result.failure_class result
        |> Option.map Tool_result.tool_failure_class_to_string);
      check bool "message" true
        (String_util.contains_substring (Tool_result.message result) "invalid redirect"))

let with_base_path_env path f =
  let key = "MASC_BASE_PATH" in
  let original = Sys.getenv_opt key in
  Unix.putenv key path;
  Fun.protect
    ~finally:(fun () ->
      match original with
      | Some value -> Unix.putenv key value
      | None -> Unix.putenv key "")
    f

(* Feature contract: past maxChars the text becomes a deterministic
   head/tail window around a [TRUNCATED ...] marker, and the complete
   extraction is offloaded content-addressed into the Tool_blob_store —
   the store keeper_artifact_read resolves (#28820) — with its sha256 in
   full_text_sha256 and one fact row in the corpus index. *)
let test_truncation_offloads_full_text () =
  let tmp_base =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-web-fetch-trunc-%d" (Unix.getpid ()))
  in
  Unix.mkdir tmp_base 0o755;
  let line index = Printf.sprintf "line %04d of the long page" index in
  let body =
    String.concat "\n" (List.init 400 line)
  in
  with_base_path_env tmp_base (fun () ->
      Masc.Tool_misc_web_fetch.with_http_fetch_for_test
        (fun ~timeout_sec:_ ~headers:_ ~max_response_bytes:_ _url ->
          Ok
            { Masc.Tool_misc_web_fetch.http_status = Some 200
            ; final_url = "https://example.com/long"
            ; redirect_count = 0
            ; content_type = Some "text/plain"
            ; downloaded_bytes = Some (String.length body)
            ; body
            })
        (fun () ->
          let json =
            success_json
              (handle ~extract_mode:"text" ~max_chars:2_000
                 "https://example.com/long")
          in
          let open Yojson.Safe.Util in
          check bool "truncated" true (json |> member "truncated" |> to_bool);
          let text = json |> member "text" |> to_string in
          check bool "head kept" true
            (String_util.contains_substring text (line 0));
          check bool "tail kept" true
            (String_util.contains_substring text (line 399));
          check bool "marker present" true
            (String_util.contains_substring text "[TRUNCATED total_chars=");
          check bool "no outline for heading-free text" false
            (String_util.contains_substring text "[OUTLINE");
          let sha256 = json |> member "full_text_sha256" |> to_string in
          check bool "marker names the content address" true
            (String_util.contains_substring text ("full_text_sha256=" ^ sha256));
          (* The blob must resolve in the exact store keeper_artifact_read
             reads (#28820): fetch it back through Tool_blob_store. *)
          let store = Tool_blob_store.create ~base_path:tmp_base in
          let stored =
            match Tool_blob_store.fetch store ~sha256 with
            | Ok (Some bytes) -> bytes
            | Ok None -> Alcotest.fail "offloaded blob is absent from the store"
            | Error error ->
              Alcotest.fail (Tool_blob_store.fetch_error_to_string error)
          in
          check bool "offloaded blob holds the full extraction" true
            (String_util.contains_substring stored (line 200));
          check int "offloaded blob is complete" 400
            (List.length (String.split_on_char '\n' stored));
          (* RFC-0383: the same round trip appended one fact row to the
             corpus index, and the row agrees with the artifact. *)
          let index_path =
            List.fold_left Filename.concat tmp_base
              [ ".masc"; "artifacts"; "web-fetch"; "index.jsonl" ]
          in
          let last_row =
            In_channel.with_open_bin index_path In_channel.input_all
            |> String.split_on_char '\n'
            |> List.filter (fun row -> not (String.equal row ""))
            |> List.rev |> List.hd
          in
          let row = Yojson.Safe.from_string last_row in
          check string "index schema" "masc.web_artifact.v1"
            (row |> member "schema" |> to_string);
          check string "index sha256 matches the blob address" sha256
            (row |> member "sha256" |> to_string);
          check string "index source_url" "https://example.com/long"
            (row |> member "source_url" |> to_string);
          check int "index bytes" (String.length stored)
            (row |> member "bytes" |> to_int);
          check bool "plain text carries no title field" true
            (row |> member "title" = `Null);
          (* Projection proof: removing the index changes no behavior. *)
          Sys.remove index_path;
          let json_again =
            success_json
              (handle ~extract_mode:"text" ~max_chars:2_000
                 "https://example.com/long")
          in
          check bool "fetch still truncates without the index" true
            (json_again |> member "truncated" |> to_bool)))

(* Feature contract: cut points that miss a newline snap to UTF-8
   codepoint starts — a Korean page with no newlines truncates into a
   window that is still valid UTF-8 end to end. *)
let test_truncation_preserves_utf8_boundaries () =
  let tmp_base =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-web-fetch-utf8-%d" (Unix.getpid ()))
  in
  Unix.mkdir tmp_base 0o755;
  let body =
    String.concat " "
      (List.init 300 (fun index -> Printf.sprintf "한글본문조각%04d" index))
  in
  with_base_path_env tmp_base (fun () ->
      Masc.Tool_misc_web_fetch.with_http_fetch_for_test
        (fun ~timeout_sec:_ ~headers:_ ~max_response_bytes:_ _url ->
          Ok
            { Masc.Tool_misc_web_fetch.http_status = Some 200
            ; final_url = "https://example.com/korean"
            ; redirect_count = 0
            ; content_type = Some "text/plain"
            ; downloaded_bytes = Some (String.length body)
            ; body
            })
        (fun () ->
          let json =
            success_json
              (handle ~extract_mode:"text" ~max_chars:1_000
                 "https://example.com/korean")
          in
          let open Yojson.Safe.Util in
          check bool "truncated" true (json |> member "truncated" |> to_bool);
          let text = json |> member "text" |> to_string in
          check bool "window is valid utf8" true (String.is_valid_utf_8 text);
          check bool "head kept" true
            (String_util.contains_substring text "한글본문조각0000");
          check bool "tail kept" true
            (String_util.contains_substring text "한글본문조각0299")))

(* Feature contract: when the truncated extraction carries markdown
   headings, the marker is followed by an [OUTLINE ...] byte-offset map
   addressing the offloaded blob — reading the artifact at a listed
   offset lands exactly on that heading line. Fenced-code [#] lines stay
   out of the count, and collection caps at 32 rows while the header
   still reports the full heading total. *)
let test_truncation_outline_maps_headings () =
  let tmp_base =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-web-fetch-outline-%d" (Unix.getpid ()))
  in
  Unix.mkdir tmp_base 0o755;
  let section index =
    Printf.sprintf
      "## section %02d\npadding %02d alpha filler text\npadding %02d beta filler text"
      index index index
  in
  let preamble = [ "# Doc Title"; "```"; "# not a heading"; "```" ] in
  let body =
    String.concat "\n" (preamble @ List.init 40 (fun i -> section (i + 1)))
  in
  (* Offset of "## section 10" computed from construction, not by
     parsing the outline back: the map row must agree with it. *)
  let expected_offset =
    String.length
      (String.concat "\n" (preamble @ List.init 9 (fun i -> section (i + 1))))
    + 1
  in
  with_base_path_env tmp_base (fun () ->
      Masc.Tool_misc_web_fetch.with_http_fetch_for_test
        (fun ~timeout_sec:_ ~headers:_ ~max_response_bytes:_ _url ->
          Ok
            { Masc.Tool_misc_web_fetch.http_status = Some 200
            ; final_url = "https://example.com/sections"
            ; redirect_count = 0
            ; content_type = Some "text/plain"
            ; downloaded_bytes = Some (String.length body)
            ; body
            })
        (fun () ->
          let json =
            success_json
              (handle ~extract_mode:"text" ~max_chars:1_000
                 "https://example.com/sections")
          in
          let open Yojson.Safe.Util in
          check bool "truncated" true (json |> member "truncated" |> to_bool);
          let text = json |> member "text" |> to_string in
          check bool "outline header counts headings, not fenced hashes" true
            (String_util.contains_substring text "[OUTLINE headings=41 shown=32");
          let row = Printf.sprintf "\n%d ## section 10" expected_offset in
          check bool "outline row carries the constructed offset" true
            (String_util.contains_substring text row);
          let sha256 = json |> member "full_text_sha256" |> to_string in
          let store = Tool_blob_store.create ~base_path:tmp_base in
          let stored =
            match Tool_blob_store.fetch store ~sha256 with
            | Ok (Some bytes) -> bytes
            | Ok None -> Alcotest.fail "offloaded blob is absent from the store"
            | Error error ->
              Alcotest.fail (Tool_blob_store.fetch_error_to_string error)
          in
          let heading = "## section 10" in
          check string "offset addresses that heading in the artifact" heading
            (String.sub stored expected_offset (String.length heading))))

(* Feature contract: web content chooses the next fetch, so loopback,
   private, link-local, unspecified, and localhost destinations are
   rejected at the entry and at every redirect hop — as caller-input
   violations, before any network round trip. *)
let test_destination_boundary () =
  let blocked_urls =
    [ "http://127.0.0.1:8935/health"
    ; "https://localhost:8888/search"
    ; "http://sub.localhost/x"
    ; "http://[::1]/"
    ; "http://169.254.169.254/latest/meta-data/"
    ; "http://10.1.2.3/internal"
    ; "http://172.16.0.9/"
    ; "http://192.168.0.10/router"
    ; "http://0.0.0.0/"
    ; "http://[fe80::1]/"
    ; "http://[fd00::2]/"
    ; "http://[::ffff:127.0.0.1]/"
      (* The spellings curl resolves through inet_aton that Ipaddr does not
         parse; each reached 127.0.0.1, 0.0.0.0, or a local interface when
         the literal check read them as hostnames. *)
    ; "http://2130706433/"
    ; "http://0x7f000001/"
    ; "http://127.1/"
    ; "http://0177.0.0.1/"
    ; "http://0/"
    ; "http://localhost./"
    ; "http://[fe80::1%25en0]/"
      (* Userinfo would be sent as credentials the model chose. *)
    ; "http://user:secret@example.com/"
      (* Uri stops the authority at a backslash and hands the rest to the
         path, so the examined host is example.com while curl connects to
         127.0.0.1 (measured with curl 8.7.1). *)
    ; "http://example.com\\@127.0.0.1:8935/"
    ; "http://example.com\\@localhost/"
      (* A libidn2 curl maps a fullwidth t to ASCII and reaches localhost;
         the percent-encoded form decodes to the same non-ASCII bytes. *)
    ; "http://localhosｔ/"
    ; "http://localhos%EF%BD%94/"
    ]
  in
  List.iter
    (fun url ->
      let result = handle url in
      check bool (url ^ " rejected") false (Tool_result.is_success result);
      check (option string) (url ^ " class") (Some "workflow_rejection")
        (Tool_result.failure_class result
        |> Option.map Tool_result.tool_failure_class_to_string);
      check bool (url ^ " reason") true
        (String_util.contains_substring (Tool_result.message result)
           "url rejected:");
      match Masc.Tool_misc_web_fetch.validate_redirect_target url with
      | Ok () -> fail (url ^ " must be rejected as a redirect hop too")
      | Error reason ->
          check bool (url ^ " hop reason") true
            (String_util.contains_substring reason "redirect target rejected:"))
    blocked_urls;
  (* A public destination still flows through to the fetch boundary. *)
  Masc.Tool_misc_web_fetch.with_http_fetch_for_test
    (fun ~timeout_sec:_ ~headers:_ ~max_response_bytes:_ url ->
      check string "public url reaches fetch" "https://example.com/public" url;
      Ok
        { Masc.Tool_misc_web_fetch.http_status = Some 200
        ; final_url = "https://example.com/public"
        ; redirect_count = 0
        ; content_type = Some "text/plain"
        ; downloaded_bytes = Some 2
        ; body = "ok"
        })
    (fun () ->
      let json = success_json (handle "https://example.com/public") in
      check string "public body extracted" "ok"
        Yojson.Safe.Util.(json |> member "text" |> to_string));
  check bool "public hop allowed" true
    (Masc.Tool_misc_web_fetch.validate_redirect_target
       "https://example.com/next"
     = Ok ())

let () =
  run "tool_misc_web_fetch"
    [
      ( "fetch",
        [
          test_case "html metadata and article extraction" `Quick
            test_html_metadata_and_article_extraction;
          test_case "plain text preserves angle brackets" `Quick
            test_plain_text_preserves_angle_brackets;
          test_case "extraction matches on the pool" `Quick
            test_extraction_matches_on_the_pool;
          test_case "invalid redirect class" `Quick
            test_invalid_redirect_is_workflow_rejection;
          test_case "truncation offloads full text" `Quick
            test_truncation_offloads_full_text;
          test_case "truncation preserves utf8 boundaries" `Quick
            test_truncation_preserves_utf8_boundaries;
          test_case "truncation outline maps headings" `Quick
            test_truncation_outline_maps_headings;
          test_case "destination boundary" `Quick test_destination_boundary;
        ] );
    ]
