open Alcotest
open Masc

module Payload = Keeper_dead_revival_payload
module Exact_read = Fs_compat.Capability_exact_read

let rec remove_tree path =
  match Unix.lstat path with
  | stat ->
    (match stat.Unix.st_kind with
     | Unix.S_DIR ->
       Sys.readdir path
       |> Array.iter (fun leaf -> remove_tree (Filename.concat path leaf));
       Unix.rmdir path
     | _ -> Unix.unlink path)
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let with_workspace prefix fn =
  let base_path = Filename.temp_file prefix ".tmp" in
  Sys.remove base_path;
  Unix.mkdir base_path 0o700;
  Fun.protect
    ~finally:(fun () ->
      Keeper_fs_durable_directory.clear ();
      remove_tree base_path)
    (fun () ->
       let config = Workspace.default_config base_path in
       ignore (Workspace.init config ~agent_name:(Some "operator"));
       fn config)
;;

let require_payload_ok label = function
  | Ok value -> value
  | Error error ->
    failf "%s: %s" label (Payload.error_to_string error)
;;

let require_string_ok label = function
  | Ok value -> value
  | Error detail -> failf "%s: %s" label detail
;;

let expect_error label predicate = function
  | Error error when predicate error -> ()
  | Error error ->
    failf
      "%s: unexpected error: %s"
      label
      (Payload.error_to_string error)
  | Ok _ -> failf "%s: expected failure" label
;;

let parse_json label raw =
  try Yojson.Safe.from_string raw with
  | Yojson.Json_error detail -> failf "%s: %s" label detail
;;

let assoc_fields label = function
  | `Assoc fields -> fields
  | _ -> failf "%s: expected JSON object" label
;;

let read_file path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))
;;

let write_file ?(mode = 0o600) path contents =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () ->
       output_string channel contents;
       flush channel);
  Unix.chmod path mode
;;

let sha256 value =
  Digestif.SHA256.(digest_string value |> to_hex)
;;

let length_delimited value =
  Printf.sprintf "%d:%s" (String.length value) value
;;

let domain_digest domain values =
  domain :: values
  |> List.map length_delimited
  |> String.concat "\000"
  |> sha256
;;

let independent_transaction_id
      ~owner_id
      ~keeper_name
      ~expected_trace_id
      ~expected_generation
      ~candidate_nonce
  =
  [ "keeper-dead-revival-transaction-v1"
  ; length_delimited owner_id
  ; length_delimited keeper_name
  ; length_delimited
      (Keeper_id.Trace_id.to_string expected_trace_id)
  ; string_of_int expected_generation
  ; string_of_int candidate_nonce
  ]
  |> String.concat "\000"
  |> sha256
;;

let independent_payload_digest bytes =
  domain_digest
    "masc.keeper-dead-revival-payload-digest.v1"
    [ bytes ]
;;

let independent_transaction_leaf transaction_id =
  "transaction-"
  ^ domain_digest
      "masc.keeper-dead-revival-payload-transaction-leaf.v1"
      [ transaction_id ]
  ^ ".json"
;;

let independent_authority_leaf keeper_name =
  "revival-"
  ^ sha256
      ("keeper-dead-revival-journal-leaf-v1\000"
       ^ length_delimited keeper_name)
  ^ ".json"
;;

let trace_id_of_string raw =
  Keeper_id.Trace_id.of_string raw
  |> require_string_ok ("parse trace id " ^ raw)
;;

let make_meta ~keeper_name ~trace_id ~nonce ~instructions =
  let meta : Keeper_meta_contract.keeper_meta =
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
         [ "name", `String keeper_name
         ; ( "agent_name"
           , `String (Keeper_identity.keeper_agent_name keeper_name) )
         ; "trace_id", `String trace_id
         ; "runtime_id", `String "runtime.primary"
         ; "autoboot_enabled", `Bool false
         ])
    |> require_string_ok "parse Keeper metadata fixture"
  in
  { meta with
    instructions
  ; runtime = { meta.runtime with nonce }
  }
;;

type fixture =
  { config : Workspace.config
  ; keeper_name : string
  ; owner_id : string
  ; expected_trace_id : Keeper_id.Trace_id.t
  ; expected_generation : int
  ; original : Keeper_meta_contract.keeper_meta
  ; candidate : Keeper_meta_contract.keeper_meta
  ; transaction_id : string
  ; payload : Payload.payload
  ; prepared : Payload.prepared
  ; reference : Payload.immutable_ref
  ; authority_shard : Payload.authority_shard
  ; authority_leaf : string
  }

let make_fixture
      ?(keeper_name = "dead-revival-payload-owner")
      ?(owner_id = "revival-owner-1")
      ?(expected_generation = 7)
      ?(candidate_nonce = 8)
      ?(candidate_instructions = "candidate-state")
      config
  =
  let trace_id_raw = "trace-" ^ keeper_name in
  let original =
    make_meta
      ~keeper_name
      ~trace_id:trace_id_raw
      ~nonce:expected_generation
      ~instructions:"original-state"
  in
  let expected_trace_id = original.runtime.trace_id in
  let candidate =
    { original with
      instructions = candidate_instructions
    ; runtime = { original.runtime with nonce = candidate_nonce }
    }
  in
  let transaction_id =
    independent_transaction_id
      ~owner_id
      ~keeper_name
      ~expected_trace_id
      ~expected_generation
      ~candidate_nonce
  in
  let payload =
    Payload.make_payload
      ~transaction_id
      ~owner_id
      ~keeper_name
      ~expected_trace_id
      ~expected_generation
      ~original
      ~candidate
    |> require_payload_ok "make payload"
  in
  let prepared =
    Payload.prepare payload
    |> require_payload_ok "prepare payload"
  in
  let reference = Payload.prepared_ref prepared in
  let authority_shard =
    Payload.authority_shard_for_keeper ~keeper_name
    |> require_payload_ok "derive authority shard"
  in
  let authority_leaf =
    Payload.authority_shard_leaf authority_shard
  in
  { config
  ; keeper_name
  ; owner_id
  ; expected_trace_id
  ; expected_generation
  ; original
  ; candidate
  ; transaction_id
  ; payload
  ; prepared
  ; reference
  ; authority_shard
  ; authority_leaf
  }
