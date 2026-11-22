(** Explicit Memory writes through the Keeper's write tool. *)

module Runtime = Masc.Keeper_tool_memory_runtime
module Current = Masc.Keeper_memory_os_current
module Render = Masc.Keeper_memory_os_render

let ordinary_facts_for ~keepers_dir ~keeper_id () =
  match Current.read_for_keepers_dir ~keepers_dir ~keeper_id with
  | Ok None -> Ok []
  | Ok (Some snapshot) -> Ok snapshot.Current.facts
  | Error message -> Error message
;;

external unsetenv : string -> unit = "masc_test_unsetenv"

let recall_history config ~keeper =
  Dated_jsonl.open_store
    (Dated_jsonl.Store.keeper
       (Masc.Workspace.dated_store_root config)
       ~keeper
       Memory_recall_artifacts)

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

(* [lstat], not [Sys.is_directory]: a symlink to a directory outside the
   temporary tree is removed as a link, never followed into. *)
let rec remove_tree path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path
    |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | { Unix.st_kind = Unix.S_REG | S_LNK | S_CHR | S_BLK | S_FIFO | S_SOCK; _ } ->
    Unix.unlink path
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

(* The Memory tools write through the Keeper's Memory writer, so every case
   runs in an Eio loop and a Keeper gets its writer before its first tool
   call. *)
let tool_case name speed body =
  Alcotest.test_case name speed (Masc_test_deps.Memory_tool_case.run body)
;;

let write_tool ~config ~(meta : Masc.Keeper_meta_contract.keeper_meta) ~args =
  Masc_test_deps.Memory_tool_case.writer ~config meta.name;
  Runtime.keeper_memory_write_with_outcome ~config ~meta ~args
;;

let retract_tool ~config ~(meta : Masc.Keeper_meta_contract.keeper_meta) ~args =
  Masc_test_deps.Memory_tool_case.writer ~config meta.name;
  Runtime.keeper_memory_retract_with_outcome ~config ~meta ~args
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
      (function
        | `String text when string_field "source" json = "history" -> text
        | `Assoc _ as match_json -> string_field "text" match_json
        | _ -> Alcotest.fail "expected history string or durable match object")
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

let replace_current_facts ?expected_revision ~keepers_dir ~keeper_id facts =
  Current.replace
    ~keepers_dir
    ~keeper_id
    ~expected_revision
    ~now:(Time_compat.now ())
    ~source:{ Current.kind = Current.Librarian; trace_id = "seed" }
    ~facts
    ()
  |> function
  | Ok _ -> ()
  | Error detail -> Alcotest.fail detail
;;

let seed_current ~config ~(meta : Masc.Keeper_meta_contract.keeper_meta) claim =
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.Masc.Workspace.base_path in
  let value = fact claim in
  match Current.upsert_fact ~pass:Masc.Keeper_memory_commit_pass.Keeper_write ~keepers_dir ~keeper_id:meta.name ~now:value.last_seen
      ~source:{Current.kind=Current.Explicit_write; trace_id="fixture"} value with
  | Ok _ -> Masc.Keeper_memory_os_types.memory_id value
  | Error _ -> Alcotest.fail "could not seed current fact"
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

(* A plain observation commits to the current snapshot and is recallable
   immediately. *)
let test_an_ordinary_write_lands_in_current_memory () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "ordinary-write" in
  let args = make_args ~title:"t" ~content:"the standby region is eu-west-2" in
  let receipt =
    (write_tool ~config ~meta ~args)
      .Masc.Keeper_tool_execution.raw_output
  in
  let json = Yojson.Safe.from_string receipt in
  Alcotest.(check string) "the write lands in current Memory"
    "persisted_current_snapshot" (string_field "outcome" json);
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  Alcotest.(check int) "the fact is recallable immediately" 1
    (List.length (current_facts ~keepers_dir ~keeper_id:meta.name))

(* Writing a claim Memory already holds moves the snapshot's stamps and nothing
   else, so the repeat guard reads every such rewrite as the same answer. *)
let test_a_rewrite_receipt_has_the_same_answer () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "rewrite-answer" in
  let args = make_args ~title:"t" ~content:"the deployment region is eu-west-1" in
  let write () =
    (write_tool ~config ~meta ~args)
      .Masc.Keeper_tool_execution.raw_output
  in
  let fingerprint receipt =
    match
      Masc.Keeper_tool_progress_identity.digest_tool_io
        ~tool_name:"keeper_memory_write" ~input:args ~output_text:receipt ()
    with
    | Some io -> io.Masc.Keeper_tool_progress_identity.output_fingerprint
    | None -> Alcotest.fail "no fingerprint for a memory write receipt"
  in
  let first = write () in
  let second = write () in
  let third = write () in
  let disposition receipt = string_field "identity_disposition" (Yojson.Safe.from_string receipt) in
  Alcotest.(check string) "the first write inserts the claim" "inserted" (disposition first);
  Alcotest.(check string) "the second sees it again" "reobserved" (disposition second);
  Alcotest.(check string) "snapshot stamps cannot manufacture progress"
    (fingerprint second) (fingerprint third);
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  Alcotest.(check int) "Memory holds the claim once" 1
    (List.length (current_facts ~keepers_dir ~keeper_id:meta.name))
;;

let test_write_comes_back_through_recall () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "durable-write" in
  let execution =
    write_tool
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
  Alcotest.(check string) "stored in the current snapshot" "current_memory_snapshot"
    (string_field "store" response);
  let recorded_at = string_field "recorded_at" response in
  Alcotest.(check bool) "receipt carries a UTC stamp" true
    (String.length recorded_at = 20 && String.ends_with ~suffix:"Z" recorded_at);
  let search () = Runtime.keeper_memory_search_json ~config ~meta
    ~ctx_work:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"")
    ~args:(`Assoc ["query",`String "reasoning_content";"source",`String "current"])
    |> Yojson.Safe.from_string |> match_texts in
  Alcotest.(check (list string)) "the claim reaches demand recall"
    ["reasoning_content must be replayed unmodified"] (search ())
;;

(* The commit lines of a Keeper's commit log, oldest first. The Memory tools
   write through the Keeper's writer, whose record of a write is that log. *)
let commit_lines ~keepers_dir ~keeper_id : Masc.Librarian_log.commit list =
  let module Store = Masc.Librarian_log_store in
  match
    Store.fold
      (Store.path_for_keepers_dir ~keepers_dir ~keeper_id)
      ~init:[]
      ~f:(fun seen (scanned : Store.scanned) ->
        match scanned.line with
        | Ok (Committed commit) -> commit :: seen
        | Ok (Started _) -> seen
        | Error (_ : Store.undecodable) -> Alcotest.fail "a commit log line does not decode")
  with
  | Ok seen -> List.rev seen
  | Error error -> Alcotest.fail (Masc.Private_jsonl_scan.error_to_string error)
;;

(* Each fact a commit removed, with why it left. *)
let removed_by (commit : Masc.Librarian_log.commit) =
  List.map
    (fun ((fact : Masc.Keeper_memory_os_types.fact), (removal : Masc.Librarian_effects.removal)) ->
       ( Masc.Keeper_memory_os_types.memory_id fact
       , match removal with
         | Retracted { by = Keeper; reason } -> "retracted by the keeper: " ^ reason
         | Retracted { by = Operator operator; reason } ->
           "retracted by " ^ operator ^ ": " ^ reason
         | Support_lost { missing } -> "support lost: " ^ String.concat "," missing
         | Superseded_by successor -> "superseded by " ^ successor
         | Dropped { reason } -> "dropped: " ^ reason
         | Merged_into successor -> "merged into " ^ successor
         | Revised_into successor -> "revised into " ^ successor
         | Molted { reason } -> "molted: " ^ reason ))
    commit.effects.removed
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
    write_tool ~config ~meta ~args
    |> fun execution ->
    execution.Masc.Keeper_tool_execution.raw_output |> Yojson.Safe.from_string
  in
  let first_id = seed_current ~config ~meta "manifest selects region A" in
  let second_id = seed_current ~config ~meta "region A capacity is healthy" in
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
    retract_tool
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
  (* The two premises were in the snapshot the writer's store opened on. The
     two derived writes and the retraction are its commit lines. *)
  let commits = commit_lines ~keepers_dir ~keeper_id:meta.name in
  Alcotest.(check int) "two writes and one retract are commit lines" 3 (List.length commits);
  (match List.rev commits with
   | retraction :: _ ->
     Alcotest.(check (list (pair string string)))
       "the line keeps each removed fact with why it left"
       [ first_id, "retracted by the keeper: manifest now selects region B"
       ; conclusion_id, "support lost: " ^ first_id
       ; consequence_id, "support lost: " ^ conclusion_id
       ]
       (removed_by retraction)
   | [] -> Alcotest.fail "no commit line");
  (* source=dropped reads the same line: each fact that left with nothing in
     its place, with why. *)
  let dropped =
    Runtime.keeper_memory_search_json
      ~config
      ~meta
      ~ctx_work:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"")
      ~args:(`Assoc [ "query", `String ""; "source", `String "dropped"; "limit", `Int 10 ])
    |> Yojson.Safe.from_string
  in
  (match json_field "matches" dropped with
   | `List rows ->
     Alcotest.(check (list (pair string string)))
       "the retracted fact and the two conclusions that lost their premise"
       [ first_id, "retracted"; conclusion_id, "support_lost"; consequence_id, "support_lost" ]
       (List.map (fun row -> string_field "memory_id" row, string_field "removal" row) rows);
     (match rows with
      | first :: _ ->
        Alcotest.(check string) "the reason the Keeper gave"
          "manifest now selects region B" (string_field "reason" first);
        Alcotest.(check string) "and who removed it" "keeper" (string_field "removed_by" first)
      | [] -> Alcotest.fail "no dropped row")
   | _ -> Alcotest.fail "matches is a list");
  let revision_before_missing = int_field "revision" response in
  let missing =
    retract_tool
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
    "missing target does not append a commit line"
    3
    (List.length (commit_lines ~keepers_dir ~keeper_id:meta.name))
;;

let test_derived_write_uses_exact_premise_receipt () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "derived-write" in
  let write args =
    write_tool ~config ~meta ~args
  in
  let premise_id = seed_current ~config ~meta "dependency failed" in
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
    write_tool
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

let test_demand_recall_does_not_materialize_or_verify_all_memory () =
  with_temp_dir @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "demand-recall" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let claim = "Remember the deployment decision only when it is relevant." in
  ignore (seed_current ~config ~meta claim);
  let sandbox_root = Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta in
  Fs_compat.mkdir_p sandbox_root;
  let source_path = "deployment.txt" in
  let host_path = Filename.concat sandbox_root source_path in
  Fs_compat.save_file host_path "old bytes";
  let source_claim = "The source-bound deployment claim is not a standing instruction." in
  let write = write_tool ~config ~meta
      ~args:(make_source_args ~title:"" ~content:source_claim ~source_path) in
  Alcotest.(check bool) "source write succeeds" true
    (json_field "ok" (Yojson.Safe.from_string write.raw_output) = `Bool true);
  let source_file = Masc.Keeper_memory_source_current.path_for_keepers_dir
      ~keepers_dir ~keeper_id:meta.name in
  let before = Fs_compat.load_file source_file in
  Fs_compat.save_file host_path "changed bytes";
  let render ~search ~reader ~now =
    Masc.Keeper_memory_os_recall.render_if_enabled
      ~memory_search_available:search ~artifact_reader_available:reader
      ~config ~meta ~keepers_dir ~keeper_id:meta.name ~now () |> Option.get in
  let prompt = render ~search:true ~reader:true ~now:100. in
  Alcotest.(check bool) "notice injects frozen-epoch Tier-1 ordinary digest" true
    (contains ~needle:"Current ordinary memory digest (epoch revision=1; 1 stored facts;" prompt
     && contains ~needle:claim prompt
     && not (contains ~needle:"bodies omitted" prompt));
  List.iter (fun text -> Alcotest.(check bool) "notice omits deferred source claim bodies and paths" false
      (contains ~needle:text prompt)) [source_claim; source_path];
  Alcotest.(check string) "prompt preparation performs no source invalidation write"
    before (Fs_compat.load_file source_file);
  let keeper_dir = Filename.concat (Masc.Workspace.keepers_runtime_dir config) meta.name in
  Alcotest.(check bool) "default recall publishes no current artifact pin" false
    (Sys.file_exists (Filename.concat keeper_dir "memory-recall-current.json"));
  Alcotest.(check bool) "default recall creates no complete blob store" false
    (Sys.file_exists (Tool_blob_store.root_dir (Tool_blob_store.create ~base_path)));
  Alcotest.(check string) "reader availability does not change a search notice" prompt
    (render ~search:true ~reader:false ~now:200.);
  let no_tools = render ~search:false ~reader:false ~now:200. in
  Alcotest.(check bool) "retrieval-less fallback keeps frozen-epoch Tier-1 ordinary digest" true
    (contains ~needle:"Current ordinary memory digest (epoch revision=1; 1 stored facts;" no_tools
     && contains ~needle:claim no_tools
     && not (contains ~needle:"bodies omitted" no_tools));
  List.iter (fun text -> Alcotest.(check bool) "retrieval-less fallback omits deferred source claims" false
      (contains ~needle:text no_tools)) [source_claim; source_path];
  Alcotest.(check bool) "retrieval-less state explicitly withdraws prior authority" true
    (contains ~needle:"Memory retrieval is unavailable" no_tools
     && contains ~needle:"this notice verifies no claim" no_tools);
  Alcotest.(check string) "notice is independent of wall clock" prompt
    (render ~search:true ~reader:true ~now:300.);
  (* Construct request access from the offered surface: a deferred name alone
     cannot promise that selection can be loaded. None of these notice requests
     should inspect the changed source or materialize its stored claim. *)
  let tool name = Agent_core.Tool.create ~name ~description:"notice fixture"
      ~parameters:[] (fun _ -> Alcotest.fail "notice must not execute a tool") in
  let select = tool "keeper_memory_select" in
  let loader = tool "keeper_tool_search" in
  let key = "MASC_TEST_MEMORY_NOTICE_KEY" in
  let with_policy ~enabled ~excluded f =
    Masc_test_deps.with_process_env key (Some "synthetic-notice-key") @@ fun () ->
    Masc_test_deps.with_typesafeai_policy
      {Runtime_schema.default_typesafeai with
       lane_enabled=true; workspace_memory_selection_enabled=enabled;
       excluded_keepers=(if excluded then [meta.name] else []);
       destinations=({Runtime_schema.endpoint="http://127.0.0.1:1";
                      model="notice-only"; api_key_env=key},[])} f in
  let notice ~offered ~loader_alive ~search ~reader =
    let access = Masc.Keeper_request_tool_access.create ~offered
        ~deferred_names:["keeper_memory_select"] ~loader_alive in
    Masc.Keeper_memory_os_recall.render_if_enabled
      ~memory_select_route:(Masc.Keeper_request_tool_access.route access
        ~name:"keeper_memory_select")
      ~memory_search_available:search ~artifact_reader_available:reader
      ~config ~meta ~keepers_dir ~keeper_id:meta.name ~now:300. () |> Option.get in
  with_policy ~enabled:true ~excluded:false (fun () ->
    let direct = notice ~offered:[select] ~loader_alive:false ~search:false ~reader:true in
    Alcotest.(check bool) "select-only request offers purpose-scoped selection" true
      (contains ~needle:"Use keeper_memory_select" direct
       && contains ~needle:"current_decision versus comparison" direct
       && contains ~needle:"not proof of no relevant memory" direct);
    Alcotest.(check bool) "select-only request does not invent lexical access" false
      (contains ~needle:"keeper_memory_search" direct);
    let both = notice ~offered:[select] ~loader_alive:false ~search:true ~reader:false in
    Alcotest.(check bool) "selection also describes available lexical history" true
      (contains ~needle:"keeper_memory_search remains available for lexical lookup" both);
    let discoverable = notice ~offered:[loader] ~loader_alive:true ~search:false ~reader:true in
    Alcotest.(check bool) "live offered loader gives truthful discovery instruction" true
      (contains ~needle:"load keeper_memory_select, then call it" discoverable);
    List.iter (fun (offered, loader_alive) ->
      Alcotest.(check string) "unloadable selection preserves lexical notice" prompt
        (notice ~offered ~loader_alive ~search:true ~reader:true);
      Alcotest.(check string) "unloadable selection preserves no-tool notice" no_tools
        (notice ~offered ~loader_alive ~search:false ~reader:false))
      [([loader],false); ([],true); ([],false)];
    List.iter (fun body ->
      Alcotest.(check bool) "selection notice injects frozen-epoch Tier-1 ordinary digest" true
        (contains ~needle:"Current ordinary memory digest (epoch revision=1; 1 stored facts;" body
         && contains ~needle:claim body
         && not (contains ~needle:"bodies omitted" body));
      List.iter (fun text ->
        Alcotest.(check bool) "selection notice omits deferred source bodies and paths" false
          (contains ~needle:text body)) [source_claim; source_path])
      [direct; both; discoverable]);
  List.iter (fun (enabled, excluded) ->
    with_policy ~enabled ~excluded (fun () ->
      Alcotest.(check string) "policy denial preserves lexical fallback" prompt
        (notice ~offered:[select] ~loader_alive:false ~search:true ~reader:true);
      Alcotest.(check string) "policy denial cannot advertise selection without other tools" no_tools
        (notice ~offered:[loader] ~loader_alive:true ~search:false ~reader:false)))
    [(false,false);(true,true)];
  Alcotest.(check string) "all selection notices leave changed-source state untouched"
    before (Fs_compat.load_file source_file);
  List.iter (fun path -> Alcotest.(check bool) "notice creates no artifact or evaluation journal"
      false (Sys.file_exists path))
    [Filename.concat keeper_dir "memory-recall-current.json";
     Filename.concat keeper_dir "memory-selection-evaluations.jsonl";
     Tool_blob_store.root_dir (Tool_blob_store.create ~base_path)];
  let search = Runtime.keeper_memory_search_json ~config ~meta
      ~ctx_work:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"")
      ~args:(`Assoc ["query", `String "deployment"; "limit", `Int 10])
      |> Yojson.Safe.from_string in
  Alcotest.(check (list string)) "demand search withholds changed source and keeps ordinary fact"
    [claim] (match_texts search);
  Alcotest.(check bool) "lookup revalidates and updates the changed source" false
    (String.equal before (Fs_compat.load_file source_file));
  with_policy ~enabled:false ~excluded:false (fun () ->
    let artifact_notice = notice ~offered:[select] ~loader_alive:false
        ~search:false ~reader:true in
    Alcotest.(check bool) "denied selection retains the offered artifact fallback" true
      (contains ~needle:"Use keeper_artifact_read" artifact_notice);
    let reference = List.hd (List.rev (String.split_on_char '\n' artifact_notice))
        |> Yojson.Safe.from_string |> Tool_output.normalized_artifact_ref_of_json in
    match reference with
    | Tool_output.Decoded_normalized_artifact_ref _ -> ()
    | _ -> Alcotest.fail "artifact-only fallback must publish a real artifact reference")
;;

let test_same_count_replacement_updates_notice_and_demand_search () =
  with_temp_dir @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "revision-demand-recall" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let old = fact "Deployment A17 remains under investigation." in
  let current = fact "Deployment A17 was investigated and is now resolved." in
  replace_current_facts ~keepers_dir ~keeper_id:meta.name [old];
  let read () = match Current.read_for_keepers_dir ~keepers_dir ~keeper_id:meta.name with
    | Ok (Some value) -> value
    | Ok None -> Alcotest.fail "current snapshot missing"
    | Error detail -> Alcotest.fail detail in
  let render now = Masc.Keeper_memory_os_recall.render_if_enabled
    ~config ~meta ~keepers_dir ~keeper_id:meta.name ~now () |> Option.get in
  let before = read () in
  let first_notice = render 100. in
  Alcotest.(check string) "unchanged store does not change with time" first_notice (render 200.);
  Alcotest.(check bool) "initial frozen-epoch digest includes prior claim only" true
    (contains ~needle:(Printf.sprintf "revision=%d" before.revision) first_notice
     && contains ~needle:old.claim first_notice
     && not (contains ~needle:current.claim first_notice)
     && not (contains ~needle:"bodies omitted" first_notice));
  (match Current.replace ~keepers_dir ~keeper_id:meta.name
    ~expected_revision:(Some before.revision) ~now:300.
    ~source:{Current.kind=Current.Librarian; trace_id="transition"} ~facts:[current] () with
   | Ok _ -> () | Error detail -> Alcotest.fail detail);
  let after = read () in
  let next_notice = render 400. in
  Alcotest.(check int) "replacement preserves count" (List.length before.facts) (List.length after.facts);
  Alcotest.(check bool) "same-count transition changes notice" true (first_notice <> next_notice);
  Alcotest.(check string) "successor epoch digest stays byte-stable across turns" next_notice (render 500.);
  Alcotest.(check bool) "notice identifies actual stored revision" true
    (contains ~needle:(Printf.sprintf "revision=%d" after.revision) next_notice);
  Alcotest.(check bool) "successor digest drops historical claim and renders current claim" true
    (not (contains ~needle:old.claim next_notice)
     && contains ~needle:current.claim next_notice
     && not (contains ~needle:"bodies omitted" next_notice));
  let search = Runtime.keeper_memory_search_json ~config ~meta
    ~ctx_work:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"")
    ~args:(`Assoc ["query", `String "deployment"]) |> Yojson.Safe.from_string in
  Alcotest.(check (list string)) "demand lookup returns only the successor" [current.claim]
    (match_texts search)
