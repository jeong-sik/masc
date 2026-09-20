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
  let board_ref ?comment_id post_id =
    match Masc.Keeper_memory_os_types.board_ref_of_ids ~post_id ~comment_id with
    | Ok board -> board
    | Error error ->
      Alcotest.failf
        "board ref fixture: %s"
        (Masc.Keeper_memory_os_types.wire_error_to_string error)
  in
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
            (Masc.Keeper_memory_os_types.Board (board_ref post_id)))
   | Runtime.Memory_write_invalid { error_kind; _ } ->
     Alcotest.failf "post reference rejected: %s" (error_label error_kind));
  (match Runtime.validate_memory_write_args (board_args ~comment_id []) with
   | Runtime.Memory_write_ok { basis; _ } ->
     Alcotest.(check bool)
       "comment reference carries the comment id"
       true
       (basis
        = Masc.Keeper_memory_os_types.Observed
            (Masc.Keeper_memory_os_types.Board (board_ref ~comment_id post_id)))
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

let mentions ~what text =
  let width = String.length what
  and length = String.length text in
  let rec scan index =
    index + width <= length
    && (String.equal (String.sub text index width) what || scan (index + 1))
  in
  scan 0
;;

(* A refusal that named only its kind left the model to pick a field, and the
   pick was to drop the derivation: of the 54 derivation refusals in
   2026-09-01..15, one was later written again with rule_id and premise_ids
   intact. The refusal has to name the field and what it takes. *)
let test_a_refused_derivation_names_the_field_and_what_it_takes () =
  let refusal args =
    match Runtime.validate_memory_write_args args with
    | Runtime.Memory_write_ok _ -> Alcotest.failf "expected a refused derivation"
    | Runtime.Memory_write_invalid { error_kind; _ } ->
      let fields = Runtime.memory_write_rejection_fields error_kind in
      let string_field name =
        match List.assoc_opt name fields with
        | Some (`String value) -> value
        | Some _ | None ->
          Alcotest.failf "%s refusal carries no %s" (error_label error_kind) name
      in
      string_field "rejected_field", string_field "expected"
  in
  let derived premise_ids =
    make_derived_args ~content:"derived" ~rule_id:"rule" ~premise_ids
  in
  let check_field what expected args =
    Alcotest.(check string) what expected (fst (refusal args))
  in
  check_field
    "a rule without premises names premise_ids"
    "premise_ids"
    (`Assoc [ "content", `String "derived"; "rule_id", `String "rule" ]);
  check_field
    "premises without a rule name rule_id"
    "rule_id"
    (`Assoc
       [ "content", `String "derived"
       ; "premise_ids", `List [ `String (memory_id 'a') ]
       ]);
  check_field
    "a blank rule names rule_id"
    "rule_id"
    (make_derived_args
       ~content:"derived"
       ~rule_id:"  "
       ~premise_ids:[ memory_id 'a' ]);
  check_field "an empty premise list names premise_ids" "premise_ids" (derived []);
  (* The index is the element that broke, not the first one. *)
  check_field
    "a repeated premise names the repeat"
    "premise_ids[1]"
    (derived [ memory_id 'a'; memory_id 'a' ]);
  check_field
    "a premise that is not a memory identity names its own position"
    "premise_ids[1]"
    (derived [ memory_id 'a'; "mem_01K4Z5BGD2FC555J0HVRNQ3959" ]);
  (* What the model actually needs: the value it sent back, the shape it
     missed, and a tool that hands out a real one. The shape is quoted from the
     predicate, so changing the grammar without the sentence fails here. *)
  let _, expected = refusal (derived [ "premise-1" ]) in
  Alcotest.(check bool)
    "the refusal quotes the value it rejected"
    true
    (mentions ~what:"premise-1" expected);
  Alcotest.(check bool)
    "the refusal states the shape the predicate accepts"
    true
    (mentions ~what:Masc.Keeper_memory_os_types.memory_id_shape expected);
  Alcotest.(check bool)
    "the refusal names a tool that returns one"
    true
    (mentions ~what:"keeper_memory_search" expected)
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
  (match Current.read_for_keepers_dir ~keepers_dir ~keeper_id:meta.name with
   | Ok (Some snapshot) ->
     Alcotest.(check int)
       "receipt revision names the committed snapshot"
       snapshot.Current.revision
       response_revision
   | Ok None -> Alcotest.fail "successful memory write left no current snapshot"
   | Error detail -> Alcotest.fail detail);
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
  (match Current.read_for_keepers_dir ~keepers_dir ~keeper_id:meta.name with
   | Ok (Some snapshot) ->
     Alcotest.(check int)
       "receipt revision names the committed snapshot"
       snapshot.Current.revision
       (int_field "revision" response)
   | Ok None -> Alcotest.fail "successful memory retract left no current snapshot"
   | Error detail -> Alcotest.fail detail);
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
  Alcotest.(check string)
    "the refusal tells the model nothing committed"
    (Tool_result.failure_effect_disposition_to_string Tool_result.Proven_pre_effect)
    (string_field "effect_disposition" missing_json);
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
  Alcotest.(check string) "the payload names the field to change" "premise_ids"
    (string_field "rejected_field" response);
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
     = Tool_result.Proven_pre_effect)
;;

