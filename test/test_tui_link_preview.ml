(** Test suite for Masc_tui_link_preview *)

open Alcotest
open Masc_tui_link_preview

let test_github_pr () =
  let p = synthesize_preview "https://github.com/jeong-sik/masc/pull/30866" in
  check (option string) "site name is GitHub" (Some "GitHub") p.site_name;
  check (option string) "title is the recognized label"
    (Some "masc PR #30866") p.title;
  check bool "has informative metadata" true (has_informative_preview p);
  match p.kind with
  | Github { label; owner; repo } ->
      check string "label" "masc PR #30866" label;
      check string "owner" "jeong-sik" owner;
      check string "repo" "masc" repo
  | _ -> fail "expected Github kind"

let test_github_issue () =
  let p = synthesize_preview "https://github.com/jeong-sik/masc/issues/22797" in
  check (option string) "title is issue label"
    (Some "masc issue #22797") p.title;
  match p.kind with
  | Github { label; _ } -> check string "issue label" "masc issue #22797" label
  | _ -> fail "expected Github kind"

let test_github_commit () =
  let p = synthesize_preview "https://github.com/jeong-sik/masc/commit/0420067137aabbccddee" in
  check (option string) "title is commit label with short sha"
    (Some "masc commit 0420067") p.title;
  match p.kind with
  | Github { label; _ } -> check string "short commit label" "masc commit 0420067" label
  | _ -> fail "expected Github kind"

let test_github_ci_run () =
  let p = synthesize_preview "https://github.com/jeong-sik/masc/actions/runs/32959102055/job/98147624211" in
  check (option string) "title is ci run label"
    (Some "masc CI run 32959102055") p.title

let test_github_file () =
  let p = synthesize_preview "https://github.com/jeong-sik/masc/blob/main/bin/masc_tui_render.ml" in
  check (option string) "title is file label"
    (Some "masc masc_tui_render.ml") p.title

let test_github_repo_root () =
  let p = synthesize_preview "https://github.com/jeong-sik/masc" in
  check (option string) "repo root title" (Some "jeong-sik/masc") p.title

let test_arxiv () =
  let p = synthesize_preview "https://arxiv.org/abs/2301.07041" in
  check (option string) "site name" (Some "arXiv.org") p.site_name;
  check (option string) "title" (Some "arXiv 2301.07041") p.title;
  check bool "has informative metadata" true (has_informative_preview p);
  match p.kind with
  | Arxiv { id } -> check string "arxiv id" "2301.07041" id
  | _ -> fail "expected Arxiv kind"

let test_hackernews () =
  let p = synthesize_preview "https://news.ycombinator.com/item?id=38912345" in
  check (option string) "site name" (Some "Hacker News") p.site_name;
  check (option string) "title" (Some "Hacker News item #38912345") p.title;
  check bool "has informative metadata" true (has_informative_preview p);
  match p.kind with
  | HackerNews { item_id } -> check string "hn item id" "38912345" item_id
  | _ -> fail "expected HackerNews kind"

let test_youtube () =
  let p1 = synthesize_preview "https://www.youtube.com/watch?v=dQw4w9WgXcQ" in
  check (option string) "yt site" (Some "YouTube") p1.site_name;
  check (option string) "yt thumbnail"
    (Some "https://img.youtube.com/vi/dQw4w9WgXcQ/hqdefault.jpg") p1.image_url;
  check bool "has metadata" true (has_informative_preview p1);
  (match p1.kind with
   | YouTube { video_id } -> check string "video id" "dQw4w9WgXcQ" video_id
   | _ -> fail "expected YouTube kind");
  let p2 = synthesize_preview "https://youtu.be/dQw4w9WgXcQ" in
  match p2.kind with
  | YouTube { video_id } -> check string "short video id" "dQw4w9WgXcQ" video_id
  | _ -> fail "expected YouTube kind"

let test_direct_image () =
  let p = synthesize_preview "https://example.com/assets/diagram.png" in
  check (option string) "filename as title" (Some "diagram.png") p.title;
  check (option string) "image_url matches url" (Some "https://example.com/assets/diagram.png") p.image_url;
  check bool "has metadata" true (has_informative_preview p);
  match p.kind with
  | Image_direct { ext } -> check string "image ext" "png" ext
  | _ -> fail "expected Image_direct kind"

let test_silence_contract () =
  let p1 = synthesize_preview "https://docs.anthropic.com/en/api" in
  check bool "anthropic docs has no synthetic metadata" false (has_informative_preview p1);
  check (option string) "badge is None under silence contract" None (render_compact_badge p1);
  let p2 = synthesize_preview "https://api.github.com/jeong-sik/masc" in
  check bool "github api subdomain gets no label" false (has_informative_preview p2);
  check (option string) "badge is None" None (render_compact_badge p2);
  let p3 = synthesize_preview "https://google.com" in
  check bool "bare google has no synthetic metadata" false (has_informative_preview p3);
  check (option string) "badge is None" None (render_compact_badge p3)