;;

let test_search_revalidates_query_sources_only () =
  let module Source = Masc.Keeper_memory_source_current in
  with_temp_dir @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "selective-source-search" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let sandbox_root = Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta in
  Fs_compat.mkdir_p sandbox_root;
  let write path claim =
    Fs_compat.save_file (Filename.concat sandbox_root path) "original";
    let output = write_tool ~config ~meta
        ~args:(make_source_args ~title:"" ~content:claim ~source_path:path) in
    Alcotest.(check bool) "source write succeeds" true
      (json_field "ok" (Yojson.Safe.from_string output.raw_output) = `Bool true) in
  write "unrelated.txt" "The unrelated astronomy claim.";
  write "stale.txt" "Deployment stale candidate.";
  write "valid.txt" "Deployment valid candidate.";
  Fs_compat.save_file (Filename.concat sandbox_root "unrelated.txt") "changed";
  Fs_compat.save_file (Filename.concat sandbox_root "stale.txt") "changed";
  let read () = match Source.read_for_keepers_dir ~keepers_dir ~keeper_id:meta.name with
    | Ok (Some snapshot) -> snapshot
    | Ok None -> Alcotest.fail "source snapshot absent"
    | Error detail -> Alcotest.fail detail in
  let before = read () in
  let search query limit = Runtime.keeper_memory_search_json ~config ~meta
      ~ctx_work:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"")
      ~args:(`Assoc ["query", `String query; "limit", `Int limit])
      |> Yojson.Safe.from_string in
  Alcotest.(check (list string)) "stale match does not crowd out valid successor"
    ["Deployment valid candidate."] (match_texts (search "Deployment" 1));
  let after = read () in
  Alcotest.(check (list string)) "only selected changed source is invalidated"
    ["stale.txt"] (List.map (fun (i : Source.invalidation) -> i.source_path) after.invalidations);
  Alcotest.(check bool) "unrelated stored claim survives without being read" true
    (List.exists (fun (fact : Source.fact) -> fact.source.path = "unrelated.txt") after.facts);
  let saved = Fs_compat.load_file (Source.path_for_keepers_dir ~keepers_dir ~keeper_id:meta.name) in
  ignore (search "no matching celestial word" 5);
  Alcotest.(check string) "no-match search does not invalidate unrelated source"
    saved (Fs_compat.load_file (Source.path_for_keepers_dir ~keepers_dir ~keeper_id:meta.name));
  Alcotest.(check int) "selected invalidation is one durable revision" (before.revision + 1) after.revision;
  ignore (search "astronomy" 5);
  Alcotest.(check bool) "later relevant lookup invalidates the unrelated changed source" true
    (List.exists (fun (i : Source.invalidation) -> i.source_path = "unrelated.txt") (read ()).invalidations)
;;

let test_selected_source_rebound_digest_stays_unverified () =
  let module Source = Masc.Keeper_memory_source_current in
  with_temp_dir @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "rebound-source-query" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let sandbox_root = Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta in
  Fs_compat.mkdir_p sandbox_root;
  let path = "config.txt" in
  let host_path = Filename.concat sandbox_root path in
  Fs_compat.save_file host_path "first bytes";
  let write claim = write_tool ~config ~meta
      ~args:(make_source_args ~title:"" ~content:claim ~source_path:path) |> ignore in
  let read () = match Source.read_for_keepers_dir ~keepers_dir ~keeper_id:meta.name with
    | Ok (Some snapshot) -> snapshot
    | Ok None -> Alcotest.fail "missing snapshot"
    | Error detail -> Alcotest.fail detail in
  write "Original selected source claim.";
  let selected = (List.hd (read ()).facts).source in
  Fs_compat.save_file host_path "second bytes";
  write "Replacement source claim.";
  let file = Source.path_for_keepers_dir ~keepers_dir ~keeper_id:meta.name in
  let before = Fs_compat.load_file file in
  Fs_compat.save_file host_path "third bytes";
  let projection = match Source.revalidate ~scope:(Source.Selected_sources [selected])
      ~config ~meta ~keepers_dir ~now:200. () with
    | Ok projection -> projection
    | Error detail -> Alcotest.fail detail in
  Alcotest.(check (list string)) "old query cannot verify replacement identity" [path]
    projection.unverified_paths;
  Alcotest.(check string) "replacement identity is not read or invalidated" before
    (Fs_compat.load_file file);
  Alcotest.(check int) "replacement stays stored" 1 (List.length projection.facts)
;;

let test_recall_artifacts_follow_history_retention () =
  with_temp_dir @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "recall-retention" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let store = Tool_blob_store.create ~base_path in
  let write content = ignore (seed_current ~config ~meta content) in
  let render now =
    Masc.Keeper_memory_os_recall.render_if_enabled ~memory_search_available:false
      ~config ~meta ~keepers_dir ~keeper_id:meta.name ~now () |> Option.get
  in
  let artifact prompt =
    let json = List.hd (List.rev (String.split_on_char '\n' prompt))
        |> Yojson.Safe.from_string in
    match Tool_output.normalized_artifact_ref_of_json json with
    | Tool_output.Decoded_normalized_artifact_ref reference -> reference
    | _ -> Alcotest.fail "expected published recall artifact"
  in
  let sweep mode =
    match Tool_blob_maintenance.run ~base_path
        ~scope:Server_tool_blob_scope.scope ~mode with
    | Ok _ -> ()
    | Error error -> Alcotest.fail (Tool_blob_maintenance.error_to_string error)
  in
  let present (reference : Tool_output.artifact_ref) =
    match Tool_blob_store.fetch store ~sha256:reference.sha256 with
    | Ok value -> Option.is_some value
    | Error error -> Alcotest.fail (Tool_blob_store.fetch_error_to_string error)
  in
  write "The first historical memory remains readable.";
  let first = artifact (render 1.) in
  write "A later decision changes the complete snapshot.";
  let latest = artifact (render 2.) in
  Alcotest.(check bool) "changed memory creates a distinct snapshot" false
    (String.equal first.sha256 latest.sha256);
  sweep Tool_blob_maintenance.Observe_only;
  sweep Tool_blob_maintenance.Delete_previous_candidates;
  Alcotest.(check bool) "historical snapshot survives GC" true (present first);
  Alcotest.(check bool) "latest snapshot survives GC" true (present latest);
  let keeper_dir = Filename.concat (Masc.Workspace.keepers_runtime_dir config) meta.name in
  ignore (Dated_jsonl.prune (recall_history config ~keeper:(Filename.basename keeper_dir)) ~days:1);
  sweep Tool_blob_maintenance.Observe_only;
  sweep Tool_blob_maintenance.Delete_previous_candidates;
  Alcotest.(check bool) "expired historical snapshot becomes collectable" false (present first);
  Alcotest.(check bool) "current snapshot stays reachable" true (present latest);
  let current_pin = Filename.concat keeper_dir "memory-recall-current.json" in
  Sys.remove current_pin;
  Unix.mkdir current_pin 0o700;
  let failed = render (Time_compat.now ()) in
  Alcotest.(check bool) "failed retention does not publish an artifact" false
    (contains ~needle:"keeper_artifact_read" failed);
  Alcotest.(check bool) "failed retention preserves readable store availability" false
    (contains ~needle:"memory is unavailable" failed);
  Alcotest.(check bool) "artifact-only failure does not offer absent search" false
    (contains ~needle:"keeper_memory_search" failed);
  let search = Runtime.keeper_memory_search_json ~config ~meta
      ~ctx_work:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"")
      ~args:(`Assoc ["query", `String "later decision";
                    "source", `String "current"; "limit", `Int 10])
      |> Yojson.Safe.from_string in
  Alcotest.(check (list string)) "search still retrieves the readable snapshot"
    ["A later decision changes the complete snapshot."] (match_texts search)