;;

let payload_root config =
  Filename.concat
    (Filename.concat
       (Workspace.masc_root_dir config)
       "keeper-lifecycle-transactions")
    "payloads"
;;

let shard_directory fixture =
  Filename.concat (payload_root fixture.config) fixture.authority_leaf
;;

let payload_path fixture reference =
  Filename.concat
    (shard_directory fixture)
    (Payload.immutable_ref_transaction_leaf reference)
;;

let meta_bytes meta =
  Keeper_meta_json.meta_to_json meta
  |> Yojson.Safe.to_string
;;

let check_reference label expected actual =
  check
    string
    (label ^ " authority")
    (Payload.immutable_ref_authority_leaf expected)
    (Payload.immutable_ref_authority_leaf actual);
  check
    string
    (label ^ " transaction")
    (Payload.immutable_ref_transaction_leaf expected)
    (Payload.immutable_ref_transaction_leaf actual);
  check
    string
    (label ^ " digest")
    (Payload.immutable_ref_sha256 expected)
    (Payload.immutable_ref_sha256 actual);
  check
    int64
    (label ^ " byte count")
    (Payload.immutable_ref_byte_count expected)
    (Payload.immutable_ref_byte_count actual)
;;

let check_payload label fixture observed =
  check
    string
    (label ^ " transaction id")
    fixture.transaction_id
    (Payload.payload_transaction_id observed);
  check
    string
    (label ^ " owner id")
    fixture.owner_id
    (Payload.payload_owner_id observed);
  check
    string
    (label ^ " keeper name")
    fixture.keeper_name
    (Payload.payload_keeper_name observed);
  check
    string
    (label ^ " trace id")
    (Keeper_id.Trace_id.to_string fixture.expected_trace_id)
    (Payload.payload_expected_trace_id observed
     |> Keeper_id.Trace_id.to_string);
  check
    int
    (label ^ " generation")
    fixture.expected_generation
    (Payload.payload_expected_generation observed);
  check
    string
    (label ^ " original metadata")
    (meta_bytes fixture.original)
    (Payload.payload_original observed |> meta_bytes);
  check
    string
    (label ^ " candidate metadata")
    (meta_bytes fixture.candidate)
    (Payload.payload_candidate observed |> meta_bytes)
;;

let replace_json_fields changes = function
  | `Assoc fields ->
    let replace fields (key, value) =
      if not (List.mem_assoc key fields)
      then failf "reference field %s is missing" key;
      List.map
        (fun (observed, current) ->
           if String.equal observed key
           then observed, value
           else observed, current)
        fields
    in
    `Assoc (List.fold_left replace fields changes)
  | _ -> fail "reference is not a JSON object"
;;

let reference_with fixture changes =
  Payload.immutable_ref_to_json fixture.reference
  |> replace_json_fields changes
  |> Payload.immutable_ref_of_json
  |> require_payload_ok "construct adjusted reference"
;;

let create_first fixture =
  match Payload.create fixture.config fixture.prepared with
  | Ok (Payload.Created prepared) -> prepared
  | Ok (Payload.Reconciled_created _) ->
    fail "fresh create unexpectedly reconciled an existing target"
  | Error error ->
    failf "fresh create failed: %s" (Payload.error_to_string error)
;;

let read_bound fixture reference =
  Payload.read
    fixture.config
    ~expected_ref:reference
    ~expected_authority_leaf:fixture.authority_leaf
    ~transaction_id:fixture.transaction_id
    ~owner_id:fixture.owner_id
    ~keeper_name:fixture.keeper_name
    ~expected_trace_id:fixture.expected_trace_id
    ~expected_generation:fixture.expected_generation
;;

let is_length_mismatch = function
  | Payload.Read_failed failure ->
    (match failure.error with
     | Exact_read.Length_mismatch _ -> true
     | _ -> false)
  | _ -> false
;;

let is_missing = function
  | Payload.Read_failed failure ->
    (match failure.error with
     | Exact_read.Missing -> true
     | _ -> false)
  | _ -> false
;;

