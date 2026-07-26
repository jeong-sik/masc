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

(* #25287: a durable store must namespace itself by the row schema version it
   reads, so bumping the version relocates the store instead of leaving the new
   reader to reject the old bytes where they lie. *)
let test_generation_dir_carries_version () =
  check
    string
    "namespace is the version segment under the parent"
    (Filename.concat "/tmp/store" "v6")
    (Common.generation_namespaced_dir ~parent_dir:"/tmp/store" ~schema_version:6)

let test_generation_dir_separates_versions () =
  let v5 = Common.generation_namespaced_dir ~parent_dir:"/tmp/store" ~schema_version:5 in
  let v6 = Common.generation_namespaced_dir ~parent_dir:"/tmp/store" ~schema_version:6 in
  check bool "consecutive versions never share a directory" false (String.equal v5 v6);
  (* The reader must not reach the retired rows by walking down from its own
     namespace either: v5 is a sibling of v6, not an ancestor or descendant. *)
  check bool "retired namespace is not inside the active one" false
    (String.starts_with ~prefix:(v6 ^ Filename.dir_sep) v5);
  check bool "active namespace is not inside the retired one" false
    (String.starts_with ~prefix:(v5 ^ Filename.dir_sep) v6)

(* Version 0 is what [Safe_ops.json_int ~default:0] yields on a missing or
   malformed schema_version field. Letting it name a directory would give every
   undecodable row a shared home that no reader claims. *)
let test_generation_dir_rejects_non_positive () =
  List.iter
    (fun schema_version ->
       check
         bool
         (Printf.sprintf "schema_version %d is refused" schema_version)
         true
         (match
            Common.generation_namespaced_dir ~parent_dir:"/tmp/store" ~schema_version
          with
          | (_ : string) -> false
          | exception Invalid_argument _ -> true))
    [ 0; -1 ]

let () =
  run "Common" [
    "finalizer_guard", [
      test_case "runs finally" `Quick test_protect_finally_runs;
      test_case "finalizer error no raise" `Quick test_protect_finally_error_no_raise;
      test_case "finalizer error raise" `Quick test_protect_finally_error_raise;
      test_case "preserve main exception" `Quick test_protect_preserves_exception;
    ];
    "generation_namespaced_dir", [
      test_case "carries the schema version" `Quick test_generation_dir_carries_version;
      test_case "separates versions" `Quick test_generation_dir_separates_versions;
      test_case "rejects non-positive versions" `Quick
        test_generation_dir_rejects_non_positive;
    ];
  ]
