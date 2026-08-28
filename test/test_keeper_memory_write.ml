(** Explicit Keeper memory writes: every write is a durable Memory OS fact. *)

module Runtime = Masc.Keeper_tool_memory_runtime
module Current = Masc.Keeper_memory_os_current

external unsetenv : string -> unit = "masc_test_unsetenv"

let make_args ~title ~content =
  `Assoc [ "title", `String title; "content", `String content ]
;;

let error_label = Runtime.memory_write_error_kind_to_string

let assert_invalid ~expected = function
  | Runtime.Memory_write_invalid { error_kind; _ } ->
    Alcotest.(check string) "error kind" expected (error_label error_kind)
  | Runtime.Memory_write_ok _ ->
    Alcotest.failf "expected invalid memory write: %s" expected
;;

let assert_ok ~body = function
  | Runtime.Memory_write_ok valid ->
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

let with_env name value f =
  let previous = Sys.getenv_opt name in
  Unix.putenv name value;
  Config_dir_resolver.reset ();
  Fun.protect
    ~finally:(fun () ->
      (match previous with
       | Some old -> Unix.putenv name old
       | None -> unsetenv name);
      Config_dir_resolver.reset ())
    f
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

let match_texts json =
  match json_field "matches" json with
  | `List matches ->
    List.map
      (fun match_json -> string_field "text" match_json)
      matches
  | _ -> Alcotest.fail "expected matches array"
;;

let fact claim : Masc.Keeper_memory_os_types.fact =
  let now = Time_compat.now () in
  { claim
  ; category = Masc.Keeper_memory_os_types.Fact
  ; first_seen = now
  }
;;

let current_facts ~keepers_dir ~keeper_id =
  match Current.read_for_keepers_dir ~keepers_dir ~keeper_id with
  | Ok None -> []
  | Ok (Some snapshot) -> snapshot.facts
  | Error detail -> Alcotest.fail detail
;;

let replace_current_facts ~keepers_dir ~keeper_id facts =
  Current.replace
    ~keepers_dir
    ~keeper_id
    ~expected_revision:None
    ~now:(Time_compat.now ())
    ~source:{ Current.kind = Current.Librarian; trace_id = "seed" }
    ~facts
    ()
  |> function
  | Ok _ -> ()
  | Error detail -> Alcotest.fail detail
;;

let test_validation_taxonomy () =
  Runtime.validate_memory_write_args (make_args ~title:"" ~content:"")
  |> assert_invalid ~expected:"content_empty";
  Runtime.validate_memory_write_args
    (make_args ~title:(String.make 121 'x') ~content:"body")
  |> assert_invalid ~expected:"title_too_long";
  Runtime.validate_memory_write_args
    (make_args ~title:"" ~content:(String.make 4097 'x'))
  |> assert_invalid ~expected:"content_too_long"
;;

let test_valid_body_composition () =
  Runtime.validate_memory_write_args (make_args ~title:"" ~content:"body")
  |> assert_ok ~body:"body";
  Runtime.validate_memory_write_args
    (make_args ~title:"hook" ~content:"body text")
  |> assert_ok ~body:"**hook** body text"
;;

(* The loop the model actually depends on: a write must reach the store
   recall reads back. The assertion goes through [read_facts_all] — the same
   reader [Keeper_memory_os_recall] calls — because routing is what this test
   is about and rendering is covered in test_keeper_memory_os. *)