let test_canonical_codec_and_domain_bindings () =
  with_workspace "masc_dead_revival_payload_codec_" @@ fun config ->
  let fixture = make_fixture config in
  let bytes = Payload.payload_to_bytes fixture.payload in
  let payload_fields =
    parse_json "canonical payload" bytes
    |> assoc_fields "canonical payload"
  in
  check
    (list string)
    "payload exact field order"
    [ "schema"
    ; "transaction_id"
    ; "owner_id"
    ; "keeper_name"
    ; "expected_trace_id"
    ; "expected_generation"
    ; "original"
    ; "candidate"
    ]
    (List.map fst payload_fields);
  let decoded =
    Payload.payload_of_bytes bytes
    |> require_payload_ok "decode canonical payload"
  in
  check_payload "payload roundtrip" fixture decoded;
  check
    string
    "payload canonical re-encoding"
    bytes
    (Payload.payload_to_bytes decoded);
  let extra_payload =
    `Assoc (payload_fields @ [ "unexpected", `Null ])
    |> Yojson.Safe.to_string
  in
  Payload.payload_of_bytes extra_payload
  |> expect_error
       "reject extra payload field"
       (function Payload.Malformed_payload _ -> true | _ -> false);
  let missing_payload =
    `Assoc
      (List.filter
         (fun (name, _) -> not (String.equal name "candidate"))
         payload_fields)
    |> Yojson.Safe.to_string
  in
  Payload.payload_of_bytes missing_payload
  |> expect_error
       "reject missing payload field"
       (function Payload.Malformed_payload _ -> true | _ -> false);
  Payload.payload_of_bytes (bytes ^ "\n")
  |> expect_error
       "reject noncanonical payload bytes"
       (function Payload.Noncanonical_payload -> true | _ -> false);
  let reference = fixture.reference in
  let reference_json = Payload.immutable_ref_to_json reference in
  let reference_fields = assoc_fields "canonical ref" reference_json in
  check
    (list string)
    "ref exact field order"
    [ "schema"
    ; "authority_leaf"
    ; "transaction_leaf"
    ; "sha256"
    ; "byte_count"
    ]
    (List.map fst reference_fields);
  let reference_bytes = Payload.immutable_ref_to_bytes reference in
  let decoded_ref =
    Payload.immutable_ref_of_bytes reference_bytes
    |> require_payload_ok "decode canonical ref"
  in
  check_reference "ref roundtrip" reference decoded_ref;
  check
    string
    "ref canonical re-encoding"
    reference_bytes
    (Payload.immutable_ref_to_bytes decoded_ref);
  Payload.immutable_ref_of_json
    (`Assoc (reference_fields @ [ "unexpected", `Null ]))
  |> expect_error
       "reject extra ref field"
       (function Payload.Malformed_ref _ -> true | _ -> false);
  Payload.immutable_ref_of_bytes (reference_bytes ^ "\n")
  |> expect_error
       "reject noncanonical ref bytes"
       (function Payload.Noncanonical_ref -> true | _ -> false);
  Payload.immutable_ref_of_json
    (replace_json_fields
       [ "sha256", `String ("A" ^ String.make 63 '0') ]
       reference_json)
  |> expect_error
       "reject uppercase ref digest"
       (function Payload.Malformed_ref _ -> true | _ -> false);
  check
    string
    "keeper-derived authority leaf"
    (independent_authority_leaf fixture.keeper_name)
    fixture.authority_leaf;
  check
    string
    "prepared ref authority"
    fixture.authority_leaf
    (Payload.immutable_ref_authority_leaf reference);
  check
    string
    "domain-separated transaction leaf"
    (independent_transaction_leaf fixture.transaction_id)
    (Payload.immutable_ref_transaction_leaf reference);
  check
    string
    "domain-separated payload digest"
    (independent_payload_digest bytes)
    (Payload.immutable_ref_sha256 reference);
  check
    bool
    "digest is not raw payload SHA"
    false
    (String.equal
       (sha256 bytes)
       (Payload.immutable_ref_sha256 reference));
  check
    int64
    "prepared byte count"
    (Int64.of_int (String.length bytes))
    (Payload.immutable_ref_byte_count reference);
  check
    bool
    "authority shard matches keeper"
    true
    (Payload.authority_shard_matches_keeper
       fixture.authority_shard
       ~keeper_name:fixture.keeper_name);
  check
    bool
    "authority shard rejects another keeper"
    false
    (Payload.authority_shard_matches_keeper
       fixture.authority_shard
       ~keeper_name:"another-keeper");
  check
    string
    "prepared payload is exact"
    bytes
    (Payload.prepared_payload fixture.prepared
     |> Payload.payload_to_bytes)
;;

let test_candidate_lifecycle_binding_rejections () =
  with_workspace "masc_dead_revival_payload_candidate_" @@ fun config ->
  let fixture = make_fixture config in
  let changed_trace =
    trace_id_of_string "trace-dead-revival-payload-replacement"
  in
  let candidate_with_changed_trace =
    { fixture.candidate with
      runtime =
        { fixture.candidate.runtime with trace_id = changed_trace }
    }
  in
  Payload.make_payload
    ~transaction_id:fixture.transaction_id
    ~owner_id:fixture.owner_id
    ~keeper_name:fixture.keeper_name
    ~expected_trace_id:fixture.expected_trace_id
    ~expected_generation:fixture.expected_generation
    ~original:fixture.original
    ~candidate:candidate_with_changed_trace
  |> expect_error
       "candidate trace must be preserved"
       (function Payload.Invalid_binding _ -> true | _ -> false);
  let reject_nonce nonce label =
    let candidate =
      { fixture.candidate with
        runtime = { fixture.candidate.runtime with nonce }
      }
    in
    let transaction_id =
      independent_transaction_id
        ~owner_id:fixture.owner_id
        ~keeper_name:fixture.keeper_name
        ~expected_trace_id:fixture.expected_trace_id
        ~expected_generation:fixture.expected_generation
        ~candidate_nonce:nonce
    in
    Payload.make_payload
      ~transaction_id
      ~owner_id:fixture.owner_id
      ~keeper_name:fixture.keeper_name
      ~expected_trace_id:fixture.expected_trace_id
      ~expected_generation:fixture.expected_generation
      ~original:fixture.original
      ~candidate
    |> expect_error
         label
         (function Payload.Invalid_binding _ -> true | _ -> false)
  in
  reject_nonce fixture.expected_generation "candidate nonce must advance";
  reject_nonce
    (fixture.expected_generation - 1)
    "candidate nonce must not move backward";
  let uppercase_transaction_id =
    "A" ^ String.sub fixture.transaction_id 1 63
  in
  Payload.make_payload
    ~transaction_id:uppercase_transaction_id
    ~owner_id:fixture.owner_id
    ~keeper_name:fixture.keeper_name
    ~expected_trace_id:fixture.expected_trace_id
    ~expected_generation:fixture.expected_generation
    ~original:fixture.original
    ~candidate:fixture.candidate
  |> expect_error
       "transaction id must be lowercase"
       (function Payload.Invalid_binding _ -> true | _ -> false)
