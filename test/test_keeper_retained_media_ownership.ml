open Alcotest

module Outbox = Masc.Keeper_client_tool_outbox
module Blob = Tool_blob_store
module Maintenance = Tool_blob_maintenance
module Paths = Keeper_official_client_paths

let require = function
  | Ok value -> value
  | Error detail -> fail detail
;;

(* This test owns only these stores. It uses the actual scanner and deletion
   engine; it does not assert coverage of Server_tool_blob_scope's other
   production domains. Every unexpected fixture entry must stop deletion. *)
let fixture_scope : Maintenance.scope =
  { workspace =
      [ Maintenance.Store
          { name = Common.keepers_runtime_dirname
          ; classification = Maintenance.In_scope Maintenance.Tree }
      ; Maintenance.Store
          { name = Blob.dirname; classification = Maintenance.Excluded Maintenance.Blob_store }
      ; Maintenance.Store
          { name = Maintenance.dirname
          ; classification = Maintenance.Excluded Maintenance.Sweep_record }
      ]
  ; config_keepers_dir =
      (fun ~base_path ->
         Filename.concat (Common.masc_dir_from_base_path ~base_path) "config/keepers")
  ; config_keepers = []
  ; derived = []
  }
;;

let sweep ~base_path =
  match
    Maintenance.run
      ~base_path
      ~scope:fixture_scope
      ~mode:Maintenance.Delete_previous_candidates
  with
  | Error error -> fail (Maintenance.error_to_string error)
  | Ok report ->
    check (list string) "every fixture store is classified" [] report.unclassified
;;

let fetch store reference =
  match Blob.fetch store ~sha256:reference.Tool_output.sha256 with
  | Ok bytes -> bytes
  | Error error -> fail (Blob.fetch_error_to_string error)
;;

let response_references response =
  let open Yojson.Safe.Util in
  response |> member "content_blocks" |> to_list
  |> List.map (fun block ->
    match Tool_output.normalized_artifact_ref_of_json (member "artifact" block) with
    | Tool_output.Decoded_normalized_artifact_ref reference -> reference
    | Tool_output.Invalid_normalized_artifact_ref { detail } -> fail detail
    | Tool_output.Not_normalized_artifact_ref -> fail "producer omitted a normalized media root")
;;

let test_ack_preserves_original_media () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  Fs_compat.set_fs env#fs;
  let base_path = Filename.temp_dir "retained-media-owner-" "" in
  Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree base_path);
  let keeper_name = "retained-media-owner" in
  (* Payloads test byte ownership, not PDF/WAV interpretation. No reader or
     external tool is called. The real producer performs Base64 decoding and
     durable blob writes. Its inactive lease models an ended producer. *)
  let document = "%PDF-1.4\nretained document bytes\n" in
  let audio = "RIFF retained audio bytes" in
  let originals = [ document; audio ] in
  let blocks =
    Llm_provider.Types.
      [ Document { media_type = "application/pdf"; source = Base64 (Base64.encode_string document) }
      ; Audio { media_type = "audio/wav"; source = Base64 (Base64.encode_string audio) }
      ]
  in
  let producer =
    require
      (Outbox.host_producer
         ~base_path ~keeper_name ~runtime_label:"retained-ownership-fixture" ~turn_count:1)
  in
  let response =
    require
      (Outbox.host_response producer ~min_result_bytes:max_int
         ~success:true ~content:"completed media result" ~content_blocks:(Some blocks))
  in
  let references = response_references response in
  check int "both original attachments have roots" 2 (List.length references);
  require
    (Outbox.retain_host_result producer ~invocation_index:0 ~call_id:"completed-call"
       ~tool_name:"Read" ~arguments:(Outbox.Known (`Assoc [])) ~response);
  let loaded = require (Outbox.load ~base_path ~keeper_name ~viewer:Outbox.Unowned_only) in
  check int "the inactive unowned receipt is visible" 1 (List.length (Outbox.receipt_ids loaded));
  let store = Blob.create ~base_path in
  let expected = List.map Option.some originals in
  sweep ~base_path;
  sweep ~base_path;
  check (list (option string)) "the retained receipt owns both blobs" expected
    (List.map (fetch store) references);
  require (Outbox.acknowledge loaded);
  require (Outbox.acknowledge loaded);
  let pending = require (Outbox.load ~base_path ~keeper_name ~viewer:Outbox.Unowned_only) in
  check (list string) "ACK is idempotent and removes only the consumed receipt" []
    (Outbox.receipt_ids pending);
  sweep ~base_path;
  check (list (option string)) "a first unowned sweep cannot delete original bytes" expected
    (List.map (fetch store) references);
  sweep ~base_path;
  check (list (option string)) "accepted receipts retain their original media after two sweeps"
    expected (List.map (fetch store) references)
;;

type fixture =
  { base_path : string
  ; keeper_name : string
  ; producer : Outbox.host_producer
  ; response : Yojson.Safe.t
  ; references : Tool_output.artifact_ref list
  ; originals : string list
  ; pending : Outbox.snapshot
  ; pending_path : string
  ; consumed_path : string
  ; original_json : Yojson.Safe.t
  }
;;

let read_json path =
  In_channel.with_open_bin path (fun channel ->
    Yojson.Safe.from_string (In_channel.input_all channel))
;;

let write_json path json =
  Out_channel.with_open_bin path (fun channel ->
    Out_channel.output_string channel (Yojson.Safe.to_string json))
;;

let only_receipt snapshot =
  match Outbox.receipt_ids snapshot with
  | [ identity ] -> identity
  | [] | _ :: _ :: _ -> fail "fixture must hold one exact physical receipt"
;;

let with_fixture f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Fs_compat.set_fs env#fs;
  let base_path = Filename.temp_dir "retained-owner-fault-" "" in
  Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree base_path);
  let keeper_name = "retained-media-owner" in
  let producer = require (Outbox.host_producer ~base_path ~keeper_name
    ~runtime_label:"retained-ownership-fixture" ~turn_count:1) in
  let originals = [ "%PDF-1.4\noriginal bytes\n"; "RIFF original audio bytes" ] in
  let blocks = List.map2
    (fun kind bytes ->
      let source = Llm_provider.Types.Base64 (Base64.encode_string bytes) in
      match kind with
      | `Document -> Llm_provider.Types.Document { media_type = "application/pdf"; source }
      | `Audio -> Llm_provider.Types.Audio { media_type = "audio/wav"; source })
    [ `Document; `Audio ] originals in
  let response = require (Outbox.host_response producer ~min_result_bytes:max_int
    ~success:true ~content:"completed media result" ~content_blocks:(Some blocks)) in
  require (Outbox.retain_host_result producer ~invocation_index:0
    ~call_id:"reused-client-call" ~tool_name:"Read"
    ~arguments:(Outbox.Known (`Assoc [])) ~response);
  let pending = require (Outbox.load ~base_path ~keeper_name ~viewer:Outbox.Unowned_only) in
  let name = only_receipt pending ^ ".json" in
  let pending_path = Filename.concat (require (Paths.outbox_dir ~base_path ~keeper_name)) name in
  let consumed_path = Filename.concat
    (require (Paths.consumed_results_dir ~base_path ~keeper_name)) name in
  f { base_path; keeper_name; producer; response; references = response_references response;
      originals; pending; pending_path; consumed_path; original_json = read_json pending_path }
