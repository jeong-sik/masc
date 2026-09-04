open Alcotest

module Cache = Masc_tui_markdown_render_cache
module Markdown = Masc_tui_markdown

let counted_renderer calls ~width text =
  incr calls;
  [ Printf.sprintf "%d:%s" width text ]

let stable identity text = Cache.Stable_source { identity; text }

let growing_renderer calls ~width text =
  calls := text :: !calls;
  Markdown.render_streaming ~palette:Markdown.plain_palette ~width text

let render_growing cache calls ?(theme_revision = 1)
    ?(palette_generation = 0) ?(width = 40) identity text =
  Cache.render_growing cache ~theme_revision ~palette_generation ~width
    ~renderer:(growing_renderer calls) ~identity ~text

let full_markdown ~width text =
  Markdown.render ~palette:Markdown.plain_palette ~width text

let render cache calls ?(theme_revision = 1) ?(palette_generation = 0)
    ?(width = 40) source =
  Cache.render cache ~theme_revision ~palette_generation ~width
    ~renderer:(counted_renderer calls) ~source

let test_same_complete_source_renders_once () =
  let calls = ref 0 in
  let cache = Cache.create ~capacity:4 in
  let source = stable "entry-a" "# heading\nbody" in
  let first = render cache calls source in
  let second = render cache calls source in
  check (list string) "a hit returns the same rows" first second;
  check int "renderer calls" 1 !calls;
  check int "one completed entry retained" 1
    (Cache.For_testing.retained_entries cache)

let test_every_render_input_invalidates () =
  let calls = ref 0 in
  let cache = Cache.create ~capacity:4 in
  ignore (render cache calls (stable "entry-a" "body") : string list);
  ignore (render cache calls (stable "entry-a" "body changed") : string list);
  ignore
    (render cache calls ~width:41 (stable "entry-a" "body changed") : string list);
  ignore
    (render cache calls ~width:41 ~theme_revision:2
       (stable "entry-a" "body changed") : string list);
  ignore
    (render cache calls ~width:41 ~theme_revision:2 ~palette_generation:1
       (stable "entry-a" "body changed") : string list);
  check int "source, width, theme, and palette each miss" 5 !calls;
  check int "one identity keeps only its newest result" 1
    (Cache.For_testing.retained_entries cache)

let test_different_entries_do_not_share_rows () =
  let calls = ref 0 in
  let cache = Cache.create ~capacity:4 in
  ignore (render cache calls (stable "entry-a" "same body") : string list);
  ignore (render cache calls (stable "entry-b" "same body") : string list);
  ignore (render cache calls (stable "entry-a" "same body") : string list);
  check int "the second identity is a miss and the first remains a hit" 2 !calls;
  check int "both identities are retained" 2
    (Cache.For_testing.retained_entries cache)

let test_streaming_source_never_reuses_partial_rows () =
  let calls = ref 0 in
  let cache = Cache.create ~capacity:4 in
  ignore (render cache calls (Cache.Streaming_source "part") : string list);
  ignore (render cache calls (Cache.Streaming_source "part") : string list);
  let grown = render cache calls (Cache.Streaming_source "partial") in
  check int "every streaming draw calls the renderer" 3 !calls;
  check (list string) "the grown source is the result returned"
    [ "40:partial" ] grown;
  check int "streaming rows are not retained" 0
    (Cache.For_testing.retained_entries cache)

let test_retention_is_bounded_and_recent () =
  let calls = ref 0 in
  let cache = Cache.create ~capacity:2 in
  ignore (render cache calls (stable "entry-a" "a") : string list);
  ignore (render cache calls (stable "entry-b" "b") : string list);
  ignore (render cache calls (stable "entry-a" "a") : string list);
  ignore (render cache calls (stable "entry-c" "c") : string list);
  ignore (render cache calls (stable "entry-b" "b") : string list);
  check int "least recently used entry was rendered again" 4 !calls;
  check int "capacity remains exact" 2
    (Cache.For_testing.retained_entries cache)

let assert_incremental_matches_full ~label ~width chunks =
  let cache = Cache.create ~capacity:4 in
  let calls = ref [] in
  let source = Buffer.create 256 in
  List.iteri
    (fun index chunk ->
      Buffer.add_string source chunk;
      let text = Buffer.contents source in
      let actual = render_growing cache calls ~width label text in
      check (list string)
        (Printf.sprintf "%s at chunk %d %S" label index chunk)
        (full_markdown ~width text) actual)
    chunks

let one_byte_chunks text =
  List.init (String.length text) (fun index -> String.make 1 text.[index])

let test_every_chunk_matches_the_canonical_full_render () =
  let source =
    "Intro [inline](https://example.invalid/x).\n\
     ```ocaml\n\
     (* open\n\
        still open *)\n\
     let x = 1\n\
     ```\n\
     ~~~text\n\
     | fenced | pipes |\n\
     | --- | --- |\n\
     ~~~\n\
     | name | value |\n\
     | --- | ---: |\n\
     | a | 1 |\n\
     | much-wider | 12345 |\n\
     After the table.\n\
     Earlier [docs][ref].\n\
     [ref]: https://example.invalid/docs\n"
  in
  List.iter
    (fun width ->
      assert_incremental_matches_full
        ~label:(Printf.sprintf "one-byte-%d" width) ~width
        (one_byte_chunks source))
    [ 18; 40; 72 ];
  assert_incremental_matches_full ~label:"utf8" ~width:24
    [ "한"; "글"; " **굵"; "게**\n"; "| 열 | 값 |\n"; "| -- | -- |\n"
    ; "| 하나 | 둘 |\n"; "다음 줄"
    ]

