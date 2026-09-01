(** Explicit Keeper memory writes: every write is a durable Memory OS fact. *)

module Runtime = Masc.Keeper_tool_memory_runtime
module Current = Masc.Keeper_memory_os_current

external unsetenv : string -> unit = "masc_test_unsetenv"

let make_args ~title ~content =
  `Assoc [ "title", `String title; "content", `String content ]
;;

let make_source_args ~title ~content ~source_path =
  `Assoc
    [ "title", `String title
    ; "content", `String content
    ; "source_path", `String source_path
    ]
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

let contains ~needle haystack =
  let needle_length = String.length needle in
  let haystack_length = String.length haystack in
  let rec loop index =
    if index + needle_length > haystack_length
    then false
    else if String.sub haystack index needle_length = needle
    then true
    else loop (index + 1)
  in
  needle_length = 0 || loop 0
;;

let fact claim : Masc.Keeper_memory_os_types.fact =
  let now = Time_compat.now () in
  Masc.Keeper_memory_os_types.observed ~claim
    ~category:Masc.Keeper_memory_os_types.Fact ~now
    ~origin:{ kind = Masc.Keeper_memory_os_types.Legacy; trace_id = "" }
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
  |> assert_invalid ~expected:"content_too_long";
  Runtime.validate_memory_write_args
    (make_source_args ~title:"" ~content:"body" ~source_path:"   ")
  |> assert_invalid ~expected:"source_path_invalid";
  Runtime.validate_memory_write_args
    (`Assoc
       [ "title", `String ""
       ; "content", `String "body"
       ; "source_path", `List []
       ])
  |> assert_invalid ~expected:"source_path_invalid"
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
  (* rfc3339_of_unix renders exactly "YYYY-MM-DDTHH:MM:SSZ" (20 bytes). The
     receipt echoes the persisted snapshot stamp so the authoring model sees
     an authoritative UTC time next to the prose it just wrote. *)
  let recorded_at = string_field "recorded_at" response in
  Alcotest.(check bool)
    "receipt carries the persisted UTC stamp"
    true
    (String.length recorded_at = 20 && String.ends_with ~suffix:"Z" recorded_at);
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

let test_source_bound_write_discards_stale_claim_and_recreates () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "source-bound-write" in
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path
  in
  let sandbox_root = Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let source_path = "config/region.txt" in
  let host_source_path = Filename.concat sandbox_root source_path in
  Fs_compat.mkdir_p (Filename.dirname host_source_path);
  let write_source contents =
    match Fs_compat.save_file_atomic host_source_path contents with
    | Ok () -> ()
    | Error detail -> Alcotest.fail detail
  in
  let write_claim content =
    Runtime.keeper_memory_write_with_outcome
      ~config
      ~meta
      ~args:(make_source_args ~title:"" ~content ~source_path)
    |> fun execution -> execution.Masc.Keeper_tool_execution.raw_output
    |> Yojson.Safe.from_string
  in
  let render () =
    Masc.Keeper_memory_os_recall.render_if_enabled
      ~config
      ~meta
      ~keepers_dir
      ~keeper_id:meta.name
      ~now:(Time_compat.now ())
      ()
    |> Option.value ~default:""
  in
  write_source "region=us-west-1\n";
  let first_write = write_claim "The deployment region is us-west-1." in
  Alcotest.(check string)
    "source-bound store is explicit"
    "source_bound_current_memory"
    (string_field "store" first_write);
  Alcotest.(check int)
    "ordinary current memory remains untouched"
    0
    (List.length (current_facts ~keepers_dir ~keeper_id:meta.name));
  let first_prompt = render () in
  Alcotest.(check bool)
    "unchanged source claim reaches recall"
    true
    (contains ~needle:"deployment region is us-west-1" first_prompt);
  Alcotest.(check bool)
    "source digest is visible"
    true
    (contains ~needle:"source_sha256=sha256:" first_prompt);
  write_source "region=eu-west-1\n";
  let invalidated_prompt = render () in
  Alcotest.(check bool)
    "stale claim is absent after source change"
    false
    (contains ~needle:"deployment region is us-west-1" invalidated_prompt);
  Alcotest.(check bool)
    "typed invalidation persists in recall"
    true
    (contains ~needle:"reason=source_changed" invalidated_prompt);
  let stale_search =
    Runtime.keeper_memory_search_json
      ~config
      ~meta
      ~ctx_work:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"")
      ~args:
        (`Assoc
           [ "query", `String "us-west-1"
           ; "source", `String "memory"
           ; "limit", `Int 10
           ])
    |> Yojson.Safe.from_string
  in
  Alcotest.(check (list string))
    "memory search cannot recover the stale claim"
    []
    (match_texts stale_search);
  let status =
    Runtime.keeper_context_status_json
      ~config
      ~meta
      ~ctx_work:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"")
    |> Yojson.Safe.from_string
  in
  Alcotest.(check int)
    "status exposes the pending invalidation"
    1
    (int_field "source_memory_invalidations_total" status);
  let source_snapshot =
    match
      Masc.Keeper_memory_source_current.read_for_keepers_dir
        ~keepers_dir
        ~keeper_id:meta.name
    with
    | Ok (Some snapshot) -> snapshot
    | Ok None -> Alcotest.fail "source-bound snapshot disappeared"
    | Error detail -> Alcotest.fail detail
  in
  Alcotest.(check int)
    "stale source fact removed"
    0
    (List.length source_snapshot.facts);
  Alcotest.(check int)
    "pending invalidation retained"
    1
    (List.length source_snapshot.invalidations);
  let replacement_write = write_claim "The deployment region is eu-west-1." in
  Alcotest.(check string)
    "replacement uses source-bound store"
    "source_bound_current_memory"
    (string_field "store" replacement_write);
  let replacement_prompt = render () in
  Alcotest.(check bool)
    "replacement claim reaches recall"
    true
    (contains ~needle:"deployment region is eu-west-1" replacement_prompt);
  Alcotest.(check bool)
    "replacement clears pending invalidation"
    false
    (contains ~needle:"reason=source_changed" replacement_prompt);
  let replacement_search =
    Runtime.keeper_memory_search_json
      ~config
      ~meta
      ~ctx_work:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"")
      ~args:
        (`Assoc
           [ "query", `String "eu-west-1"
           ; "source", `String "memory"
           ; "limit", `Int 10
           ])
    |> Yojson.Safe.from_string
  in
  Alcotest.(check (list string))
    "memory search sees the recreated claim"
    [ "The deployment region is eu-west-1." ]
    (match_texts replacement_search)
;;

let test_source_bound_write_refuses_unrecallable_payload () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "source-budget" in
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path
  in
  let sandbox_root = Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let source_path = "source.txt" in
  Fs_compat.mkdir_p sandbox_root;
  (match
     Fs_compat.save_file_atomic
       (Filename.concat sandbox_root source_path)
       "authoritative value\n"
   with
   | Ok () -> ()
   | Error detail -> Alcotest.fail detail);
  with_env "MASC_KEEPER_MEMORY_OS_RECALL_FACTS_MAX_BYTES" "32" (fun () ->
    let response =
      Runtime.keeper_memory_write_with_outcome
        ~config
        ~meta
        ~args:
          (make_source_args
             ~title:""
             ~content:"This claim cannot fit the configured recall payload."
             ~source_path)
      |> fun execution -> execution.Masc.Keeper_tool_execution.raw_output
      |> Yojson.Safe.from_string
    in
    Alcotest.(check string)
      "unrecallable source claim is not reported persisted"
      "persistence_failed"
      (string_field "error_kind" response));
  match
    Masc.Keeper_memory_source_current.read_for_keepers_dir
      ~keepers_dir
      ~keeper_id:meta.name
  with
  | Ok None -> ()
  | Ok (Some _) -> Alcotest.fail "over-budget source claim reached persistence"
  | Error detail -> Alcotest.fail detail
;;

let test_ordinary_write_reserves_source_payload () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "aggregate-budget" in
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path
  in
  let sandbox_root = Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let source_path = "source.txt" in
  Fs_compat.mkdir_p sandbox_root;
  (match
     Fs_compat.save_file_atomic (Filename.concat sandbox_root source_path) "value\n"
   with
   | Ok () -> ()
   | Error detail -> Alcotest.fail detail);
  with_env "MASC_KEEPER_MEMORY_OS_RECALL_FACTS_MAX_BYTES" "512" (fun () ->
    let source_write =
      Runtime.keeper_memory_write_with_outcome
        ~config
        ~meta
        ~args:(make_source_args ~title:"" ~content:"source claim" ~source_path)
    in
    Alcotest.(check bool)
      "source write succeeds inside aggregate budget"
      true
      (source_write.Masc.Keeper_tool_execution.disposition = Tool_result.Completed ());
    let response =
      Runtime.keeper_memory_write_with_outcome
        ~config
        ~meta
        ~args:(make_args ~title:"" ~content:(String.make 400 'x'))
      |> fun execution -> execution.Masc.Keeper_tool_execution.raw_output
      |> Yojson.Safe.from_string
    in
    Alcotest.(check string)
      "ordinary writer observes source reservation"
      "persistence_failed"
      (string_field "error_kind" response));
  Alcotest.(check int)
    "rejected ordinary write leaves its store absent"
    0
    (List.length (current_facts ~keepers_dir ~keeper_id:meta.name))
;;

let test_source_write_reserves_ordinary_payload () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "aggregate-source-budget" in
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path
  in
  let sandbox_root = Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let source_path = "source.txt" in
  Fs_compat.mkdir_p sandbox_root;
  (match
     Fs_compat.save_file_atomic (Filename.concat sandbox_root source_path) "value\n"
   with
   | Ok () -> ()
   | Error detail -> Alcotest.fail detail);
  with_env "MASC_KEEPER_MEMORY_OS_RECALL_FACTS_MAX_BYTES" "512" (fun () ->
    let ordinary = fact (String.make 400 'x') in
    Current.replace
      ~max_fact_bytes:512
      ~keepers_dir
      ~keeper_id:meta.name
      ~expected_revision:None
      ~now:100.0
      ~source:{ Current.kind = Current.Librarian; trace_id = "ordinary-first" }
      ~facts:[ ordinary ]
      ()
    |> function
    | Error detail -> Alcotest.fail detail
    | Ok _ ->
      let response =
        Runtime.keeper_memory_write_with_outcome
          ~config
          ~meta
          ~args:(make_source_args ~title:"" ~content:"source claim" ~source_path)
        |> fun execution -> execution.Masc.Keeper_tool_execution.raw_output
        |> Yojson.Safe.from_string
      in
      Alcotest.(check string)
        "source writer observes ordinary reservation"
        "persistence_failed"
        (string_field "error_kind" response));
  match
    Masc.Keeper_memory_source_current.read_for_keepers_dir
      ~keepers_dir
      ~keeper_id:meta.name
  with
  | Ok None -> ()
  | Ok (Some _) -> Alcotest.fail "rejected source write reached persistence"
  | Error detail -> Alcotest.fail detail
;;

let test_concurrent_writers_serialize_aggregate_budget () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "aggregate-concurrent" in
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path
  in
  let sandbox_root = Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let source_path = "source.txt" in
  Fs_compat.mkdir_p sandbox_root;
  (match
     Fs_compat.save_file_atomic (Filename.concat sandbox_root source_path) "value\n"
   with
   | Ok () -> ()
   | Error detail -> Alcotest.fail detail);
  with_env "MASC_KEEPER_MEMORY_OS_RECALL_FACTS_MAX_BYTES" "512" (fun () ->
    Eio_main.run
    @@ fun env ->
    let clock = Eio.Stdenv.clock env in
    let source_observing, set_source_observing = Eio.Promise.create () in
    let release_source, set_release_source = Eio.Promise.create () in
    let source_result = ref None in
    let ordinary_result = ref None in
    Eio.Fiber.both
      (fun () ->
         source_result :=
           Some
             (Masc.Keeper_memory_source_current.upsert_file_fact
                ~clock
                ~config
                ~meta
                ~keepers_dir
                ~ordinary_payload:(fun () ->
                  Eio.Promise.resolve set_source_observing ();
                  Eio.Promise.await release_source;
                  Ok "")
                ~now:100.0
                ~claim:"source claim"
                ~source_path
                ()))
      (fun () ->
         Eio.Promise.await source_observing;
         Eio.Promise.resolve set_release_source ();
         ordinary_result :=
           Some
             (Current.replace
                ~clock
                ~max_fact_bytes:512
                ~keepers_dir
                ~keeper_id:meta.name
                ~expected_revision:None
                ~now:200.0
                ~source:{ Current.kind = Current.Librarian; trace_id = "concurrent" }
                ~facts:[ fact (String.make 400 'x') ]
                ()))
    ;
    (match !source_result with
     | Some (Ok _) -> ()
     | Some
         (Error
           ( Masc.Keeper_memory_source_current.Source_read_failed detail
           | Masc.Keeper_memory_source_current.Store_write_failed detail )) ->
       Alcotest.fail detail
     | None -> Alcotest.fail "concurrent source writer did not finish");
    (match !ordinary_result with
     | Some (Error detail) ->
       Alcotest.(check bool)
         "later writer observes the committed source payload"
         true
         (String.starts_with
            ~prefix:"combined Memory OS rendered payload exceeds byte budget"
            detail)
     | Some (Ok _) -> Alcotest.fail "concurrent ordinary writer overcommitted budget"
     | None -> Alcotest.fail "concurrent ordinary writer did not finish"))
;;

let test_source_bound_rewrite_renews_first_seen () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "source-rewrite-time" in
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path
  in
  let sandbox_root = Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let source_path = "source.txt" in
  Fs_compat.mkdir_p sandbox_root;
  (match
     Fs_compat.save_file_atomic (Filename.concat sandbox_root source_path) "value\n"
   with
   | Ok () -> ()
   | Error detail -> Alcotest.fail detail);
  let write ~now ~claim =
    match
      Masc.Keeper_memory_source_current.upsert_file_fact
        ~config
        ~meta
        ~keepers_dir
        ~ordinary_payload:(fun () -> Ok "")
        ~now
        ~claim
        ~source_path
        ()
    with
    | Ok snapshot -> List.hd snapshot.facts
    | Error
        ( Masc.Keeper_memory_source_current.Source_read_failed detail
        | Masc.Keeper_memory_source_current.Store_write_failed detail ) ->
      Alcotest.fail detail
  in
  let first = write ~now:100.0 ~claim:"first wording" in
  let rewritten = write ~now:200.0 ~claim:"corrected wording" in
  Alcotest.(check (float 0.0)) "initial claim timestamp" 100.0 first.first_seen;
  Alcotest.(check (float 0.0))
    "corrected claim gets its own timestamp"
    200.0
    rewritten.first_seen
;;

let test_invalidation_rendering_is_monotone () =
  let module Source = Masc.Keeper_memory_source_current in
  let source_path = String.make 512 'p' in
  let fact : Source.fact =
    { claim = "x"
    ; first_seen = 100.0
    ; source =
        { path = source_path
        ; sha256 = "sha256:" ^ String.make 64 'a'
        }
    }
  in
  let fact_bytes = String.length (Source.render_fact fact) in
  List.iter
    (fun reason ->
       let invalidation : Source.invalidation =
         { source_path; invalidated_at = 200.0; reason }
       in
       Alcotest.(check bool)
         "invalidation never consumes more bytes than the removed fact"
         true
         (String.length (Source.render_invalidation invalidation) < fact_bytes))
    [ Source.Source_changed; Source.Source_unavailable ]
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
            "source change discards stale claim until recreation"
            `Quick
            test_source_bound_write_discards_stale_claim_and_recreates
        ; Alcotest.test_case
            "source write refuses an unrecallable payload"
            `Quick
            test_source_bound_write_refuses_unrecallable_payload
        ; Alcotest.test_case
            "ordinary write reserves source payload"
            `Quick
            test_ordinary_write_reserves_source_payload
        ; Alcotest.test_case
            "source write reserves ordinary payload"
            `Quick
            test_source_write_reserves_ordinary_payload
        ; Alcotest.test_case
            "concurrent writers serialize aggregate budget"
            `Quick
            test_concurrent_writers_serialize_aggregate_budget
        ; Alcotest.test_case
            "source rewrite renews the claim timestamp"
            `Quick
            test_source_bound_rewrite_renews_first_seen
        ; Alcotest.test_case
            "invalidation rendering only shrinks payload"
            `Quick
            test_invalidation_rendering_is_monotone
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
