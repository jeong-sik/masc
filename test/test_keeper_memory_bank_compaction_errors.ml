(** P0-6: memory-bank compaction surfaces typed errors for schema mismatch and
    write failures instead of swallowing them. *)

module Bank = Masc.Keeper_memory_bank
module Policy = Masc.Keeper_memory_policy

let make_meta name : Masc.Keeper_meta_contract.keeper_meta =
  let json = `Assoc [ ("name", `String name) ] in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok m -> m
  | Error e -> failwith ("meta_of_json failed: " ^ e)
;;

let write_file path content =
  let (_ : string) = Masc.Keeper_fs.ensure_dir (Filename.dirname path) in
  match Fs_compat.save_file_atomic path content with
  | Ok () -> ()
  | Error msg -> Alcotest.fail msg
;;

let progress_row ~trace_id ~text : string =
  `Assoc
    [ ("schema_version", `Int Policy.keeper_memory_schema_version)
    ; ("kind", `String "progress")
    ; ("horizon", `String Policy.short_term_horizon)
    ; ("source", `String "tool_result")
    ; ("trace_id", `String trace_id)
    ; ("generation", `Int 1)
    ; ("priority", `Int 50)
    ; ("text", `String text)
    ; ("ts_unix", `Float 1_700_000_000.0)
    ]
  |> Yojson.Safe.to_string
;;

let with_temp_dir f =
  let marker = Filename.temp_file "memory-bank-compaction-" ".tmp" in
  Sys.remove marker;
  Unix.mkdir marker 0o700;
  Fun.protect ~finally:(fun () ->
    try
      let rec rm path =
        if Sys.is_directory path
        then (
          Sys.readdir path
          |> Array.iter (fun name -> rm (Filename.concat path name));
          Unix.rmdir path)
        else Sys.remove path
      in
      rm marker
    with _ -> ()) (fun () -> f marker)
;;

let test_schema_mismatch_surfaces_typed_error () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "schema-mismatch" in
  let path = Masc.Keeper_types_support.keeper_memory_bank_path config meta.name in
  (* One valid row and one row with a stale schema_version. *)
  let content =
    String.concat
      "\n"
      [ progress_row ~trace_id:"t1" ~text:"valid row"
      ; (`Assoc [ ("schema_version", `Int 1); ("kind", `String "progress") ]
         |> Yojson.Safe.to_string)
      ]
    ^ "\n"
  in
  write_file path content;
  let result = Bank.compact_memory_bank_if_needed config meta in
  Alcotest.(check bool) "compaction was attempted" true result.Policy.performed;
  Alcotest.(check (option (Alcotest.testable (Fmt.of_to_string Policy.compaction_error_to_string) ( = ))))
    "schema mismatch surfaced"
    (Some Policy.Schema_mismatch)
    result.Policy.error
;;

let test_malformed_json_is_not_schema_mismatch () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "malformed-json" in
  let path = Masc.Keeper_types_support.keeper_memory_bank_path config meta.name in
  let content =
    String.concat
      "\n"
      [ progress_row ~trace_id:"t1" ~text:"valid row"; {|{"schema_version":|} ]
    ^ "\n"
  in
  write_file path content;
  let result = Bank.compact_memory_bank_if_needed config meta in
  Alcotest.(check bool) "compaction was attempted" true result.Policy.performed;
  Alcotest.(check int) "invalid row dropped" 1 result.Policy.invalid_dropped;
  Alcotest.(check (option (Alcotest.testable (Fmt.of_to_string Policy.compaction_error_to_string) ( = ))))
    "malformed json is not schema mismatch"
    None
    result.Policy.error
;;

let test_write_failure_surfaces_typed_error () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "write-failure" in
  let path = Masc.Keeper_types_support.keeper_memory_bank_path config meta.name in
  (* Enough identical rows to exceed the dedup threshold and force a rewrite. *)
  let rows =
    List.init 50 (fun i -> progress_row ~trace_id:("t" ^ string_of_int i) ~text:"duplicate")
  in
  let content = String.concat "\n" rows ^ "\n" in
  write_file path content;
  (* Make the keeper directory read-only so the atomic rewrite fails. *)
  let keeper_dir = Filename.dirname path in
  let original_perms = (Unix.stat keeper_dir).st_perm in
  Unix.chmod keeper_dir 0o555;
  Fun.protect
    ~finally:(fun () -> Unix.chmod keeper_dir original_perms)
    (fun () ->
       let result = Bank.compact_memory_bank_if_needed config meta in
       Alcotest.(check bool) "compaction was attempted" true result.Policy.performed;
       Alcotest.(check bool) "error is present" true (Option.is_some result.Policy.error);
       match result.Policy.error with
       | Some (Policy.Write_error _) -> ()
       | Some other ->
         Alcotest.failf
           "expected Write_error, got %s"
           (Policy.compaction_error_to_string other)
       | None -> Alcotest.fail "expected Write_error")
;;

let () =
  Alcotest.run
    "keeper_memory_bank_compaction_errors"
    [ ( "compaction_errors"
      , [ Alcotest.test_case
            "schema mismatch surfaces typed error"
            `Quick
            test_schema_mismatch_surfaces_typed_error
        ; Alcotest.test_case
            "write failure surfaces typed error"
            `Quick
            test_write_failure_surfaces_typed_error
        ; Alcotest.test_case
            "malformed json is not schema mismatch"
            `Quick
            test_malformed_json_is_not_schema_mismatch
        ] )
    ]
;;