;;

let expect_error = function
  | Error _ -> ()
  | Ok () -> fail "ACK must refuse an unavailable original owner"
;;

let pending_unchanged fixture =
  check bool "failed ACK preserves exact pending original" true
    (Yojson.Safe.equal fixture.original_json (read_json fixture.pending_path))
;;

let check_consumed fixture =
  check bool "consumed owner preserves complete original JSON" true
    (Yojson.Safe.equal fixture.original_json (read_json fixture.consumed_path));
  sweep ~base_path:fixture.base_path;
  sweep ~base_path:fixture.base_path;
  let store = Blob.create ~base_path:fixture.base_path in
  check (list (option string)) "original attachments survive two actual sweeps"
    (List.map Option.some fixture.originals) (List.map (fetch store) fixture.references)
;;

let test_conflicting_archive_preserves_pending () = with_fixture (fun fixture ->
  Fs_compat.mkdir_p (Filename.dirname fixture.consumed_path);
  let conflict = `Assoc [ "conflicting_original", `Bool true ] in
  write_json fixture.consumed_path conflict;
  expect_error (Outbox.acknowledge fixture.pending);
  pending_unchanged fixture;
  check bool "conflicting archive is not overwritten" true
    (Yojson.Safe.equal conflict (read_json fixture.consumed_path)))
;;

let test_equal_visible_archive_requires_durable_retry () = with_fixture (fun fixture ->
  Fs_compat.mkdir_p (Filename.dirname fixture.consumed_path);
  (* This represents the visibility left by a failed post-rename sync. It is
     deliberately not evidence of a successful durable publication. *)
  write_json fixture.consumed_path fixture.original_json;
  let staging = Filename.concat
    (Filename.dirname (Filename.dirname fixture.consumed_path))
    ".consumed-tool-results-staging" in
  Out_channel.with_open_bin staging (fun channel ->
    Out_channel.output_string channel "real staging obstruction");
  expect_error (Outbox.acknowledge fixture.pending);
  pending_unchanged fixture;
  check bool "visible original remains exact after refusal" true
    (Yojson.Safe.equal fixture.original_json (read_json fixture.consumed_path));
  Unix.unlink staging;
  require (Outbox.acknowledge fixture.pending);
  require (Outbox.acknowledge fixture.pending);
  check_consumed fixture)
;;

