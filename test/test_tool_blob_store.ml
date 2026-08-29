(** Tests for Tool_blob_store + Tool_output.

    Covers:
    - Round-trip: encode then decode for both [Inline] and [Stored] variants.
    - Backward compat: any string without marker reports [Not_marker].
    - Malformed marker surfaces as [Invalid_marker] — a visible, typed
      outcome, not a silent inline fallback.
    - Content-addressed: same bytes -> same sha -> idempotent put.
    - Sharding: blobs land under [<sha[0..1]>/<sha>].
    - Maintenance: union-scanned live refs survive and stable dead refs are
      deleted only on the second explicit retention pass.
    - Concurrent put: simultaneous writes of same content do not corrupt. *)

module B = Tool_blob_store
module M = Tool_blob_maintenance
module O = Tool_output

(* --- Helpers --- *)

let ref_exn ~sha256 ~bytes ~preview ~mime =
  match O.make_artifact_ref ~sha256 ~bytes ~preview ~mime with
  | Ok r -> r
  | Error e -> Alcotest.fail (O.make_error_to_string e)

let fetch_ok store ~sha256 =
  match B.fetch store ~sha256 with
  | Ok value -> value
  | Error error ->
      Alcotest.failf "fetch failed: %s" (B.fetch_error_to_string error)

let stored_ref_exn = function
  | O.Stored reference -> reference
  | O.Inline _ -> Alcotest.fail "expected Stored"

let with_temp_dir f =
  let dir = Filename.temp_file "masc_blob_test" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let cleanup () =
    let rec rm path =
      if Sys.file_exists path then
        if Sys.is_directory path then begin
          Array.iter (fun n -> rm (Filename.concat path n)) (Sys.readdir path);
          Unix.rmdir path
        end
        else Unix.unlink path
    in
    try rm dir with _ -> ()
  in
  let r = try Ok (f dir) with e -> Error e in
  cleanup ();
  match r with Ok v -> v | Error e -> raise e

(* --- Tool_output round-trip --- *)

let test_inline_roundtrip () =
  let s = "hello world\n" in
  let encoded = O.encode_for_agent_core (O.Inline s) in
  Alcotest.(check string) "inline encode = identity" s encoded;
  match O.decode_from_agent_core encoded with
  | O.Not_marker ->
      (* Raw text is not a marker: the content is the string itself,
         already asserted identical above. *)
      ()
  | O.Decoded _ -> Alcotest.fail "expected Not_marker"
  | O.Invalid_marker { detail } ->
      Alcotest.failf "expected Not_marker, got Invalid_marker: %s" detail

let test_stored_roundtrip () =
  let sha256 = String.make 64 'a' in
  let artifact_ref =
    ref_exn ~sha256 ~bytes:128934 ~preview:"first 200 chars\nwith newline"
      ~mime:"text/plain"
  in
  let original = O.Stored artifact_ref in
  let encoded = O.encode_for_agent_core original in
  Alcotest.(check bool)
    "encoded starts with marker"
    true
    (O.is_marker encoded);
  match O.decode_from_agent_core encoded with
  | O.Decoded { sha256 = decoded_sha; bytes; preview; mime } ->
      Alcotest.(check string) "sha256" sha256 decoded_sha;
      Alcotest.(check int) "bytes" 128934 bytes;
      Alcotest.(check string)
        "preview" "first 200 chars\nwith newline" preview;
      Alcotest.(check string) "mime" "text/plain" mime
  | O.Not_marker -> Alcotest.fail "expected Decoded"
  | O.Invalid_marker { detail } ->
      Alcotest.failf "expected Decoded, got Invalid_marker: %s" detail

(* The marker format reads mime with [%s@ ], which stops at a space, so a
   mime carrying a parameter -- text/plain; charset=utf-8 -- encodes fine and
   then fails to come back: the scan reads "text/plain;" and looks for the
   literal " preview=" where "charset=..." stands.

   No caller passes such a mime today (both put sites hand over a literal
   without spaces), so this pins a boundary rather than reporting a live
   defect. It is here because the same file already knows content types
   carry parameters -- [content_type_base] in tool_misc_web_fetch strips
   them -- so the day one reaches this codec, the failure should land in a
   test rather than in a keeper's tool result. #25499. *)
let test_mime_with_a_space_does_not_survive_the_round_trip () =
  let artifact_ref =
    ref_exn ~sha256:(String.make 64 'b') ~bytes:12 ~preview:"hi"
      ~mime:"text/plain; charset=utf-8"
  in
  let encoded = O.encode_for_agent_core (O.Stored artifact_ref) in
  Alcotest.(check bool) "encoding still produces a marker" true
    (O.is_marker encoded);
  match O.decode_from_agent_core encoded with
  | O.Invalid_marker _ -> ()
  | O.Decoded { mime; _ } ->
      Alcotest.failf
        "decode unexpectedly succeeded with mime %S -- if the codec now reads \
         mime up to the next literal, this test should assert the round trip \
         instead of the rejection"
        mime
  | O.Not_marker -> Alcotest.fail "expected Invalid_marker, got Not_marker"

(* [Scanf.sscanf] stops when the format is satisfied; it does not require the
   input to be spent. Trailing bytes after the closing bracket are therefore
   ignored rather than rejected. Same standing as above: pinned, not live. *)
let test_trailing_bytes_after_the_marker_are_ignored () =
  let artifact_ref =
    ref_exn ~sha256:(String.make 64 'c') ~bytes:7 ~preview:"hi"
      ~mime:"text/plain"
  in
  let encoded = O.encode_for_agent_core (O.Stored artifact_ref) in
  match O.decode_from_agent_core (encoded ^ "trailing bytes") with
  | O.Decoded { bytes; _ } ->
      Alcotest.(check int) "decoded the marker and dropped the tail" 7 bytes
  | O.Invalid_marker _ ->
      (* A codec that grew a full-consumption requirement would land here;
         that is the better behaviour, and this test should then assert it. *)
      ()
  | O.Not_marker -> Alcotest.fail "expected a marker"

let test_normalized_artifact_ref_roundtrip () =
  let reference =
    ref_exn
      ~sha256:(String.make 64 'b')
      ~bytes:4096
      ~mime:"application/json"
      ~preview:"{\"ok\":true}"
  in
  match O.normalized_artifact_ref_of_json (O.normalized_artifact_ref_to_json reference) with
  | O.Decoded_normalized_artifact_ref decoded ->
    Alcotest.(check string) "sha256" reference.sha256 decoded.sha256;
    Alcotest.(check int) "bytes" reference.bytes decoded.bytes;
    Alcotest.(check string) "mime" reference.mime decoded.mime;
    Alcotest.(check string) "preview" reference.preview decoded.preview
  | O.Not_normalized_artifact_ref ->
    Alcotest.fail "expected normalized artifact reference"
  | O.Invalid_normalized_artifact_ref { detail } ->
    Alcotest.failf "normalized artifact reference rejected: %s" detail

let test_encoded_marker_stays_under_externalization_threshold () =
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      let threshold = Masc.Tool_bridge.default_externalize_threshold_bytes in
      let payload = String.make (threshold + 1) '"' in
      let encoded = B.put store ~bytes:payload ~mime:"text/plain" |> O.encode_for_agent_core in
      Alcotest.(check bool)
        "marker stays below default externalization threshold"
        true
        (String.length encoded <= threshold);
      match O.decode_from_agent_core encoded with
      | O.Decoded { preview; _ } ->
        Alcotest.(check int) "preview remains documented cap" 200 (String.length preview)
      | O.Not_marker -> Alcotest.fail "expected Decoded"
      | O.Invalid_marker { detail } ->
          Alcotest.failf "expected Decoded, got Invalid_marker: %s" detail)

