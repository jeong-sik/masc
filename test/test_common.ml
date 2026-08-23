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
  ]