;;

let test_create_mode_replay_evidence_and_conflict () =
  with_workspace "masc_dead_revival_payload_create_" @@ fun config ->
  let fixture =
    make_fixture ~candidate_instructions:"candidate-a" config
  in
  let created = create_first fixture in
  check_reference
    "created prepared"
    fixture.reference
    (Payload.prepared_ref created);
  let path = payload_path fixture fixture.reference in
  let stat = Unix.lstat path in
  check bool "created target is regular" true (stat.st_kind = Unix.S_REG);
  check int "created target mode" 0o600 (stat.st_perm land 0o777);
  let original_bytes = Payload.payload_to_bytes fixture.payload in
  check string "created bytes" original_bytes (read_file path);
  (match Payload.create config fixture.prepared with
   | Error
       (Payload.Create_unsettled
          { prepared; initial_failure }) ->
     check
       bool
       "identical replay evidence target unchanged"
       true
       (initial_failure.target_effect = Fs_compat.Target_unchanged);
     check
       bool
       "identical replay evidence operation"
       true
       (initial_failure.operation
        = Fs_compat.Create_exclusive_operation);
     check_reference
       "identical replay prepared evidence"
       fixture.reference
       (Payload.prepared_ref prepared)
   | Error error ->
     failf
       "identical replay returned wrong error: %s"
       (Payload.error_to_string error)
   | Ok _ ->
     fail "identical replay was promoted without file-data durability");
  check
    string
    "identical replay preserves bytes"
    original_bytes
    (read_file path);
  let conflicting =
    make_fixture ~candidate_instructions:"candidate-b" config
  in
  check
    string
    "conflict shares transaction leaf"
    (Payload.immutable_ref_transaction_leaf fixture.reference)
    (Payload.immutable_ref_transaction_leaf conflicting.reference);
  check
    bool
    "conflict changes payload digest"
    false
    (String.equal
       (Payload.immutable_ref_sha256 fixture.reference)
       (Payload.immutable_ref_sha256 conflicting.reference));
  (match Payload.create config conflicting.prepared with
   | Error
       (Payload.Create_unsettled
          { prepared; initial_failure }) ->
     check
       bool
       "same-leaf conflict target unchanged"
       true
       (initial_failure.target_effect = Fs_compat.Target_unchanged);
     check_reference
       "same-leaf conflict prepared evidence"
       conflicting.reference
       (Payload.prepared_ref prepared)
   | Error error ->
     failf
       "same-leaf conflict returned wrong error: %s"
       (Payload.error_to_string error)
   | Ok _ -> fail "same-leaf conflict replaced immutable bytes");
  check
    string
    "same-leaf conflict preserves original bytes"
    original_bytes
    (read_file path)
;;

let test_target_created_reconciles_with_retained_evidence () =
  with_workspace "masc_dead_revival_payload_reconcile_created_" @@ fun config ->
  let fixture = make_fixture config in
  ignore (create_first fixture);
  let path = payload_path fixture fixture.reference in
  let original_bytes = read_file path in
  let reconciliation_read_observed = ref false in
  let parent_sync_observed = ref false in
  let hooks =
    Payload.For_testing.hooks
      ~create_target_effect:Fs_compat.Target_created
      ~before_reconciliation_read:(fun () ->
        reconciliation_read_observed := true)
      ~before_parent_sync_stage:(fun _ ->
        parent_sync_observed := true)
      ()
  in
  let outcome =
    Payload.For_testing.with_hooks hooks (fun () ->
      Payload.create config fixture.prepared)
  in
  (match outcome with
   | Ok
       (Payload.Reconciled_created
          { prepared; initial_failure }) ->
     check
       bool
       "reconciled-created retains target effect"
       true
       (initial_failure.target_effect = Fs_compat.Target_created);
     check
       bool
       "reconciled-created retains operation"
       true
       (initial_failure.operation
        = Fs_compat.Create_exclusive_operation);
     check_reference
       "reconciled-created prepared evidence"
       fixture.reference
       (Payload.prepared_ref prepared)
   | Ok (Payload.Created _) ->
     fail "injected Target_created unexpectedly returned Created"
   | Error error ->
     failf
       "Target_created reconciliation failed: %s"
       (Payload.error_to_string error));
  check
    bool
    "Target_created performs exact reread"
    true
    !reconciliation_read_observed;
  check
    bool
    "Target_created performs parent sync"
    true
    !parent_sync_observed;
  check
    string
    "Target_created reconciliation preserves bytes"
    original_bytes
    (read_file path);
  (match Payload.create config fixture.prepared with
   | Error
       (Payload.Create_unsettled
          { prepared; initial_failure }) ->
     check
       bool
       "fiber-local hook does not escape scope"
       true
       (initial_failure.target_effect = Fs_compat.Target_unchanged);
     check_reference
       "post-scope unsettled prepared evidence"
       fixture.reference
       (Payload.prepared_ref prepared)
   | Error error ->
     failf
       "post-scope create returned wrong error: %s"
       (Payload.error_to_string error)
   | Ok _ -> fail "Target_created hook escaped its fiber-local scope")