let test_missing_pending_still_establishes_original_owner () = with_fixture (fun fixture ->
  Unix.unlink fixture.pending_path;
  check bool "fixture has no pre-existing consumed owner" false
    (Sys.file_exists fixture.consumed_path);
  require (Outbox.acknowledge fixture.pending);
  check_consumed fixture)
;;

let test_delivery_frontier_owns_only_confirmed_originals () = with_fixture (fun fixture ->
  let delivered = require (Outbox.retain_host_result_with_delivery fixture.producer
    ~invocation_index:0 ~call_id:"reused-client-call" ~tool_name:"Read"
    ~arguments:(Outbox.Known (`Assoc [])) ~response:fixture.response) in
  Outbox.mark_response_sent delivered;
  let frontier = Outbox.close_delivery_frontier fixture.producer in
  check (list string) "delivery snapshot names the original physical receipt"
    (Outbox.receipt_ids fixture.pending) (Outbox.receipt_ids frontier);
  let later = require (Outbox.retain_host_result_with_delivery fixture.producer
    ~invocation_index:1 ~call_id:"reused-client-call" ~tool_name:"Read"
    ~arguments:(Outbox.Known (`Assoc [])) ~response:fixture.response) in
  Outbox.mark_response_sent later;
  require (Outbox.acknowledge frontier);
  let pending = require (Outbox.load ~base_path:fixture.base_path
    ~keeper_name:fixture.keeper_name ~viewer:Outbox.Unowned_only) in
  let remaining = only_receipt pending in
  check bool "late reused call ID is a distinct pending receipt" false
    (List.mem remaining (Outbox.receipt_ids frontier));
  check_consumed fixture)
;;

let test_old_loaded_ack_preserves_new_receipt () = with_fixture (fun fixture ->
  require (Outbox.retain_host_result fixture.producer
    ~invocation_index:1 ~call_id:"reused-client-call" ~tool_name:"Read"
    ~arguments:(Outbox.Known (`Assoc [])) ~response:fixture.response);
  require (Outbox.acknowledge fixture.pending);
  let pending = require (Outbox.load ~base_path:fixture.base_path
    ~keeper_name:fixture.keeper_name ~viewer:Outbox.Unowned_only) in
  let remaining = only_receipt pending in
  check bool "a new physical receipt survives an old loaded ACK" false
    (List.mem remaining (Outbox.receipt_ids fixture.pending));
  check_consumed fixture)
;;

let test_concurrent_ack_and_stable_retry () = with_fixture (fun fixture ->
  let first, second = Eio.Fiber.pair
    (fun () -> Outbox.acknowledge fixture.pending)
    (fun () -> Outbox.acknowledge fixture.pending) in
  (* An identical concurrent rename may invalidate a guarded read. Preserve
     both outcomes, then prove ownership and convergence without treating an
     observed filesystem refusal as a successful ACK. *)
  let report label = function
    | Ok () -> Printf.printf "%s: acknowledged\n%!" label
    | Error detail -> Printf.printf "%s: refused: %s\n%!" label detail
  in
  report "first concurrent ACK" first;
  report "second concurrent ACK" second;
  if Sys.file_exists fixture.pending_path then pending_unchanged fixture;
  if Sys.file_exists fixture.consumed_path then
    check bool "concurrent publication keeps the exact original" true
      (Yojson.Safe.equal fixture.original_json (read_json fixture.consumed_path));
  sweep ~base_path:fixture.base_path;
  sweep ~base_path:fixture.base_path;
  let store = Blob.create ~base_path:fixture.base_path in
  check (list (option string)) "concurrent ACK conserves originals before retry"
    (List.map Option.some fixture.originals) (List.map (fetch store) fixture.references);
  require (Outbox.acknowledge fixture.pending);
  let pending = require (Outbox.load ~base_path:fixture.base_path
    ~keeper_name:fixture.keeper_name ~viewer:Outbox.Unowned_only) in
  check (list string) "concurrent ACKs leave no pending delivery" []
    (Outbox.receipt_ids pending);
  check_consumed fixture)
;;

let () =
  run "Retained media ownership"
    [ "ACK and GC",
      [ test_case "ACK preserves original media" `Quick test_ack_preserves_original_media
      ; test_case "conflicting archive preserves pending" `Quick test_conflicting_archive_preserves_pending
      ; test_case "equal visible archive still needs durable publication" `Quick test_equal_visible_archive_requires_durable_retry
      ; test_case "missing pending snapshot establishes original owner" `Quick test_missing_pending_still_establishes_original_owner
      ; test_case "delivery frontier owns confirmed original only" `Quick test_delivery_frontier_owns_only_confirmed_originals
      ; test_case "old loaded ACK leaves new receipt" `Quick test_old_loaded_ack_preserves_new_receipt
      ; test_case "concurrent ACK and stable retry" `Quick test_concurrent_ack_and_stable_retry
      ] ]