;;

let test_superseded_recall_pin_releases_only_after_history_retention () =
  List.iter (fun demand -> with_temp_dir @@ fun base_path ->
    let config = Masc.Workspace.default_config base_path in
    let meta = make_meta "pin-retirement" in
    let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
    let store = Tool_blob_store.create ~base_path in
    (* An ordinary write now waits for Librarian admission, so the fixture
       seeds the current fact the pin is rendered from. *)
    let memory_id = seed_current ~config ~meta "Memory later becomes historical." in
    let render search = Masc.Keeper_memory_os_recall.render_if_enabled
        ~memory_search_available:search ~config ~meta ~keepers_dir ~keeper_id:meta.name ~now:1. ()
        |> Option.get in
    let prompt = render false in
    let reference = List.hd (List.rev (String.split_on_char '\n' prompt)) |> Yojson.Safe.from_string in
    let reference = match Tool_output.normalized_artifact_ref_of_json reference with
      | Tool_output.Decoded_normalized_artifact_ref reference -> reference
      | _ -> Alcotest.fail "expected artifact before retirement" in
    let keeper_dir = Filename.concat (Masc.Workspace.keepers_runtime_dir config) meta.name in
    let pin = Filename.concat keeper_dir "memory-recall-current.json" in
    let prior_pin = Fs_compat.load_file pin in
    if not demand then begin
      let retracted = retract_tool ~config ~meta
          ~args:(make_retract_args ~memory_id
            ~reason:"The last current fact was retracted.") in
      Alcotest.(check bool) "last fact retracts" true
        (json_field "ok" (Yojson.Safe.from_string retracted.Masc.Keeper_tool_execution.raw_output) = `Bool true)
    end;
    (* Neither a failed demand read nor a failed artifact revalidation is an
       empty authority. They leave the last complete pin intact. *)
    let source_path = Masc.Keeper_memory_source_current.path_for_keepers_dir
        ~keepers_dir ~keeper_id:meta.name in
    Fs_compat.save_file source_path "not a source snapshot";
    ignore (render demand);
    Alcotest.(check string) "unavailable source preserves current pin" prior_pin (Fs_compat.load_file pin);
    Sys.remove source_path;
    let ordinary_path = Current.path_for_keepers_dir ~keepers_dir ~keeper_id:meta.name in
    let ordinary = Fs_compat.load_file ordinary_path in
    Fs_compat.save_file ordinary_path "not an ordinary snapshot";
    ignore (render demand);
    Alcotest.(check string) "unavailable ordinary source preserves current pin" prior_pin (Fs_compat.load_file pin);
    Fs_compat.save_file ordinary_path ordinary;
    ignore (render demand);
    Alcotest.(check bool) "superseded current root is empty" true
      (Yojson.Safe.from_string (Fs_compat.load_file pin) = `Null);
    let sweep () = List.iter (fun mode -> match Tool_blob_maintenance.run ~base_path
          ~scope:Server_tool_blob_scope.scope ~mode with
      | Ok _ -> () | Error error -> Alcotest.fail (Tool_blob_maintenance.error_to_string error))
        [Tool_blob_maintenance.Observe_only; Delete_previous_candidates] in
    let present () = match Tool_blob_store.fetch store ~sha256:reference.sha256 with
      | Ok value -> Option.is_some value
      | Error error -> Alcotest.fail (Tool_blob_store.fetch_error_to_string error) in
    sweep ();
    Alcotest.(check bool) "retirement preserves dated historical artifact" true (present ());
    ignore (Dated_jsonl.prune (recall_history config ~keeper:(Filename.basename keeper_dir)) ~days:1);
    sweep ();
    Alcotest.(check bool) "normal history retention makes retired artifact collectable" false (present ()))
    [true; false]
;;