let test_closed_blocks_are_not_rendered_again () =
  let cache = Cache.create ~capacity:4 in
  let calls = ref [] in
  let source = Buffer.create 64 in
  let append chunk =
    Buffer.add_string source chunk;
    let text = Buffer.contents source in
    let actual = render_growing cache calls "entry-a" text in
    check (list string) ("full rows after " ^ chunk)
      (full_markdown ~width:40 text) actual
  in
  append "alpha\n";
  append "beta\n";
  append "gamma";
  append " delta";
  let unchanged = Buffer.contents source in
  ignore (render_growing cache calls "entry-a" unchanged : string list);
  check (list string) "each later render starts at the previous mutable block"
    [ "alpha\n"; "alpha\nbeta\n"; "beta\ngamma"; "gamma delta" ]
    (List.rev !calls)

let test_unchanged_growing_snapshot_never_reaches_the_renderer () =
  let cache = Cache.create ~capacity:4 in
  let calls = ref [] in
  let text = "alpha\nbeta" in
  let first = render_growing cache calls "entry-a" text in
  let second = render_growing cache calls "entry-a" text in
  let third = render_growing cache calls "entry-a" text in
  check (list string) "hits return the same rows" first second;
  check (list string) "hits keep returning the same rows" first third;
  check (list string) "only the first snapshot was parsed"
    [ text ] (List.rev !calls)

let test_appended_text_parses_only_the_new_suffix () =
  let cache = Cache.create ~capacity:4 in
  let calls = ref [] in
  let source = Buffer.create 64 in
  let append chunk =
    Buffer.add_string source chunk;
    let text = Buffer.contents source in
    let actual = render_growing cache calls "entry-a" text in
    check (list string) ("full rows after " ^ chunk)
      (full_markdown ~width:40 text) actual
  in
  append "settled line\npartial";
  append " grows";
  append " further\nnext";
  check (list string) "each render starts at the previous mutable block"
    [ "settled line\npartial"; "partial grows"; "partial grows further\nnext" ]
    (List.rev !calls)

let test_growing_retention_is_bounded_and_recent () =
  let cache = Cache.create ~capacity:2 in
  let calls = ref [] in
  ignore (render_growing cache calls "entry-a" "a" : string list);
  ignore (render_growing cache calls "entry-b" "b" : string list);
  ignore (render_growing cache calls "entry-a" "a" : string list);
  ignore (render_growing cache calls "entry-c" "c" : string list);
  ignore (render_growing cache calls "entry-b" "b" : string list);
  check int "least recently used growing entry was rendered again" 4
    (List.length !calls);
  check int "growing capacity remains exact" 2
    (Cache.For_testing.retained_growing_entries cache)

let test_growing_keys_and_non_prefix_snapshots_reset () =
  let cache = Cache.create ~capacity:4 in
  let calls = ref [] in
  let source = "alpha\nbeta" in
  ignore (render_growing cache calls "entry-a" source : string list);
  calls := [];
  ignore (render_growing cache calls ~width:41 "entry-a" source : string list);
  ignore
    (render_growing cache calls ~width:41 ~theme_revision:2 "entry-a" source
      : string list);
  ignore
    (render_growing cache calls ~width:41 ~theme_revision:2
       ~palette_generation:1 "entry-a" source
      : string list);
  ignore
    (render_growing cache calls ~width:41 ~theme_revision:2
       ~palette_generation:1 "entry-b" source
      : string list);
  ignore
    (render_growing cache calls ~width:41 ~theme_revision:2
       ~palette_generation:1 "entry-b" "replacement"
      : string list);
  check (list string)
    "width, theme, palette, identity, and a non-prefix snapshot render in full"
    [ source; source; source; source; "replacement" ]
    (List.rev !calls)

let () =
  run "tui_markdown_render_cache"
    [ ( "cache"
      , [ test_case "same complete source renders once" `Quick
            test_same_complete_source_renders_once
        ; test_case "all render inputs invalidate" `Quick
            test_every_render_input_invalidates
        ; test_case "different entries do not share rows" `Quick
            test_different_entries_do_not_share_rows
        ; test_case "streaming source bypasses cache" `Quick
            test_streaming_source_never_reuses_partial_rows
        ; test_case "retention is bounded and recent" `Quick
            test_retention_is_bounded_and_recent
        ; test_case "every chunk matches the full renderer" `Quick
            test_every_chunk_matches_the_canonical_full_render
        ; test_case "closed blocks are not rendered again" `Quick
            test_closed_blocks_are_not_rendered_again
        ; test_case "unchanged growing snapshot is not parsed again" `Quick
            test_unchanged_growing_snapshot_never_reaches_the_renderer
        ; test_case "appended text parses only the new suffix" `Quick
            test_appended_text_parses_only_the_new_suffix
        ; test_case "growing retention is bounded and recent" `Quick
            test_growing_retention_is_bounded_and_recent
        ; test_case "growing invalidation resets from the full source" `Quick
            test_growing_keys_and_non_prefix_snapshots_reset
        ] )
    ]
