(** Tests for Tool_blob_store + Tool_output.

    Covers:
    - Round-trip: encode then decode a [Stored] reference.
    - Backward compat: any string without marker reports [Not_marker].
    - Malformed marker surfaces as [Invalid_marker] — a visible, typed
      outcome.
    - Content-addressed: same bytes -> same sha -> idempotent put.
    - Sharding: blobs land under [<sha[0..1]>/<sha>].
    - Maintenance: union-scanned live refs survive and stable dead refs are
      deleted only on the second explicit retention pass.
    - Concurrent put: simultaneous writes of same content do not corrupt. *)

module B = Tool_blob_store
module M = Tool_blob_maintenance

(* Maintenance reads each workspace's posts where Board writes them. *)
let scope = Server_tool_blob_scope.scope
module O = Tool_output

let fetch_ok store ~sha256 =
  match B.fetch store ~sha256 with
  | Ok value -> value
  | Error error ->
      Alcotest.failf "fetch failed: %s" (B.fetch_error_to_string error)

let with_temp_dir f =
  let dir = Filename.temp_file "masc_blob_test" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let cleanup () =
    (* [Unix.lstat], not [Sys.is_directory]: the latter follows symlinks, so a
       link to a directory (as the symbolic-link fixtures below leave under the
       swept root) would make [Sys.readdir] enumerate the *target*, delete its
       entries, then fail [Unix.rmdir] on the link — an error this [try] used
       to swallow, silently abandoning the rest of the temp tree (#26648).
       [S_LNK] falls through to [Unix.unlink], which removes the link itself;
       a dangling link is unlinked too instead of being skipped into an
       ENOTEMPTY. *)
    let rec rm path =
      match Unix.lstat path with
      | exception Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR), _, _) -> ()
      | { Unix.st_kind = Unix.S_DIR; _ } ->
        Array.iter (fun n -> rm (Filename.concat path n)) (Sys.readdir path);
        Unix.rmdir path
      | _ -> Unix.unlink path
    in
    try rm dir with _ -> ()
  in
  let r = try Ok (f dir) with e -> Error e in
  cleanup ();
  match r with Ok v -> v | Error e -> raise e

(* Fixtures here hold a handful of small files and compete with no startup
   watchdog, so they scan unbounded; the budget path has its own tests. *)
let maintenance_ok ~base_path ~mode =
  match M.run ~base_path ~scope ~mode with
  | Ok report -> report
  | Error error ->
    Alcotest.failf "maintenance failed: %s" (M.error_to_string error)

let media_put_ok (media_store : Agent_core.History.media_store) ~media_type ~raw =
  match media_store.put ~media_type ~raw with
  | Ok stored -> stored
  | Error error -> Alcotest.fail (Agent_core.Error.to_string (Agent_core.Error.Media error))

let save_maintenance_source base_path relative json =
  let path = Filename.concat (Common.masc_dir_from_base_path ~base_path) relative in
  Fs_compat.mkdir_p (Filename.dirname path);
  Fs_compat.save_file path (Yojson.Safe.to_string json);
  path
;;

let write_maintenance_tool_receipts ~base_path input =
  let module Calls = Masc.Keeper_tool_call_log in
  (* This executable otherwise leaves the call-log owner unconfigured. Fail
     before changing it if a fixture acquires that owner in the future. *)
  Alcotest.(check bool) "call-log fixture starts without another owner" true
    (Option.is_none (Calls.store ()) && Option.is_none (Calls.configured_masc_root ()));
  Fun.protect ~finally:Calls.reset_for_testing (fun () ->
    Calls.init ~base_path ();
    let committed = ref 0 in
    let execution_evidence = `Assoc ["detail", input] in
    let output_text = Yojson.Safe.to_string (`Assoc ["status", input]) in
    List.iter (fun wire_outcome ->
      Calls.log_call ~keeper_name:"reviewer" ~tool_name:"fixture" ~input
        ~execution_evidence ~output_text ~duration_ms:0. ~wire_outcome
        ~on_committed:(fun () -> incr committed) ())
      [Tool_result.Ok;Tool_result.Error;Tool_result.Unknown];
    Alcotest.(check int) "all wire outcomes commit real producer rows" 3 !committed;
    match Calls.read_recent ~n:3 () with
    | Ok rows -> Alcotest.(check int) "the durable producer rows can be reread" 3 (List.length rows)
    | Error (Calls.Index_unavailable detail) -> Alcotest.fail detail)
;;