let test_late_pin_retirement_preserves_new_same_artifact_publication () =
  with_temp_dir @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let module Pin = Masc.Keeper_recall_artifact in
  let ok = function Ok value -> value | Error detail -> Alcotest.fail detail in
  let store = Tool_blob_store.create ~base_path in
  let artifact = Tool_blob_store.put_durable_reuse store
      ~bytes:"same memory snapshot" ~mime:"text/plain" in
  let retain () = ok (Pin.retain ~config ~keeper_id:"keeper" ~kind:Memory_os ~now:1. artifact) in
  let keeper_dir = Filename.concat (Masc.Workspace.keepers_runtime_dir config) "keeper" in
  let pin = Filename.concat keeper_dir "memory-recall-current.json" in
  let generation () = string_field "generation" (Yojson.Safe.from_string (Fs_compat.load_file pin)) in
  retain ();
  let first_generation = generation () in
  let observed = ok (Pin.observe_current ~config ~keeper_id:"keeper" ~kind:Memory_os) in
  retain ();
  let second_generation = generation () in
  retain ();
  let third_generation = generation () in
  Alcotest.(check bool) "identical publications have independent persisted generations" true
    (first_generation <> second_generation && second_generation <> third_generation
     && first_generation <> third_generation);
  let newer = Fs_compat.load_file pin in
  ok (Pin.retire_current ~config ~keeper_id:"keeper" ~kind:Memory_os observed);
  Alcotest.(check string) "late retirement cannot release newer same-hash publication" newer (Fs_compat.load_file pin);
  ignore (Dated_jsonl.prune (recall_history config ~keeper:(Filename.basename keeper_dir)) ~days:1);
  let sweep () = List.iter (fun mode -> match Tool_blob_maintenance.run ~base_path
        ~scope:Server_tool_blob_scope.scope ~mode with
    | Ok _ -> () | Error error -> Alcotest.fail (Tool_blob_maintenance.error_to_string error))
      [Tool_blob_maintenance.Observe_only; Delete_previous_candidates] in
  let present () = match Tool_blob_store.fetch store ~sha256:artifact.sha256 with
    | Ok value -> Option.is_some value
    | Error error -> Alcotest.fail (Tool_blob_store.fetch_error_to_string error) in
  sweep ();
  Alcotest.(check bool) "actual maintenance sees nested current artifact without dated history" true (present ());
  let current = ok (Pin.observe_current ~config ~keeper_id:"keeper" ~kind:Memory_os) in
  ok (Pin.retire_current ~config ~keeper_id:"keeper" ~kind:Memory_os current);
  Alcotest.(check bool) "current owner can retire its exact generation" true
    (Yojson.Safe.from_string (Fs_compat.load_file pin) = `Null);
  let snapshot () = match Fs_compat.load_owned_regular_file_with_snapshot
      ~ownership_root:(Masc.Workspace.keepers_runtime_dir config) pin with
    | Ok (Some contents) -> contents.snapshot
    | Ok None -> Alcotest.fail "retired pin is absent"
    | Error error -> Alcotest.fail (Fs_compat.owned_regular_file_read_error_to_string error) in
  let retired_snapshot = snapshot () in
  let retired = ok (Pin.observe_current ~config ~keeper_id:"keeper" ~kind:Memory_os) in
  ok (Pin.retire_current ~config ~keeper_id:"keeper" ~kind:Memory_os retired);
  ok (Pin.retire_current ~config ~keeper_id:"keeper" ~kind:Memory_os current);
  Alcotest.(check bool) "retired observation and stale generation never rewrite null" true
    (Fs_compat.equal_owned_regular_file_snapshot retired_snapshot (snapshot ()));
  sweep ();
  Alcotest.(check bool) "retired generation becomes collectable through normal maintenance" false (present ());
  (* Unversioned roots do not carry publication identity. No observation
     fabricates a generation or rewrites these roots as a hidden migration. *)
  let unversioned = Yojson.Safe.to_string (Tool_output.normalized_artifact_ref_to_json artifact) in
  Fs_compat.save_file pin unversioned;
  Alcotest.(check bool) "unversioned pin is a conservative read error" true
    (Result.is_error (Pin.observe_current ~config ~keeper_id:"keeper" ~kind:Memory_os));
  let meta = make_meta "keeper" in
  ignore (Masc.Keeper_memory_os_recall.render_if_enabled ~config ~meta
      ~keepers_dir:(Config_dir_resolver.keepers_dir_for_base_path ~base_path)
      ~keeper_id:meta.name ~now:1. ());
  Alcotest.(check string) "authoritative demand does not silently stamp or retire unversioned roots"
    unversioned (Fs_compat.load_file pin)
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
    write_tool
      ~config
      ~meta
      ~args:(make_source_args ~title:"" ~content ~source_path)
    |> fun execution -> execution.Masc.Keeper_tool_execution.raw_output
    |> Yojson.Safe.from_string
  in
  let render_prompt ~now =
    Masc.Keeper_memory_os_recall.render_if_enabled
      ~memory_search_available:false
      ~config
      ~meta
      ~keepers_dir
      ~keeper_id:meta.name
      ~now
      ()
    |> Option.value ~default:""
  in
  let render_at ~now =
    let prompt = render_prompt ~now in
    match List.rev (String.split_on_char '\n' prompt) with
    | reference :: _ ->
      (match Yojson.Safe.from_string reference with
       | json ->
         (match Tool_output.normalized_artifact_ref_of_json json with
          | Tool_output.Decoded_normalized_artifact_ref artifact ->
            (match Tool_blob_store.fetch
               (Tool_blob_store.create ~base_path:config.base_path)
               ~sha256:artifact.sha256 with
             | Ok (Some body) -> body
             | Ok None -> Alcotest.fail "recall artifact is missing"
             | Error error -> Alcotest.fail (Tool_blob_store.fetch_error_to_string error))
          | _ -> prompt)
       | exception Yojson.Json_error _ -> prompt)
    | [] -> prompt
  in
  let render () = render_at ~now:(Time_compat.now ()) in
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
           ; "source", `String "current"
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
       (string_field "source_sha256" matched);
     Alcotest.(check string) "source match shows when the claim was bound"
       (match Masc.Keeper_memory_source_current.read_for_keepers_dir
                ~keepers_dir ~keeper_id:meta.name with
        | Ok (Some { Masc.Keeper_memory_source_current.facts = [ stored ]; _ }) ->
          Masc_domain.iso8601_of_unix_seconds stored.first_seen
        | Ok _ -> Alcotest.fail "expected one stored source-bound fact"
        | Error detail -> Alcotest.fail detail)
       (string_field "first_seen" matched);
     Alcotest.(check bool) "a file-bound claim has no re-observation time" true
       (Option.is_none (List.assoc_opt "last_seen" fields))
   | _ -> Alcotest.fail "expected one source-bound memory match");
  let first_prompt = render () in
  let index_prompt = render_prompt ~now:(Time_compat.now ()) in
  Alcotest.(check bool) "stored claim is not copied into the model prompt" false
    (contains ~needle:"deployment region is us-west-1" index_prompt);
  Alcotest.(check bool) "complete memory is reachable through a paged reader" true
    (contains ~needle:"keeper_artifact_read" index_prompt);
  let no_reader = Masc.Keeper_memory_os_recall.render_if_enabled
    ~artifact_reader_available:false ~config ~meta ~keepers_dir
    ~keeper_id:meta.name ~now:(Time_compat.now ()) ()
    |> Option.value ~default:"" in
  Alcotest.(check bool) "search remains available without an artifact reader" true
    (contains ~needle:"keeper_memory_search" no_reader);
  Alcotest.(check bool) "missing reader does not fall back to full injection" false
    (contains ~needle:"deployment region is us-west-1" no_reader);
  let no_tools = Masc.Keeper_memory_os_recall.render_if_enabled
    ~artifact_reader_available:false ~memory_search_available:false
    ~config ~meta ~keepers_dir ~keeper_id:meta.name ~now:(Time_compat.now ()) ()
    |> Option.value ~default:"" in
  Alcotest.(check bool) "a tool-less runtime does not bulk-inject its snapshot" false
    (contains ~needle:"deployment region is us-west-1" no_tools);
  Alcotest.(check bool) "a tool-less runtime is not directed to absent tools" false
    (contains ~needle:"keeper_memory_search" no_tools
     || contains ~needle:"keeper_artifact_read" no_tools);
  Alcotest.(check bool)
    "unchanged source claim reaches recall"
    true
    (contains ~needle:"deployment region is us-west-1" first_prompt);
  Alcotest.(check bool)
    "source digest is visible"
    true
    (contains ~needle:"source_sha256=sha256:" first_prompt);
  Alcotest.(check string)
    "unchanged memory renders the same block at a later clock"
    first_prompt
    (render_at ~now:(Time_compat.now () +. 3600.0));
  with_env "MASC_KEEPER_MEMORY_OS_RECALL" "0" (fun () ->
    let disabled = render () in
    Alcotest.(check bool) "disabled recall suspends prior facts explicitly" true
      (contains ~needle:"Recall is disabled" disabled);
    Alcotest.(check string) "disabled state is stable" disabled (render ()));
  Alcotest.(check string) "re-enabling restores exact prior block" first_prompt (render ());
  let source_snapshot_path = Masc.Keeper_memory_source_current.path_for_keepers_dir
    ~keepers_dir ~keeper_id:meta.name in
  let saved_source_snapshot = Fs_compat.load_file source_snapshot_path in
  let source_before = match Masc.Keeper_memory_source_current.read_for_keepers_dir
      ~keepers_dir ~keeper_id:meta.name with
    | Ok (Some snapshot) -> snapshot
    | Ok None -> Alcotest.fail "source snapshot missing"
    | Error detail -> Alcotest.fail detail in
  let recommitted_source = { source_before with revision = source_before.revision + 1;
    updated_at = source_before.updated_at +. 3600.0 } in
  Fs_compat.save_file source_snapshot_path
    (Yojson.Safe.to_string (Masc.Keeper_memory_source_current.to_json recommitted_source));
  Alcotest.(check string) "source commit metadata does not replay unchanged facts"
    first_prompt (render ());
  Fs_compat.save_file source_snapshot_path "{ not json";
  let source_unavailable = render () in
  Alcotest.(check bool) "source-store failure explicitly marks uncertainty" true
    (contains ~needle:"Source-bound memory is unavailable" source_unavailable);
  Alcotest.(check string) "source-store failure is stable" source_unavailable (render ());
  Fs_compat.save_file source_snapshot_path saved_source_snapshot;
  Alcotest.(check string) "source recovery restores the exact prior block" first_prompt (render ());
  let ordinary_snapshot_path = Current.path_for_keepers_dir ~keepers_dir ~keeper_id:meta.name in
  Fs_compat.save_file ordinary_snapshot_path "{ not json";
  let ordinary_unavailable = render () in
  Alcotest.(check bool) "ordinary failure is not rendered as empty" true
    (contains ~needle:"Ordinary memory is unavailable" ordinary_unavailable);
  Alcotest.(check bool) "readable source facts survive ordinary failure" true
    (contains ~needle:"deployment region is us-west-1" ordinary_unavailable);
  Sys.remove ordinary_snapshot_path;
  Alcotest.(check string) "ordinary absence recovery restores the prior block" first_prompt (render ());
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
  let without_reader_rendered = Masc.Keeper_memory_os_recall.render_if_enabled_with_delivered
    ~artifact_reader_available:false ~config ~meta ~keepers_dir
    ~keeper_id:meta.name ~now:(Time_compat.now ()) () |> Option.get in
  let without_reader = without_reader_rendered.text in
  Alcotest.(check bool) "search notice reports pending invalidations and delivers invalidated source" true
    (contains ~needle:"1 pending invalidations" without_reader
     && contains ~needle:source_path without_reader
     && contains ~needle:"reason=source_changed" without_reader);
  Alcotest.(check int) "search notice records exact delivered invalidations without retiring pre-commit" 1
    (List.length without_reader_rendered.delivered_invalidations);
  let blob_root = Tool_blob_store.root_dir
      (Tool_blob_store.create ~base_path) in
  let saved_blob_root = blob_root ^ ".saved" in
  Sys.rename blob_root saved_blob_root;
  Fs_compat.save_file blob_root "not a directory";
  Fun.protect ~finally:(fun () -> Sys.remove blob_root; Sys.rename saved_blob_root blob_root)
    (fun () ->
      let failed_publication = render_prompt ~now:(Time_compat.now ()) in
      Alcotest.(check bool) "publication failure does not report source-store failure" false
        (contains ~needle:"Source-bound memory is unavailable" failed_publication);
      Alcotest.(check bool) "publication failure retains the invalidation" true
        (contains ~needle:"reason=source_changed" failed_publication);
      Alcotest.(check bool) "artifact-only failure does not offer absent search" false
        (contains ~needle:"keeper_memory_search" failed_publication));
  Alcotest.(check string)
    "a retained invalidation renders the same block at a later clock"
    invalidated_prompt
    (render_at ~now:(Time_compat.now () +. 3600.0));
  let stale_search =
    Runtime.keeper_memory_search_json
      ~config
      ~meta
      ~ctx_work:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"")
      ~args:
        (`Assoc
           [ "query", `String "us-west-1"
           ; "source", `String "current"
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
           ; "source", `String "current"
           ; "limit", `Int 10
           ])
    |> Yojson.Safe.from_string
  in
  Alcotest.(check (list string))
    "memory search sees the recreated claim"
    [ "The deployment region is eu-west-1." ]
    (match_texts replacement_search)
;;

(* An endpoint-owned tree (microVM, remote) is read by running this argv on
   the endpoint. Running it here checks the shell text: the bytes, the byte
   bound, and that absence and a non-file come back as exit statuses rather
   than as stderr text to parse. *)
let run_endpoint_source ?root path ~max_bytes =
  (* The script asks [/proc/self/fd/0] which file it opened, as every
     endpoint (a Linux guest) can; a host without [/proc] skips. *)
  if not (Sys.file_exists "/proc/self/fd") then Alcotest.skip ();
  (* The root is checked against its own resolved spelling, so a temporary
     directory reached through a symlink is spelled resolved here. *)
  let root = Unix.realpath (Option.value root ~default:(Filename.dirname path)) in
  let argv =
    Masc.Keeper_memory_source_current.endpoint_source_argv
      ~confined:{ Masc.Keeper_sandbox_read_backend.root; path } ~max_bytes
  in
  let ic = Unix.open_process_args_in (List.hd argv) (Array.of_list argv) in
  let out = In_channel.input_all ic in
  (Unix.close_process_in ic, out)
;;

let test_endpoint_source_read_reports_by_exit_status () =
  with_temp_dir
  @@ fun dir ->
  let file = Filename.concat dir "source.txt" in
  Out_channel.with_open_bin file (fun oc -> output_string oc "authoritative value\n");
  let exit_of code = Unix.WEXITED code in
  let module B = Masc.Keeper_sandbox_read_backend in
  (match run_endpoint_source file ~max_bytes:64 with
   | Unix.WEXITED 0, out -> Alcotest.(check string) "file bytes" "authoritative value\n" out
   | _, out -> Alcotest.fail ("file read failed: " ^ out));
  (match run_endpoint_source file ~max_bytes:5 with
   | Unix.WEXITED 0, out -> Alcotest.(check string) "byte bound" "autho" out
   | _, out -> Alcotest.fail ("bounded read failed: " ^ out));
  Alcotest.(check bool) "missing path exits with the missing status" true
    (fst (run_endpoint_source (Filename.concat dir "absent.txt") ~max_bytes:64)
     = exit_of (B.confined_open_exit B.Path_missing));
  Alcotest.(check bool) "a directory exits with the not-regular status" true
    (fst (run_endpoint_source ~root:dir dir ~max_bytes:64)
     = exit_of (B.confined_open_exit B.Not_a_regular_file));
  (* #35934: a link inside the tree to a file outside it is not read. *)
  let outside = Filename.temp_file "endpoint-source-outside-" ".txt" in
  Fun.protect ~finally:(fun () -> Sys.remove outside) (fun () ->
    Out_channel.with_open_bin outside (fun oc -> output_string oc "outside-secret\n");
    let link = Filename.concat dir "link-out" in
    Unix.symlink outside link;
    let status, out = run_endpoint_source ~root:dir link ~max_bytes:64 in
    Alcotest.(check bool) "a link out of the tree exits with the outside-root status" true
      (status = exit_of (B.confined_open_exit B.Outside_root));
    Alcotest.(check string) "no outside byte" "" out);
  if Unix.geteuid () <> 0
  then (
    let unreadable = Filename.concat dir "unreadable.txt" in
    Out_channel.with_open_bin unreadable (fun oc -> output_string oc "hidden\n");
    Unix.chmod unreadable 0o000;
    let status =
      Fun.protect
        ~finally:(fun () -> Unix.chmod unreadable 0o600)
        (fun () -> fst (run_endpoint_source unreadable ~max_bytes:64))
    in
    Alcotest.(check bool) "an unreadable file exits with the unreadable status" true
      (status = exit_of (B.confined_open_exit B.Open_failed)))
;;

(* A source the store cannot read this time is not an answer about the
   source. The fact stays, nothing is invalidated, and the recall is told it
   was not re-read. A permission-denied host file is Source_io_failed. *)
let test_unreadable_source_keeps_its_fact_marked_unverified () =
  if Unix.geteuid () = 0 then Alcotest.skip ();
  with_temp_dir
  @@ fun base_path ->
  let module Source = Masc.Keeper_memory_source_current in
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "source-unreadable" in
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path
  in
  let sandbox_root = Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let source_path = "source.txt" in
  let host_path = Filename.concat sandbox_root source_path in
  Fs_compat.mkdir_p sandbox_root;
  (match Fs_compat.save_file_atomic host_path "value\n" with
   | Ok () -> ()
   | Error detail -> Alcotest.fail detail);
  (match
     Source.upsert_file_fact ~ordinary_facts:(ordinary_facts_for ~keepers_dir ~keeper_id:meta.name)
       ~config ~meta ~keepers_dir ~now:100.0 ~claim:"the value is set" ~source_path ()
   with
   | Ok _ -> ()
   | Error (Source.Source_read_failed failure) ->
     Alcotest.fail (Source.source_read_failure_to_string failure)
   | Error (Source.Store_write_failed detail) -> Alcotest.fail detail);
  Unix.chmod host_path 0o000;
  let revalidated =
    Fun.protect
      ~finally:(fun () -> Unix.chmod host_path 0o600)
      (fun () -> Source.revalidate ~config ~meta ~keepers_dir ~now:200.0 ())
  in
  match revalidated with
  | Error detail -> Alcotest.fail detail
  | Ok projection ->
    Alcotest.(check int) "the fact is kept" 1 (List.length projection.Source.facts);
    Alcotest.(check int)
      "nothing is invalidated" 0 (List.length projection.Source.invalidations);
    Alcotest.(check (list string))
      "the recall is told it was not re-read"
      [ source_path ]
      projection.Source.unverified_paths
;;

(* One file that cannot be read says nothing about the other sources. The
   pass goes on: the unreadable fact is kept unverified, the source that
   changed on disk after it is read and invalidated, and the unchanged one is
   re-verified. *)
let test_one_unreadable_source_does_not_stop_the_pass () =
  if Unix.geteuid () = 0 then Alcotest.skip ();
  with_temp_dir
  @@ fun base_path ->
  let module Source = Masc.Keeper_memory_source_current in
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "source-unreadable-pass" in
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path
  in
  let sandbox_root = Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta in
  Fs_compat.mkdir_p sandbox_root;
  let write_source path content =
    match Fs_compat.save_file_atomic (Filename.concat sandbox_root path) content with
    | Ok () -> ()
    | Error detail -> Alcotest.fail detail
  in
  let record_fact path =
    match
      Source.upsert_file_fact ~ordinary_facts:(ordinary_facts_for ~keepers_dir ~keeper_id:meta.name)
        ~config ~meta ~keepers_dir ~now:100.0 ~claim:("claim about " ^ path)
        ~source_path:path ()
    with
    | Ok _ -> ()
    | Error (Source.Source_read_failed failure) ->
      Alcotest.fail (Source.source_read_failure_to_string failure)
    | Error (Source.Store_write_failed detail) -> Alcotest.fail detail
  in
  let unreadable = "unreadable.txt" in
  let changed = "changed.txt" in
  let unchanged = "unchanged.txt" in
  List.iter
    (fun path ->
       write_source path "value\n";
       record_fact path)
    [ unreadable; changed; unchanged ];
  write_source changed "another value\n";
  let unreadable_host = Filename.concat sandbox_root unreadable in
  Unix.chmod unreadable_host 0o000;
  let revalidated =
    Fun.protect
      ~finally:(fun () -> Unix.chmod unreadable_host 0o600)
      (fun () ->
        let prompt = Masc.Keeper_memory_os_recall.render_if_enabled
            ~memory_search_available:false ~config ~meta ~keepers_dir ~keeper_id:meta.name ~now:200.0 () |> Option.get in
        let reference = List.hd (List.rev (String.split_on_char '\n' prompt))
          |> Yojson.Safe.from_string in
        let body = match Tool_output.normalized_artifact_ref_of_json reference with
          | Tool_output.Decoded_normalized_artifact_ref artifact ->
            let execution, page = Masc.Keeper_artifact_read.handle_with_page
                ~base_path ~args:(`Assoc ["sha256", `String artifact.sha256]) in
            (match page with
             | Some page ->
               Alcotest.(check bool) "reader returns the whole small fixture" true page.eof;
               Alcotest.(check bool) "reader returns text" true
                 (page.encoding = Masc.Keeper_artifact_read.Utf_8);
               page.content
             | None -> Alcotest.fail execution.Masc.Keeper_tool_execution.raw_output)
          | _ -> Alcotest.fail "expected recall artifact" in
        Alcotest.(check bool) "unreadable claim is absent from the complete artifact" false
          (contains ~needle:("claim about " ^ unreadable) body);
        Alcotest.(check bool) "verified claim survives alongside deferred source" true
          (contains ~needle:("claim about " ^ unchanged) body);
        Alcotest.(check bool) "artifact retains deferred identity and invalidation" true
          (contains ~needle:"reason=source_unreadable_this_turn" body
           && contains ~needle:unreadable body
           && contains ~needle:"reason=source_changed" body);
        let inline = Masc.Keeper_memory_os_recall.render_if_enabled
            ~artifact_reader_available:false ~memory_search_available:false
            ~config ~meta ~keepers_dir ~keeper_id:meta.name ~now:200.0 () |> Option.get in
        Alcotest.(check bool) "tool-less fallback also withholds unreadable claim" false
          (contains ~needle:("claim about " ^ unreadable) inline);
        Alcotest.(check bool) "tool-less fallback does not bulk-inject verified facts" false
          (contains ~needle:("claim about " ^ unchanged) inline);
        let search = Runtime.keeper_memory_search_json ~config ~meta
            ~ctx_work:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"")
            ~args:(`Assoc ["query", `String "claim about";
                          "source", `String "current"; "limit", `Int 10])
            |> Yojson.Safe.from_string in
        Alcotest.(check (list string)) "search returns only revalidated source claims"
          ["claim about " ^ unchanged] (match_texts search);
        Alcotest.(check string) "partial search reports incomplete verification" "incomplete"
          (string_field "status" (json_field "source_verification" search));
        List.iter (fun scope ->
          let result = Runtime.keeper_memory_search_json ~config ~meta
              ~ctx_work:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"")
              ~args:(`Assoc ["query", `String unreadable;
                            "source", `String scope; "limit", `Int 10])
              |> Yojson.Safe.from_string in
          Alcotest.(check (list string)) "unverified-only search supplies no claim" []
            (match_texts result);
          (* The producer either asserts no_match = true or omits the key
             (keeper_tool_memory_runtime.ml); it never writes null, and
             json_field fails on an absent key. A non-definitive miss is the
             absent key. *)
          Alcotest.(check bool) "unverified-only search is not a definitive miss" false
            (match result with
             | `Assoc fields -> List.mem_assoc "no_match" fields
             | _ -> Alcotest.fail "memory search result must be an object");
          Alcotest.(check string) "current and all expose incomplete verification" "incomplete"
            (string_field "status" (json_field "source_verification" result));
          Alcotest.(check bool) "deferred identity does not leak withheld claim" false
            (contains ~needle:("claim about " ^ unreadable) (Yojson.Safe.to_string result)))
          ["current"; "all"];
        let unrelated = Runtime.keeper_memory_search_json ~config ~meta
            ~ctx_work:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"")
            ~args:(`Assoc ["query", `String "no matching astronomy"; "limit", `Int 10])
            |> Yojson.Safe.from_string in
        (* source_verification is written only when some selected source was
           deferred (keeper_tool_memory_runtime.ml, [] -> []); a complete
           lookup omits the key, and json_field fails on an absent key. *)
        Alcotest.(check bool) "unselected unreadable sources do not make a lookup incomplete" true
          ((match unrelated with
            | `Assoc fields -> not (List.mem_assoc "source_verification" fields)
            | _ -> Alcotest.fail "memory search result must be an object")
           && json_field "no_match" unrelated = `Bool true);
        Source.revalidate ~config ~meta ~keepers_dir ~now:200.0 ())
  in
  match revalidated with
  | Error detail -> Alcotest.fail detail
  | Ok projection ->
    Alcotest.(check (list string))
      "the unreadable and the unchanged facts are kept"
      [ unreadable; unchanged ]
      (List.map (fun (fact : Source.fact) -> fact.source.path) projection.Source.facts);
    Alcotest.(check (list string))
      "the changed source after the unreadable one is still read and invalidated"
      [ changed ]
      (List.map
         (fun (invalidation : Source.invalidation) -> invalidation.source_path)
         projection.Source.invalidations);
    Alcotest.(check (list string))
      "only the unreadable fact is unverified"
      [ unreadable ]
      projection.Source.unverified_paths
;;

(* What an endpoint run says about the source. A run that reached none of
   the command's declared exits is the endpoint not answering, which stops
   the revalidation pass; an unreadable file is a declared exit and is about
   that file only. The stop itself has no seam here: an endpoint that does
   not answer cannot be produced in this test without a new test hook. *)
let test_endpoint_source_outcome_separates_endpoint_from_file () =
  let module S = Masc.Keeper_memory_source_current in
  let module B = Masc.Keeper_sandbox_read_backend in
  let describe = function
    | Ok content -> "ok:" ^ content
    | Error (S.Source_endpoint_unanswered _) -> "endpoint_unanswered"
    | Error (S.Source_io_failed _) -> "file_unreadable"
    | Error S.Source_missing -> "missing"
    | Error S.Source_not_a_regular_file -> "not_regular"
    | Error (S.Source_over_limit _) -> "over_limit"
    | Error (S.Source_too_large _) -> "too_large"
    | Error (S.Source_path_rejected _) -> "path_rejected"
  in
  let check label expected outcome =
    Alcotest.(check string) label expected (describe (S.endpoint_source_read_of_outcome outcome))
  in
  (* Error texts in the shape Keeper_sandbox_read_backend's
     classify_read_outcome_with_limit gives them; the mapping reads only the
     Error case, never the text. *)
  check "a transport failure is the endpoint" "endpoint_unanswered"
    (Error "microvm_remote_read_transport_failed: endpoint=guest reason=exec failed stderr=");
  check "a signalled run is the endpoint" "endpoint_unanswered"
    (Error "microvm_remote_read_signaled: endpoint=guest signal=9 stderr=");
  check "an undeclared exit (no head on the endpoint) is the endpoint" "endpoint_unanswered"
    (Error "microvm_remote_read_failed: endpoint=guest exit=127 stderr=head: not found");
  let exit_of refusal = Ok (Unix.WEXITED (B.confined_open_exit refusal), "") in
  check "the unreadable exit is the file" "file_unreadable" (exit_of B.Open_failed);
  check "the missing exit" "missing" (exit_of B.Path_missing);
  check "the not-regular exit" "not_regular" (exit_of B.Not_a_regular_file);
  check "the outside-root exit rejects the path" "path_rejected" (exit_of B.Outside_root);
  check "an unresolvable open is the endpoint" "endpoint_unanswered"
    (exit_of B.Opened_file_unresolved);
  check "a moved sandbox root rejects the path" "path_rejected" (exit_of B.Root_moved);
  check "exit 0 carries the bytes" "ok:value\n" (Ok (Unix.WEXITED 0, "value\n"))
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
    write_tool
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
      Masc.Keeper_memory_source_current.upsert_file_fact ~ordinary_facts:(ordinary_facts_for ~keepers_dir ~keeper_id:meta.name)
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
    write_tool
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

let with_history_search ~checkpoint_texts ~current_texts check =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "history-search" in
  let user text =
    Agent_core.Types.make_message ~role:Agent_core.Types.User [ Agent_core.Types.Text text ]
  in
  let persist trace texts =
    let session =
      Masc.Keeper_context_runtime.create_session
        ~session_id:trace
        ~base_dir:(Masc.Keeper_types_support.session_base_dir_ config)
    in
    List.iteri
      (fun index text ->
         let turn_ref = Ids.Turn_ref.make ~trace_id:trace ~absolute_turn:(index + 1) in
         Masc.Keeper_context_runtime.persist_message
           ~keeper_name:trace ~turn_ref ~source:Masc.Keeper_types_support.Direct_user session (user text);
         Masc.Keeper_context_runtime.persist_message
           ~keeper_name:trace ~turn_ref ~source:Masc.Keeper_types_support.Direct_assistant session
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
  with_history_search ~checkpoint_texts:[ checkpoint_text ]
    ~current_texts:[ current_text ]
  @@ fun search ->
  Alcotest.(check (list string))
    "different messages from both stores survive a shared prefix"
    (List.sort String.compare [ checkpoint_text; current_text ])
    (List.sort String.compare (search "warehouse"));
  Alcotest.(check (list string))
    "current history remains searchable by its distinct ending"
    [ current_text ] (search "current-west")
;;

let test_history_search_deduplicates_identical_messages () =
  let text = history_search_prefix ^ "shared-endpoint" in
  with_history_search ~checkpoint_texts:[ text ] ~current_texts:[ text ]
  @@ fun search ->
  Alcotest.(check (list string))
    "the same complete message appears once across stores"
    [ text ] (search "shared-endpoint")
;;

let test_history_search_excludes_runtime_context () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "history-provenance" in
  let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  let user ?(origin=Agent_core.Types.Conversation) ~metadata text =
    Agent_core.Types.make_message ~origin ~role:Agent_core.Types.User ~metadata
      [ Agent_core.Types.Text text ]
  in
  let carriers location =
    List.map (fun origin -> user ~origin ~metadata:[]
      ("history-provenance runtime-context-only-sentinel " ^ location))
      Agent_core.Types.[System_context; Historical_system_context;
        Recovery_instruction; Tool_result_followup; Agent_instruction]
  in
  let ordinary location =
    user ~metadata:[ "unrelated", `String "preserve user text" ]
      ("history-provenance ordinary " ^ location)
  in
  let ctx_work =
    List.fold_left Masc.Keeper_context_runtime.append
      (Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"")
      (ordinary "checkpoint" :: carriers "checkpoint")
  in
  let session =
    Masc.Keeper_context_runtime.create_session ~session_id:trace_id
      ~base_dir:(Masc.Keeper_types_support.session_base_dir_ config)
  in
  List.iteri
    (fun index message ->
       Masc.Keeper_context_runtime.persist_message ~keeper_name:meta.name
         ~turn_ref:(Ids.Turn_ref.make ~trace_id ~absolute_turn:(index + 1))
         ~source:Masc.Keeper_types_support.Direct_user session message)
    (ordinary "disk" :: carriers "disk");
  let malformed_metadata =
    match Masc.Keeper_context_core.message_to_json
            (user ~metadata:[] "history-provenance runtime-context-only-sentinel malformed") with
    | `Assoc fields -> `Assoc (("metadata", `List []) :: fields)
    | _ -> Alcotest.fail "message serializer returned a non-object"
  in
  Out_channel.with_open_gen [ Open_wronly; Open_append ] 0o600
    (Masc.Keeper_types_support.keeper_history_path config trace_id)
    (fun output ->
       List.iter (fun json -> output_string output (Yojson.Safe.to_string json ^ "\n"))
         (malformed_metadata :: List.map (fun origin ->
           match Masc.Keeper_context_core.message_to_json (user ~metadata:[] "invalid stored origin") with
           | `Assoc fields -> `Assoc (("origin", origin) :: List.remove_assoc "origin" fields)
           | _ -> Alcotest.fail "message serializer returned a non-object")
           [`String "unknown"; `Null]));
  List.iter
    (fun source ->
       let search query =
         Runtime.keeper_memory_search_json ~config ~meta ~ctx_work
           ~args:(`Assoc [ "source", `String source; "query", `String query ])
         |> Yojson.Safe.from_string
       in
       let result = search "history-provenance" in
       Alcotest.(check (list string))
         "only user text is searchable from checkpoint and disk"
         [ "history-provenance ordinary checkpoint"; "history-provenance ordinary disk" ]
         (List.sort String.compare (match_texts result));
       Alcotest.(check int) "invalid provenance and malformed metadata are reported" 3
         (int_field "unreadable_rows" (json_field "history_read_errors" result));
       Alcotest.(check (list string)) "context alone cannot become a history match" []
         (match_texts (search "runtime-context-only-sentinel")))
    [ "history"; "all" ]