let with_history_search ?(additional_traces = []) ~checkpoint_texts ~current_texts ~previous_texts check =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "history-search" in
  let previous_trace = "trace-history-search-previous" in
  let meta =
    { meta with runtime =
        { meta.runtime with trace_history = previous_trace :: List.map fst additional_traces } }
  in
  let user text =
    Agent_core.Types.make_message ~role:Agent_core.Types.User [ Agent_core.Types.Text text ]
  in
  let persist trace texts =
    let session =
      Masc.Keeper_context_runtime.create_session
        ~session_id:trace
        ~base_dir:(Masc.Keeper_types_support.session_base_dir_ config)
    in
    List.iter
      (fun text ->
         Masc.Keeper_context_runtime.persist_message session (user text);
         Masc.Keeper_context_runtime.persist_message session
           (Agent_core.Types.make_message ~role:Agent_core.Types.Assistant
              [ Agent_core.Types.Text "Recorded." ]))
      texts;
    if texts <> [] then
      Alcotest.(check int) "all fixture messages remain in History"
        (2 * List.length texts)
        (In_channel.with_open_bin
           (Masc.Keeper_types_support.keeper_history_path config trace)
           (fun input -> List.length (In_channel.input_lines input)))
  in
  persist (Keeper_id.Trace_id.to_string meta.runtime.trace_id) current_texts;
  persist previous_trace previous_texts;
  List.iter (fun (trace, texts) -> persist trace texts) additional_traces;
  let ctx_work =
    List.fold_left
      (fun context text -> Masc.Keeper_context_runtime.append context (user text))
      (Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"")
      checkpoint_texts
  in
  let search ?(limit = 10) query =
    let result =
      Runtime.keeper_memory_search_json
        ~config ~meta ~ctx_work
        ~args:(`Assoc [ "source", `String "history"; "query", `String query; "limit", `Int limit ])
      |> Yojson.Safe.from_string
    in
    Alcotest.(check bool) "a clean search has no read-error warning"
      true (Yojson.Safe.Util.member "history_read_errors" result = `Null);
    string_list_field "matches" result
  in
  check search
;;

let history_search_prefix =
  "The warehouse migration checklist records the database, region, approval, and rollback prerequisites before the final endpoint setting: "
;;

let test_history_search_preserves_distinct_message_endings () =
  let checkpoint_text = history_search_prefix ^ "checkpoint-east" in
  let current_text = history_search_prefix ^ "current-west" in
  let previous_text = history_search_prefix ^ "previous-north" in
  with_history_search ~checkpoint_texts:[ checkpoint_text ]
    ~current_texts:[ current_text ] ~previous_texts:[ previous_text ]
  @@ fun search ->
  Alcotest.(check (list string))
    "different messages from all three stores survive a shared prefix"
    (List.sort String.compare [ checkpoint_text; current_text; previous_text ])
    (List.sort String.compare (search "warehouse"));
  Alcotest.(check (list string))
    "current history remains searchable by its distinct ending"
    [ current_text ] (search "current-west");
  Alcotest.(check (list string))
    "previous trace remains searchable by its distinct ending"
    [ previous_text ] (search "previous-north")
;;

let test_history_search_deduplicates_identical_messages () =
  let text = history_search_prefix ^ "shared-endpoint" in
  with_history_search ~checkpoint_texts:[ text ] ~current_texts:[ text ]
    ~previous_texts:[ text ]
  @@ fun search ->
  Alcotest.(check (list string))
    "the same complete message appears once across stores"
    [ text ] (search "shared-endpoint")
;;

let history_search_noise count =
  List.init count (fun index -> Printf.sprintf "Routine deployment note %d" index)
;;

let check_retained_history_match ~checkpoint_texts ~current_texts ~previous_texts () =
  with_history_search ~checkpoint_texts ~current_texts ~previous_texts
  @@ fun search ->
  Alcotest.(check (list string)) "the retained matching message is searchable"
    [ "Migration prerequisite: amber database" ]
    (search ~limit:1 "amber");
  Alcotest.(check (list string)) "an absent query has no matches"
    [] (search "absent-query")
;;

let test_history_complete_query_outranks_retained_fragments () =
  let exact = "alpha tuesday exact decision" in
  let fragments =
    List.init 30 (fun index ->
      Printf.sprintf "alpha deployment note %d for tuesday" index)
  in
  (* [exact] is written first, so it sits behind every fragment in the
     newest-first retained scan. The complete-query tier must still reach it
     before [limit] is allowed to admit a fragment. *)
  with_history_search ~checkpoint_texts:[] ~previous_texts:[]
    ~current_texts:(exact :: fragments)
  @@ fun search ->
  Alcotest.(check (list string))
    "a retained complete-query match outranks newer fragment matches"
    [ exact ]
    (search ~limit:1 "alpha tuesday")
;;

let test_history_search_limits_distinct_matches () =
  with_history_search ~checkpoint_texts:[] ~previous_texts:[]
    ~current_texts:
      ([ "amber database"; "amber cluster" ] @ List.init 12 (fun _ -> "amber database"))
  @@ fun search ->
  Alcotest.(check (list string)) "duplicate messages do not fill the result limit"
    [ "amber cluster"; "amber database" ]
    (List.sort String.compare (search ~limit:2 "amber"))
;;

let test_history_search_order () =
  with_history_search
    ~checkpoint_texts:[ "amber checkpoint older"; "amber checkpoint newer" ]
    ~current_texts:[ "amber current older"; "amber current newer"; "amber checkpoint newer" ]
    ~previous_texts:[ "amber previous older"; "amber previous newer"; "amber current newer" ]
    ~additional_traces:
      [ "trace-a-recorded-second",
        [ "amber second trace older"; "amber second trace newer"; "amber previous newer" ] ]
  @@ fun search ->
  Alcotest.(check (list string)) "each source is newest-first, with exact cross-source duplicates removed"
    [ "amber checkpoint newer"; "amber checkpoint older"
    ; "amber current newer"; "amber current older"
    ; "amber previous newer"; "amber previous older"
    ; "amber second trace newer"; "amber second trace older"
    ]
    (search ~limit:8 "amber");
  Alcotest.(check (list string)) "the caller limit applies to the selected result order"
    [ "amber checkpoint newer"; "amber checkpoint older"; "amber current newer" ]
    (search ~limit:3 "amber")
;;

let test_history_search_reports_read_errors ~malformed () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "history-read-errors" in
  let previous_trace = "trace-history-read-errors-previous" in
  let meta = { meta with runtime = { meta.runtime with trace_history = [ previous_trace ] } } in
  let current_trace = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  List.iter
    (fun trace ->
       let session = Masc.Keeper_context_runtime.create_session
           ~session_id:trace ~base_dir:(Masc.Keeper_types_support.session_base_dir_ config) in
       Masc.Keeper_context_runtime.persist_message session
         (Agent_core.Types.make_message ~role:Agent_core.Types.User
            [ Agent_core.Types.Text "amber database" ]))
    [ current_trace; previous_trace ];
  let path = Masc.Keeper_types_support.keeper_history_path config current_trace in
  if malformed then
    Out_channel.with_open_gen [ Open_wronly; Open_append ] 0o600 path
      (fun output -> output_string output "{invalid JSON}\n")
  else (Sys.remove path; Unix.mkdir path 0o700);
  let ctx_work = Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"" in
  List.iter
    (fun source ->
       List.iter
         (fun query ->
            let result = Runtime.keeper_memory_search_json ~config ~meta ~ctx_work
                ~args:(`Assoc [ "source", `String source; "query", `String query ])
                |> Yojson.Safe.from_string in
            let open Yojson.Safe.Util in
            Alcotest.(check int) "readable matches survive an incomplete search"
              (if query = "amber" then 1 else 0)
              (member "match_count" result |> to_int);
            Alcotest.(check bool) "an incomplete empty search is not no_match"
              true (member "no_match" result = `Null);
            let errors = member "history_read_errors" result in
            Alcotest.(check int) "visited undecodable rows are reported"
              (if malformed then 1 else 0)
              (member "unreadable_rows" errors |> to_int);
            let unavailable = member "unavailable_traces" errors |> to_list in
            Alcotest.(check int) "unreadable files are reported by trace"
              (if malformed then 0 else 1) (List.length unavailable);
            if not malformed then
              match unavailable with
              | [ error ] ->
                Alcotest.(check string) "the failed trace is named" current_trace
                  (member "trace_id" error |> to_string);
                Alcotest.(check string) "the failure has a bounded error class" "io_error"
                  (member "error_kind" error |> to_string)
              | _ -> Alcotest.fail "missing failed trace")
         [ "absent-query"; "amber" ])
    [ "history"; "all" ]
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

(* A crash mid-append leaves a line with no newline. The next absorb commits
   anyway: the append cuts the torn line back to the last complete row before
   it writes. A librarian that could not commit would spend a provider call
   every cadence and never get past the torn line on its own. *)
let test_a_torn_tail_does_not_stop_the_next_absorb () =
  let keeper_id = "torn-tail-keeper" in
  let absorbed digit =
    let f = fact (Printf.sprintf "an absorbed claim %c" digit) in
    { Masc.Keeper_memory_absorbed.recorded_at = Time_compat.now ()
    ; trace_id = "torn-tail"
    ; memory_id = Masc.Keeper_memory_os_types.memory_id f
    ; into = memory_id 'c'
    ; fact = f
    }
  in
  let append ~keepers_dir record =
    Masc.Keeper_memory_absorbed.append_all ~keepers_dir ~keeper_id [ record ]
  in
  let path_in keepers_dir =
    Masc.Keeper_memory_absorbed.path_for_keepers_dir ~keepers_dir ~keeper_id
  in
  (* One row as the store itself writes it, so the fixture below is not a
     hand-built guess at the format. *)
  let complete_row =
    with_temp_dir (fun donor ->
      match append ~keepers_dir:donor (absorbed 'a') with
      | Error error ->
        Alcotest.fail (Masc.Keeper_memory_absorbed.append_error_to_string error)
      | Ok () -> In_channel.with_open_text (path_in donor) In_channel.input_all)
  in
  with_temp_dir (fun keepers_dir ->
    let path = path_in keepers_dir in
    (* the complete row, then the head of one a crash never finished *)
    Out_channel.with_open_text path (fun oc ->
      Out_channel.output_string oc (complete_row ^ "{\"recorded_at\":\"2026-09-18"));
    (match append ~keepers_dir (absorbed 'b') with
     | Ok () -> ()
     | Error error ->
       Alcotest.failf
         "a torn tail must not stop the next absorb: %s"
         (Masc.Keeper_memory_absorbed.append_error_to_string error));
    let lines =
      In_channel.with_open_text path In_channel.input_all
      |> String.split_on_char '\n'
      |> List.filter (fun line -> line <> "")
    in
    Alcotest.(check int)
      "the complete row and the new one, the torn head gone"
      2
      (List.length lines);
    List.iter
      (fun line ->
         match Yojson.Safe.from_string line with
         | _ -> ()
         | exception Yojson.Json_error detail ->
           Alcotest.failf "a line left behind does not decode: %s (%s)" line detail)
      lines)
;;

(* RFC-0456 §4.2: a fact a librarian pass absorbed is found through
   source=absorbed and source=all, named with the claim that now says it. Rows a
   pass wrote before a replace that failed are recognised: a row for a fact
   that is still current is not returned, and a row repeating another's
   memory_id and into is returned once, at its last write. A line that does not
   decode is left out and named. *)
let test_absorbed_facts_are_searchable () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "absorbed-search" in
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path
  in
  let id = Masc.Keeper_memory_os_types.memory_id in
  let alpha = fact "alpha deploys on tuesday" in
  let beta = fact "beta deploys on tuesday" in
  let gamma = fact "gamma deploys on friday" in
  replace_current_facts ~keepers_dir ~keeper_id:meta.name [ alpha; beta; gamma ];
  let merged = fact "alpha and beta deploy on tuesday" in
  (match
     Current.apply_disposition
       ~keepers_dir
       ~keeper_id:meta.name
       ~now:(Time_compat.now ())
       ~source:{ Current.kind = Current.Librarian; trace_id = "pass" }
       ~absorbed:
         [ { Masc.Keeper_memory_os_types.absorbed = id alpha; into = id merged }
         ; { Masc.Keeper_memory_os_types.absorbed = id beta; into = id merged }
         ]
       ~new_claims:[ merged ]
       ()
   with
   | Ok _ -> ()
   | Error detail -> Alcotest.fail detail);
  let uncommitted (absorbed : Masc.Keeper_memory_os_types.fact) =
    { Masc.Keeper_memory_absorbed.recorded_at = Time_compat.now ()
    ; trace_id = "failed-pass"
    ; memory_id = id absorbed
    ; into = id merged
    ; fact = absorbed
    }
  in
  (match
     Masc.Keeper_memory_absorbed.append_all
       ~keepers_dir
       ~keeper_id:meta.name
       [ uncommitted gamma; uncommitted alpha ]
   with
   | Ok () -> ()
   | Error error -> Alcotest.fail (Masc.Keeper_memory_absorbed.append_error_to_string error));
  let search source =
    Runtime.keeper_memory_search_json
      ~config
      ~meta
      ~ctx_work:(empty_ctx ())
      ~args:
        (`Assoc [ "query", `String "deploy"; "source", `String source; "limit", `Int 10 ])
    |> Yojson.Safe.from_string
  in
  let matches response =
    match json_field "matches" response with
    | `List items -> items
    | _ -> Alcotest.fail "matches is a list"
  in
  let absorbed = matches (search "absorbed") in
  Alcotest.(check (list string))
    "each absorbed statement once, at its last write, and none for a current fact"
    [ "beta deploys on tuesday"; "alpha deploys on tuesday" ]
    (List.map (string_field "text") absorbed);
  List.iter
    (fun matched ->
       Alcotest.(check string) "the store is named" "absorbed_memory"
         (string_field "store" matched);
       Alcotest.(check string) "into names the merged claim" (id merged)
         (string_field "into" matched);
       Alcotest.(check bool) "and says it is current" true
         (json_field "into_current" matched = `Bool true))
    absorbed;
  Alcotest.(check (list string))
    "all returns the current facts, then the absorbed ones"
    [ "current_memory_snapshot"
    ; "current_memory_snapshot"
    ; "absorbed_memory"
    ; "absorbed_memory"
    ]
    (List.filter_map
       (function
         | `Assoc fields -> Option.map Yojson.Safe.Util.to_string (List.assoc_opt "store" fields)
         | _ -> None)
       (matches (search "all")));
  Alcotest.(check (list string))
    "memory still returns only current facts"
    [ "gamma deploys on friday"; "alpha and beta deploy on tuesday" ]
    (List.map (string_field "text") (matches (search "memory")));
  let channel =
    open_out_gen
      [ Open_wronly; Open_append ]
      0o600
      (Masc.Keeper_memory_absorbed.path_for_keepers_dir ~keepers_dir ~keeper_id:meta.name)
  in
  output_string channel "{\"recorded_at\": 1";
  close_out channel;
  let torn = search "absorbed" in
  Alcotest.(check int) "the readable rows are still returned" 2
    (List.length (matches torn));
  Alcotest.(check bool) "and the line that does not decode is counted" true
    (json_field "absorbed_unreadable_lines" torn
     = `Assoc [ "count", `Int 1; "first", `Int 5; "last", `Int 5 ])
;;

(* A keeper asks in several words, and a claim rarely holds them as one run of
   text. A claim answers when it holds the whole query or every word of it, in
   any order. The whole-query answers come first, so a search the substring
   rule answered is still answered the same way at its head. The absorbed
   store follows the same rule, so there too the kind of match comes before
   the order the rows were written in. *)
let test_a_query_of_several_words_is_answered () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "several-words" in
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path
  in
  let id = Masc.Keeper_memory_os_types.memory_id in
  let apart = fact "the alpha service deploys every tuesday" in
  let together = fact "alpha tuesday checklist lives in the wiki" in
  let other = fact "beta ships on tuesday" in
  let retired = fact "tuesday was chosen for alpha after the outage" in
  let retired_later = fact "the alpha tuesday window moved once" in
  (* Absorbed rows are written in the order of the snapshot they leave, so
     [retired] is written before [retired_later]. *)
  replace_current_facts
    ~keepers_dir
    ~keeper_id:meta.name
    [ apart; together; other; retired; retired_later ];
  let merged = fact "alpha deploys on a fixed weekday" in
  (match
     Current.apply_disposition
       ~keepers_dir
       ~keeper_id:meta.name
       ~now:(Time_compat.now ())
       ~source:{ Current.kind = Current.Librarian; trace_id = "pass" }
       ~absorbed:
         [ { Masc.Keeper_memory_os_types.absorbed = id retired; into = id merged }
         ; { Masc.Keeper_memory_os_types.absorbed = id retired_later; into = id merged }
         ]
       ~new_claims:[ merged ]
       ()
   with
   | Ok _ -> ()
   | Error detail -> Alcotest.fail detail);
  let search ?(limit = 10) ~source query =
    Runtime.keeper_memory_search_json
      ~config
      ~meta
      ~ctx_work:(empty_ctx ())
      ~args:
        (`Assoc [ "query", `String query; "source", `String source; "limit", `Int limit ])
    |> Yojson.Safe.from_string
  in
  let texts response =
    match json_field "matches" response with
    | `List items -> List.map (string_field "text") items
    | _ -> Alcotest.fail "matches is a list"
  in
  Alcotest.(check (list string))
    "the claim holding the whole query, then the one holding its words apart"
    [ "alpha tuesday checklist lives in the wiki"; "the alpha service deploys every tuesday" ]
    (texts (search ~source:"memory" "alpha tuesday"));
  Alcotest.(check (list string))
    "what the substring rule alone returned is the head of the result"
    [ "alpha tuesday checklist lives in the wiki" ]
    (texts (search ~limit:1 ~source:"memory" "alpha tuesday"));
  Alcotest.(check (list string))
    "word order does not matter, and snapshot order is kept"
    [ "the alpha service deploys every tuesday"; "alpha tuesday checklist lives in the wiki" ]
    (texts (search ~source:"memory" "tuesday alpha"));
  Alcotest.(check (list string))
    "the absorbed store answers by the same rule: the row holding the whole \
     query comes before the row written earlier that holds only its words"
    [ "the alpha tuesday window moved once"; "tuesday was chosen for alpha after the outage" ]
    (texts (search ~source:"absorbed" "alpha tuesday"));
  Alcotest.(check (list string))
    "and it is the row holding only the words that the limit cuts"
    [ "the alpha tuesday window moved once" ]
    (texts (search ~limit:1 ~source:"absorbed" "alpha tuesday"));
  let unanswered = search ~source:"memory" "alpha gamma" in
  Alcotest.(check (list string))
    "a word no claim holds leaves the query unanswered"
    []
    (texts unanswered);
  Alcotest.(check bool) "and the answer says so" true
    (json_field "no_match" unanswered = `Bool true)