let test_maintenance_distinguishes_tool_payloads_from_media_owners () =
  with_temp_dir (fun base_path ->
    let store = B.create ~base_path in
    let media = media_put_ok (Tool_blob_media_store.create store) ~media_type:"image/png" ~raw:"real media" in
    let sibling_media = media_put_ok (Tool_blob_media_store.create store) ~media_type:"image/png" ~raw:"official sibling only" in
    let artifact = B.put_durable store ~bytes:"demoted tool input" ~mime:"application/json" in
    let marker = B.put_durable store ~bytes:"nested result artifact" ~mime:"text/plain" in
    let dead_raw = "only arbitrary JSON names these bytes" in
    let dead = B.put_durable store ~bytes:dead_raw ~mime:"image/png" in
    let payload = `Assoc ["nested",`List [`List [
      `Assoc ["type",`String "stored";"sha256",`String dead.sha256];
      Agent_core.History.stored_source_to_json ~media_type:"image/png"
        (Agent_core.History.stored_of_raw dead_raw);
      O.normalized_artifact_ref_to_json artifact;
      `String (O.encode_for_agent_core (O.Stored marker))]]] in
    let use = Agent_core.Types.ToolUse {id="call";name="fixture";input=payload} in
    let result = Agent_core.Types.ToolResult {tool_use_id="call";content="image result";
      outcome=Tool_succeeded;json=Some payload;
      content_blocks=Some [Agent_core.Types.Image {media_type="image/png";source=Agent_core.Types.Stored media}]} in
    let assistant = Agent_core.Types.make_message ~role:Assistant [use] in
    let tool = Agent_core.Types.make_message ~role:Tool [result] in
    let official_tool = Agent_core.Types.make_message ~role:Tool
      [Agent_core.Types.ToolResult {tool_use_id="official-call";content="image result";
        outcome=Tool_succeeded;json=Some payload;
        content_blocks=Some [Agent_core.Types.Image {media_type="image/png";source=Agent_core.Types.Stored sibling_media}]}] in
    let demoted = Agent_core.Types.ToolUse {id="demoted";name="fixture";
      input=O.normalized_artifact_ref_to_json artifact} in
    ignore (save_maintenance_source base_path "keepers/reviewer/payloads.json"
      (`List [Agent_core.History.message_to_json assistant;
        Agent_core.History.content_block_to_json demoted;
        Masc.Keeper_context_core_message_json.message_to_json tool;
        Masc.Keeper_librarian_input_capture.message_json assistant;
        Masc.Keeper_librarian_input_capture.message_json tool;
        Masc.Keeper_official_client_context_codec.(to_json Canonical_source) official_tool]));
    write_maintenance_tool_receipts ~base_path payload;
    let first = maintenance_ok ~base_path ~mode:M.Delete_previous_candidates in
    Alcotest.(check int) "first complete scan only records the dead candidate" 0 first.deleted;
    let second = maintenance_ok ~base_path ~mode:M.Delete_previous_candidates in
    Alcotest.(check int) "ordinary tool JSON does not own history media" 1 second.deleted;
    Alcotest.(check int) "typed media and explicit tool artifacts remain live" 4 second.live_references;
    Alcotest.(check (option string)) "actual nested media survives" (Some "real media")
      (fetch_ok store ~sha256:media.sha256);
    Alcotest.(check (option string)) "actual media sibling with no duplicate owner survives"
      (Some "official sibling only") (fetch_ok store ~sha256:sibling_media.sha256);
    Alcotest.(check (option string)) "demoted ToolUse artifact survives" (Some "demoted tool input")
      (fetch_ok store ~sha256:artifact.sha256);
    Alcotest.(check (option string)) "marker inside arbitrary JSON survives" (Some "nested result artifact")
      (fetch_ok store ~sha256:marker.sha256);
    Alcotest.(check (option string)) "lookalike media JSON does not pin a dead blob" None
      (fetch_ok store ~sha256:dead.sha256))
;;

