(* V05 (iter 25): Memory_jsonl typed truncation marker.

   Validates the encoder+decoder contract introduced to close the
   structural half of V05 (HIGH) from
   .tmp/memory-compacting-analysis.html:

   - encode_line preserves caller's value shape verbatim when the
     serialised form is under [max_value_size] (1 MB).

   - encode_line wraps >1MB values in a typed-marker [`Assoc]
     {_truncated:true, _original_type, _original_size_bytes, _preview}
     instead of a bare [`String], so downstream decoders can branch
     explicitly via [value_is_truncated_marker] rather than mis-
     parsing a fabricated string as a real payload.

   - [value_is_truncated_marker] is structural (Yojson constructor +
     Bool field equality) — no false positives on payloads that
     happen to contain a [_truncated] field with non-Bool-true
     value. *)

let assoc_field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let tmpdir prefix =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  dir

let require_ok = function
  | Ok () -> ()
  | Error msg -> Alcotest.fail msg

let test_round_trip_small_assoc () =
  let payload : Yojson.Safe.t =
    `Assoc [("foo", `String "bar"); ("n", `Int 42)]
  in
  let line = Memory_jsonl.encode_line ~key:"small" ~value:(Some payload) in
  match Memory_jsonl.parse_line line with
  | None -> Alcotest.fail "parse_line returned None on well-formed line"
  | Some (key, Some decoded, _ts) ->
    Alcotest.(check string) "key preserved" "small" key;
    Alcotest.(check bool)
      "decoded is not a truncation marker"
      false
      (Memory_jsonl.value_is_truncated_marker decoded);
    Alcotest.(check string)
      "payload byte-equal after round-trip"
      (Yojson.Safe.to_string payload)
      (Yojson.Safe.to_string decoded)
  | Some (_, None, _) ->
    Alcotest.fail "decoded value was None (tombstone) instead of Some payload"

let test_truncation_wraps_large_assoc () =
  (* Build an Assoc whose serialised form exceeds 1 MB.
     Each `String` field is 4 KB; 300 fields -> ~1.2 MB serialised. *)
  let big_string = String.make 4096 'x' in
  let fields =
    List.init 300 (fun i ->
        (Printf.sprintf "field_%d" i, `String big_string))
  in
  let payload : Yojson.Safe.t = `Assoc fields in
  let serialised_len = String.length (Yojson.Safe.to_string payload) in
  Alcotest.(check bool)
    "payload is actually larger than 1 MB"
    true
    (serialised_len > 1024 * 1024);
  let line = Memory_jsonl.encode_line ~key:"big" ~value:(Some payload) in
  match Memory_jsonl.parse_line line with
  | None -> Alcotest.fail "parse_line returned None on truncated line"
  | Some (_, None, _) ->
    Alcotest.fail "decoded value was None (tombstone) on truncated payload"
  | Some (key, Some decoded, _ts) ->
    Alcotest.(check string) "key preserved on truncation" "big" key;
    Alcotest.(check bool)
      "decoded value is recognised as truncation marker"
      true
      (Memory_jsonl.value_is_truncated_marker decoded);
    Alcotest.(check (option string))
      "original_type recovered"
      (Some "Assoc")
      (Memory_jsonl.truncation_marker_original_type decoded);
    Alcotest.(check (option int))
      "original_size_bytes matches serialised length"
      (Some serialised_len)
      (Memory_jsonl.truncation_marker_original_size_bytes decoded);
    (match Memory_jsonl.truncation_marker_preview decoded with
     | None -> Alcotest.fail "preview missing on truncation marker"
     | Some preview ->
       Alcotest.(check int)
         "preview length is exactly 1024 bytes (truncation_preview_len)"
         1024
         (String.length preview))

let test_truncation_marker_original_type_list () =
  (* Variant: original payload is a `List`, not an `Assoc`. *)
  let big_string = String.make 4096 'y' in
  let items = List.init 300 (fun _ -> `String big_string) in
  let payload : Yojson.Safe.t = `List items in
  let line = Memory_jsonl.encode_line ~key:"big_list" ~value:(Some payload) in
  match Memory_jsonl.parse_line line with
  | Some (_, Some decoded, _) ->
    Alcotest.(check bool)
      "marker detected"
      true
      (Memory_jsonl.value_is_truncated_marker decoded);
    Alcotest.(check (option string))
      "original_type = List"
      (Some "List")
      (Memory_jsonl.truncation_marker_original_type decoded)
  | _ -> Alcotest.fail "parse_line failed on truncated List payload"

let test_no_false_positive_on_truncated_field_with_non_bool_value () =
  (* A real payload that happens to contain a [_truncated] field
     whose value is NOT [`Bool true] must NOT be recognised as a
     marker. *)
  let payload : Yojson.Safe.t =
    `Assoc [
      ("_truncated", `String "no");
      ("_original_type", `String "Assoc");
      ("payload", `Int 7);
    ]
  in
  Alcotest.(check bool)
    "_truncated field with String value is NOT a marker"
    false
    (Memory_jsonl.value_is_truncated_marker payload);
  Alcotest.(check (option string))
    "original_type returns None on non-marker"
    None
    (Memory_jsonl.truncation_marker_original_type payload);
  Alcotest.(check (option string))
    "preview returns None on non-marker"
    None
    (Memory_jsonl.truncation_marker_preview payload)

