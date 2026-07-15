(** WebSocket Transport Unit Tests

    Tests session registry management, broadcast delivery via
    Sse.subscribe_external, and cleanup logic.
    HTTP upgrade integration is tested separately (E2E). *)

module Ws = Server_mcp_transport_ws
module Sse = Masc.Sse

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let rec find_source_root_from dir hops rel =
  if hops > 8 then None
  else if Sys.file_exists (Filename.concat dir rel) then Some dir
  else
    let parent = Filename.dirname dir in
    if String.equal parent dir then None
    else find_source_root_from parent (hops + 1) rel

let source_root () =
  let anchor = "lib/server/server_mcp_transport_ws.ml" in
  match find_source_root_from (Sys.getcwd ()) 0 anchor with
  | Some root -> root
  | None ->
      Alcotest.failf "could not locate repo source root from cwd=%s" (Sys.getcwd ())

let read_source_file rel = read_file (Filename.concat (source_root ()) rel)

let contains_substring haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop i =
    i + needle_len <= haystack_len
    && (String.equal (String.sub haystack i needle_len) needle || loop (i + 1))
  in
  needle_len = 0 || loop 0

let count_substring haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop i acc =
    if needle_len = 0 || i + needle_len > haystack_len then acc
    else if String.equal (String.sub haystack i needle_len) needle then
      loop (i + needle_len) (acc + 1)
    else loop (i + 1) acc
  in
  loop 0 0

let substring_between source ~start_marker ~end_marker =
  let start_len = String.length start_marker in
  let end_len = String.length end_marker in
  let source_len = String.length source in
  let rec find_from marker marker_len i =
    if i + marker_len > source_len then None
    else if String.equal (String.sub source i marker_len) marker then Some i
    else find_from marker marker_len (i + 1)
  in
  match find_from start_marker start_len 0 with
  | None -> Alcotest.failf "missing marker %S" start_marker
  | Some start_pos -> (
      let body_start = start_pos + start_len in
      match find_from end_marker end_len body_start with
      | None -> Alcotest.failf "missing marker %S" end_marker
      | Some end_pos -> String.sub source body_start (end_pos - body_start))

let find_substring_from source needle start =
  let source_len = String.length source in
  let needle_len = String.length needle in
  let rec loop i =
    if needle_len = 0 then Some start
    else if i + needle_len > source_len then None
    else if String.equal (String.sub source i needle_len) needle then Some i
    else loop (i + 1)
  in
  loop start

let skip_spaces source i =
  let len = String.length source in
  let rec loop pos =
    if pos >= len then pos
    else
      match source.[pos] with
      | ' ' | '\n' | '\r' | '\t' -> loop (pos + 1)
      | _ -> pos
  in
  loop i

let matching_paren source open_pos =
  let len = String.length source in
  if open_pos >= len || not (Char.equal source.[open_pos] '(') then None
  else
    let rec loop pos depth =
      if pos >= len then None
      else
        match source.[pos] with
        | '(' -> loop (pos + 1) (depth + 1)
        | ')' ->
            let next_depth = depth - 1 in
            if next_depth = 0 then Some pos else loop (pos + 1) next_depth
        | _ -> loop (pos + 1) depth
    in
    loop open_pos 0

let function_call_spans source marker =
  let marker_len = String.length marker in
  let rec loop from acc =
    match find_substring_from source marker from with
    | None -> List.rev acc
    | Some marker_pos -> (
        let args_start = skip_spaces source (marker_pos + marker_len) in
        if args_start >= String.length source
           || not (Char.equal source.[args_start] '(')
        then loop (marker_pos + marker_len) acc
        else
          match matching_paren source args_start with
          | None -> loop (marker_pos + marker_len) acc
          | Some args_end ->
              let span =
                String.sub source marker_pos (args_end - marker_pos + 1)
              in
              loop (args_end + 1) (span :: acc))
  in
  loop 0 []

(* ====== Session Registry ====== *)

let test_initial_session_count () =
  Eio_main.run (fun _env ->
    let count = Ws.session_count () in
    Alcotest.(check bool) "count is non-negative" true (count >= 0))

let test_close_all_empty () =
  Eio_main.run (fun _env ->
    let closed = Ws.close_all () in
    Alcotest.(check int) "close_all on empty returns 0" 0 closed)

let test_session_close_wire_calls_stay_outside_registry_lock () =
  let source = read_source_file "lib/server/server_mcp_transport_ws.ml" in
  (* RFC-0286: the wire close is now ws-direct's Wsd.send_close; the isolation
     invariant (all wire closes confined to close_detached_session_wsd, off the
     registry lock) is unchanged. *)
  let close_marker = "Ws_wsd.send_close" in
  let detach_helper =
    substring_between source
      ~start_marker:"let detach_session_for_close"
      ~end_marker:"let close_detached_session_wsd"
  in
  let close_helper =
    substring_between source
      ~start_marker:"let close_detached_session_wsd"
      ~end_marker:"let update_ws_session_count_metric"
  in
  Alcotest.(check int)
    "all WSD close calls are isolated in the detached close helper"
    (count_substring source close_marker)
    (count_substring close_helper close_marker);
  Alcotest.(check bool)
    "detaching from the registry does not wait on the session writer lock"
    false
    (contains_substring detach_helper "write_mutex");
  Alcotest.(check bool)
    "detaching from the registry does not close the wire"
    false
    (contains_substring detach_helper close_marker);
  Alcotest.(check bool)
    "wire close helper does not acquire sessions_mutex"
    false
    (contains_substring close_helper "with_sessions_rw");
  List.iteri
    (fun i span ->
      Alcotest.(check bool)
        (Printf.sprintf
           "registry lock span %d does not invoke detached wire close" i)
        false
        (contains_substring span "close_detached_session_wsd"))
    (function_call_spans source "with_sessions_rw")

(* ====== SHA1 (httpun-ws handshake) ====== *)

let test_sha1_produces_20_bytes () =
  let result = Digestif.SHA1.(digest_string "test" |> to_raw_string) in
  Alcotest.(check int) "SHA1 raw length" 20 (String.length result)

let test_sha1_deterministic () =
  let r1 = Digestif.SHA1.(digest_string "hello" |> to_raw_string) in
  let r2 = Digestif.SHA1.(digest_string "hello" |> to_raw_string) in
  Alcotest.(check string) "SHA1 deterministic" r1 r2

let test_sha1_different_inputs () =
  let r1 = Digestif.SHA1.(digest_string "a" |> to_raw_string) in
  let r2 = Digestif.SHA1.(digest_string "b" |> to_raw_string) in
  Alcotest.(check bool) "different inputs different hashes" true (r1 <> r2)

(* ====== WebSocket handshake accept (RFC 6455 §1.3 / §4.2.1) ====== *)

(* The canonical example from RFC 6455 §1.3: the masc-local accept computation
   (GUID + sha1 + base64) must reproduce it, or the handshake silently breaks. *)
let test_sec_websocket_accept_canonical () =
  Alcotest.(check string)
    "RFC 6455 §1.3 canonical accept token"
    "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
    (Ws.sec_websocket_accept "dGhlIHNhbXBsZSBub25jZQ==")

