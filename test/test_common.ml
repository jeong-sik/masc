open Alcotest

let set_env name value = Unix.putenv name value
let unset_env name = Unix.putenv name ""

let with_env name value f =
  let prev = Sys.getenv_opt name in
  (match value with
   | Some v -> set_env name v
   | None -> unset_env name);
  Fun.protect
    ~finally:(fun () ->
      match prev with
      | Some v -> set_env name v
      | None -> unset_env name)
    f

let test_protect_finally_runs () =
  let called = ref false in
  let value =
    Common.protect
      ~module_name:"test_common"
      ~finally_label:"finally"
      ~finally:(fun () -> called := true)
      (fun () -> 42)
  in
  check int "value" 42 value;
  check bool "finally called" true !called

let test_protect_finally_error_no_raise () =
  with_env "MASC_STRICT_FINALIZERS" (Some "0") (fun () ->
    let called = ref false in
    let value =
      Common.protect
        ~module_name:"test_common"
        ~finally_label:"finally"
        ~finally:(fun () -> called := true; failwith "boom")
        (fun () -> 7)
    in
    check int "value" 7 value;
    check bool "finally called" true !called)

let test_protect_finally_error_raise () =
  with_env "MASC_STRICT_FINALIZERS" (Some "1") (fun () ->
    let raised =
      try
        let _ =
          Common.protect
            ~module_name:"test_common"
            ~finally_label:"finally"
            ~finally:(fun () -> failwith "boom")
            (fun () -> 1)
        in
        false
      with Failure _ -> true
    in
    check bool "raises in strict mode" true raised)

let test_protect_preserves_exception () =
  let raised =
    try
      let _ =
        Common.protect
          ~module_name:"test_common"
          ~finally_label:"finally"
          ~finally:(fun () -> failwith "finalizer")
          (fun () -> failwith "main")
      in
      None
    with Failure msg -> Some msg
  in
  check (option string) "main exception preserved" (Some "main") raised

let test_safe_filename_neutralizes_separators () =
  (* A name carrying path syntax must not reach the filesystem as path syntax.
     Auth built credential paths by concatenating the raw agent name, so this
     is the property that layer was missing. *)
  let escaped = Common.safe_filename "../../etc/passwd" in
  (* [.] stays legal — it belongs in file names. What must not survive is the
     separator, because without it the whole thing is one path component and
     [Filename.concat] cannot be walked out of. *)
  check bool "no separator survives" false (String.contains escaped '/');
  check string "escapes to one component" ".._2f.._2fetc_2fpasswd" escaped

let test_safe_filename_is_identity_on_live_names () =
  (* The names actually on disk already satisfy the rule, so routing auth
     through this does not orphan an existing credential file. *)
  List.iter
    (fun name -> check string name name (Common.safe_filename name))
    [ "codex-mcp-client"; "dashboard-admin-deft-cobra"; "keeper-base-agent" ]

let test_safe_filename_folds_case () =
  check string "uppercase folds" "keeper-base" (Common.safe_filename "Keeper-Base")

let test_frontmatter_crlf_delimiter_is_seen () =
  (* Two of the three readers this replaced matched "---" exactly, so a file
     written with CRLF had no frontmatter as far as they were concerned while
     the third read it fine. *)
  let content = "---\r\ntitle: Example\r\n---\r\nbody" in
  let parsed = Frontmatter.parse content in
  check string "title is read" "Example" (Frontmatter.field parsed "title")

let test_frontmatter_absent_returns_whole_content () =
  let content = "no frontmatter here" in
  let parsed = Frontmatter.parse content in
  check (list (pair string string)) "no fields" [] parsed.Frontmatter.fields;
  check string "body is the input" content parsed.Frontmatter.body

let test_frontmatter_body_keeps_the_trailing_newline () =
  (* The readers this replaced disagreed here: prompt_registry kept the body
     verbatim, mcp_server_eio_resource trimmed it. parse follows the verbatim
     reading, and the resource surface trims at its own call site. Pinned so
     a later "tidy up" in the parser does not silently change both. *)
  let parsed = Frontmatter.parse "---\ntitle: T\n---\nAlpha body\n" in
  check string "body" "Alpha body\n" parsed.Frontmatter.body

let test_frontmatter_body_excludes_the_block () =
  let parsed = Frontmatter.parse "---\ntitle: T\n---\nline one\nline two" in
  check string "body" "line one\nline two" parsed.Frontmatter.body

let test_frontmatter_tags_accept_both_shapes () =
  let bracketed = Frontmatter.parse "---\ntags: [a, b]\n---\n" in
  let bare = Frontmatter.parse "---\ntags: a, b\n---\n" in
  check (list string) "bracketed" [ "a"; "b" ] (Frontmatter.list_field bracketed "tags");
  check (list string) "bare" [ "a"; "b" ] (Frontmatter.list_field bare "tags")

let test_frontmatter_line_without_colon_is_skipped () =
  let parsed = Frontmatter.parse "---\njust text\ntitle: T\n---\n" in
  check string "title still read" "T" (Frontmatter.field parsed "title");
  check int "only one field" 1 (List.length parsed.Frontmatter.fields)

let () =
  run "Common" [
    "finalizer_guard", [
      test_case "runs finally" `Quick test_protect_finally_runs;
      test_case "finalizer error no raise" `Quick test_protect_finally_error_no_raise;
      test_case "finalizer error raise" `Quick test_protect_finally_error_raise;
      test_case "preserve main exception" `Quick test_protect_preserves_exception;
    ];
    "safe_filename", [
      test_case "neutralizes separators" `Quick test_safe_filename_neutralizes_separators;
      test_case "identity on live names" `Quick test_safe_filename_is_identity_on_live_names;
      test_case "folds case" `Quick test_safe_filename_folds_case;
    ];
    "frontmatter", [
    test_case "body keeps the trailing newline" `Quick test_frontmatter_body_keeps_the_trailing_newline;
      test_case "CRLF delimiter is seen" `Quick test_frontmatter_crlf_delimiter_is_seen;
      test_case "absent returns whole content" `Quick
        test_frontmatter_absent_returns_whole_content;
      test_case "body excludes the block" `Quick test_frontmatter_body_excludes_the_block;
      test_case "tags accept both shapes" `Quick test_frontmatter_tags_accept_both_shapes;
      test_case "line without colon is skipped" `Quick
        test_frontmatter_line_without_colon_is_skipped;
    ];
  ]