;;

let test_unsettled_target_effects_retain_evidence () =
  with_workspace "masc_dead_revival_payload_unsettled_effects_" @@ fun config ->
  let fixture = make_fixture config in
  let cases =
    [ "created incomplete", Fs_compat.Target_created_incomplete
    ; "state unknown", Fs_compat.Target_state_unknown
    ; "replaced", Fs_compat.Target_replaced
    ]
  in
  List.iter
    (fun (label, target_effect) ->
       let hooks =
         Payload.For_testing.hooks
           ~create_target_effect:target_effect
           ()
       in
       let outcome =
         Payload.For_testing.with_hooks hooks (fun () ->
           Payload.create config fixture.prepared)
       in
       match outcome with
       | Error
           (Payload.Create_unsettled
              { prepared; initial_failure }) ->
         check
           bool
           (label ^ " target effect")
           true
           (initial_failure.target_effect = target_effect);
         check
           bool
           (label ^ " operation")
           true
           (initial_failure.operation
            = Fs_compat.Create_exclusive_operation);
         check_reference
           (label ^ " prepared evidence")
           fixture.reference
           (Payload.prepared_ref prepared)
       | Error error ->
         failf
           "%s returned wrong error: %s"
           label
           (Payload.error_to_string error)
       | Ok _ -> failf "%s was promoted to success" label)
    cases;
  check
    bool
    "unsettled injected effects do not publish target"
    false
    (Sys.file_exists (payload_path fixture fixture.reference))
;;

let test_create_reconciliation_read_failure () =
  with_workspace "masc_dead_revival_payload_reconcile_read_failure_" @@ fun config ->
  let fixture = make_fixture config in
  let read_hook_observed = ref false in
  let hooks =
    Payload.For_testing.hooks
      ~create_target_effect:Fs_compat.Target_created
      ~before_reconciliation_read:(fun () ->
        read_hook_observed := true;
        failwith "injected reconciliation read failure")
      ()
  in
  let outcome =
    Payload.For_testing.with_hooks hooks (fun () ->
      Payload.create config fixture.prepared)
  in
  (match outcome with
   | Error
       (Payload.Create_reconciliation_failed
          { prepared
          ; initial_failure
          ; reconciliation_failure =
              Payload.Reconciliation_read_failed _
          }) ->
     check
       bool
       "read failure retains Target_created"
       true
       (initial_failure.target_effect = Fs_compat.Target_created);
     check_reference
       "read failure prepared evidence"
       fixture.reference
       (Payload.prepared_ref prepared)
   | Error error ->
     failf
       "reconciliation read returned wrong error: %s"
       (Payload.error_to_string error)
   | Ok _ -> fail "reconciliation read failure was promoted to success");
  check
    bool
    "reconciliation read hook executed"
    true
    !read_hook_observed
;;

let test_create_reconciliation_parent_sync_failure () =
  with_workspace "masc_dead_revival_payload_reconcile_sync_failure_" @@ fun config ->
  let fixture = make_fixture config in
  ignore (create_first fixture);
  let parent_sync_hook_observed = ref false in
  let hooks =
    Payload.For_testing.hooks
      ~create_target_effect:Fs_compat.Target_created
      ~before_parent_sync_stage:(fun _ ->
        parent_sync_hook_observed := true;
        failwith "injected reconciliation parent sync failure")
      ()
  in
  let outcome =
    Payload.For_testing.with_hooks hooks (fun () ->
      Payload.create config fixture.prepared)
  in
  (match outcome with
   | Error
       (Payload.Create_reconciliation_failed
          { prepared
          ; initial_failure
          ; reconciliation_failure =
              Payload.Reconciliation_parent_sync_failed _
          }) ->
     check
       bool
       "parent sync failure retains Target_created"
       true
       (initial_failure.target_effect = Fs_compat.Target_created);
     check_reference
       "parent sync failure prepared evidence"
       fixture.reference
       (Payload.prepared_ref prepared)
   | Error error ->
     failf
       "parent sync returned wrong error: %s"
       (Payload.error_to_string error)
   | Ok _ -> fail "parent sync failure was promoted to success");
  check
    bool
    "parent sync hook executed"
    true
    !parent_sync_hook_observed
;;