let test_no_false_positive_on_truncated_field_with_bool_false () =
  let payload : Yojson.Safe.t =
    `Assoc [
      ("_truncated", `Bool false);
      ("data", `String "real");
    ]
  in
  Alcotest.(check bool)
    "_truncated:false is NOT a marker"
    false
    (Memory_jsonl.value_is_truncated_marker payload)

let test_no_false_positive_on_bare_string () =
  (* Legacy bare-String truncated entries from before iter 25 must
     not be reported as markers — callers continue to handle them
     as plain strings, matching their existing behaviour. *)
  let payload : Yojson.Safe.t = `String "legacy truncated content" in
  Alcotest.(check bool)
    "bare String is NOT a marker"
    false
    (Memory_jsonl.value_is_truncated_marker payload)

let test_marker_field_set () =
  (* Confirm the on-wire field shape matches the documented
     contract — encoders/decoders in other repos can rely on these
     exact field names. *)
  let big = `Assoc (List.init 300 (fun i ->
      (Printf.sprintf "f%d" i, `String (String.make 4096 'z'))))
  in
  let line = Memory_jsonl.encode_line ~key:"k" ~value:(Some big) in
  match Memory_jsonl.parse_line line with
  | Some (_, Some marker, _) ->
    Alcotest.(check bool) "has _truncated"
      true (assoc_field "_truncated" marker <> None);
    Alcotest.(check bool) "has _original_type"
      true (assoc_field "_original_type" marker <> None);
    Alcotest.(check bool) "has _original_size_bytes"
      true (assoc_field "_original_size_bytes" marker <> None);
    Alcotest.(check bool) "has _preview"
      true (assoc_field "_preview" marker <> None)
  | _ -> Alcotest.fail "parse_line failed"

let test_backend_streaming_last_write_wins () =
  let base_dir = tmpdir "memory-jsonl-streaming" in
  let backend =
    Memory_jsonl.make_backend
      ~base_dir
      ~agent_name:"agent"
      ~session_id:"session"
  in
  require_ok (backend.persist ~key:"pref:first" (`String "old"));
  require_ok (backend.persist ~key:"pref:first" (`String "new"));
  require_ok (backend.persist ~key:"pref:second" (`String "two"));
  require_ok (backend.remove ~key:"pref:first");
  Alcotest.(check bool)
    "tombstone wins on retrieve"
    true
    (Option.is_none (backend.retrieve ~key:"pref:first"));
  Alcotest.(check (option string))
    "second key survives"
    (Some "two")
    (match backend.retrieve ~key:"pref:second" with
     | Some (`String value) -> Some value
     | _ -> None);
  let rows = backend.query ~prefix:"pref:" ~limit:10 in
  Alcotest.(check int) "query skips tombstone" 1 (List.length rows);
  Alcotest.(check (list string))
    "query returns live key"
    [ "pref:second" ]
    (List.map fst rows)

let () =
  Alcotest.run "memory_jsonl_truncation"
    [
      ("round-trip", [
        Alcotest.test_case "small Assoc preserved verbatim" `Quick
          test_round_trip_small_assoc;
      ]);
      ("truncation marker", [
        Alcotest.test_case ">1MB Assoc wrapped in typed marker" `Quick
          test_truncation_wraps_large_assoc;
        Alcotest.test_case ">1MB List records original_type=List" `Quick
          test_truncation_marker_original_type_list;
        Alcotest.test_case "marker has the documented field set" `Quick
          test_marker_field_set;
      ]);
      ("no false positives", [
        Alcotest.test_case "_truncated:String is not a marker" `Quick
          test_no_false_positive_on_truncated_field_with_non_bool_value;
        Alcotest.test_case "_truncated:Bool false is not a marker" `Quick
          test_no_false_positive_on_truncated_field_with_bool_false;
        Alcotest.test_case "legacy bare String is not a marker" `Quick
          test_no_false_positive_on_bare_string;
      ]);
      ("backend", [
        Alcotest.test_case "streaming read keeps last-write semantics" `Quick
          test_backend_streaming_last_write_wins;
      ]);
    ]