let test_cache_operations_and_bounding () =
  clear_cache ();
  let url = "https://arxiv.org/abs/2401.00001" in
  check bool "initially not in cache" true (Option.is_none (cache_lookup url));
  let p1 = get_preview url in
  check bool "now in cache" true (Option.is_some (cache_lookup url));
  let p2 = get_preview url in
  check string "same url from cache" p1.url p2.url;
  (* Verify bounded capacity: insert 300 entries, no exceptions, cache stays bounded *)
  for i = 1 to 300 do
    let test_url = Printf.sprintf "https://arxiv.org/abs/2401.%05d" i in
    ignore (get_preview test_url)
  done;
  clear_cache ();
  check bool "empty after clear" true (Option.is_none (cache_lookup url))

let test_render_compact_badge () =
  let p = synthesize_preview "https://github.com/jeong-sik/masc/pull/30866" in
  let badge_opt = render_compact_badge p in
  check bool "badge exists for informative preview" true (Option.is_some badge_opt);
  let badge = Option.get badge_opt in
  check bool "starts with corner glyph" true (String.starts_with ~prefix:"\xe2\x95\xb0\xe2\x94\x80" badge)

let test_render_inline_card_column_alignment () =
  let p = synthesize_preview "https://github.com/jeong-sik/masc/pull/30866" in
  let card_lines = render_inline_card ~width:50 p in
  check bool "card has lines" true (List.length card_lines >= 4);
  let widths = List.map Masc_tui_message_layout.display_width card_lines in
  let first_width = List.hd widths in
  check bool "first line has positive width" true (first_width > 0);
  List.iter
    (fun w ->
       check int "all card borders and content rows have identical display cell width"
         first_width w)
    widths

let test_render_notion_card_2column_alignment () =
  let urls =
    [ "https://github.com/jeong-sik/masc/pull/30866"
    ; "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    ; "https://arxiv.org/abs/2301.07041"
    ; "https://news.ycombinator.com/item?id=38912345"
    ; "https://example.com/assets/diagram.png"
    ; "https://example.com/article"
    ]
  in
  List.iter
    (fun url ->
       let p = synthesize_preview url in
       let card_lines = render_notion_card ~width:70 p in
       check bool "2-column card has 7 lines (top + 5 content + bottom)" true (List.length card_lines = 7);
       let widths = List.map Masc_tui_message_layout.display_width card_lines in
       let first_w = List.hd widths in
       check bool "first line has positive width" true (first_w > 0);
       List.iter
         (fun w ->
            check int (Printf.sprintf "all 7 lines match cell width for %s" url) first_w w)
         widths)
    urls

let test_render_notion_card_narrow_fallback () =
  let p = synthesize_preview "https://github.com/jeong-sik/masc/pull/30866" in
  let card_lines = render_notion_card ~width:45 p in
  check bool "narrow card has lines" true (List.length card_lines >= 4);
  let widths = List.map Masc_tui_message_layout.display_width card_lines in
  let first_w = List.hd widths in
  check bool "first line has positive width" true (first_w > 0);
  List.iter
    (fun w ->
       check int "narrow card all lines match cell width" first_w w)
    widths

let test_render_modal_card () =
  let p = synthesize_preview "https://example.com/photo.png" in
  let modal_lines = render_modal_card ~width:60 ~height:20 p in
  check bool "modal card has content lines" true (List.length modal_lines > 0)

(* ---- parse_og_html: real fetched metadata (pure, no network) ---- *)

let test_parse_og_full () =
  let body =
    {|<html><head>
      <meta property="og:title" content="Real Title">
      <meta property="og:description" content="Real description here">
      <meta property="og:image" content="https://example.com/img.png">
      <meta property="og:site_name" content="Example Site">
      <title>Ignored Fallback</title>
      </head><body>x</body></html>|}
  in
  let p = parse_og_html ~url:"https://example.com/article" ~body in
  check (option string) "og:title wins" (Some "Real Title") p.title;
  check (option string) "og:description" (Some "Real description here") p.description;
  check (option string) "og:image" (Some "https://example.com/img.png") p.image_url;
  check (option string) "og:site_name" (Some "Example Site") p.site_name;
  check bool "has_metadata true when fetched" true p.has_metadata

let test_parse_title_fallback () =
  let body = {|<html><head><title>Just A Title</title></head></html>|} in
  let p = parse_og_html ~url:"https://example.com/page" ~body in
  check (option string) "falls back to <title>" (Some "Just A Title") p.title;
  check bool "has_metadata true from title" true p.has_metadata