;;

(* [source=all] applies the match tier before the store order. A weaker current
   fact must not consume [limit] before an exact absorbed or history result.
   Once the tier is equal, the documented current/source-bound/absorbed/history
   order remains deterministic. *)
let test_all_ranks_complete_queries_before_fragments_across_stores () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "all-match-tiers" in
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path
  in
  let ordinary_fragment = fact "ordinary alpha deploys each tuesday" in
  let absorbed_exact = fact "absorbed alpha tuesday exact" in
  replace_current_facts
    ~keepers_dir
    ~keeper_id:meta.name
    [ ordinary_fragment; absorbed_exact ];
  let merged = fact "merged weekday decision" in
  (match
     Current.apply_disposition
       ~keepers_dir
       ~keeper_id:meta.name
       ~now:(Time_compat.now ())
       ~source:{ Current.kind = Current.Librarian; trace_id = "all-tier-pass" }
       ~absorbed:
         [ { Masc.Keeper_memory_os_types.absorbed =
               Masc.Keeper_memory_os_types.memory_id absorbed_exact
           ; into = Masc.Keeper_memory_os_types.memory_id merged
           }
         ]
       ~new_claims:[ merged ]
       ()
   with
   | Ok _ -> ()
   | Error detail -> Alcotest.fail detail);
  let sandbox_root = Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let source_path = "facts/source.txt" in
  Fs_compat.mkdir_p (Filename.dirname (Filename.concat sandbox_root source_path));
  (match
     Fs_compat.save_file_atomic
       (Filename.concat sandbox_root source_path)
       "source truth\n"
   with
   | Ok () -> ()
   | Error detail -> Alcotest.fail detail);
  (match
     Masc.Keeper_memory_source_current.upsert_file_fact
       ~config
       ~meta
       ~keepers_dir
       ~now:(Time_compat.now ())
       ~claim:"source alpha deploys each tuesday"
       ~source_path
       ()
   with
   | Ok _ -> ()
   | Error error ->
     let detail =
       match error with
       | Masc.Keeper_memory_source_current.Source_read_failed failure ->
         Masc.Keeper_memory_source_current.source_read_failure_to_string failure
       | Masc.Keeper_memory_source_current.Store_write_failed detail -> detail
     in
     Alcotest.fail detail);
  let ctx_work =
    Masc.Keeper_context_runtime.append
      (empty_ctx ())
      (Agent_core.Types.user_msg "history alpha tuesday exact")
  in
  let search limit =
    Runtime.keeper_memory_search_json
      ~config
      ~meta
      ~ctx_work
      ~args:
        (`Assoc
           [ "query", `String "alpha tuesday"
           ; "source", `String "all"
           ; "limit", `Int limit
           ])
    |> Yojson.Safe.from_string
    |> match_texts
  in
  Alcotest.(check (list string))
    "limit one keeps the first complete-query result"
    [ "absorbed alpha tuesday exact" ]
    (search 1);
  Alcotest.(check (list string))
    "limit two keeps complete-query results from later stores"
    [ "absorbed alpha tuesday exact"; "history alpha tuesday exact" ]
    (search 2);
  Alcotest.(check (list string))
    "fragment matches follow every complete-query result in store order"
    [ "absorbed alpha tuesday exact"
    ; "history alpha tuesday exact"
    ; "ordinary alpha deploys each tuesday"
    ; "source alpha deploys each tuesday"
    ]
    (search 4)