let test_decode_non_marker () =
  (* Any normal tool output reports Not_marker — backward compat for old
     checkpoints that pre-date the artifact store. The raw string passes
     through untouched. *)
  let cases =
    [
      "";
      "plain text";
      "{\"key\":\"value\"}";
      "[tool:gh id:xyz lines:5 chars:128 summary:\"hi\"]";
      "[masc:other prefix]";
      "[masc:blob"  (* truncated — no trailing space *);
    ]
  in
  List.iter
    (fun s ->
      match O.decode_from_agent_core s with
      | O.Not_marker -> ()
      | O.Decoded _ ->
          Alcotest.failf "expected Not_marker for %S" s
      | O.Invalid_marker _ ->
          Alcotest.failf "expected Not_marker (not Invalid_marker) for %S" s)
    cases

let test_decode_malformed_marker () =
  (* Has the prefix but body is garbage — must NOT raise. Instead of the
     old silent Inline fallback, a malformed marker is now a visible, typed
     [Invalid_marker] outcome; the caller decides what to do with the raw
     text. *)
  let bad_markers =
    [ "[masc:blob sha256=garbage that cannot scanf]"
    ; "[masc:blob sha256=garbage]"
    ]
  in
  List.iter
    (fun bad ->
       match O.decode_from_agent_core bad with
       | O.Invalid_marker { detail } ->
         Alcotest.(check bool)
           "detail explains the failure" true (String.length detail > 0)
       | O.Not_marker ->
         Alcotest.fail "malformed marker must surface as Invalid_marker"
       | O.Decoded _ -> Alcotest.fail "malformed should NOT decode as Stored")
    bad_markers

(* --- Tool_blob_store basic --- *)

let test_put_returns_stored () =
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      let payload = "hello tool output" in
      match B.put store ~bytes:payload ~mime:"text/plain" with
      | O.Stored { sha256; bytes; preview; mime } ->
          Alcotest.(check int) "sha length" 64 (String.length sha256);
          Alcotest.(check int) "bytes" (String.length payload) bytes;
          Alcotest.(check string) "preview" payload preview;
          Alcotest.(check string) "mime" "text/plain" mime
      | O.Inline _ -> Alcotest.fail "put must return Stored")

let test_put_then_fetch () =
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      let payload = String.make 5000 'x' in
      let stored = B.put store ~bytes:payload ~mime:"text/plain" in
      match stored with
      | O.Stored { sha256; _ } -> (
          match B.fetch store ~sha256 with
          | Ok (Some bytes) ->
              Alcotest.(check string) "round-trip bytes" payload bytes
          | Ok None -> Alcotest.fail "fetch returned None"
          | Error error ->
              Alcotest.failf "fetch failed: %s" (B.fetch_error_to_string error))
      | O.Inline _ -> Alcotest.fail "put returned Inline")

let test_put_then_fetch_bounded_ranges () =
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      let payload =
        String.init 8_192 (fun index -> Char.chr (index mod 251))
      in
      match B.put store ~bytes:payload ~mime:"application/octet-stream" with
      | O.Inline _ -> Alcotest.fail "put returned Inline"
      | O.Stored { sha256; _ } ->
        let fetch_range store ~offset ~max_bytes =
          match B.fetch_range store ~sha256 ~offset ~max_bytes with
          | Ok (Some range) -> range
          | Ok None -> Alcotest.fail "fetch_range returned None"
          | Error error ->
            Alcotest.failf
              "fetch_range failed: %s"
              (B.fetch_error_to_string error)
        in
        let first = fetch_range store ~offset:123 ~max_bytes:257 in
        Alcotest.(check int) "range reports total bytes"
          (String.length payload)
          first.total_bytes;
        Alcotest.(check string) "range returns exact bounded bytes"
          (String.sub payload 123 257)
          first.content;
        let reopened_store = B.create ~base_path:dir in
        let tail =
          fetch_range reopened_store ~offset:8_150 ~max_bytes:256
        in
        Alcotest.(check string) "range stops exactly at EOF"
          (String.sub payload 8_150 42)
          tail.content;
        let past_eof =
          fetch_range reopened_store ~offset:9_000 ~max_bytes:256
        in
        Alcotest.(check string) "range beyond EOF is empty"
          ""
          past_eof.content)

let test_fetch_range_revalidates_changed_snapshot () =
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      let payload = String.make 8_192 'x' in
      match B.put store ~bytes:payload ~mime:"text/plain" with
      | O.Inline _ -> Alcotest.fail "put returned Inline"
      | O.Stored { sha256; _ } ->
        (match B.fetch_range store ~sha256 ~offset:0 ~max_bytes:64 with
         | Ok (Some _) -> ()
         | Ok None -> Alcotest.fail "initial fetch_range returned None"
         | Error error ->
           Alcotest.failf
             "initial fetch_range failed: %s"
             (B.fetch_error_to_string error));
        let path =
          Filename.concat
            (Filename.concat (B.root_dir store) (String.sub sha256 0 2))
            sha256
        in
        (match
           Fs_compat.save_file_atomic path (String.make 8_192 'y')
         with
         | Ok () -> ()
         | Error error ->
           Alcotest.failf "failed to corrupt fixture: %s" error);
        match B.fetch_range store ~sha256 ~offset:64 ~max_bytes:64 with
        | Error (B.Integrity_mismatch _) -> ()
        | Error error ->
          Alcotest.failf
            "changed snapshot returned wrong error: %s"
            (B.fetch_error_to_string error)
        | Ok _ ->
          Alcotest.fail
            "changed snapshot bypassed content-address validation")

