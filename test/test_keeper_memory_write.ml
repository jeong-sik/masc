(** Explicit keeper memory writes use a direct, typed persistence path. *)

module Runtime = Masc.Keeper_tool_memory_runtime
module Bank = Masc.Keeper_memory_bank

let make_args ~kind ~title ~content =
  `Assoc
    [ "kind", `String kind
    ; "title", `String title
    ; "content", `String content
    ]
;;

let with_days args days =
  match args with
  | `Assoc fields -> `Assoc (fields @ [ "valid_for_days", `Int days ])
  | other -> other
;;

let error_label = Runtime.memory_write_error_kind_to_string

let assert_invalid ~expected = function
  | Runtime.Memory_write_invalid { error_kind; _ } ->
    Alcotest.(check string) "error kind" expected (error_label error_kind)
  | Runtime.Memory_write_ok _ ->
    Alcotest.failf "expected invalid memory write: %s" expected
;;

let assert_ok ?(valid_for_days = None) ~kind ~body = function
  | Runtime.Memory_write_ok valid ->
    Alcotest.(check (option int)) "valid_for_days" valid_for_days valid.valid_for_days;
    Alcotest.(check string)
      "kind"
      kind
      (Bank.memory_kind_to_wire valid.kind);
    Alcotest.(check string) "body" body valid.body
  | Runtime.Memory_write_invalid { error_kind; _ } ->
    Alcotest.failf "unexpected validation error: %s" (error_label error_kind)
;;

let rec remove_tree path =
  if Sys.file_exists path
  then if Sys.is_directory path
  then (
    Sys.readdir path
    |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path)
  else Sys.remove path
;;

let with_temp_dir f =
  let dir = Filename.temp_file "keeper-memory-write-" ".tmp" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () -> f dir)
;;

let make_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String name
        ; "trace_id", `String ("trace-" ^ name)
        ])
  with
  | Error error -> Alcotest.fail ("meta fixture failed: " ^ error)
  | Ok meta ->
    let usage = { meta.runtime.usage with total_turns = 7 } in
    { meta with runtime = { meta.runtime with usage } }
;;

let json_field key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some value -> value
     | None -> Alcotest.failf "missing JSON field: %s" key)
  | _ -> Alcotest.fail "expected JSON object"
;;

let string_field key json =
  match json_field key json with
  | `String value -> value
  | _ -> Alcotest.failf "expected string field: %s" key
;;

let int_field key json =
  match json_field key json with
  | `Int value -> value
  | _ -> Alcotest.failf "expected int field: %s" key
;;

let only_jsonl_row path =
  let rows =
    Fs_compat.load_file path
    |> String.split_on_char '\n'
    |> List.filter (fun line -> String.trim line <> "")
  in
  match rows with
  | [ row ] -> Yojson.Safe.from_string row
  | _ -> Alcotest.failf "expected one memory row, got %d" (List.length rows)
;;

let count_jsonl_rows path =
  if not (Sys.file_exists path)
  then 0
  else
    Fs_compat.load_file path
    |> String.split_on_char '\n'
    |> List.filter (fun line -> String.trim line <> "")
    |> List.length
;;