let test_target_created_classifies_same_leaf_conflict () =
  with_workspace "masc_dead_revival_payload_reconcile_conflict_" @@ fun config ->
  let original =
    make_fixture ~candidate_instructions:"candidate-a" config
  in
  let conflicting =
    make_fixture ~candidate_instructions:"candidate-b" config
  in
  ignore (create_first original);
  let path = payload_path original original.reference in
  let original_bytes = read_file path in
  let reconciliation_read_observed = ref false in
  let parent_sync_observed = ref false in
  let hooks =
    Payload.For_testing.hooks
      ~create_target_effect:Fs_compat.Target_created
      ~before_reconciliation_read:(fun () ->
        reconciliation_read_observed := true)
      ~before_parent_sync_stage:(fun _ ->
        parent_sync_observed := true)
      ()
  in
  let outcome =
    Payload.For_testing.with_hooks hooks (fun () ->
      Payload.create config conflicting.prepared)
  in
  (match outcome with
   | Error
       (Payload.Create_conflict
          { prepared; initial_failure }) ->
     check
       bool
       "conflict retains Target_created"
       true
       (initial_failure.target_effect = Fs_compat.Target_created);
     check_reference
       "conflict prepared evidence"
       conflicting.reference
       (Payload.prepared_ref prepared)
   | Error error ->
     failf
       "same-leaf conflict returned wrong error: %s"
       (Payload.error_to_string error)
   | Ok _ -> fail "same-leaf different bytes were reconciled");
  check
    bool
    "same-leaf conflict performs exact reread"
    true
    !reconciliation_read_observed;
  check
    bool
    "same-leaf conflict skips parent sync"
    false
    !parent_sync_observed;
  check
    string
    "same-leaf conflict preserves original bytes"
    original_bytes
    (read_file path)
;;

let test_decode_only_read () =
  with_workspace "masc_dead_revival_payload_decode_" @@ fun config ->
  let first =
    make_fixture ~candidate_instructions:"candidate-a" config
  in
  let replacement =
    make_fixture ~candidate_instructions:"candidate-b" config
  in
  ignore (create_first first);
  let replacement_bytes =
    Payload.payload_to_bytes replacement.payload
  in
  write_file
    (payload_path first first.reference)
    replacement_bytes;
  let observed =
    read_bound replacement replacement.reference
    |> require_payload_ok "decode bound canonical replacement"
  in
  check_payload "decode-only read" replacement observed;
  check
    string
    "decode-only read returns stored candidate"
    "candidate-b"
    (Payload.payload_candidate observed).instructions
;;

