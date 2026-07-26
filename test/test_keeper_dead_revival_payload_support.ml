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
      ~runtime_transition:Payload.Runtime_unchanged
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