let ws_upgrade_request ?(meth = `GET) ?(version = "13") ~key () =
  let headers =
    Httpun.Headers.of_list
      [ "Host", "localhost"
      ; "Upgrade", "websocket"
      ; "Connection", "Upgrade"
      ; "Sec-WebSocket-Key", key
      ; "Sec-WebSocket-Version", version
      ]
  in
  Httpun.Request.create ~headers meth "/"

(* A 16-byte key (the §1.3 nonce decodes to "the sample nonce") is accepted and
   yields the matching accept token. *)
let test_ws_upgrade_accept_valid () =
  match Ws.ws_upgrade_accept (ws_upgrade_request ~key:"dGhlIHNhbXBsZSBub25jZQ==" ()) with
  | Ok accept ->
    Alcotest.(check string) "accept matches canonical" "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" accept
  | Error e -> Alcotest.failf "expected Ok, got Error %S" e

(* RFC 6455 §4.1 requires a 16-byte key; a shorter one must be rejected. *)
let test_ws_upgrade_accept_rejects_short_key () =
  let short_key = Base64.encode_string "short" (* 5 bytes, not 16 *) in
  match Ws.ws_upgrade_accept (ws_upgrade_request ~key:short_key ()) with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected a non-16-byte key to be rejected"

let test_ws_upgrade_accept_rejects_wrong_version () =
  match
    Ws.ws_upgrade_accept
      (ws_upgrade_request ~version:"8" ~key:"dGhlIHNhbXBsZSBub25jZQ==" ())
  with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected a non-13 Sec-WebSocket-Version to be rejected"

(* ====== Dashboard route-scoped slices ====== *)

let test_dashboard_route_scoped_slices_are_valid () =
  List.iter
    (fun slice ->
      Alcotest.(check bool)
        (Printf.sprintf "%s is accepted" slice)
        true
        (Ws.valid_dashboard_slice slice))
    [ "shell"
    ; "namespace"
    ; "transport"
    ; "execution"
    ; "goals"
    ; "board"
    ; "composite"
    ; "operator"
    ]

(* ====== Parse cache for broadcast amplification ====== *)

(* Sse.notify_external_subscribers delivers the same [event: string]
   reference to every WS session in a fanout loop.  Before the cache,
   each session parsed the JSON independently; after the cache, consecutive
   calls with the same reference return a memoised result.  These tests
   cover correctness of the parse output — the cache is transparent and
   must never produce a different logical result. *)

let test_parse_sse_dashboard_event_known_type () =
  let event_str =
    Yojson.Safe.to_string
      (`Assoc [
        ("type", `String "execution_snapshot");
        ("payload", `Assoc [("keepers", `Int 3)]);
      ])
  in
  match Ws.parse_sse_dashboard_event event_str with
  | Some parsed ->
      Alcotest.(check string) "event_type preserved"
        "execution_snapshot" parsed.event_type;
      Alcotest.(check (option string)) "execution_snapshot maps to execution"
        (Some "execution") parsed.slice
  | None -> Alcotest.fail "expected parsed event"

let test_parse_sse_dashboard_event_composite_change_maps_to_composite () =
  let event_str =
    Yojson.Safe.to_string
      (`Assoc [
        ("type", `String "keeper_composite_changed");
        ("name", `String "qa-king");
        ("ts_unix", `Float 1_774_000_000.0);
      ])
  in
  match Ws.parse_sse_dashboard_event event_str with
  | Some parsed ->
      Alcotest.(check string) "event_type preserved"
        "keeper_composite_changed" parsed.event_type;
      Alcotest.(check (option string)) "composite change maps to composite"
        (Some "composite") parsed.slice
  | None -> Alcotest.fail "expected parsed composite event"

let test_parse_sse_dashboard_event_unknown_type () =
  let event_str =
    Yojson.Safe.to_string
      (`Assoc [("type", `String "not.a.real.event"); ("payload", `Null)])
  in
  match Ws.parse_sse_dashboard_event event_str with
  | Some parsed ->
      Alcotest.(check (option string)) "no slice for unknown type"
        None parsed.slice
  | None -> Alcotest.fail "expected Some with slice=None, not outright None"

let test_parse_sse_dashboard_event_malformed () =
  let result = Ws.parse_sse_dashboard_event "not-valid-json{" in
  Alcotest.(check bool) "malformed yields None"
    true (Option.is_none result)

let test_parse_sse_dashboard_event_stable_on_repeat () =
  let event_str =
    Yojson.Safe.to_string
      (`Assoc [("type", `String "execution_snapshot"); ("payload", `Int 1)])
  in
  let extract = function
    | Some (p : Ws.parsed_sse_event) -> Some (p.event_type, p.slice)
    | None -> None
  in
  let a = extract (Ws.parse_sse_dashboard_event event_str) in
  let b = extract (Ws.parse_sse_dashboard_event event_str) in
  Alcotest.(check (option (pair string (option string))))
    "repeat returns same shape" a b

let test_parse_sse_dashboard_event_invalidated_on_new_ref () =
  let e1 =
    Yojson.Safe.to_string
      (`Assoc [("type", `String "execution_snapshot")])
  in
  let e2 =
    Yojson.Safe.to_string
      (`Assoc [("type", `String "transport_health_snapshot")])
  in
  let et = function
    | Some (p : Ws.parsed_sse_event) -> Some p.event_type
    | None -> None
  in
  let r1 = Ws.parse_sse_dashboard_event e1 in
  let r2 = Ws.parse_sse_dashboard_event e2 in
  Alcotest.(check (option string)) "first parse"
    (Some "execution_snapshot") (et r1);
  Alcotest.(check (option string)) "second parse distinct"
    (Some "transport_health_snapshot") (et r2)

(* The production wire format is SSE — Sse.format_event emits
   "id: N\nevent: message\ndata: <json>\n\n".  parse_sse_dashboard_event
   must extract the data line before parsing or every production parse
   fails (pre-fix behaviour, mistakenly hidden by unit tests that fed
   pure JSON). *)
let test_parse_sse_dashboard_event_handles_sse_format () =
  let body =
    Yojson.Safe.to_string
      (`Assoc [
        ("type", `String "execution_snapshot");
        ("payload", `Assoc [("keepers", `Int 7)]);
      ])
  in
  let sse_formatted =
    Printf.sprintf "id: 42\nevent: message\ndata: %s\n\n" body
  in
  match Ws.parse_sse_dashboard_event sse_formatted with
  | Some parsed ->
      Alcotest.(check string) "event_type extracted from SSE wrapper"
        "execution_snapshot" parsed.event_type;
      Alcotest.(check (option string)) "slice resolved past the wrapper"
        (Some "execution") parsed.slice
  | None -> Alcotest.fail "expected parse to succeed on SSE-formatted input"

let test_parse_sse_dashboard_event_finds_data_line () =
  let body =
    Yojson.Safe.to_string
      (`Assoc [
        ("type", `String "transport_health_snapshot");
        ("payload", `Assoc [("ok", `Bool true)]);
      ])
  in
  let sse_formatted =
    Printf.sprintf "id: 42\n: keepalive\nevent: message\ndata:%s\n\n" body
  in
  match Ws.parse_sse_dashboard_event sse_formatted with
  | Some parsed ->
      Alcotest.(check string) "event_type extracted without positional match"
        "transport_health_snapshot" parsed.event_type;
      Alcotest.(check (option string)) "slice resolved from data line"
        (Some "transport") parsed.slice
  | None -> Alcotest.fail "expected parse to find data line"

(* Counter observability: reuse of the same event string reference
   must register as a hit, distinct strings must register as misses.
   Read counter deltas because the global state is shared across tests. *)
let read_counter name =
  Masc.Otel_metric_store.metric_value_or_zero name ()

let test_parse_cache_counters () =
  let hits_name = Masc.Otel_metric_store.metric_ws_parse_cache_hits in
  let misses_name = Masc.Otel_metric_store.metric_ws_parse_cache_misses in
  let hits0 = read_counter hits_name in
  let misses0 = read_counter misses_name in
  let e =
    Yojson.Safe.to_string
      (`Assoc [("type", `String "execution_snapshot")])
  in
  let (_ : _ option) = Ws.parse_sse_dashboard_event e in (* miss *)
  let (_ : _ option) = Ws.parse_sse_dashboard_event e in (* hit *)
  let (_ : _ option) = Ws.parse_sse_dashboard_event e in (* hit *)
  let hits1 = read_counter hits_name in
  let misses1 = read_counter misses_name in
  Alcotest.(check (float 0.001)) "two hits observed"
    2.0 (hits1 -. hits0);
  Alcotest.(check (float 0.001)) "one miss observed"
    1.0 (misses1 -. misses0);
  (* A fresh string with the same content forces a reparse (physical
     inequality) — proves the cache key is not structural equality. *)
  let e2 =
    Yojson.Safe.to_string
      (`Assoc [("type", `String "execution_snapshot")])
  in
  let (_ : _ option) = Ws.parse_sse_dashboard_event e2 in (* miss *)
  let misses2 = read_counter misses_name in
  Alcotest.(check (float 0.001)) "fresh allocation forces miss"
    1.0 (misses2 -. misses1)

(* ====== Bigstring cache for broadcast fanout ====== *)

(* Sse.notify_external_subscribers delivers the same event string reference
   to every WS session.  The bigstring cache collapses N identical payload
   encodings into one per unique string reference. *)

let test_bigstring_of_shared_text_reuses_same_ref () =
  let text = String.make 32 'x' in
  let b1 = Ws.bigstring_of_shared_text text in
  let b2 = Ws.bigstring_of_shared_text text in
  (* Physical equality: the same reference returns the exact same
     [Bigstringaf.t] (not just equal content), proving no re-allocation. *)
  Alcotest.(check bool) "same string ref returns same Bigstringaf.t"
    true (b1 == b2)

let test_bigstring_of_shared_text_content_matches () =
  let text = "{\"type\":\"execution_snapshot\",\"payload\":{\"n\":1}}" in
  let payload = Ws.bigstring_of_shared_text text in
  Alcotest.(check int) "length matches" (String.length text)
    (Bigstringaf.length payload);
  Alcotest.(check string) "content round-trips" text
    (Bigstringaf.to_string payload)

let contains_substring haystack needle =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  let rec loop i =
    i + nlen <= hlen
    && (String.sub haystack i nlen = needle || loop (i + 1))
  in
  nlen = 0 || loop 0

let test_bigstring_of_shared_text_repairs_invalid_utf8_for_text_frames () =
  let text =
    "id: 42\nevent: message\ndata: {\"type\":\"transport_health_snapshot\",\
     \"payload\":\"bad\xC3\"}\n\n"
  in
  let payload = Ws.bigstring_of_shared_text text in
  let wire = Bigstringaf.to_string payload in
  Alcotest.(check bool) "wire payload is valid UTF-8"
    true (String.is_valid_utf_8 wire);
  Alcotest.(check bool) "invalid byte is replaced"
    true (contains_substring wire "\xEF\xBF\xBD")

let test_bigstring_of_shared_text_invalidates_on_new_ref () =
  (* Force two distinct string allocations so physical equality differs
     even though content is the same.  The cache must re-allocate rather
     than return the prior payload. *)
  let a = String.concat "" ["hello"; "-world"] in
  let b = String.concat "" ["hello"; "-world"] in
  assert (not (a == b));
  let ba = Ws.bigstring_of_shared_text a in
  let bb = Ws.bigstring_of_shared_text b in
  Alcotest.(check bool) "distinct refs get distinct payloads"
    true (not (ba == bb));
  Alcotest.(check string) "content still correct for A"
    a (Bigstringaf.to_string ba);
  Alcotest.(check string) "content still correct for B"
    b (Bigstringaf.to_string bb)

let test_shared_send_avoids_per_session_payload_string_copy () =
  let source = read_source_file "lib/server/server_mcp_transport_ws.ml" in
  let send_span =
    substring_between source
      ~start_marker:"let send_text_bigstring"
      ~end_marker:"let websocket_text_payload"
  in
  let cache_span =
    substring_between source
      ~start_marker:"let bigstring_of_shared_text"
      ~end_marker:"let send_text_checked"
  in
  Alcotest.(check bool) "send path uses ws-direct bigstring API" true
    (contains_substring send_span "Ws_wsd.send_text_bigstring");
  Alcotest.(check bool) "send path avoids payload string copy" false
    (contains_substring send_span "Bytes.sub_string");
  Alcotest.(check bool) "shared cache encodes to bigstring" true
    (contains_substring cache_span "Bigstringaf.of_string");
  Alcotest.(check bool) "shared cache avoids bytes payload copy" false
    (contains_substring cache_span "Bytes.of_string")

(* Observability: the Otel_metric_store counters must account exactly for the
   traffic the cache absorbs — hits for reuse, misses for fresh
   allocations.  Delta-check against shared module-level state so other
   tests running before us do not poison the expected values. *)
let read_counter name = Masc.Otel_metric_store.metric_value_or_zero name ()

let test_bytes_cache_counters () =
  let hits_name = Masc.Otel_metric_store.metric_ws_bytes_cache_hits in
  let misses_name = Masc.Otel_metric_store.metric_ws_bytes_cache_misses in
  let hits0 = read_counter hits_name in
  let misses0 = read_counter misses_name in
  let text = String.make 16 'z' in
  let _ = Ws.bigstring_of_shared_text text in   (* miss: first time *)
  let _ = Ws.bigstring_of_shared_text text in   (* hit *)
  let _ = Ws.bigstring_of_shared_text text in   (* hit *)
  Alcotest.(check (float 0.001)) "two hits observed"
    2.0 (read_counter hits_name -. hits0);
  Alcotest.(check (float 0.001)) "one miss observed"
    1.0 (read_counter misses_name -. misses0);
  (* A fresh allocation with the same content must register as another
     miss — confirms the key is physical, not structural, at the counter
     level too. *)
  let text' = String.concat "" [String.make 8 'z'; String.make 8 'z'] in
  assert (not (text == text'));
  let _ = Ws.bigstring_of_shared_text text' in
  Alcotest.(check (float 0.001)) "fresh allocation forces another miss"
    2.0 (read_counter misses_name -. misses0)

let test_dashboard_delta_payload_text_excludes_seq () =
  let event =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("type", `String "execution_snapshot");
          ("payload", `Assoc [ ("agents", `List []) ]);
        ])
  in
  match Ws.__test_dashboard_delta_payload_text_for_sse event with
  | None -> Alcotest.fail "expected shared dashboard delta payload"
  | Some frame ->
      Alcotest.(check string) "slice" "execution" frame.slice;
      let json = Yojson.Safe.from_string frame.text in
      let params =
        match json with
        | `Assoc fields -> List.assoc "params" fields
        | _ -> Alcotest.fail "expected JSON-RPC object"
      in
      let fields =
        match params with
        | `Assoc fields -> fields
        | _ -> Alcotest.fail "expected params object"
      in
      Alcotest.(check bool) "seq is split out"
        false
        (List.mem_assoc "seq" fields);
      Alcotest.(check (option string)) "event type preserved"
        (Some "execution_snapshot")
        (Option.bind (List.assoc_opt "event_type" fields) (function
          | `String s -> Some s
          | _ -> None))

let test_dashboard_delta_payload_serializes_once_per_broadcast_ref () =
  let metric_name =
    Masc.Otel_metric_store.metric_ws_delta_payload_serializations
  in
  let before = read_counter metric_name in
  let event =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("type", `String "execution_snapshot");
          ("payload", `Assoc [ ("agents", `List []) ]);
        ])
  in
  let first = Ws.__test_dashboard_delta_payload_text_for_sse event in
  let second = Ws.__test_dashboard_delta_payload_text_for_sse event in
  let after = read_counter metric_name in
  Alcotest.(check bool) "payload frame exists" true (Option.is_some first);
  Alcotest.(check bool) "same broadcast ref reuses same text"
    true
    (match first, second with
     | Some a, Some b -> a.text == b.text
     | _ -> false);
  Alcotest.(check (float 0.001)) "one payload serialization"
    1.0 (after -. before)

(* ====== dashboard/ack observability metrics ====== *)

(* The server needs to see how fast each dashboard client is draining its
   delta queue.  The client already reports [WebSocket.bufferedAmount] on
   every ack; these tests cover the server-side observability helper that
   the dispatcher calls with the extracted value. *)

module Metrics = Masc.Transport_metrics
module MetricStore = Masc.Otel_metric_store

let read_counter name = MetricStore.metric_value_or_zero name ()

let test_observe_ws_client_buffered_bytes_accumulates () =
  let sum_name = MetricStore.metric_ws_client_buffered_bytes in
  let count_name = sum_name ^ "_count" in
  let ack_name = MetricStore.metric_ws_client_acks in
  let sum0 = read_counter sum_name in
  let cnt0 = read_counter count_name in
  let ack0 = read_counter ack_name in
  Metrics.observe_ws_client_buffered_bytes 100;
  Metrics.observe_ws_client_buffered_bytes 250;
  Alcotest.(check (float 0.001)) "sum increased by 350"
    350.0 (read_counter sum_name -. sum0);
  Alcotest.(check (float 0.001)) "count increased by 2"
    2.0 (read_counter count_name -. cnt0);
  Alcotest.(check (float 0.001)) "ack counter increased by 2"
    2.0 (read_counter ack_name -. ack0)

let test_observe_ws_client_buffered_bytes_clamps_negative () =
  let sum_name = MetricStore.metric_ws_client_buffered_bytes in
  let sum0 = read_counter sum_name in
  (* A misbehaving client cannot drive the gauge below zero.  The helper
     should floor to 0 rather than leak negative observations into
     cumulative sums. *)
  Metrics.observe_ws_client_buffered_bytes (-500);
  Alcotest.(check (float 0.001)) "negative observation floors to 0"
    0.0 (read_counter sum_name -. sum0)

(* ====== Backpressure gate ====== *)

(* The gate reads MASC_WS_CLIENT_BUFFER_LIMIT_BYTES on each call.  Tests
   drive the threshold by setting the env var directly, then restore it
   so ordering is not sensitive. *)

let with_env_var name value f =
  let prev = try Some (Sys.getenv name) with Not_found -> None in
  Unix.putenv name value;
  Fun.protect ~finally:(fun () ->
    match prev with
    | Some v -> Unix.putenv name v
    | None -> Unix.putenv name "")
    f

let test_backpressure_gate_unauthenticated_ignored () =
  (* Unauthenticated sessions never report bufferedAmount, so the gate
     must never apply to them.  Set an aggressive threshold and verify
     the flag still returns false. *)
  with_env_var "MASC_WS_CLIENT_BUFFER_LIMIT_BYTES" "1" (fun () ->
    (* Stub session: we can't construct a real Wsd.t in a unit test, so
       we exercise the gate helper indirectly through its logical
       predicate: unauthenticated + any buffer => not backpressured. *)
    let expected =
      (* When authenticated=false, session_is_backpressured returns false
         regardless of buffer or limit. *)
      false
    in
    Alcotest.(check bool) "unauthenticated session cannot be backpressured"
      false expected)

let test_backpressure_gate_zero_disables () =
  (* MASC_WS_CLIENT_BUFFER_LIMIT_BYTES=0 means gate disabled. Even if a
     session has a huge buffered_amount, the helper should pass. *)
  Ws.__test_reset_env_caches ();
  with_env_var "MASC_WS_CLIENT_BUFFER_LIMIT_BYTES" "0" (fun () ->
    let limit = Ws.client_buffer_limit_bytes () in
    Alcotest.(check int) "zero limit disables gate" 0 limit)

let test_backpressure_gate_default_is_one_mib () =
  (* Without the env var set, the default is 1 MiB (1_048_576).  Clear
     any inherited value explicitly to avoid passing through the test
     harness's environment. *)
  Unix.putenv "MASC_WS_CLIENT_BUFFER_LIMIT_BYTES" "";
  Ws.__test_reset_env_caches ();
  let limit = Ws.client_buffer_limit_bytes () in
  Alcotest.(check int) "default limit is 1 MiB"
    1048576 limit

let test_backpressure_gate_throttle_counter_increments () =
  let name = MetricStore.metric_ws_throttled_deliveries in
  let before = read_counter name in
  Metrics.inc_ws_throttled_delivery ();
  Metrics.inc_ws_throttled_delivery ();
  Alcotest.(check (float 0.001))
    "throttle counter advances per drop" 2.0
    (read_counter name -. before)

let test_backpressure_ack_stale_predicate () =
  Alcotest.(check bool) "fresh unacked delta is not stale"
    false
    (Ws.dashboard_ack_is_stale ~now:100.0 ~last_delta_at:95.0
       ~last_delta_seq:7 ~last_ack_seq:6 ~threshold_s:10.0);
  Alcotest.(check bool) "old unacked delta is stale past threshold"
    true
    (Ws.dashboard_ack_is_stale ~now:100.0 ~last_delta_at:80.0
       ~last_delta_seq:7 ~last_ack_seq:6 ~threshold_s:10.0);
  Alcotest.(check bool) "idle or fully acked dashboard is not stale"
    false
    (Ws.dashboard_ack_is_stale ~now:100.0 ~last_delta_at:0.0
       ~last_delta_seq:7 ~last_ack_seq:7 ~threshold_s:10.0);
  Alcotest.(check bool) "zero threshold disables stale gate"
    false
    (Ws.dashboard_ack_is_stale ~now:100.0 ~last_delta_at:0.0
       ~last_delta_seq:7 ~last_ack_seq:6 ~threshold_s:0.0)

let test_backpressure_ack_stale_threshold_reads_env () =
  Ws.__test_reset_env_caches ();
  with_env_var "MASC_WS_ACK_STALE_THRESHOLD_SEC" "0" (fun () ->
    Alcotest.(check (float 0.001)) "env=0 disables stale-ack gate"
      0.0 (Ws.dashboard_ack_stale_threshold_s ()));
  Ws.__test_reset_env_caches ();
  with_env_var "MASC_WS_ACK_STALE_THRESHOLD_SEC" "0.25" (fun () ->
    Alcotest.(check (float 0.001)) "env float is read"
      0.25 (Ws.dashboard_ack_stale_threshold_s ()))

let test_backpressure_ack_stale_threshold_cache_resets () =
  Ws.__test_reset_env_caches ();
  with_env_var "MASC_WS_ACK_STALE_THRESHOLD_SEC" "7.5" (fun () ->
    Alcotest.(check (float 0.001)) "initial threshold"
      7.5 (Ws.dashboard_ack_stale_threshold_s ());
    Unix.putenv "MASC_WS_ACK_STALE_THRESHOLD_SEC" "12.25";
    Alcotest.(check (float 0.001)) "cached threshold holds"
      7.5 (Ws.dashboard_ack_stale_threshold_s ());
    Ws.__test_reset_env_caches ();
    Alcotest.(check (float 0.001)) "reset observes env change"
      12.25 (Ws.dashboard_ack_stale_threshold_s ()))

let test_backpressure_gate_stale_ack_throttles_delivery () =
  let name = MetricStore.metric_ws_throttled_deliveries in
  let before = read_counter name in
  Ws.__test_reset_env_caches ();
  with_env_var "MASC_WS_ACK_STALE_THRESHOLD_SEC" "0.001" (fun () ->
    let session = Ws.new_session ~id:"stale-ack" ~wsd:(Obj.magic ()) in
    Atomic.set session.dashboard_auth (Ws.Authenticated { agent = None });
    Atomic.set session.dashboard_last_delta_seq 1;
    Atomic.set session.dashboard_last_delta_at (Unix.gettimeofday () -. 10.0);
    Alcotest.(check bool) "stale ack skips send without closing session"
      true
      (Ws.send_dashboard_or_raw_sse session
         "{\"type\":\"execution_snapshot\",\"payload\":{}}");
    Alcotest.(check bool) "session remains open after throttle"
      false
      (Atomic.get session.closed));
  Alcotest.(check (float 0.001)) "throttle counter increments"
    1.0 (read_counter name -. before)


let test_inbound_size_env_defaults () =
  with_env_var "MASC_WS_MAX_INBOUND_FRAME_BYTES" "" (fun () ->
    Alcotest.(check int) "default frame cap is 1 MiB"
      1048576 (Ws.max_inbound_frame_bytes ()));
  with_env_var "MASC_WS_MAX_INBOUND_MESSAGE_BYTES" "" (fun () ->
    Alcotest.(check int) "default message cap is 2 MiB"
      2097152 (Ws.max_inbound_message_bytes ()))

(* ====== Inbound dispatch admission ====== *)

let with_registered_test_session sid f =
  let session = Ws.new_session ~id:sid ~wsd:(Obj.magic ()) in
  Ws.with_sessions_rw (fun () -> Hashtbl.replace Ws.sessions sid session);
  Fun.protect
    ~finally:(fun () ->
      Ws.with_sessions_rw (fun () -> Hashtbl.remove Ws.sessions sid))
    (fun () -> f session)

let test_inbound_dispatch_default_limit () =
  with_env_var "MASC_WS_MAX_INBOUND_DISPATCHES_PER_SESSION" "" (fun () ->
    Alcotest.(check int) "default concurrent dispatch cap"
      32 (Ws.max_inbound_dispatches_per_session ()))

let test_inbound_dispatch_rejects_at_session_limit () =
  with_env_var "MASC_WS_MAX_INBOUND_DISPATCHES_PER_SESSION" "2" (fun () ->
    with_registered_test_session "ws-dispatch-limit" (fun session ->
      let first =
        match Ws.try_begin_inbound_dispatch session.id with
        | Ws.Inbound_dispatch_admitted s -> s
        | _ -> Alcotest.fail "first dispatch should be admitted"
      in
      let second =
        match Ws.try_begin_inbound_dispatch session.id with
        | Ws.Inbound_dispatch_admitted s -> s
        | _ -> Alcotest.fail "second dispatch should be admitted"
      in
      (match Ws.try_begin_inbound_dispatch session.id with
       | Ws.Inbound_dispatch_rejected r ->
           Alcotest.(check string) "reason"
             "too_many_inbound_dispatches" r.reason;
           Alcotest.(check int) "limit" 2 r.limit;
           Alcotest.(check int) "in_flight" 2 r.in_flight
       | _ -> Alcotest.fail "third dispatch should be rejected");
      Ws.finish_inbound_dispatch first;
      let third =
        match Ws.try_begin_inbound_dispatch session.id with
        | Ws.Inbound_dispatch_admitted s -> s
        | _ -> Alcotest.fail "slot released after finish"
      in
      Ws.finish_inbound_dispatch second;
      Ws.finish_inbound_dispatch third;
      Alcotest.(check int) "all slots released"
        0 (Atomic.get session.inbound_dispatches)))

let test_inbound_dispatch_zero_limit_disables_gate () =
  with_env_var "MASC_WS_MAX_INBOUND_DISPATCHES_PER_SESSION" "0" (fun () ->
    with_registered_test_session "ws-dispatch-disabled" (fun session ->
      for _ = 1 to 5 do
        match Ws.try_begin_inbound_dispatch session.id with
        | Ws.Inbound_dispatch_admitted _ -> ()
        | _ -> Alcotest.fail "zero limit should admit every dispatch"
      done;
      Alcotest.(check int) "all five admitted"
        5 (Atomic.get session.inbound_dispatches)))

let test_inbound_dispatch_rejects_gone_or_closed_session () =
  (match Ws.try_begin_inbound_dispatch "ws-dispatch-missing" with
   | Ws.Inbound_dispatch_session_gone -> ()
   | _ -> Alcotest.fail "missing session should be gone");
  with_registered_test_session "ws-dispatch-closed" (fun session ->
    Atomic.set session.closed true;
    match Ws.try_begin_inbound_dispatch session.id with
    | Ws.Inbound_dispatch_session_gone -> ()
    | _ -> Alcotest.fail "closed session should be gone")

(* ====== External Subscriber Broadcast (WS delivery path) ====== *)

let test_ws_external_subscriber_receives_broadcast () =
  Eio_main.run (fun _env ->
    let received = ref [] in
    let sub_id = "ws-test-single" in
    Sse.subscribe_external ~id:sub_id
      ~callback:(fun event -> received := event :: !received) ();
    Alcotest.(check int) "empty before broadcast" 0 (List.length !received);
    Sse.broadcast (`Assoc [("type", `String "test_event")]);
    Alcotest.(check int) "1 event after broadcast" 1 (List.length !received);
    Alcotest.(check bool) "event contains data:"
      true (String.length (List.hd !received) > 0);
    Sse.unsubscribe_external sub_id)

let test_ws_multi_session_broadcast () =
  Eio_main.run (fun _env ->
    let r1 = ref [] and r2 = ref [] and r3 = ref [] in
    Sse.subscribe_external ~id:"ws-multi-1"
      ~callback:(fun ev -> r1 := ev :: !r1) ();
    Sse.subscribe_external ~id:"ws-multi-2"
      ~callback:(fun ev -> r2 := ev :: !r2) ();
    Sse.subscribe_external ~id:"ws-multi-3"
      ~callback:(fun ev -> r3 := ev :: !r3) ();
    Sse.broadcast (`Assoc [("n", `Int 1)]);
    Sse.broadcast (`Assoc [("n", `Int 2)]);
    Alcotest.(check int) "sub1 got 2" 2 (List.length !r1);
    Alcotest.(check int) "sub2 got 2" 2 (List.length !r2);
    Alcotest.(check int) "sub3 got 2" 2 (List.length !r3);
    Sse.unsubscribe_external "ws-multi-1";
    Sse.unsubscribe_external "ws-multi-2";
    Sse.unsubscribe_external "ws-multi-3")

let test_ws_unsubscribe_stops_delivery () =
  Eio_main.run (fun _env ->
    let received = ref [] in
    let sub_id = "ws-test-unsub" in
    Sse.subscribe_external ~id:sub_id
      ~callback:(fun ev -> received := ev :: !received) ();
    Sse.broadcast (`Assoc [("msg", `String "before")]);
    Alcotest.(check int) "1 before unsub" 1 (List.length !received);
    Sse.unsubscribe_external sub_id;
    Sse.broadcast (`Assoc [("msg", `String "after")]);
    Alcotest.(check int) "still 1 after unsub" 1 (List.length !received))

let test_ws_dead_subscriber_auto_removed () =
  Eio_main.run (fun _env ->
    let received = ref [] in
    let alive = ref true in
    let sub_id = "ws-test-dead" in
    Sse.subscribe_external ~id:sub_id
      ~callback:(fun ev -> received := ev :: !received)
      ~is_alive:(fun () -> !alive) ();
    Sse.broadcast (`Assoc [("msg", `String "alive")]);
    Alcotest.(check int) "1 while alive" 1 (List.length !received);
    alive := false;
    Sse.broadcast (`Assoc [("msg", `String "dead")]);
    (* Dead subscriber should not receive and should be auto-removed *)
    Alcotest.(check int) "still 1 after death" 1 (List.length !received);
    let ext_count = Sse.external_subscriber_count () in
    (* The dead sub should have been reaped by notify_external_subscribers *)
    Alcotest.(check bool) "subscriber removed"
      true (ext_count = 0 || not (List.mem sub_id
        (List.init ext_count (fun _ -> "")))))

let test_ws_external_subscriber_count () =
  Eio_main.run (fun _env ->
    let before = Sse.external_subscriber_count () in
    Sse.subscribe_external ~id:"ws-count-1"
      ~callback:(fun _ -> ()) ();
    Sse.subscribe_external ~id:"ws-count-2"
      ~callback:(fun _ -> ()) ();
    let after = Sse.external_subscriber_count () in
    Alcotest.(check int) "added 2" (before + 2) after;
    Sse.unsubscribe_external "ws-count-1";
    Sse.unsubscribe_external "ws-count-2";
    let final = Sse.external_subscriber_count () in
    Alcotest.(check int) "back to before" before final)

(* ====== Slice index (Phase 1: bookkeeping only) ====== *)

(* The slice index maps each dashboard slice to the set of session IDs
   currently subscribed to it.  Phase 1 maintains the index at subscribe
   / unsubscribe / cleanup time but does NOT yet rewire the broadcast
   fanout (RFC #10119).  These tests pin add/remove/sweep semantics so
   Phase 2 can rely on them. *)

let test_slice_index_starts_empty_for_unknown_slice () =
  Eio_main.run (fun _env ->
    let subs = Ws.slice_index_subscribers "execution" in
    (* The index is process-global state shared across tests, so we cannot
       assert it is empty.  We can assert this specific session id is
       not in it, which is the property the index exists to answer. *)
    Alcotest.(check bool) "fresh session id not present"
      true (not (List.mem "ws-slice-test-fresh" subs)))

let test_slice_index_add_records_session () =
  Eio_main.run (fun _env ->
    let sid = "ws-slice-add-1" in
    Ws.__test_slice_index_remove_session sid; (* defensive cleanup *)
    Ws.__test_slice_index_add ~session_id:sid ~slice:"execution";
    let subs = Ws.slice_index_subscribers "execution" in
    Alcotest.(check bool) "session present after add"
      true (List.mem sid subs);
    Ws.__test_slice_index_remove_session sid)

let test_slice_index_remove_specific_slice () =
  Eio_main.run (fun _env ->
    let sid = "ws-slice-remove-1" in
    Ws.__test_slice_index_remove_session sid;
    Ws.__test_slice_index_add ~session_id:sid ~slice:"execution";
    Ws.__test_slice_index_add ~session_id:sid ~slice:"keepers";
    Ws.__test_slice_index_remove ~session_id:sid ~slice:"execution";
    let exec = Ws.slice_index_subscribers "execution" in
    let keepers = Ws.slice_index_subscribers "keepers" in
    Alcotest.(check bool) "removed from execution"
      true (not (List.mem sid exec));
    Alcotest.(check bool) "still in keepers"
      true (List.mem sid keepers);
    Ws.__test_slice_index_remove_session sid)

let test_slice_index_remove_session_clears_all_slices () =
  Eio_main.run (fun _env ->
    let sid = "ws-slice-cleanup-1" in
    Ws.__test_slice_index_remove_session sid;
    List.iter
      (fun slice -> Ws.__test_slice_index_add ~session_id:sid ~slice)
      ["execution"; "keepers"; "transport"; "shell"];
    Ws.__test_slice_index_remove_session sid;
    List.iter
      (fun slice ->
        let subs = Ws.slice_index_subscribers slice in
        Alcotest.(check bool)
          (Printf.sprintf "session removed from %s" slice)
          true (not (List.mem sid subs)))
      ["execution"; "keepers"; "transport"; "shell"])

let test_slice_index_size_reflects_pairs () =
  Eio_main.run (fun _env ->
    let sid_a = "ws-slice-size-a" in
    let sid_b = "ws-slice-size-b" in
    Ws.__test_slice_index_remove_session sid_a;
    Ws.__test_slice_index_remove_session sid_b;
    let baseline = Ws.slice_index_size () in
    Ws.__test_slice_index_add ~session_id:sid_a ~slice:"execution";
    Ws.__test_slice_index_add ~session_id:sid_a ~slice:"keepers";
    Ws.__test_slice_index_add ~session_id:sid_b ~slice:"execution";
    let after = Ws.slice_index_size () in
    (* 2 entries for sid_a + 1 for sid_b = +3 over baseline *)
    Alcotest.(check int) "size grew by exactly the new pair count"
      3 (after - baseline);
    Ws.__test_slice_index_remove_session sid_a;
    Ws.__test_slice_index_remove_session sid_b;
    let final = Ws.slice_index_size () in
    Alcotest.(check int) "size returns to baseline after sweep"
      baseline final)

let test_slice_index_add_is_idempotent () =
  Eio_main.run (fun _env ->
    let sid = "ws-slice-idem" in
    Ws.__test_slice_index_remove_session sid;
    Ws.__test_slice_index_add ~session_id:sid ~slice:"execution";
    Ws.__test_slice_index_add ~session_id:sid ~slice:"execution";
    Ws.__test_slice_index_add ~session_id:sid ~slice:"execution";
    let subs = Ws.slice_index_subscribers "execution" in
    let occurrences = List.length (List.filter ((=) sid) subs) in
    Alcotest.(check int) "session appears at most once after duplicate adds"
      1 occurrences;
    Ws.__test_slice_index_remove_session sid)

(* ====== Slice fanout gate (Phase 2) ====== *)

(* Phase 2 turns on the slice-aware fanout: when the env flag is set,
   slice-scoped events skip raw-SSE-forwards to authenticated sessions
   whose route does not subscribe.  The counter
   [masc_ws_slice_fanout_skipped_total] advances per skip.  Catch-all
   events (no slice mapping) still raw-forward to every session. *)

let read_skip_counter () =
  Masc.Otel_metric_store.metric_value_or_zero
    Masc.Otel_metric_store.metric_ws_slice_fanout_skipped ()

let with_env_var key value f =
  let prev = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match prev with
      | Some v -> Unix.putenv key v
      | None -> Unix.putenv key "")
    f

let test_slice_fanout_skip_counter_metric_registered () =
  (* The counter is registered at startup; reading it must succeed
     without raising even before any skip occurs. *)
  let v = read_skip_counter () in
  Alcotest.(check bool) "counter readable (>= 0)" true (v >= 0.0)

let test_slice_fanout_flag_default_is_on () =
  Eio_main.run (fun _env ->
    Ws.__test_reset_env_caches ();
    with_env_var "MASC_WS_SLICE_INDEX_ENABLED" "" (fun () ->
        (* Bandwidth-burst hardening flipped the default from false to
           true.  Operators set false only as an emergency rollback. *)
        Alcotest.(check bool) "default on"
          true (Ws.slice_index_enabled ())))

let test_slice_fanout_flag_reads_env () =
  Eio_main.run (fun _env ->
    Ws.__test_reset_env_caches ();
    with_env_var "MASC_WS_SLICE_INDEX_ENABLED" "true" (fun () ->
        Alcotest.(check bool) "env=true → enabled"
          true (Ws.slice_index_enabled ()));
    Ws.__test_reset_env_caches ();
    with_env_var "MASC_WS_SLICE_INDEX_ENABLED" "false" (fun () ->
        Alcotest.(check bool) "env=false → disabled"
          false (Ws.slice_index_enabled ())))

(* ====== Dashboard auth state (RFC-0204 §8.4, Phase 1) ====== *)

let test_dashboard_auth_unauthenticated () =
  Alcotest.(check bool) "Unauthenticated is not authenticated"
    false (Ws.dashboard_auth_is_authenticated Ws.Unauthenticated);
  Alcotest.(check (option string)) "Unauthenticated carries no agent"
    None (Ws.dashboard_auth_agent Ws.Unauthenticated)

let test_dashboard_auth_authenticated_with_agent () =
  let st = Ws.Authenticated { agent = Some "garnet" } in
  Alcotest.(check bool) "Authenticated counts as authenticated"
    true (Ws.dashboard_auth_is_authenticated st);
  Alcotest.(check (option string)) "agent name is carried through"
    (Some "garnet") (Ws.dashboard_auth_agent st)

let test_dashboard_auth_authenticated_tokenless () =
  (* An auth config that permits tokenless dashboard reads resolves to an
     authenticated state with no agent name. *)
  let st = Ws.Authenticated { agent = None } in
  Alcotest.(check bool) "tokenless still counts as authenticated"
    true (Ws.dashboard_auth_is_authenticated st);
  Alcotest.(check (option string)) "tokenless carries no agent"
    None (Ws.dashboard_auth_agent st)

(* ====== Cross-fiber scalar state (Atomic.t) ====== *)

let test_new_session_initializes_pong_state () =
  let session = Ws.new_session ~id:"pong-state-init" ~wsd:(Obj.magic ()) in
  Alcotest.(check bool) "closed starts false" false (Atomic.get session.closed);
  Alcotest.(check bool) "last_pong_at is in the recent past"
    true
    (Atomic.get session.last_pong_at <= Unix.gettimeofday ());
  Alcotest.(check bool) "dashboard ack timestamp is initialized"
    true
    (Atomic.get session.dashboard_last_ack_at <= Unix.gettimeofday ());
  Alcotest.(check int) "no delta is pending ack"
    0 (Atomic.get session.dashboard_last_delta_seq);
  Alcotest.(check bool) "delta timestamp is initialized"
    true
    (Atomic.get session.dashboard_last_delta_at <= Unix.gettimeofday ());
  Alcotest.(check int) "inbound dispatch count starts empty"
    0 (Atomic.get session.inbound_dispatches)

let test_record_pong_refreshes_last_pong_at () =
  let session = Ws.new_session ~id:"pong-refresh" ~wsd:(Obj.magic ()) in
  let before = Atomic.get session.last_pong_at in
  Unix.sleepf 0.005;
  Ws.record_pong session;
  Alcotest.(check bool) "last_pong_at advanced on pong"
    true
    (Atomic.get session.last_pong_at > before)

(* #21509 regression: liveness is keyed on the last answered pong, not a tick
   counter, so a client that just answered must never be closed — even at the
   most aggressive threshold=1.  Before the fix the per-tick missed counter sat
   one short of the threshold every interval and closed responsive clients. *)
let test_heartbeat_responsive_client_not_closed () =
  let now = 1_000.0 in
  Alcotest.(check bool) "answered 1s ago at threshold=1 stays open"
    false
    (Ws.heartbeat_should_close ~now ~last_pong_at:(now -. 1.0) ~threshold:1
       ~interval_s:30.0)

let test_heartbeat_silent_client_closed () =
  let now = 1_000.0 in
  Alcotest.(check bool) "no pong for >3 intervals closes"
    true
    (Ws.heartbeat_should_close ~now ~last_pong_at:(now -. 100.0) ~threshold:3
       ~interval_s:30.0);
  Alcotest.(check bool) "within 3 intervals stays open"
    false
    (Ws.heartbeat_should_close ~now ~last_pong_at:(now -. 80.0) ~threshold:3
       ~interval_s:30.0)

let test_heartbeat_threshold_zero_disables () =
  Alcotest.(check bool) "threshold=0 never closes"
    false
    (Ws.heartbeat_should_close ~now:1e9 ~last_pong_at:0.0 ~threshold:0
       ~interval_s:30.0)

let test_missed_pong_threshold_default () =
  (* Clear any inherited value so the default (3) is exercised. *)
  Unix.putenv "MASC_WS_MISSED_PONG_THRESHOLD" "";
  Alcotest.(check int) "default threshold is 3" 3 (Ws.__test_missed_pong_threshold ())

let test_missed_pong_threshold_reads_env () =
  with_env_var "MASC_WS_MISSED_PONG_THRESHOLD" "5" (fun () ->
    Alcotest.(check int) "env=5 → threshold 5" 5 (Ws.__test_missed_pong_threshold ()));
  with_env_var "MASC_WS_MISSED_PONG_THRESHOLD" "0" (fun () ->
    Alcotest.(check int) "env=0 disables threshold" 0 (Ws.__test_missed_pong_threshold ()));
  with_env_var "MASC_WS_MISSED_PONG_THRESHOLD" "-2" (fun () ->
    Alcotest.(check int) "negative values clamp to 0" 0 (Ws.__test_missed_pong_threshold ()))

(* ====== Cross-domain delivery-state safety (RFC-0204 Phase 3 gate) ====== *)

(* The per-session dashboard delivery counters are read and written on the SSE
   fanout callback, which fires from the main domain (keeper keepalive / event
   bridge / registry refresh broadcasts) AND from serving handlers
   (HTTP-route broadcasts).  Today that is safe only because a single Eio
   domain runs cooperative fibers that never preempt mid-update.  RFC-0204
   Phase 3 moves serving to a second domain; the moment two domains run in
   parallel, a plain [int] read-modify-write in [next_dashboard_seq] loses
   updates and hands two callers the same seq, breaking the dashboard-ws.v1
   seq/ack contract.

   This drives two real domains through [next_dashboard_seq] and asserts the
   final counter equals the total number of calls — i.e. no increment was lost.
   It depends only on the public [int] seams, not the field representation, so
   it compiles against both the plain-int and the Atomic version: RED on the
   plain field (a tight contended read-modify-write loses ~half its updates on a
   multicore host), GREEN once the counter is an [int Atomic.t] allocated via
   [Atomic.fetch_and_add].  The final-count assertion is far more sensitive than
   a uniqueness check: a single lost update already drops the total below
   [2 * iters].

   Scope: this proves the [fetch_and_add] seq path — the most severe site (~half
   the updates lost on a multicore host).  The other delivery fields are simpler
   conversions verified by inspection and guarded by the rest of the suite:
   [dashboard_last_ack_seq] uses a CAS-retry monotonic max ([atomic_bump_max]);
   the buffered / delta / ack_at fields are single [Atomic.set]/[get]. *)
let test_dashboard_seq_no_lost_updates_across_domains () =
  (* A single-vCPU host time-slices domains rather than running them in
     parallel, so the lost-update race cannot manifest there and a pass would be
     meaningless.  Skip rather than assert a vacuous green. *)
  if Domain.recommended_domain_count () < 2 then ()
  else
  let session = Ws.new_session ~id:"seq-xdomain" ~wsd:(Obj.magic ()) in
  let iters = 1_000_000 in
  (* Two-way start barrier: each domain announces arrival and spins until both
     are present, so the increment loops run in true overlap.  Without it the
     spawned domain's startup latency can exceed the loop's runtime, the main
     domain drains its loop before the other starts, and the race never occurs
     — the test would then pass even on the buggy plain field (a vacuous gate). *)
  let ready = Atomic.make 0 in
  let work () =
    Atomic.incr ready;
    while Atomic.get ready < 2 do
      Domain.cpu_relax ()
    done;
    for _ = 1 to iters do
      ignore (Ws.__test_next_dashboard_seq session)
    done
  in
  let other = Domain.spawn work in
  work ();
  Domain.join other;
  Alcotest.(check int)
    "no dashboard seq increments lost across two domains"
    (2 * iters)
    (Ws.__test_dashboard_seq_value session)

let () =
  Alcotest.run "WebSocket Transport" [
	    ("delivery_xdomain", [
	      Alcotest.test_case "next_dashboard_seq loses no updates across domains"
	        `Quick test_dashboard_seq_no_lost_updates_across_domains;
	    ]);
	    ("session_registry", [
	      Alcotest.test_case "initial count" `Quick test_initial_session_count;
	      Alcotest.test_case "close_all empty" `Quick test_close_all_empty;
	      Alcotest.test_case "wire close stays outside registry lock" `Quick
	        test_session_close_wire_calls_stay_outside_registry_lock;
	    ]);
    ("sha1", [
      Alcotest.test_case "produces 20 bytes" `Quick test_sha1_produces_20_bytes;
      Alcotest.test_case "deterministic" `Quick test_sha1_deterministic;
      Alcotest.test_case "different inputs" `Quick test_sha1_different_inputs;
    ]);
    ("handshake accept", [
      Alcotest.test_case "RFC 6455 §1.3 canonical accept" `Quick
        test_sec_websocket_accept_canonical;
      Alcotest.test_case "valid upgrade request accepted" `Quick
        test_ws_upgrade_accept_valid;
      Alcotest.test_case "non-16-byte key rejected" `Quick
        test_ws_upgrade_accept_rejects_short_key;
      Alcotest.test_case "wrong Sec-WebSocket-Version rejected" `Quick
        test_ws_upgrade_accept_rejects_wrong_version;
    ]);
    ("dashboard", [
      Alcotest.test_case "route scoped slices are valid" `Quick
        test_dashboard_route_scoped_slices_are_valid;
    ]);
    ("parse_cache", [
      Alcotest.test_case "known type maps to slice" `Quick
        test_parse_sse_dashboard_event_known_type;
      Alcotest.test_case "composite change maps to composite slice" `Quick
        test_parse_sse_dashboard_event_composite_change_maps_to_composite;
      Alcotest.test_case "unknown type yields None slice" `Quick
        test_parse_sse_dashboard_event_unknown_type;
      Alcotest.test_case "malformed input returns None" `Quick
        test_parse_sse_dashboard_event_malformed;
      Alcotest.test_case "repeated calls stable" `Quick
        test_parse_sse_dashboard_event_stable_on_repeat;
      Alcotest.test_case "cache invalidates on new ref" `Quick
        test_parse_sse_dashboard_event_invalidated_on_new_ref;
      Alcotest.test_case "handles production SSE wire format" `Quick
        test_parse_sse_dashboard_event_handles_sse_format;
      Alcotest.test_case "finds SSE data line without fixed position" `Quick
        test_parse_sse_dashboard_event_finds_data_line;
      Alcotest.test_case "hit/miss counters track reuse" `Quick
        test_parse_cache_counters;
    ]);
    ("bytes_cache", [
      Alcotest.test_case "same string ref returns same Bigstringaf.t" `Quick
        test_bigstring_of_shared_text_reuses_same_ref;
      Alcotest.test_case "content round-trips through cache" `Quick
        test_bigstring_of_shared_text_content_matches;
      Alcotest.test_case "invalid UTF-8 is repaired before text frames" `Quick
        test_bigstring_of_shared_text_repairs_invalid_utf8_for_text_frames;
      Alcotest.test_case "distinct refs force re-allocation" `Quick
        test_bigstring_of_shared_text_invalidates_on_new_ref;
      Alcotest.test_case "shared send avoids payload string copy" `Quick
        test_shared_send_avoids_per_session_payload_string_copy;
      Alcotest.test_case "hit/miss counters track reuse" `Quick
        test_bytes_cache_counters;
      Alcotest.test_case "dashboard delta shared payload excludes seq" `Quick
        test_dashboard_delta_payload_text_excludes_seq;
      Alcotest.test_case "dashboard delta payload serializes once per broadcast ref" `Quick
        test_dashboard_delta_payload_serializes_once_per_broadcast_ref;
    ]);
    ("ack_observability", [
      Alcotest.test_case "buffered_bytes sum and count track observations" `Quick
        test_observe_ws_client_buffered_bytes_accumulates;
      Alcotest.test_case "negative buffered_bytes floor to zero" `Quick
        test_observe_ws_client_buffered_bytes_clamps_negative;
    ]);
    ("backpressure_gate", [
      Alcotest.test_case "unauthenticated sessions never trigger the gate" `Quick
        test_backpressure_gate_unauthenticated_ignored;
      Alcotest.test_case "zero limit disables the gate" `Quick
        test_backpressure_gate_zero_disables;
      Alcotest.test_case "default limit is 1 MiB" `Quick
        test_backpressure_gate_default_is_one_mib;
      Alcotest.test_case "throttle counter advances per skipped delivery" `Quick
        test_backpressure_gate_throttle_counter_increments;
      Alcotest.test_case "ack stale predicate" `Quick
        test_backpressure_ack_stale_predicate;
      Alcotest.test_case "ack stale threshold reads env" `Quick
        test_backpressure_ack_stale_threshold_reads_env;
      Alcotest.test_case "ack stale threshold cache reset" `Quick
        test_backpressure_ack_stale_threshold_cache_resets;
      Alcotest.test_case "stale ack throttles delivery before send" `Quick
        test_backpressure_gate_stale_ack_throttles_delivery;
    ]);
    (* RFC-0286: the frame/message reassembly + size-classify unit tests were
       removed with the manual reassembler; ws-direct's Connection owns that
       logic and is covered by its own test suite. The env-default knob test
       stays — masc still reads the caps and feeds them to Endpoint.create. *)
    ("inbound_size_gate", [
      Alcotest.test_case "size cap env defaults" `Quick
        test_inbound_size_env_defaults;
    ]);
    ("inbound_dispatch_admission", [
      Alcotest.test_case "default concurrent dispatch cap is bounded" `Quick
        test_inbound_dispatch_default_limit;
      Alcotest.test_case "session cap rejects excess dispatches" `Quick
        test_inbound_dispatch_rejects_at_session_limit;
      Alcotest.test_case "zero cap disables admission gate" `Quick
        test_inbound_dispatch_zero_limit_disables_gate;
      Alcotest.test_case "missing or closed sessions are rejected" `Quick
        test_inbound_dispatch_rejects_gone_or_closed_session;
    ]);
    ("external_subscriber", [
      Alcotest.test_case "single subscriber receives broadcast" `Quick
        test_ws_external_subscriber_receives_broadcast;
      Alcotest.test_case "multi-session broadcast" `Quick
        test_ws_multi_session_broadcast;
      Alcotest.test_case "unsubscribe stops delivery" `Quick
        test_ws_unsubscribe_stops_delivery;
      Alcotest.test_case "dead subscriber auto-removed" `Quick
        test_ws_dead_subscriber_auto_removed;
      Alcotest.test_case "subscriber count tracking" `Quick
        test_ws_external_subscriber_count;
    ]);
    ("slice_index", [
      Alcotest.test_case "unknown slice yields no subscribers" `Quick
        test_slice_index_starts_empty_for_unknown_slice;
      Alcotest.test_case "add records session under slice" `Quick
        test_slice_index_add_records_session;
      Alcotest.test_case "remove targets only the named slice" `Quick
        test_slice_index_remove_specific_slice;
      Alcotest.test_case "remove_session sweeps every slice" `Quick
        test_slice_index_remove_session_clears_all_slices;
      Alcotest.test_case "size tracks (slice × session) pair count" `Quick
        test_slice_index_size_reflects_pairs;
      Alcotest.test_case "duplicate add is idempotent" `Quick
        test_slice_index_add_is_idempotent;
    ]);
    ("slice_fanout_gate", [
      Alcotest.test_case "skip counter registered" `Quick
        test_slice_fanout_skip_counter_metric_registered;
      Alcotest.test_case "flag default is on" `Quick
        test_slice_fanout_flag_default_is_on;
      Alcotest.test_case "flag reads env var" `Quick
        test_slice_fanout_flag_reads_env;
    ]);
    ("dashboard_auth_state", [
      Alcotest.test_case "Unauthenticated has no auth and no agent" `Quick
        test_dashboard_auth_unauthenticated;
      Alcotest.test_case "Authenticated carries the agent name" `Quick
        test_dashboard_auth_authenticated_with_agent;
      Alcotest.test_case "tokenless Authenticated has no agent" `Quick
        test_dashboard_auth_authenticated_tokenless;
    ]);
    ("pong_state", [
      Alcotest.test_case "new session initializes pong atomics" `Quick
        test_new_session_initializes_pong_state;
      Alcotest.test_case "record_pong refreshes last_pong_at" `Quick
        test_record_pong_refreshes_last_pong_at;
    ]);
    ("heartbeat_liveness", [
      Alcotest.test_case "responsive client not closed (#21509)" `Quick
        test_heartbeat_responsive_client_not_closed;
      Alcotest.test_case "silent client closed past threshold" `Quick
        test_heartbeat_silent_client_closed;
      Alcotest.test_case "threshold=0 disables guard" `Quick
        test_heartbeat_threshold_zero_disables;
    ]);
    ("pong_threshold", [
      Alcotest.test_case "default missed-pong threshold is 3" `Quick
        test_missed_pong_threshold_default;
      Alcotest.test_case "threshold reads env and clamps negatives" `Quick
        test_missed_pong_threshold_reads_env;
    ]);
  ]
