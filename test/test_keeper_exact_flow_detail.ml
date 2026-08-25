(** Unit tests for the shared exact-output flow error rendering. *)

module Detail = Masc.Keeper_exact_flow_detail
module Exact_output = Agent_core.Exact_output

let test_execution_cause_detail () =
  Alcotest.(check string)
    "refused"
    "provider refused (http_status=413 refusal=request_body_refused)"
    (Detail.execution_cause_detail
       (Exact_output.Provider_response_refused
          { http_status = 413; refusal = Exact_output.Request_body_refused }));
  (* The line an operator reads when a lane dies on quota. It carried neither
     the status nor the kind while a 429 was classified as a bare
     [Completion_failed]. *)
  Alcotest.(check string)
    "rate limited"
    "provider refused (http_status=429 refusal=rate_limited)"
    (Detail.execution_cause_detail
       (Exact_output.Provider_response_refused
          { http_status = 429; refusal = Exact_output.Rate_limited }));
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

(* The eleven distinct execution causes reach the advance line through
   [execution_cause_detail]. The execution-failed branch of
   the execution-failed branch cannot be built here — [flow_attempt_snapshot] is a
   private agent-core type with no constructor — so what is pinned is that every
   cause the renderer can receive still renders apart from every other. A
   single shared label is what made the eleven indistinguishable in the log,
   and this fails if any two collapse onto the same string. *)
let test_every_execution_cause_renders_distinctly () =
  let causes : Exact_output.execution_error_cause list =
    [ Attempt_already_started
    ; Clock_required_for_timeout
    ; Frozen_request_mismatch
    ; Completion_failed
    ; Provider_response_refused { http_status = 413; refusal = Request_body_refused }
    ; Provider_response_refused { http_status = 429; refusal = Rate_limited }
    ; Provider_response_refused { http_status = 529; refusal = Overloaded }
    ; Provider_response_refused { http_status = 500; refusal = Server_error }
    ; Provider_response_refused { http_status = 401; refusal = Auth_failed }
    ; Provider_response_refused { http_status = 403; refusal = Authorization_refused }
    ; Provider_response_refused { http_status = 402; refusal = Payment_required }
    ; Provider_response_refused { http_status = 400; refusal = Invalid_request }
    ; Provider_response_refused { http_status = 404; refusal = Not_found }
    ; Provider_response_refused { http_status = 400; refusal = Context_overflow }
    ; Provider_response_refused { http_status = 400; refusal = Input_capacity }
    ; Provider_response_refused { http_status = 400; refusal = Network_error }
    ; Provider_response_refused { http_status = 408; refusal = Timeout }
    ; Incomplete_output
    ; Missing_output
    ; Ambiguous_output 3
    ; Unexpected_output_content
    ; Invalid_json_output
    ; Internal_non_json_output
    ]
  in
  let rendered = List.map Detail.execution_cause_detail causes in
  let unique = List.sort_uniq String.compare rendered in
  Alcotest.(check int)
    "every cause keeps its own wording"
    (List.length causes)
    (List.length unique);
  (* The two an operator most needs to tell apart: a provider that refused the
     call outright versus one that answered but ran out of output budget. *)
  Alcotest.(check bool)
    "quota refusal and truncated output are not the same string"
    false
    (String.equal
       (Detail.execution_cause_detail Completion_failed)
       (Detail.execution_cause_detail Incomplete_output))
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
        ; Alcotest.test_case "every execution cause renders distinctly" `Quick
            test_every_execution_cause_renders_distinctly
        ] )
    ]