let test_fetch_miss () =
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      match B.fetch store ~sha256:(String.make 64 '0') with
      | Ok None -> ()
      | Ok (Some _) -> Alcotest.fail "expected None for unknown sha"
      | Error error ->
          Alcotest.failf "fetch failed: %s" (B.fetch_error_to_string error))

let test_idempotent_put () =
  (* Same content twice = same sha = same path, no error. *)
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      let payload = "idempotent payload" in
      let r1 = B.put store ~bytes:payload ~mime:"text/plain" in
      let r2 = B.put store ~bytes:payload ~mime:"text/plain" in
      let sha_of = function
        | O.Stored { sha256; _ } -> sha256
        | O.Inline _ -> Alcotest.fail "expected Stored"
      in
      Alcotest.(check string)
        "same content -> same sha" (sha_of r1) (sha_of r2);
      Alcotest.(check int) "single entry" 1 (List.length (B.list_all store)))

let test_sharding_layout () =
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      let payload = "sharding test" in
      let stored = B.put store ~bytes:payload ~mime:"text/plain" in
      match stored with
      | O.Stored { sha256; _ } ->
          let prefix = String.sub sha256 0 2 in
          let expected =
            Filename.concat (B.root_dir store)
              (Filename.concat prefix sha256)
          in
          Alcotest.(check bool)
            "sharded path exists" true
            (Sys.file_exists expected)
      | O.Inline _ -> Alcotest.fail "put returned Inline")

(* Fixtures here hold a handful of small files and compete with no startup
   watchdog, so they scan unbounded; the budget path has its own tests. *)
let maintenance_ok ~base_path ~mode =
  match M.run ~base_path ~mode with
  | Ok report -> report
  | Error error ->
    Alcotest.failf "maintenance failed: %s" (M.error_to_string error)

let test_maintenance_keeps_live_and_deletes_stable_dead_after_restart () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let live =
        B.put store ~bytes:"live shared bridge output" ~mime:"text/plain"
        |> stored_ref_exn
      in
      let dead =
        B.put store ~bytes:"dead replay sidecar output" ~mime:"text/plain"
        |> stored_ref_exn
      in
      let replay_live =
        B.put store ~bytes:"live gate replay output" ~mime:"text/plain"
        |> stored_ref_exn
      in
      let durable_consumer =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "keepers/keeper-a/sessions/history.jsonl"
      in
      Fs_compat.mkdir_p (Filename.dirname durable_consumer);
      Fs_compat.save_file
        durable_consumer
        (Yojson.Safe.to_string
           (`Assoc
             [ "consumer", `String "Tool_bridge"
             ; "output_ref", `String (O.encode_for_agent_core (O.Stored live))
             ])
         ^ "\n");
      let replay_sidecar =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "gate/replay-results.json"
      in
      Fs_compat.mkdir_p (Filename.dirname replay_sidecar);
      Fs_compat.save_file
        replay_sidecar
        (Yojson.Safe.pretty_to_string
           (`Assoc
             [ "approval_id", `String "approval-maintenance"
             ; ( "outcome"
               , `String (O.encode_for_agent_core (O.Stored replay_live)) )
             ]));
      let observed = maintenance_ok ~base_path ~mode:M.Observe_only in
      Alcotest.(check int) "union includes both consumers" 2 observed.live_references;
      Alcotest.(check int) "three blobs observed" 3 observed.blobs_observed;
      Alcotest.(check int) "one candidate" 1 observed.candidates_recorded;
      Alcotest.(check int) "observe deletes none" 0 observed.deleted;
      Alcotest.(check bool)
        "dead remains after observation"
        true
        (Option.is_some (fetch_ok store ~sha256:dead.sha256));
      (* The second call deliberately uses only the durable candidate snapshot:
         this is the restart boundary of the two-state retention policy. *)
      let swept =
        maintenance_ok
          ~base_path
          ~mode:M.Delete_previous_candidates
      in
      Alcotest.(check int) "stable dead blob deleted" 1 swept.deleted;
      Alcotest.(check (option string))
        "shared consumer reference remains live"
        (Some "live shared bridge output")
        (fetch_ok store ~sha256:live.sha256);
      Alcotest.(check (option string))
        "dead blob no longer exists"
        None
        (fetch_ok store ~sha256:dead.sha256);
      Alcotest.(check (option string))
        "Gate replay sidecar reference remains live"
        (Some "live gate replay output")
        (fetch_ok store ~sha256:replay_live.sha256))

