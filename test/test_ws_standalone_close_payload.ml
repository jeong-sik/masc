open Alcotest
module WS = Masc_mcp.Server_ws_standalone.For_testing

let truncation_suffix = "...<truncated>"
let utf8_han = "\237\149\156"

let close_payload ?(reason = "") code =
  let payload = Bytes.create (2 + String.length reason) in
  Bytes.set payload 0 (Char.chr ((code lsr 8) land 0xff));
  Bytes.set payload 1 (Char.chr (code land 0xff));
  Bytes.blit_string reason 0 payload 2 (String.length reason);
  payload
;;

let test_truncate_ws_close_reason_boundaries () =
  let exact_ascii = String.make WS.max_ws_close_reason_log_len 'a' in
  check
    string
    "96-byte ascii unchanged"
    exact_ascii
    (WS.truncate_ws_close_reason exact_ascii);
  let over_ascii = String.make (WS.max_ws_close_reason_log_len + 1) 'a' in
  check
    string
    "97-byte ascii truncates"
    (exact_ascii ^ truncation_suffix)
    (WS.truncate_ws_close_reason over_ascii);
  let exact_utf8 =
    String.make (WS.max_ws_close_reason_log_len - String.length utf8_han) 'a' ^ utf8_han
  in
  check
    string
    "full utf8 codepoint at boundary unchanged"
    exact_utf8
    (WS.truncate_ws_close_reason exact_utf8);
  let crossing_utf8 = String.make (WS.max_ws_close_reason_log_len - 2) 'a' ^ utf8_han in
  check
    string
    "utf8 codepoint crossing boundary is not split"
    (String.make (WS.max_ws_close_reason_log_len - 2) 'a' ^ truncation_suffix)
    (WS.truncate_ws_close_reason crossing_utf8)
;;

let test_summarize_ws_close_payload_boundaries () =
  check
    string
    "zero-length close payload"
    "code=none received_len=0 declared_len=0"
    (WS.summarize_ws_close_payload (Bytes.create 0) ~received_len:0 ~declared_len:0);
  check
    string
    "single-byte close payload is malformed"
    "malformed_close_payload received_len=1 declared_len=1"
    (WS.summarize_ws_close_payload (Bytes.of_string "x") ~received_len:1 ~declared_len:1);
  check
    string
    "two-byte close payload reports code"
    "code=1000 reason=<empty> received_len=2 declared_len=2"
    (WS.summarize_ws_close_payload (close_payload 1000) ~received_len:2 ~declared_len:2);
  check
    string
    "partial payload is tagged"
    "code=1000 reason=<empty> received_len=2 declared_len=4 partial=true"
    (WS.summarize_ws_close_payload
       (close_payload ~reason:"xy" 1000)
       ~received_len:2
       ~declared_len:4);
  check
    string
    "reason payload is escaped"
    "code=1000 reason=\"bye\" received_len=5 declared_len=5"
    (WS.summarize_ws_close_payload
       (close_payload ~reason:"bye" 1000)
       ~received_len:5
       ~declared_len:5)
;;

let check_some label expected = function
  | Some actual -> check string label expected actual
  | None -> failf "%s: expected Some" label
;;

let check_none label = function
  | None -> ()
  | Some actual -> failf "%s: expected None, got %S" label actual
;;

let test_immediate_ws_close_payload_summary_boundaries () =
  check_some
    "declared_len 0 finishes immediately"
    "code=none received_len=0 declared_len=0"
    (WS.immediate_ws_close_payload_summary ~declared_len:0);
  check_some
    "negative declared_len is retained in diagnostics"
    "code=none received_len=0 declared_len=-1"
    (WS.immediate_ws_close_payload_summary ~declared_len:(-1));
  check_none
    "declared_len 1 reads payload"
    (WS.immediate_ws_close_payload_summary ~declared_len:1);
  check_none
    "declared_len 125 reads payload"
    (WS.immediate_ws_close_payload_summary ~declared_len:125);
  check_some
    "declared_len 126 rejects control frame"
    "payload_len=126 exceeds_control_frame_limit"
    (WS.immediate_ws_close_payload_summary ~declared_len:126)
;;

let test_plan_ws_close_payload_chunk_guards_zero_len () =
  (match WS.plan_ws_close_payload_chunk ~offset:0 ~declared_len:3 ~chunk_len:0 with
   | WS.Reject_empty_chunk summary ->
     check
       string
       "zero chunk finishes instead of rescheduling"
       "payload_read_empty_chunk received_len=0 declared_len=3"
       summary
   | _ -> fail "expected zero chunk to reject");
  match WS.plan_ws_close_payload_chunk ~offset:1 ~declared_len:3 ~chunk_len:5 with
  | WS.Copy_then_finish { copy_len; next_offset } ->
    check int "copy remaining bytes" 2 copy_len;
    check int "next offset reaches declared len" 3 next_offset
  | _ -> fail "expected oversized chunk to finish after copying remaining bytes"
;;

let () =
  run
    "ws_standalone_close_payload"
    [ ( "close payload diagnostics"
      , [ test_case
            "truncate close reason boundaries"
            `Quick
            test_truncate_ws_close_reason_boundaries
        ; test_case
            "summarize payload boundaries"
            `Quick
            test_summarize_ws_close_payload_boundaries
        ; test_case
            "immediate declared length boundaries"
            `Quick
            test_immediate_ws_close_payload_summary_boundaries
        ; test_case
            "zero-length read chunk guard"
            `Quick
            test_plan_ws_close_payload_chunk_guards_zero_len
        ] )
    ]
;;
