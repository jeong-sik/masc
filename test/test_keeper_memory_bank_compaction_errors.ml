(** P0-6: memory-bank compaction surfaces typed errors for schema mismatch and
    write failures instead of swallowing them. *)

module Bank = Masc.Keeper_memory_bank
module Policy = Masc.Keeper_memory_policy
module Recall = Masc.Keeper_memory_recall
module Search = Masc.Keeper_tool_memory_runtime

let make_meta ?trace_id name : Masc.Keeper_meta_contract.keeper_meta =
  let fields =
    [ ("name", `String name) ]
    @
    match trace_id with
    | Some value -> [ ("trace_id", `String value) ]
    | None -> []
  in
  let json = `Assoc fields in
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

let with_env key value f =
  let previous = Sys.getenv_opt key in
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some old -> Unix.putenv key old
      | None -> Unix.putenv key "")
    (fun () ->
      Unix.putenv key value;
      f ())
;;

let progress_row ?(priority = 50) ~trace_id ~text () : string =
  `Assoc
    [ ("schema_version", `Int Policy.keeper_memory_schema_version)
    ; ("kind", `String "progress")
    ; ("horizon", `String Policy.short_term_horizon)
    ; ("source", `String "tool_result")
    ; ("trace_id", `String trace_id)
    ; ("generation", `Int 1)
    ; ("priority", `Int priority)
    ; ("text", `String text)
    ; ("ts_unix", `Float 1_700_000_000.0)
    ]
  |> Yojson.Safe.to_string
;;

let with_temp_dir f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let marker = Filename.temp_file "memory-bank-compaction-" ".tmp" in
  Sys.remove marker;
  Unix.mkdir marker 0o700;
  Fun.protect
    ~finally:(fun () ->
      Fs_compat.clear_fs ();
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
      with _ -> ())
    (fun () -> f marker)
;;

let with_eio_fs f () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Fun.protect ~finally:Fs_compat.clear_fs f
;;

let assoc_field name = function
  | `Assoc fields ->
    (match List.assoc_opt name fields with
     | Some value -> value
     | None -> Alcotest.failf "missing JSON field %s" name)
  | _ -> Alcotest.fail "expected JSON object"
;;

let json_int_field name json =
  match assoc_field name json with
  | `Int n -> n
  | other ->
    Alcotest.failf
      "expected integer field %s, got %s"
      name
      (Yojson.Safe.to_string other)
;;

let json_string_field name json =
  match assoc_field name json with
  | `String s -> s
  | other ->
    Alcotest.failf
      "expected string field %s, got %s"
      name
      (Yojson.Safe.to_string other)
;;

let json_bool_field name json =
  match assoc_field name json with
  | `Bool value -> value
  | other ->
    Alcotest.failf
      "expected bool field %s, got %s"
      name
      (Yojson.Safe.to_string other)
;;

let json_float_field name json =
  match assoc_field name json with
  | `Float f -> f
  | `Int n -> float_of_int n
  | other ->
    Alcotest.failf
      "expected numeric field %s, got %s"
      name
      (Yojson.Safe.to_string other)
;;

let json_list_field name json =
  match assoc_field name json with
  | `List values -> values
  | other ->
    Alcotest.failf
      "expected list field %s, got %s"
      name
      (Yojson.Safe.to_string other)
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
      [ progress_row ~trace_id:"t1" ~text:"valid row" ()
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
      [ progress_row ~trace_id:"t1" ~text:"valid row" (); {|{"schema_version":|} ]
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

let test_memory_search_json_returns_partial_bank_match () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "partial-search" in
  let path = Masc.Keeper_types_support.keeper_memory_bank_path config meta.name in
  let relevant_text = "notable release lesson persisted for future keeper recall" in
  let weaker_text = "event-only low priority note" in
  let content =
    String.concat
      "\n"
      [ progress_row ~priority:100 ~trace_id:"partial-1" ~text:relevant_text ()
      ; progress_row ~priority:5 ~trace_id:"partial-2" ~text:weaker_text ()
      ]
    ^ "\n"
  in
  write_file path content;
  let ctx_work =
    Masc.Keeper_context_runtime.create
      ~eio:false
      ~system_prompt:"test"
      ~max_tokens:4000
  in
  let raw =
    Search.keeper_memory_search_json
      ~config
      ~meta
      ~ctx_work
      ~args:
        (`Assoc
          [ ("source", `String "memory")
          ; ("query", `String "notable event lesson learned")
          ; ("limit", `Int 2)
          ])
  in
  let json = Yojson.Safe.from_string raw in
  Alcotest.(check int) "bank candidates" 2 (json_int_field "total_candidates" json);
  Alcotest.(check int) "partial matches returned" 2 (json_int_field "match_count" json);
  (match List.assoc_opt "no_match" (match json with `Assoc fields -> fields | _ -> []) with
   | None -> ()
   | Some _ -> Alcotest.fail "partial memory search must not report no_match");
  match json_list_field "matches" json with
  | first :: _ ->
    Alcotest.(check string)
      "stronger partial match is ranked first"
      relevant_text
      (json_string_field "text" first);
    Alcotest.(check bool)
      "top score is positive"
      true
      (json_float_field "score" first > 0.0)
  | [] -> Alcotest.fail "expected at least one memory match"
;;

let test_memory_search_history_surfaces_read_error () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let current_trace_id = "history-read-error-trace" in
  let meta = make_meta ~trace_id:current_trace_id "history-read-error-search" in
  let history_path =
    Masc.Keeper_types_support.keeper_history_path config current_trace_id
  in
  let (_ : string) = Masc.Keeper_fs.ensure_dir (Filename.dirname history_path) in
  Unix.mkdir history_path 0o700;
  let ctx_work =
    Masc.Keeper_context_runtime.create
      ~eio:false
      ~system_prompt:"test"
      ~max_tokens:4000
    |> fun ctx ->
    Masc.Keeper_context_runtime.append ctx
      (Agent_sdk.Types.user_msg "checkpoint history needle survives")
  in
  let raw =
    Search.keeper_memory_search_json
      ~config
      ~meta
      ~ctx_work
      ~args:
        (`Assoc
          [ ("source", `String "history")
          ; ("query", `String "checkpoint needle")
          ; ("limit", `Int 5)
          ])
  in
  let json = Yojson.Safe.from_string raw in
  Alcotest.(check int) "checkpoint match survives" 1 (json_int_field "match_count" json);
  Alcotest.(check int) "history read error count" 1 (json_int_field "read_error_count" json);
  Alcotest.(check bool) "partial result marked" true (json_bool_field "partial" json);
  (match json_list_field "matches" json with
   | [ `String msg ] ->
     Alcotest.(check string)
       "checkpoint match text"
       "checkpoint history needle survives"
       msg
   | other ->
     Alcotest.failf
       "expected one checkpoint string match, got %s"
       (Yojson.Safe.to_string (`List other)));
  (match json_list_field "read_errors" json with
   | [ error ] ->
     Alcotest.(check string) "error source" "history" (json_string_field "source" error);
     Alcotest.(check string) "error path" history_path (json_string_field "path" error);
     Alcotest.(check string)
       "error class"
       "io_error"
       (json_string_field "exception_class" error)
   | other ->
     Alcotest.failf
       "expected one history read error, got %s"
       (Yojson.Safe.to_string (`List other)))
;;

let test_recall_candidates_with_history_outcome_reports_read_error () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let trace_id = "recall-candidates-read-error-trace" in
  let history_path = Masc.Keeper_types_support.keeper_history_path config trace_id in
  let (_ : string) = Masc.Keeper_fs.ensure_dir (Filename.dirname history_path) in
  Unix.mkdir history_path 0o700;
  let outcome =
    Recall.recall_candidates_with_history_outcome
      ~checkpoint_messages:
        [ Agent_sdk.Types.user_msg "checkpoint recall survives history read error" ]
      ~history_path
      ~max_checkpoint:5
      ~max_history:5
  in
  Alcotest.(check (list string))
    "checkpoint candidate survives"
    [ "checkpoint recall survives history read error" ]
    outcome.Recall.candidates;
  match outcome.Recall.history_read_error with
  | Some exn_class ->
    Alcotest.(check string)
      "history read error class"
      "io_error"
      (Masc.Keeper_memory_recall_exn_class.to_label exn_class)
  | None -> Alcotest.fail "expected history read error"
;;

let test_write_failure_surfaces_typed_error () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "write-failure" in
  let path = Masc.Keeper_types_support.keeper_memory_bank_path config meta.name in
  (* Enough identical rows to exceed the compaction target and force a rewrite. *)
  let target_notes = Bank.memory_compaction_target_notes () in
  let rows =
    List.init (target_notes + 30) (fun i ->
      progress_row ~trace_id:("t" ^ string_of_int i) ~text:"duplicate" ())
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
       let result =
         with_env "MASC_KEEPER_MEMORY_MAX_NOTES" "40" (fun () ->
           Bank.compact_memory_bank_if_needed config meta)
       in
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
            (with_eio_fs test_schema_mismatch_surfaces_typed_error)
        ; Alcotest.test_case
            "write failure surfaces typed error"
            `Quick
            (with_eio_fs test_write_failure_surfaces_typed_error)
        ; Alcotest.test_case
            "malformed json is not schema mismatch"
            `Quick
            (with_eio_fs test_malformed_json_is_not_schema_mismatch)
        ; Alcotest.test_case
            "partial search returns memory-bank match"
            `Quick
            (with_eio_fs test_memory_search_json_returns_partial_bank_match)
        ; Alcotest.test_case
            "history search surfaces read errors"
            `Quick
            (with_eio_fs test_memory_search_history_surfaces_read_error)
        ; Alcotest.test_case
            "recall candidates outcome reports history read errors"
            `Quick
            (with_eio_fs
               test_recall_candidates_with_history_outcome_reports_read_error)
        ] )
    ]
;;
