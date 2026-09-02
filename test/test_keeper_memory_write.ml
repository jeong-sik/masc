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

let make_derived_args ~content ~rule_id ~premise_ids =
  `Assoc
    [ "content", `String content
    ; "rule_id", `String rule_id
    ; "premise_ids", `List (List.map (fun premise_id -> `String premise_id) premise_ids)
    ]
;;

let make_retract_args ~memory_id ~reason =
  `Assoc [ "memory_id", `String memory_id; "reason", `String reason ]
;;

let memory_id digit = "sha256:" ^ String.make 64 digit

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

let string_list_field key json =
  match json_field key json with
  | `List values ->
    List.map
      (function
        | `String value -> value
        | _ -> Alcotest.failf "expected string list field: %s" key)
      values
  | _ -> Alcotest.failf "expected list field: %s" key
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
    ~origin:{ kind = Masc.Keeper_memory_os_types.Authored; trace_id = "" }
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

(* A Board reference names where an observation was read. It is an observation
   source, so it cannot ride a derivation or a source-bound claim, and a comment
   needs its post. The ids are checked against the Board grammar only. *)
let test_board_reference_validation () =
  let post_id = "p-0123456789abcdef0123456789abcdef" in
  let comment_id = "c-0123456789abcdef0123456789abcdef" in
  let board_args ?comment_id ?(content = "read on the board") extra =
    `Assoc
      ([ "content", `String content; "board_post_id", `String post_id ]
       @ (match comment_id with
          | None -> []
          | Some comment_id -> [ "board_comment_id", `String comment_id ])
       @ extra)
  in
  (match Runtime.validate_memory_write_args (board_args []) with
   | Runtime.Memory_write_ok { basis; _ } ->
     Alcotest.(check bool)
       "post reference is an observation from the board"
       true
       (basis
        = Masc.Keeper_memory_os_types.Observed
            (Masc.Keeper_memory_os_types.Board { post_id; comment_id = None }))
   | Runtime.Memory_write_invalid { error_kind; _ } ->
     Alcotest.failf "post reference rejected: %s" (error_label error_kind));
  (match Runtime.validate_memory_write_args (board_args ~comment_id []) with
   | Runtime.Memory_write_ok { basis; _ } ->
     Alcotest.(check bool)
       "comment reference carries the comment id"
       true
       (basis
        = Masc.Keeper_memory_os_types.Observed
            (Masc.Keeper_memory_os_types.Board { post_id; comment_id = Some comment_id }))
   | Runtime.Memory_write_invalid { error_kind; _ } ->
     Alcotest.failf "comment reference rejected: %s" (error_label error_kind));
  Runtime.validate_memory_write_args
    (`Assoc [ "content", `String "x"; "board_post_id", `String "p-1 2" ])
  |> assert_invalid ~expected:"board_ref_invalid";
  Runtime.validate_memory_write_args
    (`Assoc [ "content", `String "x"; "board_post_id", `List [] ])
  |> assert_invalid ~expected:"board_ref_invalid";
  Runtime.validate_memory_write_args
    (`Assoc [ "content", `String "x"; "board_comment_id", `String comment_id ])
  |> assert_invalid ~expected:"board_comment_without_post";
  Runtime.validate_memory_write_args
    (board_args
       [ "rule_id", `String "rule"; "premise_ids", `List [ `String (memory_id 'a') ] ])
  |> assert_invalid ~expected:"board_ref_with_derivation_unsupported";
  Runtime.validate_memory_write_args (board_args [ "source_path", `String "notes.md" ])
  |> assert_invalid ~expected:"board_ref_with_source_path_unsupported";
  Runtime.validate_memory_write_args (make_args ~title:"" ~content:"plain")
  |> function
  | Runtime.Memory_write_ok { basis; _ } ->
    Alcotest.(check bool)
      "no board field means the transcript"
      true
      (basis
       = Masc.Keeper_memory_os_types.Observed Masc.Keeper_memory_os_types.Transcript)
  | Runtime.Memory_write_invalid { error_kind; _ } ->
    Alcotest.failf "plain write rejected: %s" (error_label error_kind)
;;

let test_validation_taxonomy () =
  Runtime.validate_memory_write_args (make_args ~title:"" ~content:"")
  |> assert_invalid ~expected:"content_empty";
  Runtime.validate_memory_write_args
    (make_source_args ~title:"" ~content:"body" ~source_path:"   ")
  |> assert_invalid ~expected:"source_path_invalid";
  Runtime.validate_memory_write_args
    (`Assoc
       [ "title", `String ""
       ; "content", `String "body"
       ; "source_path", `List []
       ])
  |> assert_invalid ~expected:"source_path_invalid";
  Runtime.validate_memory_write_args
    (`Assoc [ "content", `String "derived"; "rule_id", `String "rule" ])
  |> assert_invalid ~expected:"derivation_incomplete";
  Runtime.validate_memory_write_args
    (make_derived_args
       ~content:"derived"
       ~rule_id:"rule"
       ~premise_ids:[ memory_id 'a'; memory_id 'a' ])
  |> assert_invalid ~expected:"derivation_invalid";
  List.iter
    (fun premise_id ->
       Runtime.validate_memory_write_args
         (make_derived_args
            ~content:"derived"
            ~rule_id:"rule"
            ~premise_ids:[ premise_id ])
       |> assert_invalid ~expected:"derivation_invalid")
    [ "sha256:" ^ String.make 63 'a'
    ; "sha256:" ^ String.make 65 'a'
    ; "sha256:" ^ String.make 64 'A'
    ; memory_id 'a' ^ "\n"
    ];
  Runtime.validate_memory_write_args
    (`Assoc
       [ "content", `String "derived"
       ; "rule_id", `String "rule"
       ; "premise_ids", `List [ `String (memory_id 'a') ]
       ; "source_path", `String "evidence.txt"
       ])
  |> assert_invalid ~expected:"derived_source_path_unsupported"
;;

let test_retract_validation_taxonomy () =
  let error_label = Runtime.memory_retract_error_kind_to_string in
  let assert_invalid expected = function
    | Runtime.Memory_retract_invalid kind ->
      Alcotest.(check string) "retract error kind" expected (error_label kind)
    | Runtime.Memory_retract_ok _ ->
      Alcotest.failf "expected invalid memory retraction: %s" expected
  in
  Runtime.validate_memory_retract_args
    (make_retract_args ~memory_id:"not-an-id" ~reason:"incorrect")
  |> assert_invalid "memory_id_invalid";
  Runtime.validate_memory_retract_args
    (make_retract_args ~memory_id:(memory_id 'a') ~reason:"   ")
  |> assert_invalid "reason_empty";
  match
    Runtime.validate_memory_retract_args
      (make_retract_args ~memory_id:(memory_id 'a') ~reason:"  corrected  ")
  with
  | Runtime.Memory_retract_ok { memory_id = identity; reason } ->
    Alcotest.(check string) "exact identity" (memory_id 'a') identity;
    Alcotest.(check string) "normalized reason" "corrected" reason
  | Runtime.Memory_retract_invalid kind ->
    Alcotest.failf "valid memory retraction rejected: %s" (error_label kind)
;;

let test_valid_body_composition () =
  Runtime.validate_memory_write_args (make_args ~title:"" ~content:"body")
  |> assert_ok ~body:"body";
  Runtime.validate_memory_write_args
    (make_args ~title:"hook" ~content:"body text")
  |> assert_ok ~body:"**hook** body text";
  let large_title = String.make 256 't' in
  let large_content = String.make 8192 'c' in
  Runtime.validate_memory_write_args
    (make_args ~title:large_title ~content:large_content)
  |> assert_ok ~body:(Printf.sprintf "**%s** %s" large_title large_content);
  (match
     Runtime.validate_memory_write_args
       (make_derived_args
          ~content:"derived"
          ~rule_id:"rule"
          ~premise_ids:[ memory_id 'a'; memory_id 'b' ])
   with
   | Runtime.Memory_write_ok
       { basis = Masc.Keeper_memory_os_types.Derived [ derivation ]; _ } ->
     Alcotest.(check string) "rule identity" "rule" derivation.rule_id;
     Alcotest.(check (list string))
       "exact premise identities"
       [ memory_id 'a'; memory_id 'b' ]
       derivation.premise_ids
   | Runtime.Memory_write_ok _ -> Alcotest.fail "derived input decoded as observed"
   | Runtime.Memory_write_invalid { error_kind; _ } ->
     Alcotest.failf "unexpected validation error: %s" (error_label error_kind))
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
  let memory_id = string_field "memory_id" response in
  Alcotest.(check string)
    "write receipt declares observed basis"
    "observed"
    (string_field "kind" (json_field "basis" response));
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
   | Some (Masc.Keeper_tool_execution.Memory_retract_completed _) ->
     Alcotest.fail "memory write returned a memory-retract receipt"
   | None -> Alcotest.fail "successful memory write has no terminal receipt");
  let facts = current_facts ~keepers_dir ~keeper_id:meta.name in
  Alcotest.(check int) "one durable claim" 1 (List.length facts);
  let fact = List.hd facts in
  Alcotest.(check string)
    "receipt identity resolves the stored fact"
    memory_id
    (Masc.Keeper_memory_os_types.memory_id fact);
  Alcotest.(check string)
    "the claim reaches a later turn"
    "reasoning_content must be replayed unmodified"
    fact.Masc.Keeper_memory_os_types.claim;
  Alcotest.(check bool)
    "producer timestamp recorded"
    true
    (fact.Masc.Keeper_memory_os_types.first_seen > 0.0)
;;

let test_retract_cascades_through_public_tool_and_journals_reason () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "retract-support-chain" in
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path
  in
  let write args =
    Runtime.keeper_memory_write_with_outcome ~config ~meta ~args
    |> fun execution ->
    execution.Masc.Keeper_tool_execution.raw_output |> Yojson.Safe.from_string
  in
  let first = write (make_args ~title:"" ~content:"manifest selects region A") in
  let second = write (make_args ~title:"" ~content:"region A capacity is healthy") in
  let first_id = string_field "memory_id" first in
  let second_id = string_field "memory_id" second in
  let conclusion =
    write
      (make_derived_args
         ~content:"deployment may proceed"
         ~rule_id:"deployment_ready"
         ~premise_ids:[ first_id; second_id ])
  in
  let conclusion_id = string_field "memory_id" conclusion in
  let consequence =
    write
      (make_derived_args
         ~content:"announce the rollout"
         ~rule_id:"announce_when_ready"
         ~premise_ids:[ conclusion_id ])
  in
  let consequence_id = string_field "memory_id" consequence in
  let execution =
    Runtime.keeper_memory_retract_with_outcome
      ~config
      ~meta
      ~args:
        (make_retract_args
           ~memory_id:first_id
           ~reason:"manifest now selects region B")
  in
  let response =
    execution.Masc.Keeper_tool_execution.raw_output |> Yojson.Safe.from_string
  in
  Alcotest.(check bool)
    "retraction succeeds"
    true
    (json_field "ok" response = `Bool true);
  Alcotest.(check (list string))
    "direct target and both unsupported conclusions are removed"
    [ first_id; conclusion_id; consequence_id ]
    (string_list_field "removed_memory_ids" response);
  let invalidations =
    match json_field "support_invalidations" response with
    | `List values -> values
    | _ -> Alcotest.fail "support_invalidations is not a list"
  in
  Alcotest.(check (list string))
    "receipt names cascaded identities"
    [ conclusion_id; consequence_id ]
    (List.map (string_field "memory_id") invalidations);
  Alcotest.(check (list string))
    "first conclusion names the direct missing premise"
    [ first_id ]
    (string_list_field "missing_premise_ids" (List.hd invalidations));
  Alcotest.(check (list string))
    "second conclusion names its now-missing conclusion premise"
    [ conclusion_id ]
    (string_list_field "missing_premise_ids" (List.nth invalidations 1));
  (match execution.Masc.Keeper_tool_execution.terminal_effect_receipt with
   | Some (Masc.Keeper_tool_execution.Memory_retract_completed { revision }) ->
     Alcotest.(check int) "receipt revision" (int_field "revision" response) revision
   | Some (Masc.Keeper_tool_execution.Memory_write_completed _) ->
     Alcotest.fail "memory retract returned a memory-write receipt"
   | Some (Masc.Keeper_tool_execution.Surface_post_completed _) ->
     Alcotest.fail "memory retract returned a surface-post receipt"
   | None -> Alcotest.fail "successful memory retract has no terminal receipt");
  Alcotest.(check (list string))
    "recall authority retains only the independent observation"
    [ second_id ]
    (current_facts ~keepers_dir ~keeper_id:meta.name
     |> List.map Masc.Keeper_memory_os_types.memory_id);
  let journal =
    Current.read_journal_tail ~keepers_dir ~keeper_id:meta.name ~limit:10
  in
  Alcotest.(check int) "four writes and one retract are journaled" 5 (List.length journal);
  (match List.rev journal |> List.hd with
   | Ok
       (Current.Journal_committed
          { source = { kind = Current.Explicit_retract; _ }
          ; dropped = Some [ dropped ]
          ; change
          ; _
          }) ->
     Alcotest.(check string) "journal direct target" first_id dropped.memory_id;
     Alcotest.(check string)
       "journal durable reason"
       "manifest now selects region B"
       dropped.reason;
     Alcotest.(check int) "journal cascaded support evidence" 2 (List.length change.invalidated)
   | Ok _ -> Alcotest.fail "last journal line is not the exact retract commit"
   | Error detail -> Alcotest.fail detail);
  let revision_before_missing = int_field "revision" response in
  let missing =
    Runtime.keeper_memory_retract_with_outcome
      ~config
      ~meta
      ~args:
        (make_retract_args
           ~memory_id:first_id
           ~reason:"duplicate retraction must not commit")
  in
  let missing_json =
    missing.Masc.Keeper_tool_execution.raw_output |> Yojson.Safe.from_string
  in
  Alcotest.(check string)
    "missing fact is typed"
    "fact_not_found"
    (string_field "error_kind" missing_json);
  Alcotest.(check bool)
    "missing fact is proven before domain effect"
    true
    (missing.Masc.Keeper_tool_execution.failure_effect_disposition
     = Tool_result.Proven_pre_effect);
  let current =
    match Current.read_for_keepers_dir ~keepers_dir ~keeper_id:meta.name with
    | Ok (Some snapshot) -> snapshot
    | Ok None -> Alcotest.fail "retract snapshot disappeared"
    | Error detail -> Alcotest.fail detail
  in
  Alcotest.(check int) "missing target does not advance revision" revision_before_missing current.revision;
  Alcotest.(check int)
    "missing target does not append journal"
    5
    (List.length (Current.read_journal_tail ~keepers_dir ~keeper_id:meta.name ~limit:10))
;;

let test_derived_write_uses_exact_premise_receipt () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "derived-write" in
  let write args =
    Runtime.keeper_memory_write_with_outcome ~config ~meta ~args
  in
  let premise = write (make_args ~title:"" ~content:"dependency failed") in
  let premise_json =
    premise.Masc.Keeper_tool_execution.raw_output |> Yojson.Safe.from_string
  in
  let premise_id = string_field "memory_id" premise_json in
  let conclusion =
    write
      (make_derived_args
         ~content:"rollout is blocked"
         ~rule_id:"RULE_ID_MUST_STAY_OUT_OF_WRITE_RECEIPT"
         ~premise_ids:[ premise_id ])
  in
  let response =
    conclusion.Masc.Keeper_tool_execution.raw_output |> Yojson.Safe.from_string
  in
  Alcotest.(check bool) "derived write succeeds" true
    (json_field "ok" response = `Bool true);
  let basis = json_field "basis" response in
  Alcotest.(check string) "receipt declares derived basis" "derived"
    (string_field "kind" basis);
  Alcotest.(check int) "one proof path" 1 (int_field "proof_count" basis);
  Alcotest.(check bool) "raw rule identity omitted from write receipt" false
    (String_util.contains_substring
       conclusion.Masc.Keeper_tool_execution.raw_output
       "RULE_ID_MUST_STAY_OUT_OF_WRITE_RECEIPT");
  let stored =
    current_facts
      ~keepers_dir:
        (Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path)
      ~keeper_id:meta.name
  in
  Alcotest.(check int) "premise and conclusion persist" 2 (List.length stored);
  Alcotest.(check string) "conclusion receipt resolves exact fact"
    (string_field "memory_id" response)
    (Masc.Keeper_memory_os_types.memory_id (List.nth stored 1))
;;

let test_unsupported_derived_write_is_proven_pre_effect () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "unsupported-derived-write" in
  let execution =
    Runtime.keeper_memory_write_with_outcome
      ~config
      ~meta
      ~args:
        (make_derived_args
           ~content:"unsupported conclusion"
           ~rule_id:"requires_missing"
           ~premise_ids:[ memory_id 'c' ])
  in
  let response =
    execution.Masc.Keeper_tool_execution.raw_output |> Yojson.Safe.from_string
  in
  Alcotest.(check string) "typed rejection" "unsupported_derivation"
    (string_field "error_kind" response);
  Alcotest.(check bool) "no snapshot effect is possible" true
    (execution.Masc.Keeper_tool_execution.failure_effect_disposition
     = Tool_result.Proven_pre_effect);
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path
  in
  Alcotest.(check int) "no ordinary fact was persisted" 0
    (List.length (current_facts ~keepers_dir ~keeper_id:meta.name))
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
  let source_search =
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
  (match json_field "matches" source_search with
   | `List [ (`Assoc fields as matched) ] ->
     Alcotest.(check string) "source search names its store"
       "source_bound_current_memory"
       (string_field "store" matched);
     Alcotest.(check bool) "source identity is not mislabeled as memory_id" true
       (Option.is_none (List.assoc_opt "memory_id" fields));
     Alcotest.(check string) "source receipt and search share exact identity"
       (string_field "source_sha256" first_write)
       (string_field "source_sha256" matched)
   | _ -> Alcotest.fail "expected one source-bound memory match");
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

let test_source_bound_write_is_not_gated_by_recall_size () =
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
  let response =
    Runtime.keeper_memory_write_with_outcome
      ~config
      ~meta
      ~args:
        (make_source_args
           ~title:""
           ~content:(String.make 512 'x')
           ~source_path)
    |> fun execution -> execution.Masc.Keeper_tool_execution.raw_output
    |> Yojson.Safe.from_string
  in
  Alcotest.(check bool) "large source truth persists" true
    (Yojson.Safe.Util.member "ok" response |> Yojson.Safe.Util.to_bool);
  match
    Masc.Keeper_memory_source_current.read_for_keepers_dir
      ~keepers_dir
      ~keeper_id:meta.name
  with
  | Ok (Some snapshot) -> Alcotest.(check int) "source fact persisted" 1 (List.length snapshot.facts)
  | Ok None -> Alcotest.fail "source fact was hidden by a size threshold"
  | Error detail -> Alcotest.fail detail
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
        ~now
        ~claim
        ~source_path
        ()
    with
    | Ok snapshot -> List.hd snapshot.facts
    | Error (Masc.Keeper_memory_source_current.Source_read_failed failure) ->
      Alcotest.fail
        (Masc.Keeper_memory_source_current.source_read_failure_to_string failure)
    | Error (Masc.Keeper_memory_source_current.Store_write_failed detail) ->
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
   | Tool_result.Failed Tool_result.Policy_rejection -> ()
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
         matches);
    let first = List.hd matches in
    Alcotest.(check string) "ordinary match names premise-eligible store"
      "current_memory_snapshot"
      (string_field "store" first);
    Alcotest.(check string) "match exposes exact memory identity"
      (Masc.Keeper_memory_os_types.memory_id first_match)
      (string_field "memory_id" first);
    Alcotest.(check string) "match exposes observed basis" "observed"
      (string_field "kind" (json_field "basis" first))
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

(* --- The failure class names which side failed ------------------------ *)

let failure_class_of (execution : Masc.Keeper_tool_execution.t) =
  match execution.Masc.Keeper_tool_execution.disposition with
  | Tool_result.Failed class_ -> Some class_
  | Tool_result.Completed () | Tool_result.Deferred () -> None
;;

let check_failure_class label expected execution =
  Alcotest.(check (option string))
    label
    (Some (Tool_result.tool_failure_class_to_string expected))
    (Option.map Tool_result.tool_failure_class_to_string (failure_class_of execution))
;;

let empty_ctx () = Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:""

(* A store the runtime cannot decode is a dependency that did not answer.
   Before, [read_current_facts] raised and the dispatcher printed
   [Failure("...invalid current Memory OS snapshot...")] back to the model,
   which then retried the search with other arguments (79 such failures on
   2026-09-01, 65 of them one keeper's corrupt file). *)
let test_corrupt_snapshot_is_a_dependency_failure () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "corrupt-store" in
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path
  in
  Fs_compat.mkdir_p keepers_dir;
  let snapshot_path = Filename.concat keepers_dir (meta.name ^ ".memory-current.json") in
  let oc = open_out_bin snapshot_path in
  output_string oc "{ this is not a snapshot";
  close_out oc;
  let execution =
    Runtime.keeper_memory_search_with_outcome
      ~config
      ~meta
      ~ctx_work:(empty_ctx ())
      ~args:(`Assoc [ "query", `String "anything"; "source", `String "memory" ])
  in
  check_failure_class "corrupt store" Tool_result.Dependency_unavailable execution;
  let response =
    execution.Masc.Keeper_tool_execution.raw_output |> Yojson.Safe.from_string
  in
  Alcotest.(check string)
    "the store, not the query, is named"
    "snapshot_read_failed"
    (string_field "error_kind" response);
  let detail = string_field "detail" response in
  let rec mentions_path i =
    i + String.length snapshot_path <= String.length detail
    && (String.equal (String.sub detail i (String.length snapshot_path)) snapshot_path
        || mentions_path (i + 1))
  in
  Alcotest.(check bool) "the detail names the file" true (mentions_path 0)
;;

(* A write that cannot reach its store is the same dependency failure; the
   claim is reported as not saved, and the class tells the model that other
   arguments will not save it either. *)
let test_unwritable_store_is_a_dependency_failure () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "unwritable-store" in
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path
  in
  (* A directory where the snapshot file belongs: every open for writing
     fails regardless of the user the test runs as. *)
  Fs_compat.mkdir_p (Filename.concat keepers_dir (meta.name ^ ".memory-current.json"));
  let execution =
    Runtime.keeper_memory_write_with_outcome
      ~config
      ~meta
      ~args:(make_args ~title:"" ~content:"a claim that cannot be saved")
  in
  check_failure_class "unwritable store" Tool_result.Dependency_unavailable execution;
  let response =
    execution.Masc.Keeper_tool_execution.raw_output |> Yojson.Safe.from_string
  in
  Alcotest.(check string)
    "persistence, not validation"
    "persistence_failed"
    (string_field "error_kind" response)
;;

(* Input the caller can correct is a policy rejection, like a schema
   rejection; a fact that is not there is the state refusing, a workflow
   rejection. *)
let test_input_and_state_failures_keep_their_own_classes () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "classes" in
  check_failure_class
    "empty content is the caller's to fix"
    Tool_result.Policy_rejection
    (Runtime.keeper_memory_write_with_outcome
       ~config
       ~meta
       ~args:(make_args ~title:"" ~content:""));
  check_failure_class
    "a malformed memory id is the caller's to fix"
    Tool_result.Policy_rejection
    (Runtime.keeper_memory_retract_with_outcome
       ~config
       ~meta
       ~args:(make_retract_args ~memory_id:"not-an-id" ~reason:"incorrect"));
  check_failure_class
    "an absent fact is the state refusing"
    Tool_result.Workflow_rejection
    (Runtime.keeper_memory_retract_with_outcome
       ~config
       ~meta
       ~args:(make_retract_args ~memory_id:(memory_id 'a') ~reason:"incorrect"))
;;

(* A source path the caller can fix -- missing, outside the read boundary --
   is refused before any store is touched and says so with Policy_rejection;
   only a filesystem that does not answer is a dependency failure. *)
let test_unreadable_source_path_is_the_callers_to_fix () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "source-path" in
  let write source_path =
    Runtime.keeper_memory_write_with_outcome
      ~config
      ~meta
      ~args:(make_source_args ~title:"" ~content:"a claim" ~source_path)
  in
  let missing = write "does-not-exist.txt" in
  check_failure_class "missing source" Tool_result.Policy_rejection missing;
  let response =
    missing.Masc.Keeper_tool_execution.raw_output |> Yojson.Safe.from_string
  in
  Alcotest.(check string) "named as a source read failure" "source_read_failed"
    (string_field "error_kind" response);
  check_failure_class "outside the read boundary" Tool_result.Policy_rejection
    (write "../../outside.txt")
;;

let () =
  Alcotest.run
    "keeper_memory_write"
    [ ( "validation"
      , [ Alcotest.test_case "typed validation failures" `Quick test_validation_taxonomy
        ; Alcotest.test_case
            "board reference validation"
            `Quick
            test_board_reference_validation
        ; Alcotest.test_case
            "typed retract validation failures"
            `Quick
            test_retract_validation_taxonomy
        ; Alcotest.test_case
            "runtime validation is proven pre-effect"
            `Quick
            test_invalid_write_is_proven_pre_effect
        ; Alcotest.test_case
            "valid input composes the stored body"
            `Quick
            test_valid_body_composition
        ; Alcotest.test_case
            "unsupported derived write is proven pre-effect"
            `Quick
            test_unsupported_derived_write_is_proven_pre_effect
        ] )
    ; ( "persistence"
      , [ Alcotest.test_case
            "write comes back through recall"
            `Quick
            test_write_comes_back_through_recall
        ; Alcotest.test_case
            "derived write uses exact premise receipt"
            `Quick
            test_derived_write_uses_exact_premise_receipt
        ; Alcotest.test_case
            "retract cascades and journals durable reason"
            `Quick
            test_retract_cascades_through_public_tool_and_journals_reason
        ; Alcotest.test_case
            "source change discards stale claim until recreation"
            `Quick
            test_source_bound_write_discards_stale_claim_and_recreates
        ; Alcotest.test_case
            "source write has no recall size gate"
            `Quick
            test_source_bound_write_is_not_gated_by_recall_size
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
    ; ( "failure class"
      , [ Alcotest.test_case
            "corrupt snapshot is a dependency failure"
            `Quick
            test_corrupt_snapshot_is_a_dependency_failure
        ; Alcotest.test_case
            "unwritable store is a dependency failure"
            `Quick
            test_unwritable_store_is_a_dependency_failure
        ; Alcotest.test_case
            "input and state failures keep their own classes"
            `Quick
            test_input_and_state_failures_keep_their_own_classes
        ; Alcotest.test_case
            "unreadable source path is the caller's to fix"
            `Quick
            test_unreadable_source_path_is_the_callers_to_fix
        ] )
    ]
;;
