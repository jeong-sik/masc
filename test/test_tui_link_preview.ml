(** Test suite for Masc_tui_link_preview *)

open Alcotest
open Masc_tui_link_preview

let test_github_pr () =
  let p = synthesize_preview "https://github.com/jeong-sik/masc/pull/30866" in
  check (option string) "site name is GitHub" (Some "GitHub") p.site_name;
  check (option string) "title contains PR number"
    (Some "jeong-sik/masc · Pull Request #30866") p.title;
  match p.kind with
  | Github { owner; repo; item } ->
      check string "owner" "jeong-sik" owner;
      check string "repo" "masc" repo;
      check string "item" "PR #30866" item
  | _ -> fail "expected Github kind"

let test_github_issue () =
  let p = synthesize_preview "https://github.com/jeong-sik/masc/issues/22797" in
  check (option string) "title contains issue number"
    (Some "jeong-sik/masc · Issue #22797") p.title;
  match p.kind with
  | Github { owner; repo; item } ->
      check string "owner" "jeong-sik" owner;
      check string "repo" "masc" repo;
      check string "item" "Issue #22797" item
  | _ -> fail "expected Github kind"

let test_github_commit () =
  let p = synthesize_preview "https://github.com/jeong-sik/masc/commit/0420067137aabbccddee" in
  check (option string) "title contains short sha"
    (Some "jeong-sik/masc · Commit 0420067") p.title;
  match p.kind with
  | Github { item; _ } -> check string "short commit item" "Commit 0420067" item
  | _ -> fail "expected Github kind"

let test_github_ci_run () =
  let p = synthesize_preview "https://github.com/jeong-sik/masc/actions/runs/32959102055/job/98147624211" in
  match p.kind with
  | Github { item; _ } -> check string "run id item" "Run 32959102055" item
  | _ -> fail "expected Github kind"

let test_github_file () =
  let p = synthesize_preview "https://github.com/jeong-sik/masc/blob/main/bin/masc_tui_render.ml" in
  match p.kind with
  | Github { item; _ } -> check string "file item" "masc_tui_render.ml" item
  | _ -> fail "expected Github kind"

let test_github_repo_root () =
  let p = synthesize_preview "https://github.com/jeong-sik/masc" in
  check (option string) "repo root title" (Some "jeong-sik/masc") p.title;
  match p.kind with
  | Github { item; _ } -> check string "item repo" "Repository" item
  | _ -> fail "expected Github kind"

let test_arxiv () =
  let p = synthesize_preview "https://arxiv.org/abs/2301.07041" in
  check (option string) "site name" (Some "arXiv.org") p.site_name;
  check (option string) "title" (Some "arXiv:2301.07041") p.title;
  match p.kind with
  | Arxiv { id } -> check string "arxiv id" "2301.07041" id
  | _ -> fail "expected Arxiv kind"

let test_hackernews () =
  let p = synthesize_preview "https://news.ycombinator.com/item?id=38912345" in
  check (option string) "site name" (Some "Hacker News") p.site_name;
  check (option string) "title" (Some "Hacker News discussion #38912345") p.title;
  match p.kind with
  | HackerNews { item_id } -> check string "hn item id" "38912345" item_id
  | _ -> fail "expected HackerNews kind"

let test_youtube () =
  let p1 = synthesize_preview "https://www.youtube.com/watch?v=dQw4w9WgXcQ" in
  check (option string) "yt site" (Some "YouTube") p1.site_name;
  check (option string) "yt thumbnail"
    (Some "https://img.youtube.com/vi/dQw4w9WgXcQ/hqdefault.jpg") p1.image_url;
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
  match p.kind with
  | Image_direct { ext } -> check string "image ext" "png" ext
  | _ -> fail "expected Image_direct kind"

let test_generic_web () =
  let p = synthesize_preview "https://ocaml.org/manual/latest/" in
  check (option string) "host as site name" (Some "ocaml.org") p.site_name;
  match p.kind with
  | Web_page -> ()
  | _ -> fail "expected Web_page kind"

let test_json_roundtrip () =
  let p = synthesize_preview "https://github.com/jeong-sik/masc/pull/30866" in
  let json = to_json p in
  let decoded = of_json p.url json in
  check bool "json decoded successfully" true (Option.is_some decoded);
  let p2 = Option.get decoded in
  check string "url preserved" p.url p2.url;
  check (option string) "title preserved" p.title p2.title;
  check (option string) "site_name preserved" p.site_name p2.site_name

let test_json_enrichment () =
  let custom_json =
    `Assoc
      [ ("title", `String "Custom Enriched Title")
      ; ("description", `String "A detailed description from OpenGraph")
      ; ("site_name", `String "GitHub")
      ; ("image_url", `String "https://github.com/jeong-sik/masc/banner.png")
      ; ("cache_state", `String "live")
      ]
  in
  let decoded = of_json "https://github.com/jeong-sik/masc/pull/30866" custom_json in
  check bool "enriched decoded" true (Option.is_some decoded);
  let p = Option.get decoded in
  check (option string) "title enriched" (Some "Custom Enriched Title") p.title;
  check (option string) "description enriched" (Some "A detailed description from OpenGraph") p.description;
  check (option string) "image_url enriched" (Some "https://github.com/jeong-sik/masc/banner.png") p.image_url;
  check string "cache_state live" "live" p.cache_state

let test_cache_operations () =
  clear_cache ();
  let url = "https://arxiv.org/abs/2401.00001" in
  check bool "initially not in cache" true (Option.is_none (cache_lookup url));
  let p1 = get_preview url in
  check bool "now in cache" true (Option.is_some (cache_lookup url));
  let p2 = get_preview url in
  check string "same url from cache" p1.url p2.url;
  clear_cache ();
  check bool "empty after clear" true (Option.is_none (cache_lookup url))

let test_render_compact_badge () =
  let p = synthesize_preview "https://github.com/jeong-sik/masc/pull/30866" in
  let badge = render_compact_badge p in
  check bool "starts with corner glyph" true (String.starts_with ~prefix:"\xe2\x95\xb0\xe2\x94\x80" badge)

let test_render_inline_card () =
  let p = synthesize_preview "https://github.com/jeong-sik/masc/pull/30866" in
  let card_lines = render_inline_card ~width:60 p in
  check bool "card has lines" true (List.length card_lines >= 4);
  let top = List.hd card_lines in
  let bottom = List.hd (List.rev card_lines) in
  check bool "top border starts with rounded corner" true (String.starts_with ~prefix:"\xe2\x95\xad" top);
  check bool "bottom border starts with rounded corner" true (String.starts_with ~prefix:"\xe2\x95\xb0" bottom)

let test_render_modal_card () =
  let p = synthesize_preview "https://example.com/photo.png" in
  let modal_lines = render_modal_card ~width:60 ~height:20 p in
  check bool "modal card has content lines" true (List.length modal_lines > 0)

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
        ; test_case "generic web" `Quick test_generic_web
        ] )
    ; ( "json"
      , [ test_case "roundtrip" `Quick test_json_roundtrip
        ; test_case "enrichment" `Quick test_json_enrichment
        ] )
    ; ( "cache"
      , [ test_case "cache lifecycle" `Quick test_cache_operations ] )
    ; ( "render"
      , [ test_case "compact badge" `Quick test_render_compact_badge
        ; test_case "inline card" `Quick test_render_inline_card
        ; test_case "modal card" `Quick test_render_modal_card
        ] )
    ]