let test_maintenance_opaque_payloads_preserve_fail_closed_boundaries () =
  List.iter (fun shape -> with_temp_dir (fun base_path ->
    let store = B.create ~base_path in
    let survivor = B.put_durable store ~bytes:"preserve until owners are valid" ~mime:"text/plain" in
    ignore (maintenance_ok ~base_path ~mode:M.Observe_only);
    let snapshot_path = M.candidate_snapshot_path ~base_path in
    let bytes () = In_channel.with_open_bin snapshot_path In_channel.input_all in
    let before = bytes () in
    let malformed_source = `Assoc ["type",`String "stored";"sha256",`String survivor.sha256] in
    let result_message ?content_blocks ?(payload = malformed_source) () =
      Agent_core.Types.make_message ~role:Tool
        [Agent_core.Types.ToolResult {tool_use_id="call";content="data";
          outcome=Tool_succeeded;json=Some payload;content_blocks}] in
    let official_result () =
      Masc.Keeper_official_client_context_codec.(to_json Canonical_source)
        (result_message ()) in
    let malformed_media_sibling = function
      | `Assoc fields ->
        `Assoc (List.remove_assoc "source" fields @ ["source",malformed_source])
      | _ -> Alcotest.fail "invalid media fixture" in
    let malformed_result_sibling result =
      let source_name = match shape with
        | `Captured_media_sibling -> "content_blocks"
        | `Official_media_sibling -> "content"
        | `Media | `Artifact | `Unknown_tool | `Unknown_receipt
        | `Duplicate_official | `Unknown_failure_kind | `Unknown_error_class ->
          Alcotest.fail "not a media sibling fixture" in
      match result with
      | `Assoc fields ->
        let media = match List.assoc source_name fields with
          | `List [media] -> malformed_media_sibling media
          | _ -> Alcotest.fail "invalid result media fixture" in
        `Assoc (List.remove_assoc source_name fields @
          [source_name,`List [media]])
      | _ -> Alcotest.fail "invalid result fixture" in
    let malformed_message_sibling block_key = function
      | `Assoc fields ->
        let result = match List.assoc block_key fields with
          | `List [result] -> malformed_result_sibling result
          | _ -> Alcotest.fail "invalid result message fixture" in
        `Assoc (List.remove_assoc block_key fields @ [block_key,`List [result]])
      | _ -> Alcotest.fail "invalid message fixture" in
    let media_message () =
      let stored = Agent_core.History.stored_of_raw "preserve until owners are valid" in
      (* Keep the arbitrary payload well formed: the only malformed reference
         in these two cases is the media-bearing sibling. *)
      result_message ~content_blocks:[Agent_core.Types.Image {media_type="image/png";
        source=Agent_core.Types.Stored stored}]
        ~payload:(Agent_core.History.stored_source_to_json ~media_type:"image/png" stored) () in
    let corrupt_official_result fields =
      match official_result () with
      | `Assoc envelope ->
        let message = match List.assoc "message" envelope with
          | `Assoc message -> message | _ -> Alcotest.fail "invalid official fixture message" in
        let block = match List.assoc "content_blocks" message with
          | `List [`Assoc block] -> block | _ -> Alcotest.fail "invalid official fixture block" in
        let block = List.filter (fun (name, _) -> not (List.mem_assoc name fields)) block @ fields in
        let message = List.remove_assoc "content_blocks" message @ ["content_blocks",`List [`Assoc block]] in
        `Assoc (List.remove_assoc "message" envelope @ ["message",`Assoc message])
      | _ -> Alcotest.fail "invalid official fixture envelope" in
    let source = match shape with
      | `Media -> `Assoc ["type",`String "image";"source",malformed_source]
      | `Artifact -> Agent_core.History.content_block_to_json
          (Agent_core.Types.ToolUse {id="call";name="fixture";
            input=`List [`List [`Assoc ["_blob",`Assoc ["sha256",`String survivor.sha256]]]]})
      | `Unknown_tool -> `Assoc ["type",`String "tool_use";"id",`String "call";"input",malformed_source]
      | `Unknown_receipt -> `Assoc ["record_kind",`String "other";"input",malformed_source]
      | `Duplicate_official ->
        (match official_result () with
         | `Assoc fields -> `Assoc (fields @ ["schema",`String "masc.official-client-context-message.v5"])
         | _ -> Alcotest.fail "invalid official fixture envelope")
      | `Unknown_failure_kind ->
        corrupt_official_result ["is_error",`Bool true;"failure_kind",`String "unknown-kind"]
      | `Unknown_error_class ->
        corrupt_official_result ["is_error",`Bool true;
          "failure_kind",Agent_core.Types.tool_failure_kind_to_yojson Reported_tool_error;
          "error_class",`String "unknown-class"]
      | `Captured_media_sibling ->
        Masc.Keeper_librarian_input_capture.message_json (media_message ())
        |> malformed_message_sibling "content"
      | `Official_media_sibling ->
        (match Masc.Keeper_official_client_context_codec.(to_json Canonical_source) (media_message ()) with
         | `Assoc envelope ->
           let message = List.assoc "message" envelope
             |> malformed_message_sibling "content_blocks" in
           `Assoc (List.remove_assoc "message" envelope @
             ["message",message])
         | _ -> Alcotest.fail "invalid official fixture envelope") in
    ignore (save_maintenance_source base_path "keepers/reviewer/refused.json" source);
    (match M.run ~base_path ~scope ~mode:M.Delete_previous_candidates with
     | Error (M.Malformed_structured_artifact_reference _) -> ()
     | Error error -> Alcotest.fail (M.error_to_string error)
     | Ok _ -> Alcotest.fail "malformed or unrecognized owner authorized deletion");
    Alcotest.(check string) "failed scan preserves candidate snapshot" before (bytes ());
    Alcotest.(check (option string)) "failed scan preserves candidate blob"
      (Some "preserve until owners are valid") (fetch_ok store ~sha256:survivor.sha256)))
    [`Media;`Artifact;`Unknown_tool;`Unknown_receipt;`Duplicate_official;`Unknown_failure_kind;`Unknown_error_class;
     `Captured_media_sibling;`Official_media_sibling]
;;

let () =
  Alcotest.run "tool_blob_store_librarian_input_capture"
    [
      ( "gc",
        [
          Alcotest.test_case "maintenance distinguishes arbitrary tool JSON from media ownership" `Quick
            test_maintenance_distinguishes_tool_payloads_from_media_owners;
          Alcotest.test_case "maintenance opaque payloads keep malformed references fail-closed" `Quick
            test_maintenance_opaque_payloads_preserve_fail_closed_boundaries;
        ] );
    ]