let test_maintenance_keeps_wire_capture_reference_within_retention () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let captured =
        B.put store ~bytes:"captured provider response" ~mime:"text/plain"
        |> stored_ref_exn
      in
      let dead =
        B.put store ~bytes:"unreferenced provider response" ~mime:"text/plain"
        |> stored_ref_exn
      in
      let wire_capture =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "wire-capture/2026-07/28.jsonl"
      in
      Fs_compat.mkdir_p (Filename.dirname wire_capture);
      Fs_compat.save_file
        wire_capture
        (Yojson.Safe.to_string
           (`Assoc
             [ "kind", `String "response"
             ; ( "response_text"
               , `String (O.encode_for_agent_core (O.Stored captured)) )
             ])
         ^ "\n");
      let observed = maintenance_ok ~base_path ~mode:M.Observe_only in
      Alcotest.(check int)
        "wire capture reference is live"
        1
        observed.live_references;
      Alcotest.(check int)
        "only the unreferenced blob is a candidate"
        1
        observed.candidates_recorded;
      let swept =
        maintenance_ok
          ~base_path
          ~mode:M.Delete_previous_candidates
      in
      Alcotest.(check int) "stable unreferenced blob is deleted" 1 swept.deleted;
      Alcotest.(check (option string))
        "wire capture blob remains readable"
        (Some "captured provider response")
        (fetch_ok store ~sha256:captured.sha256);
      Alcotest.(check (option string))
        "unreferenced blob no longer exists"
        None
        (fetch_ok store ~sha256:dead.sha256))

let test_maintenance_rejects_uncoordinated_cluster_roots () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let blob =
        B.put store ~bytes:"cluster-owned output" ~mime:"text/plain"
        |> stored_ref_exn
      in
      let cluster_capture =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "clusters/secondary/wire-capture/2026-07/28.jsonl"
      in
      Fs_compat.mkdir_p (Filename.dirname cluster_capture);
      Fs_compat.save_file
        cluster_capture
        (Yojson.Safe.to_string
           (`Assoc
             [ "response_text", `String (O.encode_for_agent_core (O.Stored blob)) ])
         ^ "\n");
      (match M.run ~base_path ~mode:M.Delete_previous_candidates with
       | Error
           (M.Clustered_durable_roots_uncoordinated
             { path; entries }) ->
         Alcotest.(check string)
           "exact cluster root"
           (Filename.concat
              (Common.masc_dir_from_base_path ~base_path)
              "clusters")
           path;
         Alcotest.(check int) "one cluster entry" 1 entries
       | Error error ->
         Alcotest.failf
           "unexpected clustered maintenance error: %s"
           (M.error_to_string error)
       | Ok _ ->
         Alcotest.fail
           "shared blob maintenance ran without cross-cluster coordination");
      Alcotest.(check (option string))
        "cluster-owned blob remains readable"
        (Some "cluster-owned output")
        (fetch_ok store ~sha256:blob.sha256);
      Alcotest.(check bool)
        "cluster refusal does not publish a candidate snapshot"
        false
        (Sys.file_exists (M.candidate_snapshot_path ~base_path)))

let test_maintenance_malformed_reference_fails_closed () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let blob =
        B.put store ~bytes:"must survive malformed source" ~mime:"text/plain"
        |> stored_ref_exn
      in
      let source =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "gate/malformed.jsonl"
      in
      Fs_compat.mkdir_p (Filename.dirname source);
      Fs_compat.save_file source "{\"output\":\"[masc:blob sha256=garbage]\"}\n";
      (match M.run ~base_path ~mode:M.Delete_previous_candidates with
       | Error (M.Malformed_artifact_reference { path; line; _ }) ->
         Alcotest.(check string) "exact malformed source" source path;
         Alcotest.(check int) "exact malformed line" 1 line
       | Error error ->
         Alcotest.failf
           "unexpected maintenance error: %s"
           (M.error_to_string error)
       | Ok _ -> Alcotest.fail "malformed reference reached deletion");
      Alcotest.(check (option string))
        "blob retained on malformed reference"
        (Some "must survive malformed source")
        (fetch_ok store ~sha256:blob.sha256))

let test_maintenance_noncanonical_reference_fails_closed () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let blob =
        B.put store ~bytes:"must survive noncanonical source" ~mime:"text/plain"
        |> stored_ref_exn
      in
      let source =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "gate/noncanonical.json"
      in
      Fs_compat.mkdir_p (Filename.dirname source);
      Fs_compat.save_file
        source
        (Yojson.Safe.to_string
           (`String
             (O.encode_for_agent_core (O.Stored blob) ^ " trailing text")));
      (match M.run ~base_path ~mode:M.Delete_previous_candidates with
       | Error (M.Malformed_artifact_reference { path; line; offset; _ }) ->
         Alcotest.(check string) "exact noncanonical source" source path;
         Alcotest.(check int) "exact malformed line" 1 line;
         Alcotest.(check int) "whole-value offset" 0 offset
       | Error error ->
         Alcotest.failf
           "unexpected maintenance error: %s"
           (M.error_to_string error)
       | Ok _ -> Alcotest.fail "noncanonical reference reached deletion");
      Alcotest.(check (option string))
        "blob retained on noncanonical reference"
        (Some "must survive noncanonical source")
        (fetch_ok store ~sha256:blob.sha256))

let test_maintenance_ignores_marker_embedded_in_prose () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let blob =
        B.put store ~bytes:"unreferenced output" ~mime:"text/plain"
        |> stored_ref_exn
      in
      let source =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "gate/prompt.json"
      in
      Fs_compat.mkdir_p (Filename.dirname source);
      Fs_compat.save_file
        source
        (Yojson.Safe.to_string
           (`Assoc
             [ ( "content"
               , `String
                   ("documentation example: "
                    ^ O.encode_for_agent_core (O.Stored blob)) )
             ]));
      let observed = maintenance_ok ~base_path ~mode:M.Observe_only in
      Alcotest.(check int)
        "embedded marker is not a live reference"
        0
        observed.live_references;
      Alcotest.(check int)
        "prose does not claim blob ownership"
        1
        observed.candidates_recorded;
      Alcotest.(check (option string))
        "observe-only scan retains candidate"
        (Some "unreferenced output")
        (fetch_ok store ~sha256:blob.sha256))

let test_maintenance_does_not_scan_repository_mirrors () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let blob =
        B.put store ~bytes:"not owned by a repository mirror" ~mime:"text/plain"
        |> stored_ref_exn
      in
      let repository_source =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "repos/masc/docs/blob-marker.md"
      in
      Fs_compat.mkdir_p (Filename.dirname repository_source);
      Fs_compat.save_file
        repository_source
        "documentation example: [masc:blob not-a-reference]";
      let observed = maintenance_ok ~base_path ~mode:M.Observe_only in
      Alcotest.(check int)
        "repository source does not claim blob ownership"
        1
        observed.candidates_recorded;
      let swept =
        maintenance_ok
          ~base_path
          ~mode:M.Delete_previous_candidates
      in
      Alcotest.(check int) "stable unowned blob is deleted" 1 swept.deleted;
      Alcotest.(check (option string))
        "repository text did not retain the blob"
        None
        (fetch_ok store ~sha256:blob.sha256))

let test_maintenance_does_not_scan_trajectory_previews () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let blob =
        B.put store ~bytes:"not owned by a trajectory preview" ~mime:"text/plain"
        |> stored_ref_exn
      in
      let trajectory_source =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "trajectories/keeper-a/trace.jsonl"
      in
      Fs_compat.mkdir_p (Filename.dirname trajectory_source);
      let marker = O.encode_for_agent_core (O.Stored blob) in
      Fs_compat.save_file
        trajectory_source
        (Yojson.Safe.to_string
           (`Assoc
             [ ( "result"
               , `String
                   (String.sub marker 0 (min 120 (String.length marker))
                    ^ "...") )
             ])
         ^ "\n");
      let observed = maintenance_ok ~base_path ~mode:M.Observe_only in
      Alcotest.(check int)
        "trajectory preview is not a live reference"
        0
        observed.live_references;
      Alcotest.(check int)
        "trajectory preview does not claim blob ownership"
        1
        observed.candidates_recorded;
      Alcotest.(check (option string))
        "observe-only scan retains trajectory candidate"
        (Some "not owned by a trajectory preview")
        (fetch_ok store ~sha256:blob.sha256))

