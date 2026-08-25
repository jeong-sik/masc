open Alcotest

module Cache = Masc_tui_markdown_render_cache

let counted_renderer calls ~width text =
  incr calls;
  [ Printf.sprintf "%d:%s" width text ]

let stable identity text = Cache.Stable_source { identity; text }

let render cache calls ?(theme_revision = 1) ?(palette_generation = 0)
    ?(width = 40) source =
  Cache.render cache ~theme_revision ~palette_generation ~width
    ~renderer:(counted_renderer calls) ~source

let test_same_complete_source_renders_once () =
  let calls = ref 0 in
  let cache = Cache.create ~capacity:4 ~equal:String.equal in
  let source = stable "entry-a" "# heading\nbody" in
  let first = render cache calls source in
  let second = render cache calls source in
  check (list string) "a hit returns the same rows" first second;
  check int "renderer calls" 1 !calls;
  check int "one completed entry retained" 1
    (Cache.For_testing.retained_entries cache)

let test_every_render_input_invalidates () =
  let calls = ref 0 in
  let cache = Cache.create ~capacity:4 ~equal:String.equal in
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
  let cache = Cache.create ~capacity:4 ~equal:String.equal in
  ignore (render cache calls (stable "entry-a" "same body") : string list);
  ignore (render cache calls (stable "entry-b" "same body") : string list);
  ignore (render cache calls (stable "entry-a" "same body") : string list);
  check int "the second identity is a miss and the first remains a hit" 2 !calls;
  check int "both identities are retained" 2
    (Cache.For_testing.retained_entries cache)

let test_streaming_source_never_reuses_partial_rows () =
  let calls = ref 0 in
  let cache = Cache.create ~capacity:4 ~equal:String.equal in
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
  let cache = Cache.create ~capacity:2 ~equal:String.equal in
  ignore (render cache calls (stable "entry-a" "a") : string list);
  ignore (render cache calls (stable "entry-b" "b") : string list);
  ignore (render cache calls (stable "entry-a" "a") : string list);
  ignore (render cache calls (stable "entry-c" "c") : string list);
  ignore (render cache calls (stable "entry-b" "b") : string list);
  check int "least recently used entry was rendered again" 4 !calls;
  check int "capacity remains exact" 2
    (Cache.For_testing.retained_entries cache)

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
        ] )
    ]