;;

let history_search_noise count =
  List.init count (fun index -> Printf.sprintf "Routine deployment note %d" index)
;;

let check_retained_history_match ~checkpoint_texts ~current_texts () =
  with_history_search ~checkpoint_texts ~current_texts
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
  with_history_search ~checkpoint_texts:[]
    ~current_texts:(exact :: fragments)
  @@ fun search ->
  Alcotest.(check (list string))
    "a retained complete-query match outranks newer fragment matches"
    [ exact ]
    (search ~limit:1 "alpha tuesday")
;;

let test_history_search_limits_distinct_matches () =
  with_history_search ~checkpoint_texts:[]
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
  @@ fun search ->
  Alcotest.(check (list string)) "each source is newest-first, with exact cross-source duplicates removed"
    [ "amber checkpoint newer"; "amber checkpoint older"
    ; "amber current newer"; "amber current older"
    ]
    (search ~limit:4 "amber");
  Alcotest.(check (list string)) "the caller limit applies to the selected result order"
    [ "amber checkpoint newer"; "amber checkpoint older"; "amber current newer" ]
    (search ~limit:3 "amber");
  Alcotest.(check (list string))
    "history still needs every term: one shared term is not a match"
    []
    (search "amber gamma")
;;

let test_history_search_reports_read_errors ~malformed () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "history-read-errors" in
  let current_trace = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  let amber = Agent_core.Types.make_message ~role:Agent_core.Types.User
      [ Agent_core.Types.Text "amber database" ] in
  let session = Masc.Keeper_context_runtime.create_session
      ~session_id:current_trace ~base_dir:(Masc.Keeper_types_support.session_base_dir_ config) in
  Masc.Keeper_context_runtime.persist_message
    ~keeper_name:meta.name
    ~turn_ref:(Ids.Turn_ref.make ~trace_id:current_trace ~absolute_turn:1)
    ~source:Masc.Keeper_types_support.Direct_user session amber;
  let path = Masc.Keeper_types_support.keeper_history_path config current_trace in
  if malformed then
    Out_channel.with_open_gen [ Open_wronly; Open_append ] 0o600 path
      (fun output -> output_string output "{invalid JSON}\n")
  else (Sys.remove path; Unix.mkdir path 0o700);
  (* The working context keeps a readable copy, so the incomplete History read
     must still surface it alongside the reported read error. *)
  let ctx_work =
    Masc.Keeper_context_runtime.append
      (Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"")
      amber
  in
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

let test_short_acronym_search_does_not_select_word_interiors () =
  with_temp_dir @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "short-acronym-search" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let noise = ["source revalidation"; "SRC policy"; "city notes"] in
  let useful = ["RC는 보류한다"; "RC-12 release"; "CI가 끝났다"] in
  replace_current_facts ~keepers_dir ~keeper_id:meta.name
    (List.map fact (noise @ useful));
  let ctx_work = List.fold_left (fun context text ->
    Masc.Keeper_context_runtime.append context
      (Agent_core.Types.make_message ~role:Agent_core.Types.User [Agent_core.Types.Text text]))
      (Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"") (noise @ useful) in
  List.iter (fun source ->
    let search query = Runtime.keeper_memory_search_json ~config ~meta ~ctx_work
      ~args:(`Assoc ["query", `String query; "source", `String source; "limit", `Int 10])
      |> Yojson.Safe.from_string |> match_texts in
    let rc = search "RC" in
    Alcotest.(check bool) (source ^ " finds Korean suffixed acronym") true
      (List.mem "RC는 보류한다" rc);
    Alcotest.(check bool) (source ^ " finds punctuated release identifier") true
      (List.mem "RC-12 release" rc);
    List.iter (fun unrelated ->
      Alcotest.(check bool) (source ^ " excludes " ^ unrelated) false (List.mem unrelated rc)) noise;
    Alcotest.(check bool) (source ^ " CI excludes city") false (List.mem "city notes" (search "CI")))
    ["current"; "history"; "all"]
;;

let test_search_keeps_exact_matches_in_store_order () =
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
           ; "source", `String "current"
           ; "limit", `Int 10
           ])
    |> Yojson.Safe.from_string
  in
  Alcotest.(check (list string))
    "complete-query matches keep store order, and a claim holding one term follows"
    [ first_match.claim; newer_match.claim; "alpha only" ]
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
      (string_field "kind" (json_field "basis" first));
    Alcotest.(check string) "match shows when the claim entered memory"
      (Masc_domain.iso8601_of_unix_seconds first_match.first_seen)
      (string_field "first_seen" first);
    Alcotest.(check string) "match shows when the claim was last observed again"
      (Masc_domain.iso8601_of_unix_seconds first_match.last_seen)
      (string_field "last_seen" first)
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
      write_tool
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
             ; "source", `String "current"
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
      (int_field "memory_facts_total" status);
    Alcotest.(check string)
      "context status leaves repository checkouts uninspected"
      "not_inspected"
      Yojson.Safe.Util.(
        status
        |> member "sandbox_live"
        |> member "repository_checkouts"
        |> member "state"
        |> to_string))
;;

(* The source parser sits behind Safe_ops.json_string, which returns its
   default for both an absent key and a key holding a non-string. Before the
   fix {"source": ["current"]} reached Current while {"source": "currnt"} was
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
    (Runtime.memory_search_source_of_string_opt "currnt" = None)
;;

let test_source_parser_rejects_removed_memory_alias () =
  Alcotest.(check bool)
    "the ambiguous memory alias is a hard-cut rejection"
    true
    (Runtime.memory_search_source_of_string_opt "memory" = None)
;;

let test_source_parser_rejects_json_rendering_of_a_non_string () =
  Alcotest.(check bool)
    "a rendered JSON array is not a source"
    true
    (Runtime.memory_search_source_of_string_opt
       (Yojson.Safe.to_string (`List [ `String "current" ]))
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

(* A Keeper's write that supersedes [old] with [claim]. The commit log keeps
   the fact that left and names the claim that took its place, which is what
   source=absorbed reads. *)
let supersede_tool ~config ~meta ~old claim =
  let response =
    (write_tool ~config ~meta
       ~args:(`Assoc [ "content", `String claim; "supersedes", `String old ]))
      .Masc.Keeper_tool_execution.raw_output
    |> Yojson.Safe.from_string
  in
  if json_field "ok" response <> `Bool true
  then Alcotest.failf "the superseding write was refused: %s" (Yojson.Safe.to_string response)
;;

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
      ~args:(`Assoc [ "query", `String "anything"; "source", `String "current" ])
      ()
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

