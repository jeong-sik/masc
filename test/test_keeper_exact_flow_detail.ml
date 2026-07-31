(** Unit tests for the shared exact-output flow error rendering. *)

module Detail = Masc.Keeper_exact_flow_detail
module Exact_output = Agent_sdk.Exact_output

let test_execution_cause_detail () =
  Alcotest.(check string)
    "refused"
    "serialized request refused (http_status=413)"
    (Detail.execution_cause_detail
       (Exact_output.Serialized_request_refused { http_status = 413 }));
  Alcotest.(check string)
    "completion"
    "completion failed"
    (Detail.execution_cause_detail Exact_output.Completion_failed);
  Alcotest.(check string)
    "ambiguous"
    "ambiguous output (candidates=2)"
    (Detail.execution_cause_detail (Exact_output.Ambiguous_output 2))
;;

let test_raw_response_excerpt_none () =
  Alcotest.(check string)
    "none"
    "raw_response=none"
    (Detail.raw_response_excerpt None)
;;

let test_raw_response_excerpt_flattens_newlines () =
  let raw : Exact_output.raw_response =
    { body = "line1\nline2\rline3"; body_sha256 = "abc" }
  in
  Alcotest.(check string)
    "flattened"
    "raw_response=line1 line2 line3"
    (Detail.raw_response_excerpt (Some raw))
;;

let test_raw_response_excerpt_bounds_long_bodies () =
  let raw : Exact_output.raw_response =
    { body = String.make 600 'x'; body_sha256 = "deadbeef" }
  in
  let rendered = Detail.raw_response_excerpt (Some raw) in
  Alcotest.(check bool) "bounded" true (String.length rendered < 400);
  Alcotest.(check bool)
    "keeps total byte count"
    true
    (Astring.String.is_infix ~affix:"600 bytes total" rendered);
  Alcotest.(check bool)
    "keeps body sha"
    true
    (Astring.String.is_infix ~affix:"deadbeef" rendered)
;;

let test_raw_response_excerpt_redacts_secrets () =
  let raw : Exact_output.raw_response =
    { body = "error: upstream rejected Bearer sk-live-abc123 token"
    ; body_sha256 = "redsha"
    }
  in
  let rendered = Detail.raw_response_excerpt (Some raw) in
  Alcotest.(check bool)
    "secret is gone"
    false
    (Astring.String.is_infix ~affix:"sk-live-abc123" rendered);
  Alcotest.(check bool)
    "redaction marker present"
    true
    (Astring.String.is_infix ~affix:"[REDACTED]" rendered)
;;

let test_raw_response_excerpt_cuts_on_utf8_boundary () =
  let body = "a" ^ String.concat "" (List.init 100 (fun _ -> "가")) in
  let raw : Exact_output.raw_response = { body; body_sha256 = "utf8sha" } in
  let rendered = Detail.raw_response_excerpt (Some raw) in
  let start = String.length "raw_response=" in
  let marker_index =
    match Astring.String.find_sub ~sub:"... (" rendered with
    | Some index -> index
    | None -> Alcotest.fail "expected truncation marker"
  in
  let excerpt = String.sub rendered start (marker_index - start) in
  (* A 240-byte cut would land mid-character: one ASCII byte plus 79 full
     three-byte "가" characters is 238 bytes, the largest boundary-aligned
     prefix. A raw [String.sub] would return 240 malformed bytes instead. *)
  Alcotest.(check int) "boundary-aligned length" 238 (String.length excerpt);
  Alcotest.(check bool)
    "keeps original byte count"
    true
    (Astring.String.is_infix ~affix:"301 bytes total" rendered)
;;

let () =
  Alcotest.run
    "keeper_exact_flow_detail"
    [ ( "render"
      , [ Alcotest.test_case "execution cause detail" `Quick
            test_execution_cause_detail
        ; Alcotest.test_case "raw response none" `Quick
            test_raw_response_excerpt_none
        ; Alcotest.test_case "raw response flattens newlines" `Quick
            test_raw_response_excerpt_flattens_newlines
        ; Alcotest.test_case "raw response bounds long bodies" `Quick
            test_raw_response_excerpt_bounds_long_bodies
        ; Alcotest.test_case "raw response redacts secrets" `Quick
            test_raw_response_excerpt_redacts_secrets
        ; Alcotest.test_case "raw response cuts on utf8 boundary" `Quick
            test_raw_response_excerpt_cuts_on_utf8_boundary
        ] )
    ]