let test_write_comes_back_through_recall () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "durable-write" in
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path
  in
  let execution =
    Runtime.keeper_memory_write_with_outcome
      ~config
      ~meta
      ~args:
        (make_args
           ~title:""
           ~content:"reasoning_content must be replayed unmodified")
  in
  let response =
    execution.Masc.Keeper_tool_execution.raw_output |> Yojson.Safe.from_string
  in
  Alcotest.(check bool)
    "write succeeds"
    true
    (match json_field "ok" response with
     | `Bool value -> value
     | _ -> false);
  Alcotest.(check string)
    "routed to the current snapshot"
    "current_memory_snapshot"
    (string_field "store" response);
  let response_revision = int_field "revision" response in
  (match execution.Masc.Keeper_tool_execution.terminal_effect_receipt with
   | Some
       (Masc.Keeper_tool_execution.Memory_write_completed { revision }) ->
     Alcotest.(check int)
       "terminal receipt names the committed revision"
       response_revision
       revision
   | Some (Masc.Keeper_tool_execution.Surface_post_completed _) ->
     Alcotest.fail "memory write returned a surface-post receipt"
   | None -> Alcotest.fail "successful memory write has no terminal receipt");
  let facts = current_facts ~keepers_dir ~keeper_id:meta.name in
  Alcotest.(check int) "one durable claim" 1 (List.length facts);
  let fact = List.hd facts in
  Alcotest.(check string)
    "the claim reaches a later turn"
    "reasoning_content must be replayed unmodified"
    fact.Masc.Keeper_memory_os_types.claim;
  Alcotest.(check bool)
    "producer timestamp recorded"
    true
    (fact.Masc.Keeper_memory_os_types.first_seen > 0.0)
;;

let test_invalid_write_is_proven_pre_effect () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let result =
    Runtime.keeper_memory_write_with_outcome
      ~config
      ~meta:(make_meta "invalid-write")
      ~args:(make_args ~title:"" ~content:"")
  in
  (match result.Masc.Keeper_tool_execution.disposition with
   | Tool_result.Failed Tool_result.Workflow_rejection -> ()
   | Tool_result.Completed () | Tool_result.Deferred () ->
     Alcotest.fail "invalid memory write did not fail"
   | Tool_result.Failed _ ->
     Alcotest.fail "invalid memory write used the wrong failure class");
  Alcotest.(check bool)
    "validation failure is known to precede persistence"
    true
    (result.Masc.Keeper_tool_execution.failure_effect_disposition
     = Tool_result.Proven_pre_effect);
  Alcotest.(check bool)
    "validation failure has no terminal receipt"
    true
    (Option.is_none result.Masc.Keeper_tool_execution.terminal_effect_receipt)
;;

let test_search_filters_exact_substring_without_ranking () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "search-order" in
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path
  in
  let first_match =
    { (fact "prefix alpha beta suffix") with first_seen = 100.0 }
  in
  let newer_match =
    { (fact "alpha beta newer") with first_seen = 1_000.0 }
  in
  replace_current_facts
    ~keepers_dir
    ~keeper_id:meta.name
    [ fact "alpha only"; first_match; newer_match ];
  let response =
    Runtime.keeper_memory_search_json
      ~config
      ~meta
      ~ctx_work:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"")
      ~args:
        (`Assoc
           [ "query", `String "alpha beta"
           ; "source", `String "memory"
           ; "limit", `Int 10
           ])
    |> Yojson.Safe.from_string
  in
  Alcotest.(check (list string))
    "stored order survives exact substring filtering"
    [ first_match.claim; newer_match.claim ]
    (match_texts response);
  match json_field "matches" response with
  | `List matches ->
    Alcotest.(check bool)
      "search emits no heuristic score"
      true
      (List.for_all
         (function
           | `Assoc fields -> Option.is_none (List.assoc_opt "score" fields)
           | _ -> false)
         matches)
  | _ -> Alcotest.fail "expected matches array"
;;

let test_tools_isolate_workspace_base_path_from_ambient_decoy () =
  with_temp_dir
  @@ fun target_base ->
  with_temp_dir
  @@ fun other_base ->
  with_temp_dir
  @@ fun decoy_base ->
  let config = Masc.Workspace.default_config target_base in
  let meta = make_meta "base-path-isolated-tools" in
  let keepers_dir base_path =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path
  in
  let target_keepers = keepers_dir target_base in
  let other_keepers = keepers_dir other_base in
  let decoy_keepers = keepers_dir decoy_base in
  replace_current_facts
    ~keepers_dir:other_keepers
    ~keeper_id:meta.name
    [ fact "workspace B only" ];
  replace_current_facts
    ~keepers_dir:decoy_keepers
    ~keeper_id:meta.name
    [ fact "ambient decoy workspace only" ];
  with_env "MASC_BASE_PATH" decoy_base (fun () ->
    let write_response =
      Runtime.keeper_memory_write_with_outcome
        ~config
        ~meta
        ~args:(make_args ~title:"" ~content:"workspace A only")
      |> fun result -> result.Masc.Keeper_tool_execution.raw_output
      |> Yojson.Safe.from_string
    in
    Alcotest.(check bool)
      "write uses config base path"
      true
      (match json_field "ok" write_response with
       | `Bool value -> value
       | _ -> false);
    let claims_at keepers_dir =
      current_facts ~keepers_dir ~keeper_id:meta.name
      |> List.map (fun fact -> fact.Masc.Keeper_memory_os_types.claim)
    in
    Alcotest.(check (list string))
      "target receives only its write"
      [ "workspace A only" ]
      (claims_at target_keepers);
    Alcotest.(check (list string))
      "other workspace remains isolated"
      [ "workspace B only" ]
      (claims_at other_keepers);
    Alcotest.(check (list string))
      "ambient decoy remains untouched"
      [ "ambient decoy workspace only" ]
      (claims_at decoy_keepers);
    let search =
      Runtime.keeper_memory_search_json
        ~config
        ~meta
        ~ctx_work:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"")
        ~args:
          (`Assoc
             [ "query", `String "workspace"
             ; "source", `String "memory"
             ; "limit", `Int 10
             ])
      |> Yojson.Safe.from_string
    in
    Alcotest.(check (list string))
      "search sees only the target workspace"
      [ "workspace A only" ]
      (match_texts search);
    let status =
      Runtime.keeper_context_status_json
        ~config
        ~meta
        ~ctx_work:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"")
      |> Yojson.Safe.from_string
    in
    Alcotest.(check int)
      "context status counts only target facts"
      1
      (int_field "memory_facts_total" status))