let test_parse_no_metadata_degrades () =
  (* An unknown web page with no <title> or og:* must NOT claim metadata it does
     not have: it degrades to the synthesized base (silence contract). *)
  let body = {|<html><head></head><body>no meta here</body></html>|} in
  let p = parse_og_html ~url:"https://example.com/bare" ~body in
  check bool "does not fabricate has_metadata" false p.has_metadata;
  check (option string) "no fabricated title" None p.title

let test_parse_entities () =
  let body =
    {|<head><meta property="og:title" content="Tom &amp; Jerry&#39;s Page"></head>|}
  in
  let p = parse_og_html ~url:"https://example.com/x" ~body in
  check (option string) "entities decoded" (Some "Tom & Jerry's Page") p.title

let test_parse_keeps_kind () =
  (* A fetched GitHub URL keeps its Github kind (and banner styling); only the
     text is upgraded from synthesized to real. *)
  let body =
    {|<head><meta property="og:title" content="Fetched PR Title">
      <meta property="og:description" content="Fetched body"></head>|}
  in
  let p = parse_og_html ~url:"https://github.com/jeong-sik/masc/pull/30866" ~body in
  check (option string) "og title overrides synth label" (Some "Fetched PR Title") p.title;
  (match p.kind with
   | Github _ -> ()
   | _ -> fail "expected Github kind preserved")

let test_parse_single_quote_and_name_attr () =
  let body = {|<head><meta property='og:title' content='Single Quoted'></head>|} in
  let p = parse_og_html ~url:"https://example.com/sq" ~body in
  check (option string) "single-quoted attrs" (Some "Single Quoted") p.title;
  let body2 = {|<head><meta name="og:title" content="Via Name Attr"></head>|} in
  let p2 = parse_og_html ~url:"https://example.com/na" ~body:body2 in
  check (option string) "name= attribute accepted" (Some "Via Name Attr") p2.title

let test_parse_og_far_into_body () =
  (* Regression: real pages (YouTube's watch page, ~700 KB in) place og:* well
     past the first hundreds of KB, after large inline scripts. A head-window
     scan would silently miss them; the parser must scan the whole body. *)
  let filler = String.make 400_000 'x' in
  let body =
    Printf.sprintf
      {|<html><head><script>%s</script><meta property="og:title" content="Deep OG Title"></head></html>|}
      filler
  in
  let p = parse_og_html ~url:"https://example.com/deep" ~body in
  check (option string) "og found far into body" (Some "Deep OG Title") p.title;
  check bool "has_metadata true" true p.has_metadata

let test_parse_collapses_newlines () =
  (* A real og:description (a PR body) can be multi-line; it must collapse to one
     line, or it splits the card row and misaligns the banner. *)
  let body =
    "<head><meta property=\"og:description\" content=\"Line one.\nLine two.\tTabbed   spaced\"></head>"
  in
  let p = parse_og_html ~url:"https://example.com/multi" ~body in
  check (option string) "newlines/tabs/space-runs collapsed"
    (Some "Line one. Line two. Tabbed spaced") p.description

let () =
  run "tui link preview"
    [ ( "synthesizer"
      , [ test_case "github pr" `Quick test_github_pr
        ; test_case "github issue" `Quick test_github_issue
        ; test_case "github commit" `Quick test_github_commit
        ; test_case "github ci run" `Quick test_github_ci_run
        ; test_case "github file" `Quick test_github_file
        ; test_case "github repo root" `Quick test_github_repo_root
        ; test_case "arxiv" `Quick test_arxiv
        ; test_case "hackernews" `Quick test_hackernews
        ; test_case "youtube" `Quick test_youtube
        ; test_case "direct image" `Quick test_direct_image
        ; test_case "silence contract" `Quick test_silence_contract
        ] )
    ; ( "cache"
      , [ test_case "cache lifecycle and bounding" `Quick test_cache_operations_and_bounding ] )
    ; ( "render"
      , [ test_case "compact badge" `Quick test_render_compact_badge
        ; test_case "inline card column alignment" `Quick test_render_inline_card_column_alignment
        ; test_case "notion 2-column card alignment" `Quick test_render_notion_card_2column_alignment
        ; test_case "notion narrow fallback" `Quick test_render_notion_card_narrow_fallback
        ; test_case "modal card" `Quick test_render_modal_card
        ] )
    ; ( "fetch (og parse)"
      , [ test_case "og full" `Quick test_parse_og_full
        ; test_case "title fallback" `Quick test_parse_title_fallback
        ; test_case "no metadata degrades honestly" `Quick test_parse_no_metadata_degrades
        ; test_case "entity decode" `Quick test_parse_entities
        ; test_case "keeps kind" `Quick test_parse_keeps_kind
        ; test_case "single quote and name attr" `Quick test_parse_single_quote_and_name_attr
        ; test_case "og far into body (no head cap)" `Quick test_parse_og_far_into_body
        ; test_case "collapses newlines" `Quick test_parse_collapses_newlines
        ] )
    ]