(* A keeper asks in several words, and a claim rarely holds them as one run of
   text. A claim answers when it holds the whole query, or any word of it.
   The whole-query answers come first in store order, so a search the
   substring rule answered is still answered the same way at its head; the
   rest are ranked by BM25, so a claim holding every word comes before one
   holding a single word. The absorbed facts follow the same rule, so there
   too the kind of match comes before the order they left in. *)
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
  replace_current_facts
    ~keepers_dir
    ~keeper_id:meta.name
    [ apart; together; other; retired; retired_later ];
  (* [retired] leaves first, so it is first among the absorbed facts. The
     second write supersedes into the claim the first one wrote. *)
  let merged = "alpha deploys on a fixed weekday" in
  supersede_tool ~config ~meta ~old:(id retired) merged;
  supersede_tool ~config ~meta ~old:(id retired_later) merged;
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
    "the claims holding the whole query, current then absorbed, then the ones \
     holding both words apart, then the ones holding one"
    [ "alpha tuesday checklist lives in the wiki"
    ; "the alpha tuesday window moved once"
    ; "the alpha service deploys every tuesday"
    ; "tuesday was chosen for alpha after the outage"
    ; "beta ships on tuesday"
    ; "alpha deploys on a fixed weekday"
    ]
    (texts (search ~source:"all" "alpha tuesday"));
  Alcotest.(check (list string))
    "what the substring rule alone returned is the head of the result"
    [ "alpha tuesday checklist lives in the wiki" ]
    (texts (search ~limit:1 ~source:"all" "alpha tuesday"));
  Alcotest.(check (list string))
    "word order does not matter: claims holding both words come before claims \
     holding one"
    [ "the alpha tuesday window moved once"
    ; "the alpha service deploys every tuesday"
    ; "alpha tuesday checklist lives in the wiki"
    ; "tuesday was chosen for alpha after the outage"
    ; "beta ships on tuesday"
    ; "alpha deploys on a fixed weekday"
    ]
    (texts (search ~source:"all" "tuesday alpha"));
  Alcotest.(check (list string))
    "the absorbed facts answer by the same rule: the fact holding the whole \
     query comes before the one that left earlier holding only its words"
    [ "the alpha tuesday window moved once"; "tuesday was chosen for alpha after the outage" ]
    (texts (search ~source:"absorbed" "alpha tuesday"));
  Alcotest.(check (list string))
    "and it is the fact holding only the words that the limit cuts"
    [ "the alpha tuesday window moved once" ]
    (texts (search ~limit:1 ~source:"absorbed" "alpha tuesday"));
  Alcotest.(check (list string))
    "a word no claim holds does not take away the claims holding the others"
    [ "alpha deploys on a fixed weekday"
    ; "the alpha service deploys every tuesday"
    ; "alpha tuesday checklist lives in the wiki"
    ]
    (texts (search ~source:"current" "alpha gamma"));
  let unanswered = search ~source:"current" "gamma delta" in
  Alcotest.(check (list string))
    "a query none of whose words any claim holds is unanswered"
    []
    (texts unanswered);
  Alcotest.(check bool) "and the answer says so" true
    (json_field "no_match" unanswered = `Bool true)
;;

(* [source=all] applies the match tier before the store order. A weaker current
   fact must not consume [limit] before an exact absorbed or history result.
   Complete-query results keep the current/source-bound/absorbed/history
   order; the claims after them are ranked by BM25 across the stores they came
   from (the shorter of two claims holding the same words ranks first). The
   default current search does not include either historical store. *)
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
  supersede_tool
    ~config
    ~meta
    ~old:(Masc.Keeper_memory_os_types.memory_id absorbed_exact)
    "merged weekday decision";
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
     Masc.Keeper_memory_source_current.upsert_file_fact ~ordinary_facts:(ordinary_facts_for ~keepers_dir ~keeper_id:meta.name)
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
  let search ?(source = "all") limit =
    Runtime.keeper_memory_search_json
      ~config
      ~meta
      ~ctx_work
      ~args:
        (`Assoc
           [ "query", `String "alpha tuesday"
           ; "source", `String source
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
    "word matches follow every complete-query result, ranked across stores"
    [ "absorbed alpha tuesday exact"
    ; "history alpha tuesday exact"
    ; "source alpha deploys each tuesday"
    ; "ordinary alpha deploys each tuesday"
    ]
    (search 4);
  Alcotest.(check (list string))
    "the default current search starts with the first current fragment"
    [ "ordinary alpha deploys each tuesday" ]
    (search ~source:"current" 1);
  Alcotest.(check (list string))
    "current scope contains ordinary and source-bound facts only"
    [ "ordinary alpha deploys each tuesday"
    ; "source alpha deploys each tuesday"
    ]
    (search ~source:"current" 4)
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
    [ fact "concatenate task-10 safely"
    ; fact "alpha deploys tuesday"
    ; fact "\xEC\x86\x8C\xEC\xA3\xBC\xEB\xA5\xBC \xEC\xA2\x8B\xEC\x95\x84\xED\x95\x9C\xEB\x8B\xA4" (* 소주를 좋아한다 *)
    ];
  let search query =
    Runtime.keeper_memory_search_json
      ~config
      ~meta
      ~ctx_work:(empty_ctx ())
      ~args:(`Assoc [ "query", `String query; "source", `String "current" ])
    |> Yojson.Safe.from_string
    |> match_texts
  in
  Alcotest.(check (list string))
    "ASCII fragments are substrings rather than lexical words"
    [ "concatenate task-10 safely" ]
    (search "cat task-1");
  Alcotest.(check (list string))
    "punctuation stays in a whitespace-delimited term"
    []
    (search "alpha,");
  Alcotest.(check (list string))
    "and a term that does not match leaves the others answering"
    [ "alpha deploys tuesday" ]
    (search "alpha, tuesday");
  Alcotest.(check (list string))
    "a term of three or more characters matches inside a word, so a Korean \
     suffix does not hide the claim"
    [ "\xEC\x86\x8C\xEC\xA3\xBC\xEB\xA5\xBC \xEC\xA2\x8B\xEC\x95\x84\xED\x95\x9C\xEB\x8B\xA4" ]
    (search "\xEC\x86\x8C\xEC\xA3\xBC\xEB\xA5\xBC \xEB\xA7\x88\xEC\x85\xA8\xEB\x8B\xA4" (* 소주를 마셨다 *));
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

(* The commit log is read only by source=absorbed, source=dropped and
   source=all. When it cannot be read, current still answers independently;
   all answers from the current facts and names the log it went without. *)
let test_an_unreadable_memory_log_leaves_all_its_current_facts () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "memory-log-unreadable" in
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path
  in
  replace_current_facts ~keepers_dir ~keeper_id:meta.name [ fact "gamma deploys on friday" ];
  Unix.mkdir
    (Masc.Librarian_log_store.path_for_keepers_dir ~keepers_dir ~keeper_id:meta.name)
    0o700;
  let search source =
    Runtime.keeper_memory_search_with_outcome
      ~config
      ~meta
      ~ctx_work:(empty_ctx ())
      ~args:(`Assoc [ "query", `String "deploy"; "source", `String source ])
      ()
  in
  List.iter
    (fun source ->
       let alone = search source in
       check_failure_class (source ^ " alone") Tool_result.Dependency_unavailable alone;
       Alcotest.(check string) (source ^ ": the log is named")
         "memory_log_read_failed"
         (string_field "error_kind"
            (Yojson.Safe.from_string alone.Masc.Keeper_tool_execution.raw_output)))
    [ "absorbed"; "dropped" ];
  let answered source =
    (search source).Masc.Keeper_tool_execution.raw_output |> Yojson.Safe.from_string
  in
  let default_search = answered "current" in
  (match json_field "matches" default_search with
   | `List [ matched ] ->
     Alcotest.(check string) "the current search still answers its current fact"
       "gamma deploys on friday" (string_field "text" matched)
   | _ -> Alcotest.fail "expected the one fact from the current search");
  Alcotest.(check bool) "current never touches or reports the log" true
    (match default_search with
     | `Assoc fields -> Option.is_none (List.assoc_opt "unavailable_stores" fields)
     | _ -> false);
  (match json_field "memory_writer" default_search with
   | `Assoc _ as writer ->
     Alcotest.(check string)
       "a process with no writer says the snapshot was not checked against the log"
       "none_in_process"
       (string_field "state" writer)
   | _ -> Alcotest.fail "expected the writer's state");
  let all = answered "all" in
  (match json_field "matches" all with
   | `List [ matched ] ->
     Alcotest.(check string) "the current fact is still answered"
       "gamma deploys on friday" (string_field "text" matched)
   | _ -> Alcotest.fail "expected the one current fact");
  match json_field "unavailable_stores" all with
  | `List [ store ] ->
    Alcotest.(check string) "and the missing log is named" "memory_log"
      (string_field "store" store)
  | _ -> Alcotest.fail "expected the commit log to be named unavailable"
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
  (* A directory where the snapshot file belongs: the writer's store cannot
     read it as a snapshot, whatever user the test runs as. *)
  Fs_compat.mkdir_p (Current.path_for_keepers_dir ~keepers_dir ~keeper_id:meta.name);
  let execution =
    write_tool
      ~config
      ~meta
      ~args:(make_args ~title:"" ~content:"a claim that cannot be saved")
  in
  check_failure_class "unwritable store" Tool_result.Dependency_unavailable execution;
  let response =
    execution.Masc.Keeper_tool_execution.raw_output |> Yojson.Safe.from_string
  in
  Alcotest.(check string)
    "Memory did not take the write"
    "memory_unwritable"
    (string_field "error_kind" response);
  Alcotest.(check string)
    "the writer's store stopped on a snapshot it cannot read"
    "store_stopped_memory_unreadable"
    (string_field "unwritable" response);
  Alcotest.(check bool)
    "nothing was committed"
    true
    (execution.Masc.Keeper_tool_execution.failure_effect_disposition
     = Tool_result.Proven_pre_effect);
  Alcotest.(check string)
    "the payload names the same disposition"
    (Tool_result.failure_effect_disposition_to_string Tool_result.Proven_pre_effect)
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
    (write_tool
       ~config
       ~meta
       ~args:(make_args ~title:"" ~content:""));
  check_failure_class
    "a malformed memory id is the caller's to fix"
    Tool_result.Policy_rejection
    (retract_tool
       ~config
       ~meta
       ~args:(make_retract_args ~memory_id:"not-an-id" ~reason:"incorrect"));
  check_failure_class
    "an absent fact is the state refusing"
    Tool_result.Workflow_rejection
    (retract_tool
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
    write_tool
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
  match Events.read ~keepers_dir ~keeper_id with
  | Error error -> Alcotest.fail (Events.file_read_error_to_string error)
  | Ok rows ->
    List.map (fun (index, row) ->
      match row with
      | Ok event -> event
      | Error error ->
        Alcotest.failf
          "events line %d unreadable: %s"
          index
          (Events.read_error_to_string error)) rows
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

(* Every ordinary fact a search returns is a retrieval of that fact,
   recorded with the query and the turn. A miss records nothing. The
   decision-log line names the same ids, so the two records agree, and counts
   the facts searched, so a miss can be told from an empty store. *)
let test_current_search_pages_all_matching_memory () =
  with_temp_dir @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "current-pages" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let ordinary = List.init 23 (fun index -> fact (Printf.sprintf "deployment decision %02d" index)) in
  replace_current_facts ~keepers_dir ~keeper_id:meta.name ordinary;
  let sandbox_root = Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta in
  Fs_compat.mkdir_p sandbox_root;
  List.iter (fun index ->
    let source_path = Printf.sprintf "decision-%02d.txt" index in
    Fs_compat.save_file (Filename.concat sandbox_root source_path) "original decision";
    let written = write_tool ~config ~meta
        ~args:(make_source_args ~title:""
          ~content:(Printf.sprintf "deployment source decision %02d" index) ~source_path) in
    Alcotest.(check bool) "source fact persisted" true
      (json_field "ok" (Yojson.Safe.from_string written.raw_output) = `Bool true))
    (List.init 12 Fun.id);
  let search ?cursor ?(source = "current") ?(query = "deployment") ?(limit = 10) () =
    Runtime.keeper_memory_search_json ~config ~meta
      ~ctx_work:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"")
      ~args:(`Assoc ([ "query", `String query; "source", `String source; "limit", `Int limit ]
        @ match cursor with None -> [] | Some cursor -> [ "cursor", cursor ]))
    |> Yojson.Safe.from_string in
  let first = search () in
  Alcotest.(check int) "first page respects existing page size" 10 (int_field "match_count" first);
  let cursor = json_field "next_cursor" first in
  let rec pages response =
    let matches = match_texts response in
    if json_field "truncated" response = `Bool true then
      matches @ pages (search ~cursor:(json_field "next_cursor" response) ())
    else (
      (* The last page leaves the field out; [json_field] fails on a missing
         one, so read it as optional. *)
      Alcotest.(check bool) "last page has no next cursor" true
        (Yojson.Safe.Util.member "next_cursor" response = `Null);
      matches) in
  let all = pages first in
  let source_snapshot = match Masc.Keeper_memory_source_current.read_for_keepers_dir
      ~keepers_dir ~keeper_id:meta.name with
    | Ok (Some snapshot) -> snapshot
    | _ -> Alcotest.fail "source snapshot missing" in
  Alcotest.(check (list string)) "every ordinary and source fact appears once in store order"
    (List.map (fun (f : Masc.Keeper_memory_os_types.fact) -> f.claim) ordinary
     @ List.map (fun (f : Masc.Keeper_memory_source_current.fact) -> f.claim) source_snapshot.facts)
    all;
  Alcotest.(check (list string)) "only emitted ordinary facts receive retrievals"
    (List.map Masc.Keeper_memory_os_types.memory_id ordinary)
    (List.map (fun (event : Events.event) -> event.memory_id)
       (events_for ~keepers_dir ~keeper_id:meta.name));
  let count = List.length (events_for ~keepers_dir ~keeper_id:meta.name) in
  let rejected kind response =
    Alcotest.(check string) "cursor rejection is explicit" kind (string_field "error_kind" response);
    Alcotest.(check int) "rejected cursor emits no retrieval" count
      (List.length (events_for ~keepers_dir ~keeper_id:meta.name)) in
  rejected "stale_memory_search_cursor" (search ~cursor ~query:"decision" ());
  rejected "unsupported_memory_search_cursor_scope" (search ~cursor ~source:"all" ());
  rejected "invalid_memory_search_cursor" (search ~cursor:(`String "malformed") ());
  rejected "invalid_memory_search_cursor" (search ~cursor:(`Int 10) ());
  (* The snapshot seeded above is revision 1; replacing it names that one. *)
  replace_current_facts ~expected_revision:1 ~keepers_dir ~keeper_id:meta.name
    (ordinary @ [fact "unrelated new fact changes the corpus"]);
  rejected "stale_memory_search_cursor" (search ~cursor ());
  let restart = search () in
  Alcotest.(check int) "restart after corpus change returns first page" 10 (int_field "match_count" restart);
  let source_cursor = json_field "next_cursor" restart in
  Fs_compat.save_file (Filename.concat sandbox_root "decision-00.txt") "changed source";
  let refused = Runtime.keeper_memory_search_with_outcome ~config ~meta
      ~ctx_work:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"")
      ~args:(`Assoc [ "query", `String "deployment"; "cursor", source_cursor ]) () in
  Alcotest.(check string) "source invalidation makes the old page cursor stale"
    "stale_memory_search_cursor"
    (string_field "error_kind" (Yojson.Safe.from_string refused.raw_output));
  Alcotest.(check bool) "post-revalidation refusal does not claim proven no effects" true
    (refused.failure_effect_disposition = Tool_result.Effect_outcome_unknown)