;;

(* The source parser sits behind Safe_ops.json_string, which returns its
   default for both an absent key and a key holding a non-string. Before the
   fix {"source": ["memory"]} reached Memory while {"source": "memry"} was
   refused, so a type error was treated more permissively than a value error.
   These pin the parser itself; the handler now feeds it the member directly. *)
let test_source_parser_accepts_every_supported_value () =
  List.iter
    (fun s ->
      match Runtime.memory_search_source_of_string_opt s with
      | Some _ -> ()
      | None -> Alcotest.failf "supported source %S rejected" s)
    Runtime.valid_memory_search_source_strings
;;

let test_source_parser_rejects_unknown_value () =
  Alcotest.(check bool)
    "misspelled source is not a source"
    true
    (Runtime.memory_search_source_of_string_opt "memry" = None)
;;

let test_source_parser_rejects_json_rendering_of_a_non_string () =
  Alcotest.(check bool)
    "a rendered JSON array is not a source"
    true
    (Runtime.memory_search_source_of_string_opt
       (Yojson.Safe.to_string (`List [ `String "memory" ]))
     = None)
;;

let () =
  Alcotest.run
    "keeper_memory_write"
    [ ( "validation"
      , [ Alcotest.test_case "typed validation failures" `Quick test_validation_taxonomy
        ; Alcotest.test_case
            "runtime validation is proven pre-effect"
            `Quick
            test_invalid_write_is_proven_pre_effect
        ; Alcotest.test_case
            "valid input composes the stored body"
            `Quick
            test_valid_body_composition
        ] )
    ; ( "persistence"
      , [ Alcotest.test_case
            "write comes back through recall"
            `Quick
            test_write_comes_back_through_recall
        ; Alcotest.test_case
            "tools isolate config BasePath from ambient decoy"
            `Quick
            test_tools_isolate_workspace_base_path_from_ambient_decoy
        ; Alcotest.test_case
            "search filters exact substring without ranking"
            `Quick
            test_search_filters_exact_substring_without_ranking
        ; Alcotest.test_case
            "source parser accepts every supported value"
            `Quick
            test_source_parser_accepts_every_supported_value
        ; Alcotest.test_case
            "source parser rejects unknown value"
            `Quick
            test_source_parser_rejects_unknown_value
        ; Alcotest.test_case
            "source parser rejects a non-string rendering"
            `Quick
            test_source_parser_rejects_json_rendering_of_a_non_string
        ] )
    ]
;;