;;

let test_fragment_contract_is_whitespace_split_substring_matching () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "fragment-contract" in
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path
  in
  replace_current_facts
    ~keepers_dir
    ~keeper_id:meta.name
    [ fact "concatenate task-10 safely"; fact "alpha deploys tuesday" ];
  let search query =
    Runtime.keeper_memory_search_json
      ~config
      ~meta
      ~ctx_work:(empty_ctx ())
      ~args:(`Assoc [ "query", `String query; "source", `String "memory" ])
    |> Yojson.Safe.from_string
    |> match_texts
  in
  Alcotest.(check (list string))
    "ASCII fragments are substrings rather than lexical words"
    [ "concatenate task-10 safely" ]
    (search "cat task-1");
  Alcotest.(check (list string))
    "punctuation stays in a whitespace-delimited fragment"
    []
    (search "alpha, tuesday");
  let history_empty =
    Runtime.keeper_memory_search_json
      ~config
      ~meta
      ~ctx_work:
        (Masc.Keeper_context_runtime.append
           (empty_ctx ())
           (Agent_core.Types.user_msg "history row"))
      ~args:(`Assoc [ "query", `String ""; "source", `String "history" ])
    |> Yojson.Safe.from_string
    |> match_texts
  in
  Alcotest.(check (list string))
    "history requires a non-empty query"
    []
    history_empty