;;

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
           [ "query", `String query; "source", `String "current"; "limit", `Int 10 ])
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
          Alcotest.(check string) "the query is recorded" "alpha beta" query);
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
      (string_list_field "matched_memory_ids" miss_line);
    Alcotest.(check int) "the miss line counts no match" 0
      (int_field "match_count" miss_line);
    Alcotest.(check (list int))
      "both lines count the current facts searched"
      [ 3; 3 ]
      [ int_field "durable_candidates" hit_line; int_field "durable_candidates" miss_line ];
    Alcotest.(check bool) "the miss read every store" false
      (match json_field "read_errors" miss_line with
       | `Bool value -> value
       | _ -> Alcotest.fail "expected bool field: read_errors")
  | _ -> Alcotest.fail "expected one decision-log line per search"
;;

(* A successful retract records removal in its own journal row, which
   outlives the fact; it writes no sidecar event (#37433). A retract of an id
   no fact has records nothing. *)
let test_retract_records_a_retraction () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "retract-events" in
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path
  in
  let write () =
    (write_tool ~config ~meta ~args:(make_args ~title:"" ~content:"the deploy needs assets"))
      .Masc.Keeper_tool_execution.raw_output
    |> Yojson.Safe.from_string
  in
  let written_id = string_field "memory_id" (write ()) in
  let retract id =
    retract_tool
      ~config
      ~meta
      ~args:(make_retract_args ~memory_id:id ~reason:"superseded by the runbook")
  in
  let response =
    Yojson.Safe.from_string (retract written_id).Masc.Keeper_tool_execution.raw_output
  in
  Alcotest.(check bool) "retraction succeeds" true (json_field "ok" response = `Bool true);
  (* Every retraction the commit log holds, as the fact and why it left. *)
  let retractions () =
    List.concat_map removed_by (commit_lines ~keepers_dir ~keeper_id:meta.name)
  in
  let recorded = [ written_id, "retracted by the keeper: superseded by the runbook" ] in
  Alcotest.(check (list (pair string string)))
    "the commit line keeps the retracted fact with its reason" recorded (retractions ());
  Alcotest.(check int)
    "a retract writes no sidecar event" 0
    (List.length (events_for ~keepers_dir ~keeper_id:meta.name));
  ignore (retract (memory_id 'f'));
  Alcotest.(check (list (pair string string)))
    "a retract of an unknown id records nothing" recorded (retractions ());
  Alcotest.(check int) "the retracted fact is no longer current" 0
    (List.length (current_facts ~keepers_dir ~keeper_id:meta.name));
  let restored = write () in
  Alcotest.(check string)
    "the claim written again keeps its content identity" written_id
    (string_field "memory_id" restored);
  Alcotest.(check string)
    "and is a new fact, not the retracted one seen again" "inserted"
    (string_field "identity_disposition" restored);
  Alcotest.(check (list string))
    "it is current again" [ written_id ]
    (current_facts ~keepers_dir ~keeper_id:meta.name
     |> List.map Masc.Keeper_memory_os_types.memory_id);
  Alcotest.(check (list (pair string string)))
    "and the earlier retraction stays in the commit log" recorded (retractions ())
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
  let write () = match Source.upsert_file_fact ~ordinary_facts:(ordinary_facts_for ~keepers_dir ~keeper_id:meta.name) ~config ~meta ~keepers_dir
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
    (match Source.upsert_file_fact ~ordinary_facts:(ordinary_facts_for ~keepers_dir ~keeper_id:meta.name) ~config ~meta ~keepers_dir ~now:300.
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

let test_ordinary_commit_budget_preserves_store_on_rejection () =
  with_temp_dir @@ fun keepers_dir ->
  with_env Env_config.KeeperMemoryOs.facts_max_bytes_env_key "500" @@ fun () ->
  let keeper_id = "ordinary-budget" in
  replace_current_facts ~keepers_dir ~keeper_id [ fact "small current fact" ];
  let snapshot_path = Current.path_for_keepers_dir ~keepers_dir ~keeper_id in
  let journal_path = Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
  let before_snapshot = Fs_compat.load_file snapshot_path in
  let before_journal = Fs_compat.load_file journal_path in
  let proposed = current_facts ~keepers_dir ~keeper_id @ [ fact (String.make 600 'x') ] in
  (match
     Current.replace
       ~keepers_dir ~keeper_id ~expected_revision:(Some 1)
       ~now:(Time_compat.now ())
       ~source:{ Current.kind = Current.Librarian; trace_id = "oversize" }
       ~facts:proposed ()
   with
   | Error detail ->
     Alcotest.(check bool) "budget explains rejection" true
       (contains ~needle:"exceed commit budget" detail)
   | Ok _ -> Alcotest.fail "over-budget ordinary facts committed");
  Alcotest.(check string) "snapshot unchanged" before_snapshot
    (Fs_compat.load_file snapshot_path);
  Alcotest.(check string) "journal unchanged" before_journal
    (Fs_compat.load_file journal_path)
;;

let test_over_budget_retraction_recovers_incrementally () =
  with_temp_dir @@ fun keepers_dir ->
  let keeper_id = "retraction-budget" in
  let first = fact (String.make 300 'a') in
  let second = fact (String.make 300 'b') in
  with_env Env_config.KeeperMemoryOs.facts_max_bytes_env_key "1000" @@ fun () ->
  replace_current_facts ~keepers_dir ~keeper_id [ first; second ];
  with_env Env_config.KeeperMemoryOs.facts_max_bytes_env_key "200" @@ fun () ->
  let source = { Current.kind = Current.Explicit_write; trace_id = "retract" } in
  (match
     Current.retract_fact ~pass:Masc.Keeper_memory_commit_pass.Keeper_delete
       ~keepers_dir ~keeper_id ~now:(Time_compat.now ()) ~source
       ~memory_id:(Masc.Keeper_memory_os_types.memory_id first)
       ~reason:"less useful" ()
   with
   | Ok _ -> ()
   | Error _ -> Alcotest.fail "a reducing over-budget retraction was rejected");
  let remaining = current_facts ~keepers_dir ~keeper_id in
  Alcotest.(check int) "one fact remains" 1
    (List.length remaining);
  Alcotest.(check bool) "remaining fact is still over the reduced cap" true
    (Render.facts_payload_bytes ~ordinary_facts:remaining ~source_lines:[] > 200);
  Alcotest.(check bool) "the second fact remains" true
    (String.equal (List.hd remaining).claim second.claim);
  (match
     Current.replace
       ~keepers_dir ~keeper_id ~expected_revision:(Some 2)
       ~now:(Time_compat.now ()) ~source
       ~facts:(remaining @ [ fact "new fact" ]) ()
   with
   | Error detail ->
     Alcotest.(check bool) "growth fails for the budget" true
       (contains ~needle:"exceed commit budget" detail)
   | Ok _ -> Alcotest.fail "over-budget growth was committed");
  Alcotest.(check int) "growth left the current set alone" 1
    (List.length (current_facts ~keepers_dir ~keeper_id));
  (match
     Current.retract_fact ~pass:Masc.Keeper_memory_commit_pass.Keeper_delete
       ~keepers_dir ~keeper_id ~now:(Time_compat.now ()) ~source
       ~memory_id:(Masc.Keeper_memory_os_types.memory_id second)
       ~reason:"less useful" ()
   with
   | Ok _ -> ()
   | Error _ -> Alcotest.fail "final recovery retraction was rejected");
  Alcotest.(check int) "all facts removed" 0
    (List.length (current_facts ~keepers_dir ~keeper_id))
;;

let test_source_commit_budget_counts_ordinary_facts () =
  with_temp_dir @@ fun base_path ->
  with_env Env_config.KeeperMemoryOs.facts_max_bytes_env_key "500" @@ fun () ->
  let module Source = Masc.Keeper_memory_source_current in
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "source-aggregate-budget" in
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path
  in
  replace_current_facts ~keepers_dir ~keeper_id:meta.name
    [ fact (String.make 180 'o') ];
  let ordinary_path = Current.path_for_keepers_dir ~keepers_dir ~keeper_id:meta.name in
  let before_ordinary = Fs_compat.load_file ordinary_path in
  let sandbox_root = Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta in
  Fs_compat.mkdir_p sandbox_root;
  let source_path = "source.txt" in
  (match Fs_compat.save_file_atomic
     (Filename.concat sandbox_root source_path) "source value\n" with
   | Ok () -> ()
   | Error detail -> Alcotest.fail detail);
  (match
     Source.upsert_file_fact
       ~ordinary_facts:(ordinary_facts_for ~keepers_dir ~keeper_id:meta.name)
       ~config ~meta ~keepers_dir ~now:(Time_compat.now ())
       ~claim:(String.make 180 's') ~source_path ()
   with
   | Error (Source.Store_write_failed detail) ->
     Alcotest.(check bool) "aggregate budget explains rejection" true
       (contains ~needle:"exceed commit budget" detail)
   | Error (Source.Source_read_failed failure) ->
     Alcotest.fail (Source.source_read_failure_to_string failure)
   | Ok _ -> Alcotest.fail "over-budget combined facts committed");
  (match Source.read_for_keepers_dir ~keepers_dir ~keeper_id:meta.name with
   | Ok None -> ()
   | Ok (Some _) | Error _ -> Alcotest.fail "rejected source snapshot appeared");
  Alcotest.(check string) "ordinary snapshot unchanged" before_ordinary
    (Fs_compat.load_file ordinary_path)
;;

let test_ordinary_commit_budget_counts_source_facts () =
  with_temp_dir @@ fun base_path ->
  with_env Env_config.KeeperMemoryOs.facts_max_bytes_env_key "500" @@ fun () ->
  let module Source = Masc.Keeper_memory_source_current in
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "ordinary-aggregate-budget" in
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path
  in
  let sandbox_root = Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta in
  Fs_compat.mkdir_p sandbox_root;
  let source_path = "source.txt" in
  (match Fs_compat.save_file_atomic
     (Filename.concat sandbox_root source_path) "source value\n" with
   | Ok () -> ()
   | Error detail -> Alcotest.fail detail);
  (match
     Source.upsert_file_fact
       ~ordinary_facts:(ordinary_facts_for ~keepers_dir ~keeper_id:meta.name)
       ~config ~meta ~keepers_dir ~now:(Time_compat.now ())
       ~claim:(String.make 180 's') ~source_path ()
   with
   | Ok _ -> ()
   | Error (Source.Store_write_failed detail) -> Alcotest.fail detail
   | Error (Source.Source_read_failed failure) ->
     Alcotest.fail (Source.source_read_failure_to_string failure));
  let source_store_path = Source.path_for_keepers_dir ~keepers_dir ~keeper_id:meta.name in
  let before_source = Fs_compat.load_file source_store_path in
  (match
     Current.replace
       ~keepers_dir ~keeper_id:meta.name ~expected_revision:None
       ~now:(Time_compat.now ())
       ~source:{ Current.kind = Current.Librarian; trace_id = "oversize" }
       ~facts:[ fact (String.make 180 'o') ] ()
   with
   | Error detail ->
     Alcotest.(check bool) "aggregate budget explains rejection" true
       (contains ~needle:"exceed commit budget" detail)
   | Ok _ -> Alcotest.fail "over-budget combined facts committed");
  (match Current.read_for_keepers_dir ~keepers_dir ~keeper_id:meta.name with
   | Ok None -> ()
   | Ok (Some _) | Error _ -> Alcotest.fail "rejected ordinary snapshot appeared");
  Alcotest.(check string) "source snapshot unchanged" before_source
    (Fs_compat.load_file source_store_path)
;;

let test_source_invalidation_committed_turn_retirement () =
  with_temp_dir @@ fun base_path ->
  let module Source = Masc.Keeper_memory_source_current in
  let module Recall = Masc.Keeper_memory_os_recall in
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "invalidation-retirement" in
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path
  in
  let sandbox_root = Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta in
  Fs_compat.mkdir_p sandbox_root;
  let source_path = "deploy.env" in
  let host_path = Filename.concat sandbox_root source_path in
  let write_file content =
    match Fs_compat.save_file_atomic host_path content with
    | Ok () -> ()
    | Error detail -> Alcotest.fail detail
  in
  let upsert ~now claim =
    match
      Source.upsert_file_fact
        ~ordinary_facts:(ordinary_facts_for ~keepers_dir ~keeper_id:meta.name)
        ~config ~meta ~keepers_dir ~now ~claim ~source_path ()
    with
    | Ok _ -> ()
    | Error (Source.Store_write_failed detail) -> Alcotest.fail detail
    | Error (Source.Source_read_failed failure) ->
      Alcotest.fail (Source.source_read_failure_to_string failure)
  in
  let read_snapshot () =
    match Source.read_for_keepers_dir ~keepers_dir ~keeper_id:meta.name with
    | Ok (Some snap) -> snap
    | Ok None -> Alcotest.fail "expected source-bound snapshot"
    | Error detail -> Alcotest.fail detail
  in
  let render_demand ~now =
    match
      Recall.render_if_enabled_with_delivered
        ~memory_search_available:true ~artifact_reader_available:false
        ~config ~meta ~keepers_dir ~keeper_id:meta.name ~now ()
    with
    | Some rendered -> rendered
    | None -> Alcotest.fail "expected recall block"
  in
  (* 1. Create a source-bound fact, mutate the file, and invalidate with a
     fractional float timestamp to exercise JSON float round-trip matching. *)
  write_file "env=prod-v1\n";
  upsert ~now:1700000000.125 "Deployment env is prod-v1.";
  write_file "env=prod-v2\n";
  (match Source.revalidate ~config ~meta ~keepers_dir ~now:1700000100.1234567 () with
   | Ok projection ->
     Alcotest.(check int) "revalidation produces one invalidation" 1
       (List.length projection.invalidations)
   | Error detail -> Alcotest.fail detail);
  let snap_before = read_snapshot () in
  Alcotest.(check int) "budget_lines counts the pending invalidation" 1
    (List.length (Source.budget_lines (Some snap_before)));
  (* 2. Demand notice delivers the invalidation once without mutating disk. *)
  let delivered_turn1 = render_demand ~now:1700000200.0 in
  Alcotest.(check bool) "demand notice renders invalidated source_path" true
    (contains ~needle:"1 pending invalidations" delivered_turn1.text
     && contains ~needle:source_path delivered_turn1.text
     && contains ~needle:"reason=source_changed" delivered_turn1.text);
  Alcotest.(check int) "delivered list captures exact invalidation" 1
    (List.length delivered_turn1.delivered_invalidations);
  (* 3. Failed / uncommitted turn retains 100% of invalidations (failure_keeps_evidence). *)
  (match
     Recall.retire_after_turn_settlement
       ~keepers_dir ~keeper_id:meta.name
       ~settlement:Recall.Turn_not_committed
       ~delivered:delivered_turn1.delivered_invalidations
       ()
   with
   | Ok retired -> Alcotest.(check int) "uncommitted turn retires nothing" 0 retired
   | Error detail -> Alcotest.fail detail);
  let snap_after_fail = read_snapshot () in
  Alcotest.(check int) "revision unchanged on uncommitted turn"
    snap_before.revision snap_after_fail.revision;
  Alcotest.(check int) "invalidation retained on uncommitted turn" 1
    (List.length snap_after_fail.invalidations);
  (* 4. Crash between commit and retire self-heals on next committed turn:
     render again -> still delivered -> commit & retire -> 0 rows & shrunk budget. *)
  let delivered_turn2 = render_demand ~now:1700000300.0 in
  Alcotest.(check int) "next turn still receives unretired invalidation" 1
    (List.length delivered_turn2.delivered_invalidations);
  (match
     Recall.retire_after_turn_settlement
       ~keepers_dir ~keeper_id:meta.name
       ~settlement:Recall.Turn_committed
       ~delivered:delivered_turn2.delivered_invalidations
       ()
   with
   | Ok retired -> Alcotest.(check int) "committed turn retires delivered invalidation" 1 retired
   | Error detail -> Alcotest.fail detail);
  let snap_after_commit = read_snapshot () in
  Alcotest.(check int) "revision bumps once on retirement"
    (snap_before.revision + 1) snap_after_commit.revision;
  Alcotest.(check int) "invalidations cleared after committed turn" 0
    (List.length snap_after_commit.invalidations);
  Alcotest.(check int) "budget_lines shrinks to zero after retirement" 0
    (List.length (Source.budget_lines (Some snap_after_commit)));
  let clean_turn = render_demand ~now:1700000400.0 in
  Alcotest.(check bool) "clean demand notice reports 0 pending invalidations and omits path" true
    (contains ~needle:"0 pending invalidations" clean_turn.text
     && not (contains ~needle:source_path clean_turn.text));
  Alcotest.(check int) "clean turn delivers zero invalidations" 0
    (List.length clean_turn.delivered_invalidations);
  (* Repeat retirement of already-retired rows is a no-op with no revision bump. *)
  (match
     Source.retire_delivered_invalidations
       ~keepers_dir ~keeper_id:meta.name
       ~delivered:delivered_turn2.delivered_invalidations
       ()
   with
   | Ok retired -> Alcotest.(check int) "repeat retirement is a no-op" 0 retired
   | Error detail -> Alcotest.fail detail);
  Alcotest.(check int) "repeat retirement does not bump revision"
    snap_after_commit.revision (read_snapshot ()).revision;
  (* 5. Concurrent newer invalidation for the EXACT same source_path survives
     retirement of an earlier delivered invalidation. *)
  write_file "env=prod-v3\n";
  upsert ~now:1700000500.0 "Deployment env is prod-v3.";
  write_file "env=prod-v4\n";
  (match Source.revalidate ~config ~meta ~keepers_dir ~now:1700000600.25 () with
   | Ok _ -> ()
   | Error detail -> Alcotest.fail detail);
  let earlier_delivered = (render_demand ~now:1700000650.0).delivered_invalidations in
  Alcotest.(check int) "earlier invalidation delivered" 1 (List.length earlier_delivered);
  (* Concurrently re-bind and then remove the source file, producing a newer invalidation. *)
  upsert ~now:1700000700.0 "Deployment env is prod-v4.";
  Sys.remove host_path;
  (match Source.revalidate ~config ~meta ~keepers_dir ~now:1700000800.75 () with
   | Ok _ -> ()
   | Error detail -> Alcotest.fail detail);
  let snap_with_newer = read_snapshot () in
  (match
     Recall.retire_after_turn_settlement
       ~keepers_dir ~keeper_id:meta.name
       ~settlement:Recall.Turn_committed
       ~delivered:earlier_delivered
       ()
   with
   | Ok retired ->
     Alcotest.(check int) "stale delivered invalidation cannot retire newer invalidation" 0 retired
   | Error detail -> Alcotest.fail detail);
  let snap_after_stale_retire = read_snapshot () in
  Alcotest.(check int) "newer invalidation keeps revision untouched"
    snap_with_newer.revision snap_after_stale_retire.revision;
  (match snap_after_stale_retire.invalidations with
   | [ (inv : Source.invalidation) ] ->
     Alcotest.(check string) "same source_path survives" source_path inv.source_path;
     Alcotest.(check bool) "newer reason survives" true (inv.reason = Source.Source_unavailable)
   | _ -> Alcotest.fail "expected newer invalidation to survive");
  (* 6. Filesystem / lock exceptions during post-commit retirement are caught
     as Error rather than aborting an already-committed turn. *)
  let not_a_dir = Filename.concat base_path "not-a-directory" in
  Fs_compat.save_file not_a_dir "blocker";
  (match
     Recall.retire_after_turn_settlement
       ~keepers_dir:not_a_dir ~keeper_id:meta.name
       ~settlement:Recall.Turn_committed
       ~delivered:earlier_delivered
       ()
   with
   | Error detail ->
     Alcotest.(check bool) "caught error is non-empty" true (String.trim detail <> "")
   | Ok _ -> Alcotest.fail "non-directory keepers_dir must fail with Error")
;;

let () =
  Alcotest.run
    "keeper_memory_write"
    [ ( "commit notification"
      , [ tool_case "source writes and invalidations notify after locks" `Quick test_source_snapshot_commit_notifications ] )
    ; ( "repeat guard answer"
      , [ tool_case
            "a rewrite receipt has the same answer"
            `Quick
            test_a_rewrite_receipt_has_the_same_answer
        ] )
    ; ( "ordinary write"
      , [ tool_case
            "an ordinary write lands in current Memory"
            `Quick
            test_an_ordinary_write_lands_in_current_memory
        ] )
    ; ( "validation"
      , [ tool_case "typed validation failures" `Quick test_validation_taxonomy
        ; tool_case
            "a refused derivation names the field and what it takes"
            `Quick
            test_a_refused_derivation_names_the_field_and_what_it_takes
        ; tool_case
            "board reference validation"
            `Quick
            test_board_reference_validation
        ; tool_case
            "typed retract validation failures"
            `Quick
            test_retract_validation_taxonomy
        ; tool_case
            "runtime validation is proven pre-effect"
            `Quick
            test_invalid_write_is_proven_pre_effect
        ; tool_case
            "valid input composes the stored body"
            `Quick
            test_valid_body_composition
        ; tool_case
            "unsupported derived write is proven pre-effect"
            `Quick
            test_unsupported_derived_write_is_proven_pre_effect
        ] )
    ; ( "persistence"
      , [ tool_case
            "ordinary commit budget preserves snapshot and journal"
            `Quick
            test_ordinary_commit_budget_preserves_store_on_rejection
        ; tool_case
            "over-budget retractions recover incrementally"
            `Quick
            test_over_budget_retraction_recovers_incrementally
        ; tool_case
            "source commit budget counts ordinary facts"
            `Quick
            test_source_commit_budget_counts_ordinary_facts
        ; tool_case
            "ordinary commit budget counts source facts"
            `Quick
            test_ordinary_commit_budget_counts_source_facts
        ; tool_case
            "write comes back through recall"
            `Quick
            test_write_comes_back_through_recall
        ; tool_case
            "derived write uses exact premise receipt"
            `Quick
            test_derived_write_uses_exact_premise_receipt
        ; tool_case
            "retract cascades and journals durable reason"
            `Quick
            test_retract_cascades_through_public_tool_and_journals_reason
        ; tool_case
            "recall snapshots survive GC until history retention releases them"
            `Quick
            test_recall_artifacts_follow_history_retention
        ; tool_case "superseded recall pins keep history then permit collection" `Quick
            test_superseded_recall_pin_releases_only_after_history_retention
        ; tool_case "late recall retirement preserves same-hash publication" `Quick
            test_late_pin_retirement_preserves_new_same_artifact_publication
        ; tool_case "demand recall avoids bulk artifact and source work" `Quick
            test_demand_recall_does_not_materialize_or_verify_all_memory
        ; tool_case "same-count replacement updates notice and selective recall" `Quick
            test_same_count_replacement_updates_notice_and_demand_search
        ; tool_case "source search validates query candidates only" `Quick
            test_search_revalidates_query_sources_only
        ; tool_case "selected source replacement is not verified by an old query" `Quick
            test_selected_source_rebound_digest_stays_unverified
        ; tool_case
            "source change discards stale claim until recreation"
            `Quick
            test_source_bound_write_discards_stale_claim_and_recreates
        ; tool_case
            "committed turn retires delivered source invalidations"
            `Quick
            test_source_invalidation_committed_turn_retirement
        ; tool_case
            "source write has no recall size gate"
            `Quick
            test_source_bound_write_is_not_gated_by_recall_size
        ; tool_case
            "source rewrite renews the claim timestamp"
            `Quick
            test_source_bound_rewrite_renews_first_seen
        ; tool_case
            "invalidation rendering only shrinks payload"
            `Quick
            test_invalidation_rendering_is_monotone
        ; tool_case
            "tools isolate config BasePath from ambient decoy"
            `Quick
            test_tools_isolate_workspace_base_path_from_ambient_decoy
        ; tool_case
            "history search preserves distinct message endings"
            `Quick
            test_history_search_preserves_distinct_message_endings
        ; tool_case
            "history search deduplicates identical messages"
            `Quick
            test_history_search_deduplicates_identical_messages
        ; tool_case
            "history and all search exclude runtime context from checkpoint and disk"
            `Quick
            test_history_search_excludes_runtime_context
        ; tool_case "history search reaches retained current messages" `Quick
            (check_retained_history_match ~checkpoint_texts:[]
               ~current_texts:("Migration prerequisite: amber database" :: history_search_noise 75))
        ; tool_case "history search includes the newest current message" `Quick
            (check_retained_history_match ~checkpoint_texts:[]
               ~current_texts:(history_search_noise 50 @ [ "Migration prerequisite: amber database" ]))
        ; tool_case "history search reaches all working-context messages" `Quick
            (check_retained_history_match ~current_texts:[]
               ~checkpoint_texts:("Migration prerequisite: amber database" :: history_search_noise 100))
        ; tool_case
            "history complete query outranks retained fragments"
            `Quick
            test_history_complete_query_outranks_retained_fragments
        ; tool_case "current search pages every matching fact and refuses stale cursors" `Quick
            test_current_search_pages_all_matching_memory
        ; tool_case "history search limits distinct matches" `Quick
            test_history_search_limits_distinct_matches
        ; tool_case "history search orders selected messages" `Quick
            test_history_search_order
        ; tool_case "history search reports malformed rows" `Quick
            (test_history_search_reports_read_errors ~malformed:true)
        ; tool_case "history search reports unreadable files" `Quick
            (test_history_search_reports_read_errors ~malformed:false)
        ; tool_case "short acronym search keeps Korean suffixes and excludes word interiors" `Quick
            test_short_acronym_search_does_not_select_word_interiors
        ; tool_case
            "search keeps exact matches in store order"
            `Quick
            test_search_keeps_exact_matches_in_store_order
        ; tool_case
            "search records a retrieval per ordinary match"
            `Quick
            test_search_records_a_retrieval_per_ordinary_match
        ; tool_case
            "retract records removal and survives re-adding the claim"
            `Quick
            test_retract_records_a_retraction
        ; tool_case
            "source parser accepts every supported value"
            `Quick
            test_source_parser_accepts_every_supported_value
        ; tool_case
            "source parser rejects unknown value"
            `Quick
            test_source_parser_rejects_unknown_value
        ; tool_case
            "source parser rejects removed memory alias"
            `Quick
            test_source_parser_rejects_removed_memory_alias
        ; tool_case
            "source parser rejects a non-string rendering"
            `Quick
            test_source_parser_rejects_json_rendering_of_a_non_string
        ] )
    ; ( "failure class"
      , [ tool_case
            "corrupt snapshot is a dependency failure"
            `Quick
            test_corrupt_snapshot_is_a_dependency_failure
        ; tool_case
            "a query of several words is answered"
            `Quick
            test_a_query_of_several_words_is_answered
        ; tool_case
            "all ranks complete queries across stores"
            `Quick
            test_all_ranks_complete_queries_before_fragments_across_stores
        ; tool_case
            "fragment matching contract is explicit"
            `Quick
            test_fragment_contract_is_whitespace_split_substring_matching
        ; tool_case
            "an unreadable memory log leaves all its current facts"
            `Quick
            test_an_unreadable_memory_log_leaves_all_its_current_facts
        ; tool_case
            "unwritable store is a dependency failure"
            `Quick
            test_unwritable_store_is_a_dependency_failure
        ; tool_case
            "a commit that omits the claim is after the effect"
            `Quick
            test_a_commit_that_omits_the_claim_is_after_the_effect
        ; tool_case
            "input and state failures keep their own classes"
            `Quick
            test_input_and_state_failures_keep_their_own_classes
        ; tool_case
            "unreadable source path is the caller's to fix"
            `Quick
            test_unreadable_source_path_is_the_callers_to_fix
        ; tool_case
            "endpoint source read reports absence by exit status"
            `Quick
            test_endpoint_source_read_reports_by_exit_status
        ; tool_case
            "an unreadable source keeps its fact, marked unverified"
            `Quick
            test_unreadable_source_keeps_its_fact_marked_unverified
        ; tool_case
            "one unreadable source does not stop the pass"
            `Quick
            test_one_unreadable_source_does_not_stop_the_pass
        ; tool_case
            "endpoint source outcome separates the endpoint from the file"
            `Quick
            test_endpoint_source_outcome_separates_endpoint_from_file
        ] )
    ]
;;