(* No Unix.unsetenv in the stdlib; restore the prior value, or "true"
   (the flag's default) when it was unset — behaviourally equivalent for the
   other tests, which all expect bank writes enabled. *)
let with_bank_write_disabled f =
  let key = "MASC_KEEPER_MEMORY_BANK_WRITE" in
  let prev = Sys.getenv_opt key in
  Unix.putenv key "false";
  Fun.protect
    ~finally:(fun () -> Unix.putenv key (Option.value prev ~default:"true"))
    f
;;

let test_validation_taxonomy () =
  Runtime.validate_memory_write_args
    (make_args ~kind:"bogus" ~title:"" ~content:"body")
  |> assert_invalid ~expected:"invalid_memory_kind";
  Runtime.validate_memory_write_args
    (make_args ~kind:"next" ~title:"" ~content:"body")
  |> assert_invalid ~expected:"invalid_memory_kind";
  Runtime.validate_memory_write_args
    (make_args ~kind:"constraints" ~title:"" ~content:"body")
  |> assert_invalid ~expected:"invalid_memory_kind";
  Runtime.validate_memory_write_args
    (make_args ~kind:"GOAL" ~title:"" ~content:"body")
  |> assert_invalid ~expected:"invalid_memory_kind";
  Runtime.validate_memory_write_args
    (make_args ~kind:" goal " ~title:"" ~content:"body")
  |> assert_invalid ~expected:"invalid_memory_kind";
  Runtime.validate_memory_write_args
    (make_args ~kind:"goal" ~title:"" ~content:"")
  |> assert_invalid ~expected:"content_empty";
  Runtime.validate_memory_write_args
    (make_args ~kind:"goal" ~title:(String.make 121 'x') ~content:"body")
  |> assert_invalid ~expected:"title_too_long";
  Runtime.validate_memory_write_args
    (make_args ~kind:"goal" ~title:"" ~content:"none")
  |> assert_invalid ~expected:"content_rejected";
  (* RFC-0351 S2: a lifetime is a claim about scope, so both ends are real
     boundaries and a turn-scoped kind cannot carry one at all. *)
  Runtime.validate_memory_write_args
    (with_days (make_args ~kind:"long_term" ~title:"" ~content:"body") 0)
  |> assert_invalid ~expected:"invalid_valid_for_days";
  Runtime.validate_memory_write_args
    (with_days (make_args ~kind:"long_term" ~title:"" ~content:"body") 366)
  |> assert_invalid ~expected:"invalid_valid_for_days";
  Runtime.validate_memory_write_args
    (with_days (make_args ~kind:"goal" ~title:"" ~content:"body") 7)
  |> assert_invalid ~expected:"valid_for_days_on_turn_scoped_kind"
;;

let test_valid_body_has_no_intermediate_projection () =
  Runtime.validate_memory_write_args
    (make_args ~kind:"long_term" ~title:"" ~content:"body")
  |> assert_ok ~kind:"long_term" ~body:"body";
  Runtime.validate_memory_write_args
    (with_days (make_args ~kind:"long_term" ~title:"" ~content:"body") 30)
  |> assert_ok ~valid_for_days:(Some 30) ~kind:"long_term" ~body:"body";
  Runtime.validate_memory_write_args
    (make_args ~kind:"decision" ~title:"hook" ~content:"body text")
  |> assert_ok ~kind:"decision" ~body:"**hook** body text";
  Runtime.validate_memory_write_args
    (make_args ~kind:"goal" ~title:"" ~content:"plain body")
  |> assert_ok ~kind:"goal" ~body:"plain body"
;;

let test_bank_rejects_nonwritable_kind () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "invalid-bank-write" in
  (match
     Bank.append_explicit_memory_note
       config
       meta
       ~turn:7
       ~kind:Bank.Long_term
       ~text:"reserved kind"
   with
   | Error (Bank.Explicit_memory_kind_not_writable Bank.Long_term) -> ()
   | _ -> Alcotest.fail "nonwritable kind must be rejected explicitly");
  match
    Bank.append_explicit_memory_note
      config
      meta
      ~turn:7
      ~kind:Bank.Goal
      ~text:"none"
  with
  | Error Bank.Rejected_explicit_memory_text -> ()
  | _ -> Alcotest.fail "filtered content must return a typed rejection"
;;

(* RFC-0351 L1 / masc#25517. The loop the model actually depends on: a
   long-term write must reach the store recall reads back, not the turn-scoped
   bank that no prompt block renders. The assertion goes through
   [read_facts_all] — the same reader [Keeper_memory_os_recall] calls — rather
   than through the rendered block, because routing is what this test is about
   and rendering is covered in test_keeper_memory_os. *)
let test_long_term_write_comes_back_through_recall () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "durable-write" in
  let keepers_dir = Filename.concat base_path "keepers" in
  Masc.Keeper_memory_os_io.For_testing.with_keepers_dir keepers_dir (fun () ->
    let response =
      Runtime.keeper_memory_write_json
        ~config
        ~meta
        ~args:
          (make_args
             ~kind:"long_term"
             ~title:""
             ~content:"reasoning_content must be replayed unmodified")
      |> Yojson.Safe.from_string
    in
    Alcotest.(check bool)
      "write succeeds"
      true
      (match json_field "ok" response with
       | `Bool value -> value
       | _ -> false);
    Alcotest.(check string)
      "routed to the durable store"
      "durable_fact_store"
      (string_field "store" response);
    let facts = Masc.Keeper_memory_os_io.read_facts_all ~keeper_id:meta.name in
    Alcotest.(check int) "one durable claim" 1 (List.length facts);
    let fact = List.hd facts in
    Alcotest.(check string)
      "the claim reaches a later turn"
      "reasoning_content must be replayed unmodified"
      fact.Masc.Keeper_memory_os_types.claim;
    Alcotest.(check int)
      "provenance carries this turn"
      7
      fact.Masc.Keeper_memory_os_types.source.turn;
    (* The model asserted this itself; it did not carry it out of another
       tool's result, and the field says where an observation came from. *)
    Alcotest.(check bool)
      "no borrowed tool provenance"
      true
      (fact.Masc.Keeper_memory_os_types.source.tool_call_id = None);
    Alcotest.(check bool)
      "a claim with no declared lifetime stays permanent"
      true
      (fact.Masc.Keeper_memory_os_types.valid_until = None))
;;

(* RFC-0351 S2. Recall has always dropped expired facts; until now nothing
   could set the boundary, so all 747 facts in the live fleet read as
   permanent. This pins the whole path: the declared lifetime reaches the
   store, and the reader recall uses actually drops the claim past it. *)
let test_declared_lifetime_expires () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "expiring-write" in
  let keepers_dir = Filename.concat base_path "keepers" in
  Masc.Keeper_memory_os_io.For_testing.with_keepers_dir keepers_dir (fun () ->
    let response =
      Runtime.keeper_memory_write_json
        ~config
        ~meta
        ~args:
          (with_days
             (make_args ~kind:"long_term" ~title:"" ~content:"task-2288 is blocked on the git-root gate")
             7)
      |> Yojson.Safe.from_string
    in
    Alcotest.(check bool)
      "write succeeds"
      true
      (match json_field "ok" response with
       | `Bool value -> value
       | _ -> false);
    let fact = List.hd (Masc.Keeper_memory_os_io.read_facts_all ~keeper_id:meta.name) in
    let valid_until =
      match fact.Masc.Keeper_memory_os_types.valid_until with
      | Some ts -> ts
      | None -> Alcotest.fail "declared lifetime did not reach the store"
    in
    let first_seen = fact.Masc.Keeper_memory_os_types.first_seen in
    (* 7 days from the write, to the second. *)
    Alcotest.(check (float 1.0))
      "boundary is the declared span"
      (7.0 *. 86_400.)
      (valid_until -. first_seen);
    Alcotest.(check bool)
      "still current inside the window"
      true
      (Masc.Keeper_memory_os_types.fact_is_current
         ~now:(valid_until -. 86_400.)
         fact);
    Alcotest.(check bool)
      "recall drops it past the window"
      false
      (Masc.Keeper_memory_os_types.fact_is_current
         ~now:(valid_until +. 1.0)
         fact))
;;

let test_tool_write_persists_typed_provenance () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "typed-provenance" in
  let response =
    Runtime.keeper_memory_write_json
      ~config
      ~meta
      ~args:(make_args ~kind:"decision" ~title:"choice" ~content:"Use typed rows")
    |> Yojson.Safe.from_string
  in
  Alcotest.(check bool) "write succeeds" true
    (match json_field "ok" response with `Bool value -> value | _ -> false);
  Alcotest.(check int) "one row" 1 (int_field "rows_written" response);
  let path = Masc.Keeper_types_support.keeper_memory_bank_path config meta.name in
  let row = only_jsonl_row path in
  Alcotest.(check string)
    "typed source"
    "explicit_memory_write"
    (string_field "source" row);
  Alcotest.(check string) "kind" "decision" (string_field "kind" row);
  Alcotest.(check string) "horizon" "mid_term" (string_field "horizon" row);
  Alcotest.(check int) "turn comes from runtime usage SSOT" 7 (int_field "turn" row);
  Alcotest.(check string)
    "body"
    "**choice** Use typed rows"
    (string_field "text" row)
;;

let test_source_round_trip () =
  let source = Bank.Explicit_memory_write in
  let wire = Bank.memory_row_source_to_string source in
  Alcotest.(check string) "wire" "explicit_memory_write" wire;
  Alcotest.(check bool)
    "round trip"
    true
    (Bank.memory_row_source_of_string wire = source)
;;

(* RFC keeper-memory-bank-write-reduction: the MASC_KEEPER_MEMORY_BANK_WRITE
   kill-switch. When off, a valid explicit note is not persisted and reports
   [Skipped_bank_writes_disabled]; when on (default), it persists. Counterfactual:
   without the gate the disabled case would append a row and return [Persisted]. *)
let test_bank_write_kill_switch () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "bank-write-gate" in
  let path = Masc.Keeper_types_support.keeper_memory_bank_path config meta.name in
  let write () =
    Bank.append_explicit_memory_note
      config
      meta
      ~turn:7
      ~kind:Bank.Decision
      ~text:"Release task-1851 due to the HITL approval loop blocking evidence"
  in
  with_bank_write_disabled (fun () ->
    match write () with
    | Ok Bank.Skipped_bank_writes_disabled -> ()
    | Ok Bank.Persisted ->
      Alcotest.fail "kill-switch off must skip the write, not persist"
    | Error _ -> Alcotest.fail "a valid note under the kill-switch must not error");
  Alcotest.(check int) "nothing persisted while disabled" 0 (count_jsonl_rows path);
  (match write () with
   | Ok Bank.Persisted -> ()
   | Ok Bank.Skipped_bank_writes_disabled ->
     Alcotest.fail "with the kill-switch restored (default on) the note must persist"
   | Error _ -> Alcotest.fail "enabled write must not error");
  Alcotest.(check int) "one row persisted once re-enabled" 1 (count_jsonl_rows path)
;;

let () =
  Alcotest.run
    "keeper_memory_write"
    [ ( "validation"
      , [ Alcotest.test_case "typed validation failures" `Quick test_validation_taxonomy
        ; Alcotest.test_case
            "valid input remains a direct kind/body pair"
            `Quick
            test_valid_body_has_no_intermediate_projection
        ] )
    ; ( "persistence"
      , [ Alcotest.test_case
            "bank rejects nonwritable kinds"
            `Quick
            test_bank_rejects_nonwritable_kind
        ; Alcotest.test_case
            "long-term write comes back through recall"
            `Quick
            test_long_term_write_comes_back_through_recall
        ; Alcotest.test_case
            "declared lifetime reaches the store and expires"
            `Quick
            test_declared_lifetime_expires
        ; Alcotest.test_case
            "tool write stores typed provenance"
            `Quick
            test_tool_write_persists_typed_provenance
        ; Alcotest.test_case "source round trips" `Quick test_source_round_trip
        ; Alcotest.test_case
            "bank write kill-switch skips and reports"
            `Quick
            test_bank_write_kill_switch
        ] )
    ]
;;
