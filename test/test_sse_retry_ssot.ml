(* RFC-0089 — SSE reconnect-interval SSOT. The presence-stream and
   activity-stream primers build their "retry:" directive via
   [sse_comment_with_retry], sourced from [sse_retry_ms], instead of inlining
   "retry: 3000" (which would silently diverge if the interval were tuned). *)

module H = Server_mcp_transport_http_headers
open Alcotest

let contains s sub =
  let ls = String.length s and lsub = String.length sub in
  let rec go i = (i + lsub <= ls) && (String.sub s i lsub = sub || go (i + 1)) in
  lsub = 0 || go 0

let test_frame_derives_from_ssot () =
  check string "presence frame is sourced from sse_retry_ms"
    (Printf.sprintf ": presence-stream\nretry: %d\n\n" H.sse_retry_ms)
    (H.sse_comment_with_retry ~comment:"presence-stream")

let test_comment_interpolated_retry_constant () =
  let a = H.sse_comment_with_retry ~comment:"activity-stream after=7" in
  let b = H.sse_comment_with_retry ~comment:"presence-stream" in
  check bool "distinct comments yield distinct frames" true (a <> b);
  let retry_line = Printf.sprintf "retry: %d" H.sse_retry_ms in
  check bool "activity frame carries sse_retry_ms" true (contains a retry_line);
  check bool "presence frame carries sse_retry_ms" true (contains b retry_line);
  check bool "frame is an SSE comment (leading ': ')" true
    (String.length a >= 2 && String.sub a 0 2 = ": ")

let () =
  run "sse_comment_with_retry"
    [
      ( "ssot",
        [
          test_case "frame derives from sse_retry_ms" `Quick
            test_frame_derives_from_ssot;
          test_case "comment interpolated, retry constant" `Quick
            test_comment_interpolated_retry_constant;
        ] );
    ]