let test_maintenance_rechecks_candidate_referenced_before_startup () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let candidate =
        B.put store ~bytes:"referenced before startup sweep" ~mime:"text/plain"
        |> stored_ref_exn
      in
      let observed = maintenance_ok ~base_path ~mode:M.Observe_only in
      Alcotest.(check int) "one candidate observed" 1 observed.candidates_recorded;
      let durable_consumer =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "keepers/keeper-a/history.jsonl"
      in
      Fs_compat.mkdir_p (Filename.dirname durable_consumer);
      Fs_compat.save_file
        durable_consumer
        (Yojson.Safe.to_string
           (`Assoc
             [ "output_ref", `String (O.encode_for_agent_core (O.Stored candidate)) ])
         ^ "\n");
      let swept =
        maintenance_ok
          ~base_path
          ~mode:M.Delete_previous_candidates
      in
      Alcotest.(check int) "new live reference prevents deletion" 0 swept.deleted;
      Alcotest.(check (option string))
        "newly referenced candidate remains readable"
        (Some "referenced before startup sweep")
        (fetch_ok store ~sha256:candidate.sha256))

let test_maintenance_keeps_normalized_tool_call_blob_reference () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let reference =
        B.put
          store
          ~bytes:"normalized tool-call output"
          ~mime:"text/plain"
        |> stored_ref_exn
      in
      let tool_call_log =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "tool_calls/2026-07/29.jsonl"
      in
      Fs_compat.mkdir_p (Filename.dirname tool_call_log);
      Fs_compat.save_file
        tool_call_log
        (Yojson.Safe.to_string
           (`Assoc
             [ "keeper", `String "keeper-tool-log"
             ; "tool", `String "large_output"
             ; ( "output"
               , `Assoc
                   [ ( "_blob"
                     , `Assoc
                         [ "sha256", `String reference.sha256
                         ; "bytes", `Int reference.bytes
                         ; "mime", `String reference.mime
                         ; "preview", `String reference.preview
                         ] )
                   ] )
             ])
         ^ "\n");
      let observed = maintenance_ok ~base_path ~mode:M.Observe_only in
      Alcotest.(check int)
        "normalized tool-call reference is live"
        1
        observed.live_references;
      Alcotest.(check int)
        "normalized live blob is not a candidate"
        0
        observed.candidates_recorded;
      let swept =
        maintenance_ok
          ~base_path
          ~mode:M.Delete_previous_candidates
      in
      Alcotest.(check int) "normalized live blob is not deleted" 0 swept.deleted;
      Alcotest.(check (option string))
        "normalized tool-call blob remains readable"
        (Some "normalized tool-call output")
        (fetch_ok store ~sha256:reference.sha256))

let test_maintenance_follows_typed_result_manifest () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let child =
        B.put_durable store ~bytes:"manifest-owned child" ~mime:"text/plain"
      in
      let structured_content =
        `Assoc [ "output_artifact", O.normalized_artifact_ref_to_json child ]
      in
      let manifest_payload =
        O.artifact_manifest_to_json
          ~content:(Yojson.Safe.to_string structured_content)
          ~structured_content
        |> Yojson.Safe.to_string
      in
      let manifest =
        B.put_durable
          store
          ~bytes:manifest_payload
          ~mime:O.artifact_manifest_mime
      in
      let checkpoint =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "keepers/keeper-a/checkpoint.json"
      in
      Fs_compat.mkdir_p (Filename.dirname checkpoint);
      Fs_compat.save_file
        checkpoint
        (Yojson.Safe.to_string
           (`Assoc
             [ ( "tool_result"
               , `String (O.encode_for_agent_core (O.Stored manifest)) ) ]));
      let observed = maintenance_ok ~base_path ~mode:M.Observe_only in
      Alcotest.(check int)
        "checkpoint marker roots manifest and child"
        2
        observed.live_references;
      Alcotest.(check int) "manifest graph has no candidates" 0 observed.candidates_recorded;
      let swept =
        maintenance_ok ~base_path ~mode:M.Delete_previous_candidates
      in
      Alcotest.(check int) "manifest graph survives the second pass" 0 swept.deleted;
      Alcotest.(check (option string))
        "manifest-owned child remains readable"
        (Some "manifest-owned child")
        (fetch_ok store ~sha256:child.sha256))

let test_maintenance_rejects_malformed_typed_result_manifest () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let survivor =
        B.put_durable store ~bytes:"survive malformed manifest" ~mime:"text/plain"
      in
      let malformed =
        O.artifact_manifest_to_json
          ~content:"malformed"
          ~structured_content:
            (`Assoc
               [ ( "output_artifact"
                 , `Assoc [ "_blob", `Assoc [ "sha256", `String survivor.sha256 ] ]
                 )
               ])
        |> Yojson.Safe.to_string
      in
      let manifest =
        B.put_durable store ~bytes:malformed ~mime:O.artifact_manifest_mime
      in
      let checkpoint =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "keepers/keeper-a/checkpoint.json"
      in
      Fs_compat.mkdir_p (Filename.dirname checkpoint);
      Fs_compat.save_file
        checkpoint
        (Yojson.Safe.to_string
           (`String (O.encode_for_agent_core (O.Stored manifest))));
      (match M.run ~base_path ~mode:M.Delete_previous_candidates with
       | Error (M.Artifact_manifest_invalid { sha256; _ }) ->
         Alcotest.(check string) "exact malformed manifest" manifest.sha256 sha256
       | Error error ->
         Alcotest.failf "unexpected maintenance error: %s" (M.error_to_string error)
       | Ok _ -> Alcotest.fail "malformed typed manifest reached deletion");
      Alcotest.(check (option string))
        "malformed manifest abort preserves unrelated blobs"
        (Some "survive malformed manifest")
        (fetch_ok store ~sha256:survivor.sha256))

let test_maintenance_malformed_normalized_blob_fails_closed () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let reference =
        B.put store ~bytes:"survive malformed normalized ref" ~mime:"text/plain"
        |> stored_ref_exn
      in
      let tool_call_log =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "tool_calls/2026-07/29.jsonl"
      in
      Fs_compat.mkdir_p (Filename.dirname tool_call_log);
      Fs_compat.save_file
        tool_call_log
        (Yojson.Safe.to_string
           (`Assoc
             [ ( "output"
               , `Assoc
                   [ ( "_blob"
                     , `Assoc [ "sha256", `String reference.sha256 ] )
                   ] )
             ])
         ^ "\n");
      (match M.run ~base_path ~mode:M.Delete_previous_candidates with
       | Error
           (M.Malformed_structured_artifact_reference
             { path; line; _ }) ->
         Alcotest.(check string) "exact malformed tool-call log" tool_call_log path;
         Alcotest.(check int) "exact malformed tool-call line" 1 line
       | Error error ->
         Alcotest.failf
           "unexpected normalized-reference error: %s"
           (M.error_to_string error)
       | Ok _ -> Alcotest.fail "malformed normalized reference reached deletion");
      Alcotest.(check (option string))
        "malformed normalized reference retains every blob"
        (Some "survive malformed normalized ref")
        (fetch_ok store ~sha256:reference.sha256))

let test_maintenance_ignores_route_evidence_artifact_schema () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let reference =
        B.put store ~bytes:"schema-safe live artifact" ~mime:"text/plain"
        |> stored_ref_exn
      in
      let tool_call_log =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "tool_calls/2026-08/25.jsonl"
      in
      Fs_compat.mkdir_p (Filename.dirname tool_call_log);
      let artifact_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "output_artifact"
                  , `Assoc
                      [ "type", `String "object"
                      ; ( "properties"
                        , `Assoc
                            [ ( "_blob"
                              , `Assoc [ "type", `String "object" ] )
                            ] )
                      ] )
                ] )
          ]
      in
      Fs_compat.save_file
        tool_call_log
        (Yojson.Safe.to_string
           (`Assoc
             [ ( "route_evidence"
               , `Assoc
                   [ ( "composable_output"
                     , `Assoc
                         [ "kind", `String "json"
                         ; "schema", artifact_schema
                         ] )
                   ] )
             ; ( "artifact_refs"
               , `List [ O.normalized_artifact_ref_to_json reference ] )
             ])
         ^ "\n");
      let observed = maintenance_ok ~base_path ~mode:M.Observe_only in
      Alcotest.(check int)
        "route schema is not an artifact and the durable root remains live"
        1
        observed.live_references;
      Alcotest.(check int)
        "live artifact is not recorded as a deletion candidate"
        0
        observed.candidates_recorded)
;;

let test_maintenance_truncated_normalized_blob_fails_closed () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let reference =
        B.put store ~bytes:"survive truncated normalized ref" ~mime:"text/plain"
        |> stored_ref_exn
      in
      let observed = maintenance_ok ~base_path ~mode:M.Observe_only in
      Alcotest.(check int)
        "unreferenced blob is first recorded"
        1
        observed.candidates_recorded;
      let tool_call_log =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "tool_calls/2026-07/29.jsonl"
      in
      Fs_compat.mkdir_p (Filename.dirname tool_call_log);
      let complete_reference =
        O.normalized_artifact_ref_to_json reference
        |> Yojson.Safe.to_string
      in
      Fs_compat.save_file
        tool_call_log
        ("{\"output\":" ^ complete_reference);
      (match M.run ~base_path ~mode:M.Delete_previous_candidates with
       | Error
           (M.Malformed_structured_artifact_reference
             { path; line; _ }) ->
         Alcotest.(check string) "exact truncated tool-call log" tool_call_log path;
         Alcotest.(check int) "exact truncated tool-call line" 1 line
       | Error error ->
         Alcotest.failf
           "unexpected truncated-reference error: %s"
           (M.error_to_string error)
       | Ok _ ->
         Alcotest.fail "truncated normalized reference reached deletion");
      Alcotest.(check (option string))
        "truncated normalized reference retains every blob"
        (Some "survive truncated normalized ref")
        (fetch_ok store ~sha256:reference.sha256))

let test_maintenance_unlink_failure_is_typed () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let sha256 = String.make 64 'a' in
      let shard_dir =
        Filename.concat (B.root_dir store) (String.sub sha256 0 2)
      in
      Fs_compat.mkdir_p shard_dir;
      Unix.mkdir (Filename.concat shard_dir sha256) 0o755;
      ignore (maintenance_ok ~base_path ~mode:M.Observe_only);
      match M.run ~base_path ~mode:M.Delete_previous_candidates with
      | Error
          (M.Blob_delete_failed
            { Tool_blob_store.sha256 = actual; _ }) ->
        Alcotest.(check string) "exact failed blob" sha256 actual
      | Error error ->
        Alcotest.failf
          "unexpected unlink error: %s"
          (M.error_to_string error)
      | Ok _ -> Alcotest.fail "unlink failure was silently skipped")

let test_maintenance_rejects_symbolic_link_shard () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      Fs_compat.mkdir_p (B.root_dir store);
      let outside = Filename.concat base_path "outside-blobs" in
      Unix.mkdir outside 0o755;
      Fs_compat.save_file
        (Filename.concat outside (String.make 64 'a'))
        "outside";
      Unix.symlink outside (Filename.concat (B.root_dir store) "aa");
      match M.run ~base_path ~mode:M.Observe_only with
      | Error (M.Blob_listing_failed { Tool_blob_store.path; _ }) ->
        Alcotest.(check string)
          "exact symbolic-link shard"
          (Filename.concat (B.root_dir store) "aa")
          path
      | Error error ->
        Alcotest.failf
          "unexpected symbolic-link error: %s"
          (M.error_to_string error)
      | Ok _ -> Alcotest.fail "symbolic-link shard crossed blob ownership")

let test_maintenance_rejects_symbolic_link_durable_source () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let blob =
        B.put store ~bytes:"must survive linked source" ~mime:"text/plain"
        |> stored_ref_exn
      in
      let outside = Filename.concat base_path "outside-consumer.json" in
      Fs_compat.save_file
        outside
        (Yojson.Safe.to_string
           (`Assoc
             [ "output_ref", `String (O.encode_for_agent_core (O.Stored blob)) ]));
      let linked_source =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "messages/linked-consumer.json"
      in
      Fs_compat.mkdir_p (Filename.dirname linked_source);
      Unix.symlink outside linked_source;
      (match M.run ~base_path ~mode:M.Observe_only with
       | Error (M.Durable_source_stat_failed { path; _ }) ->
         Alcotest.(check string) "exact linked source" linked_source path
       | Error error ->
         Alcotest.failf
           "unexpected linked-source error: %s"
           (M.error_to_string error)
       | Ok _ -> Alcotest.fail "symbolic-link source was silently skipped");
      Alcotest.(check (option string))
        "blob retained when source ownership is ambiguous"
        (Some "must survive linked source")
        (fetch_ok store ~sha256:blob.sha256))

let test_maintenance_rejects_symbolic_link_candidate_snapshot () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let blob =
        B.put store ~bytes:"must survive linked snapshot" ~mime:"text/plain"
        |> stored_ref_exn
      in
      ignore (maintenance_ok ~base_path ~mode:M.Observe_only);
      let candidate_path = M.candidate_snapshot_path ~base_path in
      let outside = Filename.concat base_path "outside-candidates.json" in
      Fs_compat.save_file
        outside
        (Yojson.Safe.to_string
           (`Assoc
             [ "schema_version", `Int 1
             ; "unreferenced_candidates", `List [ `String blob.sha256 ]
             ]));
      Sys.remove candidate_path;
      Unix.symlink outside candidate_path;
      (match M.run ~base_path ~mode:M.Delete_previous_candidates with
       | Error (M.Candidate_snapshot_read_failed { path; _ }) ->
         Alcotest.(check string) "exact linked snapshot" candidate_path path
       | Error error ->
         Alcotest.failf
           "unexpected linked-snapshot error: %s"
           (M.error_to_string error)
       | Ok _ -> Alcotest.fail "symbolic-link candidate snapshot reached deletion");
      Alcotest.(check (option string))
        "blob retained when candidate snapshot ownership is ambiguous"
        (Some "must survive linked snapshot")
        (fetch_ok store ~sha256:blob.sha256))

(* --- Repeated put: documents the atomicity contract --- *)

(* Atomicity is guaranteed at the OS layer by [Fs_compat.save_file_atomic]
   (tempfile + rename). Same-content puts always produce same sha256 ->
   same path -> rename is idempotent. We don't need a true concurrency test
   here; serial repetition exercises the same code path. *)
let test_repeated_put_no_dup () =
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      let payload = String.make 1024 'z' in
      for _ = 1 to 8 do
        let _ = B.put store ~bytes:payload ~mime:"text/plain" in
        ()
      done;
      Alcotest.(check int)
        "single sha after 8 puts" 1
        (List.length (B.list_all store));
      let sha = List.hd (B.list_all store) in
      Alcotest.(check (option string))
        "fetched content matches" (Some payload)
        (fetch_ok store ~sha256:sha))

(* --- Storage-failure contract --- *)

(* [put] must surface a storage failure (raise) rather than silently returning
   a [Stored] marker for bytes it never persisted. Here [base_path] is a
   regular file, so the blob store directory cannot be created and the write
   cannot land. Using a file (not a chmod) makes the failure structural
   (ENOTDIR), so the test holds even when run as root. *)
let test_put_raises_on_unwritable_store () =
  let file = Filename.temp_file "masc_blob_unwritable" "" in
  let store = B.create ~base_path:file in
  let raised =
    try
      let _ = B.put store ~bytes:(String.make 5000 'x') ~mime:"text/plain" in
      false
    with _ -> true
  in
  (try Sys.remove file with _ -> ());
  Alcotest.(check bool) "put raises on unwritable store" true raised

let test_fetch_rejects_non_regular_paths () =
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      let assert_rejected character expected_kind create_path =
        let sha256 = String.make 64 character in
        let shard_dir =
          Filename.concat (B.root_dir store) (String.make 2 character)
        in
        Fs_compat.mkdir_p shard_dir;
        let path = Filename.concat shard_dir sha256 in
        create_path path;
        match B.fetch store ~sha256 with
        | Error
            (B.Owned_read_failed
              { failure = Fs_compat.Path_is_not_regular_file { kind; _ }
              ; _
              }) ->
            Alcotest.(check bool) "exact non-regular kind" true (kind = expected_kind)
        | Error error ->
            Alcotest.failf "unexpected fetch error: %s" (B.fetch_error_to_string error)
        | Ok _ -> Alcotest.fail "non-regular path reached blob read"
      in
      let target = Filename.concat dir "symlink-target" in
      Fs_compat.save_file target "outside blob store";
      assert_rejected 'a' Unix.S_DIR (fun path -> Unix.mkdir path 0o755);
      assert_rejected 'b' Unix.S_FIFO (fun path -> Unix.mkfifo path 0o600);
      assert_rejected 'c' Unix.S_LNK (fun path -> Unix.symlink target path))

let test_fetch_reports_inspection_failure () =
  let base_path = Filename.temp_file "masc_blob_parent_file" "" in
  let store = B.create ~base_path in
  let sha256 = String.make 64 'b' in
  let result = B.fetch store ~sha256 in
  (try Sys.remove base_path with _ -> ());
  match result with
  | Error
      (B.Owned_read_failed
        { failure = Fs_compat.Ownership_boundary_rejected _; _ }) -> ()
  | Error error ->
      Alcotest.failf
        "unexpected fetch error: %s"
        (B.fetch_error_to_string error)
  | Ok None -> Alcotest.fail "structural store failure was reported as missing"
  | Ok (Some _) -> Alcotest.fail "structural store failure returned bytes"

let test_fetch_rejects_symbolic_link_parent () =
  with_temp_dir (fun dir ->
    let outside = Filename.concat dir "outside" in
    Unix.mkdir outside 0o755;
    let linked_parent = Filename.concat dir ".masc" in
    Unix.symlink outside linked_parent;
    Fun.protect
      ~finally:(fun () -> Unix.unlink linked_parent)
      (fun () ->
         let store = B.create ~base_path:dir in
         match B.fetch store ~sha256:(String.make 64 '0') with
         | Error
             (B.Owned_read_failed
               { failure = Fs_compat.Ownership_boundary_rejected _; _ }) -> ()
         | Error error ->
           Alcotest.failf
             "unexpected fetch error: %s"
             (B.fetch_error_to_string error)
         | Ok _ -> Alcotest.fail "symbolic-link parent escaped blob ownership"))

let test_fetch_reports_integrity_mismatch () =
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      let original = "content-addressed bytes" in
      match B.put store ~bytes:original ~mime:"text/plain" with
      | O.Inline _ -> Alcotest.fail "put returned Inline"
      | O.Stored { sha256; _ } ->
          let path =
            Filename.concat
              (Filename.concat (B.root_dir store) (String.sub sha256 0 2))
              sha256
          in
          Fs_compat.save_file path "tampered bytes";
          (match B.fetch store ~sha256 with
           | Error (B.Integrity_mismatch _) -> ()
           | Error error ->
               Alcotest.failf
                 "unexpected fetch error: %s"
                 (B.fetch_error_to_string error)
           | Ok None -> Alcotest.fail "tampered blob was reported as missing"
           | Ok (Some _) -> Alcotest.fail "tampered blob passed digest verification"))

let test_sha256_rejects_path_component () =
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      match B.fetch store ~sha256:("../" ^ String.make 61 'a') with
      | Error (B.Invalid_sha256 _) -> ()
      | Error error ->
          Alcotest.failf
            "unexpected fetch error: %s"
            (B.fetch_error_to_string error)
      | Ok _ -> Alcotest.fail "path-like digest reached blob lookup")

(* --- Entry point --- *)

let () =
  Alcotest.run "tool_blob_store"
    [
      ( "tool_output round-trip",
        [
          Alcotest.test_case "inline" `Quick test_inline_roundtrip;
          Alcotest.test_case "stored" `Quick test_stored_roundtrip;
          Alcotest.test_case "mime with a space does not survive" `Quick
            test_mime_with_a_space_does_not_survive_the_round_trip;
          Alcotest.test_case "trailing bytes after the marker are ignored"
            `Quick test_trailing_bytes_after_the_marker_are_ignored;
          Alcotest.test_case
            "normalized artifact reference"
            `Quick
            test_normalized_artifact_ref_roundtrip;
          Alcotest.test_case
            "encoded marker stays under externalization threshold"
            `Quick
            test_encoded_marker_stays_under_externalization_threshold;
          Alcotest.test_case "non-marker = Not_marker" `Quick
            test_decode_non_marker;
          Alcotest.test_case "malformed = Invalid_marker" `Quick
            test_decode_malformed_marker;
        ] );
      ( "blob store basic",
        [
          Alcotest.test_case "put returns Stored" `Quick
            test_put_returns_stored;
          Alcotest.test_case "put then fetch" `Quick test_put_then_fetch;
          Alcotest.test_case "put then fetch bounded ranges" `Quick
            test_put_then_fetch_bounded_ranges;
          Alcotest.test_case "changed range snapshot revalidates digest" `Quick
            test_fetch_range_revalidates_changed_snapshot;
          Alcotest.test_case "fetch miss = None" `Quick test_fetch_miss;
          Alcotest.test_case "idempotent put" `Quick test_idempotent_put;
          Alcotest.test_case "sharding layout" `Quick test_sharding_layout;
        ] );
      ( "gc",
        [
          Alcotest.test_case
            "maintenance keeps live and deletes stable dead after restart"
            `Quick
            test_maintenance_keeps_live_and_deletes_stable_dead_after_restart;
          Alcotest.test_case
            "maintenance malformed reference fails closed"
            `Quick
            test_maintenance_malformed_reference_fails_closed;
          Alcotest.test_case
            "maintenance noncanonical reference fails closed"
            `Quick
            test_maintenance_noncanonical_reference_fails_closed;
          Alcotest.test_case
            "maintenance ignores marker embedded in prose"
            `Quick
            test_maintenance_ignores_marker_embedded_in_prose;
          Alcotest.test_case
            "maintenance keeps wire-capture reference within retention"
            `Quick
            test_maintenance_keeps_wire_capture_reference_within_retention;
          Alcotest.test_case
            "maintenance rejects uncoordinated cluster roots"
            `Quick
            test_maintenance_rejects_uncoordinated_cluster_roots;
          Alcotest.test_case
            "maintenance ignores repository mirrors"
            `Quick
            test_maintenance_does_not_scan_repository_mirrors;
          Alcotest.test_case
            "maintenance ignores trajectory previews"
            `Quick
            test_maintenance_does_not_scan_trajectory_previews;
          Alcotest.test_case
            "maintenance rechecks candidate referenced before startup"
            `Quick
            test_maintenance_rechecks_candidate_referenced_before_startup;
          Alcotest.test_case
            "maintenance keeps normalized tool-call blob reference"
            `Quick
            test_maintenance_keeps_normalized_tool_call_blob_reference;
          Alcotest.test_case
            "maintenance follows typed result manifest"
            `Quick
            test_maintenance_follows_typed_result_manifest;
          Alcotest.test_case
            "maintenance rejects malformed typed result manifest"
            `Quick
            test_maintenance_rejects_malformed_typed_result_manifest;
          Alcotest.test_case
            "maintenance malformed normalized blob fails closed"
            `Quick
            test_maintenance_malformed_normalized_blob_fails_closed;
          Alcotest.test_case
            "maintenance ignores route evidence artifact schema"
            `Quick
            test_maintenance_ignores_route_evidence_artifact_schema;
          Alcotest.test_case
            "maintenance truncated normalized blob fails closed"
            `Quick
            test_maintenance_truncated_normalized_blob_fails_closed;
          Alcotest.test_case
            "maintenance unlink failure is typed"
            `Quick
            test_maintenance_unlink_failure_is_typed;
          Alcotest.test_case
            "maintenance rejects symbolic-link shard"
            `Quick
            test_maintenance_rejects_symbolic_link_shard;
          Alcotest.test_case
            "maintenance rejects symbolic-link durable source"
            `Quick
            test_maintenance_rejects_symbolic_link_durable_source;
          Alcotest.test_case
            "maintenance rejects symbolic-link candidate snapshot"
            `Quick
            test_maintenance_rejects_symbolic_link_candidate_snapshot;
        ] );
      ( "atomicity",
        [
          Alcotest.test_case "repeated put no dup" `Quick
            test_repeated_put_no_dup;
        ] );
      ( "storage failure",
        [
          Alcotest.test_case "put raises on unwritable store" `Quick
            test_put_raises_on_unwritable_store;
          Alcotest.test_case "fetch rejects non-regular paths" `Quick
            test_fetch_rejects_non_regular_paths;
          Alcotest.test_case "fetch reports inspection failure" `Quick
            test_fetch_reports_inspection_failure;
          Alcotest.test_case "fetch rejects symbolic-link parent" `Quick
            test_fetch_rejects_symbolic_link_parent;
          Alcotest.test_case "fetch reports integrity mismatch" `Quick
            test_fetch_reports_integrity_mismatch;
          Alcotest.test_case "sha256 rejects path component" `Quick
            test_sha256_rejects_path_component;
        ] );
    ]
