(** Round-trip + classification tests for [Auth_error_kind].

    Guards the closed-enum contract that prometheus dashboards depend on
    (issue #11266 Track 2a). Stable string labels must round-trip and
    every modelled [Types.t] constructor must classify to a non-[Other]
    label. *)

open Alcotest
module Aek = Masc_mcp.Auth_error_kind

let test_to_of_string_round_trip () =
  List.iter
    (fun kind ->
      let s = Aek.to_string kind in
      match Aek.of_string s with
      | Some kind' when kind' = kind -> ()
      | Some _ ->
          Alcotest.failf "to_string/of_string drift for %s" s
      | None ->
          Alcotest.failf "of_string returned None for known label %s" s)
    Aek.all

let test_of_string_unknown_returns_none () =
  (* Unrecognised labels must return None rather than collapsing to
     [Other] — callers rely on that to detect contract drift. *)
  match Aek.of_string "definitely_not_a_label" with
  | None -> ()
  | Some _ ->
      Alcotest.fail "of_string should return None for unknown label"

let test_classify_invalid_token () =
  match Aek.classify (Types.Auth (Types.Auth_error.InvalidToken "x")) with
  | Aek.Token_mismatch -> ()
  | other ->
      Alcotest.failf
        "InvalidToken should classify as Token_mismatch, got %s"
        (Aek.to_string other)

let test_classify_token_expired () =
  match Aek.classify (Types.Auth (Types.Auth_error.TokenExpired "x")) with
  | Aek.Token_expired -> ()
  | other ->
      Alcotest.failf
        "TokenExpired should classify as Token_expired, got %s"
        (Aek.to_string other)

let test_classify_unauthorized () =
  match Aek.classify (Types.Auth (Types.Auth_error.Unauthorized "x")) with
  | Aek.Unauthorized -> ()
  | other ->
      Alcotest.failf
        "Unauthorized should classify as Unauthorized, got %s"
        (Aek.to_string other)

let test_classify_forbidden () =
  match Aek.classify (Types.Auth (Types.Auth_error.Forbidden { agent = "a"; action = "b" })) with
  | Aek.Forbidden -> ()
  | other ->
      Alcotest.failf
        "Forbidden should classify as Forbidden, got %s"
        (Aek.to_string other)

let test_classify_agent_not_found () =
  match Aek.classify (Types.Agent (Types.Agent_error.NotFound "x")) with
  | Aek.Agent_not_found -> ()
  | other ->
      Alcotest.failf
        "AgentNotFound should classify as Agent_not_found, got %s"
        (Aek.to_string other)

let test_classify_io_error () =
  match Aek.classify (Types.System (Types.System_error.IoError "x")) with
  | Aek.Io_error -> ()
  | other ->
      Alcotest.failf
        "IoError should classify as Io_error, got %s"
        (Aek.to_string other)

let test_classify_invalid_json () =
  match Aek.classify (Types.System (Types.System_error.InvalidJson "x")) with
  | Aek.Invalid_json -> ()
  | other ->
      Alcotest.failf
        "InvalidJson should classify as Invalid_json, got %s"
        (Aek.to_string other)

let test_classify_unmodelled_falls_to_other () =
  (* IoError is not auth-relevant and intentionally falls through
     to [Other]. If a future PR moves it under an explicit arm, this
     test is the breakpoint. *)
  match Aek.classify (Types.System (Types.System_error.IoError "disk")) with
  | Aek.Other -> ()
  | other ->
      Alcotest.failf
        "IoError should classify as Other, got %s"
        (Aek.to_string other)

let test_label_set_stable () =
  (* Lock the prometheus dashboard contract. If a label is renamed,
     this test must be updated together with the dashboard query. *)
  let expected =
    [ "token_mismatch"
    ; "token_expired"
    ; "unauthorized"
    ; "forbidden"
    ; "agent_not_found"
    ; "io_error"
    ; "invalid_json"
    ; "other"
    ]
  in
  let actual = List.map Aek.to_string Aek.all in
  Alcotest.(check (list string)) "label set" expected actual

let suite =
  [ test_case "to_string/of_string round-trip" `Quick test_to_of_string_round_trip
  ; test_case "of_string returns None for unknown" `Quick test_of_string_unknown_returns_none
  ; test_case "classify InvalidToken" `Quick test_classify_invalid_token
  ; test_case "classify TokenExpired" `Quick test_classify_token_expired
  ; test_case "classify Unauthorized" `Quick test_classify_unauthorized
  ; test_case "classify Forbidden" `Quick test_classify_forbidden
  ; test_case "classify AgentNotFound" `Quick test_classify_agent_not_found
  ; test_case "classify IoError" `Quick test_classify_io_error
  ; test_case "classify InvalidJson" `Quick test_classify_invalid_json
  ; test_case "classify unmodelled → Other" `Quick test_classify_unmodelled_falls_to_other
  ; test_case "label set stable" `Quick test_label_set_stable
  ]

let () = Alcotest.run "Auth_error_kind" [ ("auth_error_kind", suite) ]