let test_read_failures () =
  with_workspace "masc_dead_revival_payload_read_failures_" @@ fun config ->
  let fixture = make_fixture config in
  ignore (create_first fixture);
  let byte_count =
    Payload.immutable_ref_byte_count fixture.reference
  in
  let length_ref =
    reference_with
      fixture
      [ ( "byte_count"
        , `Intlit (Int64.succ byte_count |> Int64.to_string) )
      ]
  in
  read_bound fixture length_ref
  |> expect_error "read length mismatch" is_length_mismatch;
  let wrong_digest =
    let zero = String.make 64 '0' in
    if String.equal
         zero
         (Payload.immutable_ref_sha256 fixture.reference)
    then String.make 64 '1'
    else zero
  in
  let digest_ref =
    reference_with fixture [ "sha256", `String wrong_digest ]
  in
  read_bound fixture digest_ref
  |> expect_error
       "read digest mismatch"
       (function Payload.Payload_digest_mismatch -> true | _ -> false);
  Payload.read
    config
    ~expected_ref:fixture.reference
    ~expected_authority_leaf:fixture.authority_leaf
    ~transaction_id:fixture.transaction_id
    ~owner_id:"hostile-owner"
    ~keeper_name:fixture.keeper_name
    ~expected_trace_id:fixture.expected_trace_id
    ~expected_generation:fixture.expected_generation
  |> expect_error
       "read owner binding"
       (function Payload.Payload_binding_mismatch -> true | _ -> false);
  Payload.read
    config
    ~expected_ref:fixture.reference
    ~expected_authority_leaf:fixture.authority_leaf
    ~transaction_id:fixture.transaction_id
    ~owner_id:fixture.owner_id
    ~keeper_name:fixture.keeper_name
    ~expected_trace_id:(trace_id_of_string "trace-hostile-reader")
    ~expected_generation:fixture.expected_generation
  |> expect_error
       "read trace binding"
       (function Payload.Payload_binding_mismatch -> true | _ -> false);
  Payload.read
    config
    ~expected_ref:fixture.reference
    ~expected_authority_leaf:fixture.authority_leaf
    ~transaction_id:fixture.transaction_id
    ~owner_id:fixture.owner_id
    ~keeper_name:fixture.keeper_name
    ~expected_trace_id:fixture.expected_trace_id
    ~expected_generation:(fixture.expected_generation + 1)
  |> expect_error
       "read generation binding"
       (function Payload.Payload_binding_mismatch -> true | _ -> false);
  let other_transaction =
    make_fixture ~candidate_nonce:9 config
  in
  Payload.read
    config
    ~expected_ref:other_transaction.reference
    ~expected_authority_leaf:fixture.authority_leaf
    ~transaction_id:fixture.transaction_id
    ~owner_id:fixture.owner_id
    ~keeper_name:fixture.keeper_name
    ~expected_trace_id:fixture.expected_trace_id
    ~expected_generation:fixture.expected_generation
  |> expect_error
       "read transaction ref binding"
       (function Payload.Payload_binding_mismatch -> true | _ -> false);
  let other_keeper =
    make_fixture ~keeper_name:"hostile-swapped-keeper" config
  in
  Payload.read
    config
    ~expected_ref:other_keeper.reference
    ~expected_authority_leaf:fixture.authority_leaf
    ~transaction_id:fixture.transaction_id
    ~owner_id:fixture.owner_id
    ~keeper_name:fixture.keeper_name
    ~expected_trace_id:fixture.expected_trace_id
    ~expected_generation:fixture.expected_generation
  |> expect_error
       "read authority ref binding"
       (function Payload.Payload_binding_mismatch -> true | _ -> false);
  Payload.read
    config
    ~expected_ref:fixture.reference
    ~expected_authority_leaf:other_keeper.authority_leaf
    ~transaction_id:fixture.transaction_id
    ~owner_id:fixture.owner_id
    ~keeper_name:fixture.keeper_name
    ~expected_trace_id:fixture.expected_trace_id
    ~expected_generation:fixture.expected_generation
  |> expect_error
       "read caller authority binding"
       (function Payload.Invalid_binding _ -> true | _ -> false)
;;

let test_read_rejects_noncanonical_stored_bytes () =
  with_workspace "masc_dead_revival_payload_noncanonical_" @@ fun config ->
  let fixture = make_fixture config in
  ignore (create_first fixture);
  let noncanonical =
    Payload.payload_to_bytes fixture.payload ^ "\n"
  in
  write_file
    (payload_path fixture fixture.reference)
    noncanonical;
  let adjusted_ref =
    reference_with
      fixture
      [ ( "byte_count"
        , `Intlit
            (Int64.of_int (String.length noncanonical)
             |> Int64.to_string) )
      ; "sha256", `String (independent_payload_digest noncanonical)
      ]
  in
  read_bound fixture adjusted_ref
  |> expect_error
       "read rejects noncanonical stored bytes"
       (function Payload.Noncanonical_payload -> true | _ -> false)
;;

let test_transaction_bound_idempotent_delete () =
  with_workspace "masc_dead_revival_payload_delete_" @@ fun config ->
  let first = make_fixture config in
  let second = make_fixture ~candidate_nonce:9 config in
  ignore (create_first first);
  ignore (create_first second);
  let first_path = payload_path first first.reference in
  let second_path = payload_path second second.reference in
  Payload.delete
    config
    ~keeper_name:first.keeper_name
    ~expected_authority_leaf:first.authority_leaf
    ~transaction_id:first.transaction_id
    second.reference
  |> expect_error
       "hostile swapped ref delete"
       (function Payload.Payload_binding_mismatch -> true | _ -> false);
  check bool "hostile delete preserves first" true (Sys.file_exists first_path);
  check bool "hostile delete preserves second" true (Sys.file_exists second_path);
  Payload.delete
    config
    ~keeper_name:first.keeper_name
    ~expected_authority_leaf:first.authority_leaf
    ~transaction_id:first.transaction_id
    first.reference
  |> require_payload_ok "delete bound transaction";
  check bool "bound delete removes target" false (Sys.file_exists first_path);
  Payload.delete
    config
    ~keeper_name:first.keeper_name
    ~expected_authority_leaf:first.authority_leaf
    ~transaction_id:first.transaction_id
    first.reference
  |> require_payload_ok "repeat bound delete";
  read_bound first first.reference
  |> expect_error "read deleted transaction" is_missing;
  check bool "other transaction remains" true (Sys.file_exists second_path)
;;

let find_shard_for_keeper shards keeper_name =
  match
    List.find_opt
      (fun shard ->
         Payload.authority_shard_matches_keeper shard ~keeper_name)
      shards
  with
  | Some shard -> shard
  | None -> failf "inventory shard missing for %s" keeper_name
;;

let test_root_shard_and_transaction_inventory () =
  with_workspace "masc_dead_revival_payload_inventory_" @@ fun config ->
  let initial =
    Payload.inventory_authority_shards config
    |> require_payload_ok "inventory absent payload root"
  in
  check int "absent root inventory" 0 (List.length initial);
  (* Direct payload creation precedes any Reserved journal publication. *)
  let first =
    make_fixture
      ~keeper_name:"inventory-orphan"
      ~candidate_nonce:8
      config
  in
  let second =
    make_fixture
      ~keeper_name:"inventory-orphan"
      ~candidate_nonce:9
      config
  in
  ignore (create_first first);
  ignore (create_first second);
  let shards =
    Payload.inventory_authority_shards config
    |> require_payload_ok "inventory orphan authority shard"
  in
  check int "one orphan authority shard" 1 (List.length shards);
  let shard = find_shard_for_keeper shards first.keeper_name in
  check
    string
    "opaque orphan shard leaf"
    first.authority_leaf
    (Payload.authority_shard_leaf shard);
  let transactions =
    Payload.inventory_transactions config shard
    |> require_payload_ok "inventory orphan transactions"
  in
  check int "two orphan transactions" 2 (List.length transactions);
  let expected_order =
    [ independent_transaction_leaf first.transaction_id, first.transaction_id
    ; independent_transaction_leaf second.transaction_id, second.transaction_id
    ]
    |> List.sort (fun (left, _) (right, _) -> String.compare left right)
    |> List.map snd
  in
  List.iter2
    (fun inventory transaction_id ->
       check
         bool
         "transaction inventory order and binding"
         true
         (Payload.inventory_transaction_matches
            inventory
            ~transaction_id))
    transactions
    expected_order;
  let other =
    make_fixture ~keeper_name:"inventory-other" config
  in
  ignore (create_first other);
  let all_shards =
    Payload.inventory_authority_shards config
    |> require_payload_ok "inventory multiple authority shards"
  in
  check
    (list string)
    "authority shards sorted"
    (List.sort
       String.compare
       [ first.authority_leaf; other.authority_leaf ])
    (List.map Payload.authority_shard_leaf all_shards);
  let other_shard =
    find_shard_for_keeper all_shards other.keeper_name
  in
  let first_inventory = List.hd transactions in
  Payload.delete_inventory_transaction
    config
    ~authority_shard:other_shard
    first_inventory
  |> expect_error
       "inventory delete rejects swapped shard"
       (function Payload.Invalid_binding _ -> true | _ -> false);
  Payload.delete_inventory_transaction
    config
    ~authority_shard:shard
    first_inventory
  |> require_payload_ok "delete opaque orphan transaction";
  Payload.delete_inventory_transaction
    config
    ~authority_shard:shard
    first_inventory
  |> require_payload_ok "repeat opaque orphan delete"
;;

let test_inventory_rejects_invalid_entries () =
  with_workspace "masc_dead_revival_payload_inventory_invalid_" @@ fun config ->
  let fixture = make_fixture config in
  ignore (create_first fixture);
  let root = payload_root config in
  let invalid_root = Filename.concat root "unexpected-entry" in
  write_file invalid_root "invalid";
  Payload.inventory_authority_shards config
  |> expect_error
       "reject invalid payload-root entry"
       (function Payload.Inventory_failed _ -> true | _ -> false);
  Sys.remove invalid_root;
  let non_directory_authority =
    Filename.concat
      root
      (independent_authority_leaf "non-directory-authority")
  in
  write_file non_directory_authority "invalid";
  Payload.inventory_authority_shards config
  |> expect_error
       "reject non-directory authority entry"
       (function Payload.Inventory_failed _ -> true | _ -> false);
  Sys.remove non_directory_authority;
  let invalid_transaction =
    Filename.concat (shard_directory fixture) "unexpected-entry"
  in
  write_file invalid_transaction "invalid";
  Payload.inventory_transactions config fixture.authority_shard
  |> expect_error
       "reject invalid transaction entry"
       (function Payload.Inventory_failed _ -> true | _ -> false);
  Sys.remove invalid_transaction;
  let recovered =
    Payload.inventory_transactions config fixture.authority_shard
    |> require_payload_ok "inventory after invalid entry removal"
  in
  check int "valid transaction remains" 1 (List.length recovered)
;;

let test_large_metadata_roundtrip () =
  with_workspace "masc_dead_revival_payload_large_" @@ fun config ->
  let large = String.make (1_048_576 + 16_384) 'x' in
  let fixture =
    make_fixture ~candidate_instructions:large config
  in
  check
    bool
    "payload exceeds one MiB"
    true
    (Int64.compare
       (Payload.immutable_ref_byte_count fixture.reference)
       1_048_576L
     > 0);
  ignore (create_first fixture);
  let observed =
    read_bound fixture fixture.reference
    |> require_payload_ok "read large metadata payload"
  in
  let observed_instructions =
    (Payload.payload_candidate observed).instructions
  in
  check
    int
    "large metadata length"
    (String.length large)
    (String.length observed_instructions);
  check
    string
    "large metadata digest"
    (sha256 large)
    (sha256 observed_instructions);
  Payload.delete
    config
    ~keeper_name:fixture.keeper_name
    ~expected_authority_leaf:fixture.authority_leaf
    ~transaction_id:fixture.transaction_id
    fixture.reference
  |> require_payload_ok "delete large metadata payload"
;;

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Masc_test_deps.init_eio_clock env;
  run
    "keeper dead revival payload"
    [ ( "codec"
      , [ test_case
            "canonical codec and domain bindings"
            `Quick
            test_canonical_codec_and_domain_bindings
        ; test_case
            "candidate lifecycle binding rejections"
            `Quick
            test_candidate_lifecycle_binding_rejections
        ] )
    ; ( "storage"
      , [ test_case
            "create mode, replay evidence, and conflict"
            `Quick
            test_create_mode_replay_evidence_and_conflict
        ; test_case
            "decode-only read"
            `Quick
            test_decode_only_read
        ; test_case
            "Target_created reconciliation"
            `Quick
            test_target_created_reconciles_with_retained_evidence
        ; test_case
            "unsettled target effects"
            `Quick
            test_unsettled_target_effects_retain_evidence
        ; test_case
            "reconciliation read failure"
            `Quick
            test_create_reconciliation_read_failure
        ; test_case
            "reconciliation parent sync failure"
            `Quick
            test_create_reconciliation_parent_sync_failure
        ; test_case
            "Target_created same-leaf conflict"
            `Quick
            test_target_created_classifies_same_leaf_conflict
        ; test_case
            "read failures"
            `Quick
            test_read_failures
        ; test_case
            "noncanonical stored bytes"
            `Quick
            test_read_rejects_noncanonical_stored_bytes
        ; test_case
            "transaction-bound idempotent delete"
            `Quick
            test_transaction_bound_idempotent_delete
        ; test_case
            "large metadata roundtrip"
            `Quick
            test_large_metadata_roundtrip
        ] )
    ; ( "inventory"
      , [ test_case
            "root, shard, and transaction inventory"
            `Quick
            test_root_shard_and_transaction_inventory
        ; test_case
            "invalid inventory entries"
            `Quick
            test_inventory_rejects_invalid_entries
        ] )
    ]
;;
