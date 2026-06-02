open Alcotest

(** RFC-0084 §3.1 Tool_name.t exhaustiveness closure.

    PR-2 adds 4 missing variants to [Tool_name.Masc_keeper.t] so that all
    dispatched [masc_keeper_*] tool names round-trip through the typed
    sum without falling back to the runtime tag-registry path in
    [keeper_tag_dispatch.ml].

    Reference: agent #1 spot-trace (RFC-0084 §1.1) identified that
    [masc_keeper_sandbox_status/start/stop] and [masc_keeper_msg_result]
    were dispatched but missing from the typed variant, forcing routes
    through [static_tag_of_tool_name] to return [None] and fall through
    to runtime tag-registry. *)

let all_masc_keeper_variants : Masc_mcp.Tool_name.Masc_keeper.t list =
  [ Clear
  ; Compact
  ; Create_from_persona
  ; Down
  ; List
  ; Msg
  ; Msg_result
  ; Persona_audit
  ; Repair
  ; Reset
  ; Sandbox_start
  ; Sandbox_status
  ; Sandbox_stop
  ; Status
  ; Up
  ]

let test_round_trip_all_masc_keeper_variants () =
  (* Every Masc_keeper.t variant must round-trip through to_string/of_string. *)
  List.iter
    (fun v ->
      let s = Masc_mcp.Tool_name.Masc_keeper.to_string v in
      match Masc_mcp.Tool_name.Masc_keeper.of_string s with
      | Some v' when v = v' -> ()
      | Some _ ->
        failf "round-trip mismatch for %s (different variant)" s
      | None ->
        failf "round-trip miss: of_string %S returned None" s)
    all_masc_keeper_variants

let test_msg_result_typed () =
  (* RFC-0084 §3.1: masc_keeper_msg_result must resolve to typed variant. *)
  (check (option string))
    "masc_keeper_msg_result of_string returns Some Msg_result"
    (Some "masc_keeper_msg_result")
    (Option.map
       Masc_mcp.Tool_name.Masc_keeper.to_string
       (Masc_mcp.Tool_name.Masc_keeper.of_string "masc_keeper_msg_result"))

let test_sandbox_start_typed () =
  (check (option string))
    "masc_keeper_sandbox_start of_string returns Some Sandbox_start"
    (Some "masc_keeper_sandbox_start")
    (Option.map
       Masc_mcp.Tool_name.Masc_keeper.to_string
       (Masc_mcp.Tool_name.Masc_keeper.of_string "masc_keeper_sandbox_start"))

let test_sandbox_status_typed () =
  (check (option string))
    "masc_keeper_sandbox_status of_string returns Some Sandbox_status"
    (Some "masc_keeper_sandbox_status")
    (Option.map
       Masc_mcp.Tool_name.Masc_keeper.to_string
       (Masc_mcp.Tool_name.Masc_keeper.of_string "masc_keeper_sandbox_status"))

let test_sandbox_stop_typed () =
  (check (option string))
    "masc_keeper_sandbox_stop of_string returns Some Sandbox_stop"
    (Some "masc_keeper_sandbox_stop")
    (Option.map
       Masc_mcp.Tool_name.Masc_keeper.to_string
       (Masc_mcp.Tool_name.Masc_keeper.of_string "masc_keeper_sandbox_stop"))

let test_unknown_returns_none () =
  (check (option string))
    "unknown masc_keeper_* name returns None"
    None
    (Option.map
       Masc_mcp.Tool_name.Masc_keeper.to_string
       (Masc_mcp.Tool_name.Masc_keeper.of_string "masc_keeper_nonexistent"))

let test_variant_count () =
  (* Pin the variant count so future additions are caught by this assertion. *)
  (check int)
    "Masc_keeper.t variant count (RFC-0084 §3.1; update when adding variants)"
    15
    (List.length all_masc_keeper_variants)

let test_top_level_of_string_via_masc_keeper () =
  (* Top-level Tool_name.of_string routes masc_keeper_* through Masc_keeper. *)
  match Masc_mcp.Tool_name.of_string "masc_keeper_sandbox_start" with
  | Some (Masc_mcp.Tool_name.Masc_keeper Sandbox_start) -> ()
  | Some other ->
    failf
      "expected Masc_keeper Sandbox_start, got %s"
      (Masc_mcp.Tool_name.to_string other)
  | None -> failf "Tool_name.of_string returned None for masc_keeper_sandbox_start"

let () =
  Alcotest.run
    "RFC-0084 Tool_name.t exhaustive closure"
    [ ( "masc-keeper-variants"
      , [ test_case "round-trip-all-variants" `Quick test_round_trip_all_masc_keeper_variants
        ; test_case "msg-result-typed" `Quick test_msg_result_typed
        ; test_case "sandbox-start-typed" `Quick test_sandbox_start_typed
        ; test_case "sandbox-status-typed" `Quick test_sandbox_status_typed
        ; test_case "sandbox-stop-typed" `Quick test_sandbox_stop_typed
        ; test_case "unknown-returns-none" `Quick test_unknown_returns_none
        ; test_case "variant-count-pin" `Quick test_variant_count
        ; test_case "top-level-of-string" `Quick test_top_level_of_string_via_masc_keeper
        ] )
    ]