;;

(* The absorbed store is one of three that source=all reads. When it cannot be
   read at all, source=absorbed fails as a store that did not answer, and
   source=all still answers from the current facts and names the store it went
   without. *)
let test_an_unreadable_absorbed_store_leaves_all_its_current_facts () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "absorbed-unreadable" in
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path
  in
  replace_current_facts ~keepers_dir ~keeper_id:meta.name [ fact "gamma deploys on friday" ];
  Unix.mkdir
    (Masc.Keeper_memory_absorbed.path_for_keepers_dir ~keepers_dir ~keeper_id:meta.name)
    0o700;
  let search source =
    Runtime.keeper_memory_search_with_outcome
      ~config
      ~meta
      ~ctx_work:(empty_ctx ())
      ~args:(`Assoc [ "query", `String "deploy"; "source", `String source ])
  in
  let absorbed = search "absorbed" in
  check_failure_class "absorbed alone" Tool_result.Dependency_unavailable absorbed;
  Alcotest.(check string) "the absorbed store is named"
    "absorbed_read_failed"
    (string_field "error_kind"
       (Yojson.Safe.from_string absorbed.Masc.Keeper_tool_execution.raw_output));
  let all =
    (search "all").Masc.Keeper_tool_execution.raw_output |> Yojson.Safe.from_string
  in
  (match json_field "matches" all with
   | `List [ matched ] ->
     Alcotest.(check string) "the current fact is still answered"
       "gamma deploys on friday" (string_field "text" matched)
   | _ -> Alcotest.fail "expected the one current fact");
  match json_field "unavailable_stores" all with
  | `List [ store ] ->
    Alcotest.(check string) "and the missing store is named" "absorbed_memory"
      (string_field "store" store)
  | _ -> Alcotest.fail "expected the absorbed store to be named unavailable"
;;

(* A write that cannot reach its store is the same dependency failure. The
   class tells the model that other arguments will not save the claim. A store
   error does not say whether the new snapshot was moved into place before it,
   so the commit is reported as unknown rather than as not saved. *)
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
    (string_field "error_kind" response);
  Alcotest.(check bool)
    "the commit is unknown"
    true
    (execution.Masc.Keeper_tool_execution.failure_effect_disposition
     = Tool_result.Effect_outcome_unknown);
  Alcotest.(check string)
    "the payload names the same disposition"
    (Tool_result.failure_effect_disposition_to_string Tool_result.Effect_outcome_unknown)
    (string_field "effect_disposition" response)
;;

(* A store that commits a revision without the claim in it is past the
   effect: a revision was written. No store here produces it, so the kind's
   own disposition is what keeps it from being reported as unknown. *)
let test_a_commit_that_omits_the_claim_is_after_the_effect () =
  Alcotest.(check bool)
    "commit_receipt_inconsistent is after the effect"
    true
    (Runtime.memory_write_error_effect_disposition Runtime.Commit_receipt_inconsistent
     = Tool_result.Proven_post_effect)
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

module Events = Masc.Keeper_memory_os_events

let events_for ~keepers_dir ~keeper_id =
  Events.read ~keepers_dir ~keeper_id
  |> List.map (fun (index, row) ->
    match row with
    | Ok event -> event
    | Error error ->
      Alcotest.failf
        "events line %d unreadable: %s"
        index
        (Events.read_error_to_string error))
;;

let string_list_field key json =
  match json_field key json with
  | `List items ->
    List.map
      (function
        | `String s -> s
        | _ -> Alcotest.failf "%s holds a non-string" key)
      items
  | _ -> Alcotest.failf "expected list field: %s" key
;;

(* RFC-0418: every ordinary fact a search returns is a retrieval of that fact,
   recorded with the query and the turn. A miss records nothing. The
   decision-log line names the same ids, so the two records agree. *)
let test_search_records_a_retrieval_per_ordinary_match () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "search-events" in
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path
  in
  let hit_a = fact "alpha beta first" in
  let hit_b = fact "second alpha beta" in
  let miss = fact "gamma only" in
  replace_current_facts ~keepers_dir ~keeper_id:meta.name [ hit_a; miss; hit_b ];
  let search query =
    Runtime.keeper_memory_search_json
      ~config
      ~meta
      ~ctx_work:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"")
      ~args:
        (`Assoc
           [ "query", `String query; "source", `String "memory"; "limit", `Int 10 ])
    |> Yojson.Safe.from_string
  in
  let response = search "alpha beta" in
  Alcotest.(check int) "two matches" 2 (int_field "match_count" response);
  let id = Masc.Keeper_memory_os_types.memory_id in
  let events = events_for ~keepers_dir ~keeper_id:meta.name in
  Alcotest.(check (list string))
    "one retrieval per matched fact, in result order"
    [ id hit_a; id hit_b ]
    (List.map (fun (e : Events.event) -> e.memory_id) events);
  List.iter
    (fun (e : Events.event) ->
       (match e.kind with
        | Events.Retrieved { query } ->
          Alcotest.(check string) "the query is recorded" "alpha beta" query
        | Events.Cited _ | Events.Revised _ ->
          Alcotest.fail "a search records retrievals only");
       Alcotest.(check string)
         "the turn is recorded"
         (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
         e.trace_id)
    events;
  ignore (search "nothing here");
  Alcotest.(check int)
    "a miss records nothing"
    2
    (List.length (events_for ~keepers_dir ~keeper_id:meta.name));
  let log_lines =
    Fs_compat.load_jsonl
      (Masc.Keeper_types_support.keeper_decision_log_path config meta.name)
  in
  match List.rev log_lines with
  | miss_line :: hit_line :: _ ->
    Alcotest.(check (list string))
      "the hit line names the retrieved ids"
      [ id hit_a; id hit_b ]
      (string_list_field "matched_memory_ids" hit_line);
    Alcotest.(check (list string))
      "the miss line names none"
      []
      (string_list_field "matched_memory_ids" miss_line)
  | _ -> Alcotest.fail "expected one decision-log line per search"
;;

(* RFC-0418: a retract names the fact by id and the store found it, so the id
   was cited; the event outlives the fact. A retract of an id no fact has
   records nothing. *)
let test_retract_records_a_citation () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "retract-events" in
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path
  in
  let written =
    Runtime.keeper_memory_write_with_outcome
      ~config
      ~meta
      ~args:(make_args ~title:"" ~content:"the deploy needs assets")
  in
  let written_id =
    string_field
      "memory_id"
      (Yojson.Safe.from_string written.Masc.Keeper_tool_execution.raw_output)
  in
  let retract id =
    Runtime.keeper_memory_retract_with_outcome
      ~config
      ~meta
      ~args:(make_retract_args ~memory_id:id ~reason:"superseded by the runbook")
  in
  let response =
    Yojson.Safe.from_string (retract written_id).Masc.Keeper_tool_execution.raw_output
  in
  Alcotest.(check bool) "retraction succeeds" true (json_field "ok" response = `Bool true);
  (match events_for ~keepers_dir ~keeper_id:meta.name with
   | [ e ] ->
     Alcotest.(check string) "the retracted id is the cited one" written_id e.memory_id;
     (match e.kind with
      | Events.Cited { tool } ->
        Alcotest.(check string) "cited through the retract tool" "keeper_memory_retract" tool
      | Events.Retrieved _ | Events.Revised _ -> Alcotest.fail "a retract records a citation")
   | events -> Alcotest.failf "expected one event, got %d" (List.length events));
  ignore (retract (memory_id 'f'));
  Alcotest.(check int)
    "a retract of an unknown id records nothing"
    1
    (List.length (events_for ~keepers_dir ~keeper_id:meta.name))
;;

let test_source_snapshot_commit_notifications () =
  let module Source = Masc.Keeper_memory_source_current in
  let module Notifications = Masc.Keeper_memory_commit_notifications in
  with_temp_dir @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "source-commit-notifications" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path in
  Fs_compat.mkdir_p keepers_dir;
  let physical_keepers_dir = Unix.realpath keepers_dir in
  let sandbox_root = Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta in
  Fs_compat.mkdir_p sandbox_root;
  let source_path = "source.txt" in
  let absolute = Filename.concat sandbox_root source_path in
  let write_bytes bytes = match Fs_compat.save_file_atomic absolute bytes with
    | Ok () -> () | Error detail -> Alcotest.fail detail
  in
  let observed = ref [] in
  let stop = Notifications.subscribe (fun (event : Notifications.event) ->
    if String.equal event.keepers_dir physical_keepers_dir then (
      let snapshot =
        Masc.Keeper_memory_os_aggregate_lock.with_lock
          ~keepers_dir ~keeper_id:meta.name (fun () ->
            File_lock_eio.with_lock
              (Source.path_for_keepers_dir ~keepers_dir ~keeper_id:meta.name)
              (fun () -> Source.read_for_keepers_dir ~keepers_dir ~keeper_id:meta.name))
      in
      observed := (event, snapshot) :: !observed))
  in
  let write () = match Source.upsert_file_fact ~config ~meta ~keepers_dir
      ~now:100. ~claim:"source-backed fact" ~source_path () with
    | Ok _ -> ()
    | Error (Source.Source_read_failed failure) -> Alcotest.fail (Source.source_read_failure_to_string failure)
    | Error (Source.Store_write_failed detail) -> Alcotest.fail detail
  in
  let revalidate () = match Source.revalidate ~config ~meta ~keepers_dir ~now:200. () with
    | Ok projection -> projection | Error detail -> Alcotest.fail detail
  in
  Fun.protect ~finally:stop (fun () ->
    ignore (revalidate ());
    Alcotest.(check int) "absent revalidation is not a write" 0 (List.length !observed);
    write_bytes "first source\n";
    write ();
    ignore (revalidate ());
    Alcotest.(check int) "unchanged revalidation emits nothing" 1 (List.length !observed);
    write_bytes "changed source\n";
    let invalidated = revalidate () in
    Alcotest.(check int) "source change persists invalidation" 1 (List.length invalidated.invalidations);
    ignore (revalidate ());
    Alcotest.(check int) "pending invalidation recheck emits nothing" 2 (List.length !observed);
    write ();
    Sys.remove absolute;
    ignore (revalidate ());
    (match Source.upsert_file_fact ~config ~meta ~keepers_dir ~now:300.
      ~claim:"missing source" ~source_path () with
     | Error (Source.Source_read_failed _) -> ()
     | Error (Source.Store_write_failed detail) -> Alcotest.fail detail
     | Ok _ -> Alcotest.fail "missing source unexpectedly committed");
    Alcotest.(check int) "only four snapshot commits notify" 4 (List.length !observed);
    List.rev !observed |> List.iteri (fun index (event, snapshot) ->
      Alcotest.(check int) "source revision" (index + 1) event.Notifications.revision;
      Alcotest.(check bool) "source-bound store" true (event.store = Notifications.Source_bound);
      match snapshot with
      | Ok (Some snapshot) -> Alcotest.(check int) "committed state readable outside locks" event.revision snapshot.Source.revision
      | Ok None | Error _ -> Alcotest.fail "notification preceded source commit");
    stop ();
    write_bytes "recreated source\n";
    write ();
    Alcotest.(check int) "unsubscribe detaches source listener" 4 (List.length !observed))
;;

let () =
  Alcotest.run
    "keeper_memory_write"
    [ ( "commit notification"
      , [ Alcotest.test_case "source writes and invalidations notify after locks" `Quick test_source_snapshot_commit_notifications ] )
    ; ( "validation"
      , [ Alcotest.test_case "typed validation failures" `Quick test_validation_taxonomy
        ; Alcotest.test_case
            "a refused derivation names the field and what it takes"
            `Quick
            test_a_refused_derivation_names_the_field_and_what_it_takes
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
            "history search preserves distinct message endings"
            `Quick
            test_history_search_preserves_distinct_message_endings
        ; Alcotest.test_case
            "history search deduplicates identical messages"
            `Quick
            test_history_search_deduplicates_identical_messages
        ; Alcotest.test_case "history search reaches retained current messages" `Quick
            (check_retained_history_match ~checkpoint_texts:[] ~previous_texts:[]
               ~current_texts:("Migration prerequisite: amber database" :: history_search_noise 75))
        ; Alcotest.test_case "history search reaches retained previous messages" `Quick
            (check_retained_history_match ~checkpoint_texts:[] ~current_texts:[]
               ~previous_texts:("Migration prerequisite: amber database" :: history_search_noise 30))
        ; Alcotest.test_case "history search includes the newest current message" `Quick
            (check_retained_history_match ~checkpoint_texts:[] ~previous_texts:[]
               ~current_texts:(history_search_noise 50 @ [ "Migration prerequisite: amber database" ]))
        ; Alcotest.test_case "history search includes the newest previous message" `Quick
            (check_retained_history_match ~checkpoint_texts:[] ~current_texts:[]
               ~previous_texts:(history_search_noise 20 @ [ "Migration prerequisite: amber database" ]))
        ; Alcotest.test_case "history search reaches all working-context messages" `Quick
            (check_retained_history_match ~current_texts:[] ~previous_texts:[]
               ~checkpoint_texts:("Migration prerequisite: amber database" :: history_search_noise 100))
        ; Alcotest.test_case
            "history complete query outranks retained fragments"
            `Quick
            test_history_complete_query_outranks_retained_fragments
        ; Alcotest.test_case "history search limits distinct matches" `Quick
            test_history_search_limits_distinct_matches
        ; Alcotest.test_case "history search orders selected messages" `Quick
            test_history_search_order
        ; Alcotest.test_case "history search reports malformed rows" `Quick
            (test_history_search_reports_read_errors ~malformed:true)
        ; Alcotest.test_case "history search reports unreadable files" `Quick
            (test_history_search_reports_read_errors ~malformed:false)
        ; Alcotest.test_case
            "search filters exact substring without ranking"
            `Quick
            test_search_filters_exact_substring_without_ranking
        ; Alcotest.test_case
            "search records a retrieval per ordinary match"
            `Quick
            test_search_records_a_retrieval_per_ordinary_match
        ; Alcotest.test_case
            "retract records a citation"
            `Quick
            test_retract_records_a_citation
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
            "a torn tail does not stop the next absorb"
            `Quick
            test_a_torn_tail_does_not_stop_the_next_absorb
        ; Alcotest.test_case
            "absorbed facts are searchable"
            `Quick
            test_absorbed_facts_are_searchable
        ; Alcotest.test_case
            "a query of several words is answered"
            `Quick
            test_a_query_of_several_words_is_answered
        ; Alcotest.test_case
            "all ranks complete queries across stores"
            `Quick
            test_all_ranks_complete_queries_before_fragments_across_stores
        ; Alcotest.test_case
            "fragment matching contract is explicit"
            `Quick
            test_fragment_contract_is_whitespace_split_substring_matching
        ; Alcotest.test_case
            "an unreadable absorbed store leaves all its current facts"
            `Quick
            test_an_unreadable_absorbed_store_leaves_all_its_current_facts
        ; Alcotest.test_case
            "unwritable store is a dependency failure"
            `Quick
            test_unwritable_store_is_a_dependency_failure
        ; Alcotest.test_case
            "a commit that omits the claim is after the effect"
            `Quick
            test_a_commit_that_omits_the_claim_is_after_the_effect
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
