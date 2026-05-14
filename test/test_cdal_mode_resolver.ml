(** Pin tests for Mode_resolver — deterministic downgrade logic.

    These tests lock the behavior of [resolve]: the effective mode is the
    minimum of requested, risk_class.max_mode, and capability_cap derived
    from the tool list. Never upgrades beyond requested.

    Part of #14323: restoring CDAL unit test coverage. *)

open Alcotest
module Mr = Masc_mcp_cdal_runtime.Mode_resolver
module Em = Masc_mcp_cdal_runtime.Execution_mode
module Rc = Masc_mcp_cdal_runtime.Risk_class
module Cp = Masc_mcp_cdal_runtime.Cdal_proof
module Me = Masc_mcp_cdal_runtime.Mode_enforcer

let check_string = check string
let check_bool = check bool

let read_only_caps =
  Cp.
    { tools = [ "resolver_test_read1"; "resolver_test_read2" ]
    ; mcp_servers = []
    ; max_turns = 10
    ; max_tokens = None
    ; thinking_enabled = None
    }
;;

let workspace_caps =
  Cp.
    { tools = [ "resolver_test_read1"; "resolver_test_mut1" ]
    ; mcp_servers = []
    ; max_turns = 10
    ; max_tokens = None
    ; thinking_enabled = None
    }
;;

let full_caps =
  Cp.
    { tools = [ "resolver_test_ext1" ]
    ; mcp_servers = [ "serena" ]
    ; max_turns = 200
    ; max_tokens = Some 8192
    ; thinking_enabled = Some true
    }
;;

let () =
  (* Register test tools for deterministic capability classification *)
  Me.register_tool_class "resolver_test_read1" Me.Read_only;
  Me.register_tool_class "resolver_test_read2" Me.Read_only;
  Me.register_tool_class "resolver_test_mut1" Me.Local_mutation;
  Me.register_tool_class "resolver_test_ext1" Me.External_effect
;;

(* ── Passthrough: no downgrade ─────────────────────────────────── *)

let test_passthrough_low_risk_execute () =
  match Mr.resolve ~requested:Em.Execute ~risk_class:Rc.Low ~capabilities:full_caps with
  | Ok d ->
    check_bool "effective = Execute" true (Em.equal d.effective_mode Em.Execute);
    check_string "source" "passthrough" d.source
  | Error e -> failf "resolve failed: %s" e
;;

let test_passthrough_medium_risk_draft () =
  match
    Mr.resolve ~requested:Em.Draft ~risk_class:Rc.Medium ~capabilities:workspace_caps
  with
  | Ok d ->
    check_bool "effective = Draft" true (Em.equal d.effective_mode Em.Draft);
    check_string "source" "passthrough" d.source
  | Error e -> failf "resolve failed: %s" e
;;

(* ── Risk-driven downgrade ─────────────────────────────────────── *)

let test_risk_downgrade_medium_is_passthrough () =
  (* Medium risk has max_mode = Execute, so no downgrade *)
  match
    Mr.resolve ~requested:Em.Execute ~risk_class:Rc.Medium ~capabilities:full_caps
  with
  | Ok d ->
    check_bool "effective = Execute" true (Em.equal d.effective_mode Em.Execute);
    check_string "source" "passthrough" d.source
  | Error e -> failf "resolve failed: %s" e
;;

let test_risk_downgrade_high () =
  (* High risk has max_mode = Draft *)
  match Mr.resolve ~requested:Em.Execute ~risk_class:Rc.High ~capabilities:full_caps with
  | Ok d ->
    check_bool "effective = Draft" true (Em.equal d.effective_mode Em.Draft);
    check_string "source" "risk_class_downgrade" d.source
  | Error e -> failf "resolve failed: %s" e
;;

let test_risk_forbids_critical () =
  match
    Mr.resolve ~requested:Em.Execute ~risk_class:Rc.Critical ~capabilities:full_caps
  with
  | Ok _ -> fail "expected Error for Critical risk"
  | Error e -> check_bool "error mentions risk" true (String.contains e 'r')
;;

(* ── Capability-driven downgrade ───────────────────────────────── *)

let test_capability_limit_read_only_tools () =
  match
    Mr.resolve ~requested:Em.Execute ~risk_class:Rc.Low ~capabilities:read_only_caps
  with
  | Ok d ->
    check_bool
      "effective = Diagnose (read-only tools)"
      true
      (Em.equal d.effective_mode Em.Diagnose);
    check_string "source" "capability_limit" d.source
  | Error e -> failf "resolve failed: %s" e
;;

let test_capability_limit_workspace_tools () =
  (* workspace_caps has read + mutation -> capability_cap = Draft *)
  match
    Mr.resolve ~requested:Em.Execute ~risk_class:Rc.Low ~capabilities:workspace_caps
  with
  | Ok d ->
    check_bool
      "effective = Draft (workspace tools)"
      true
      (Em.equal d.effective_mode Em.Draft);
    check_string "source" "capability_limit" d.source
  | Error e -> failf "resolve failed: %s" e
;;

(* ── Never upgrades beyond requested ───────────────────────────── *)

let test_never_upgrades_diagnose () =
  match Mr.resolve ~requested:Em.Diagnose ~risk_class:Rc.Low ~capabilities:full_caps with
  | Ok d ->
    check_bool
      "effective = Diagnose (requested)"
      true
      (Em.equal d.effective_mode Em.Diagnose)
  | Error e -> failf "resolve failed: %s" e
;;

let test_never_upgrades_draft () =
  match Mr.resolve ~requested:Em.Draft ~risk_class:Rc.Low ~capabilities:full_caps with
  | Ok d ->
    check_bool "effective = Draft (requested)" true (Em.equal d.effective_mode Em.Draft)
  | Error e -> failf "resolve failed: %s" e
;;

(* ── Determinism ────────────────────────────────────────────────── *)

let test_deterministic () =
  let r1 =
    Mr.resolve ~requested:Em.Execute ~risk_class:Rc.Medium ~capabilities:full_caps
  in
  let r2 =
    Mr.resolve ~requested:Em.Execute ~risk_class:Rc.Medium ~capabilities:full_caps
  in
  match r1, r2 with
  | Ok d1, Ok d2 ->
    check_bool "same mode" true (Em.equal d1.effective_mode d2.effective_mode);
    check_string "same source" d1.source d2.source
  | _ -> fail "resolve failed"
;;

let () =
  Alcotest.run
    "cdal_mode_resolver"
    [ ( "passthrough"
      , [ test_case "low risk execute" `Quick test_passthrough_low_risk_execute
        ; test_case "medium risk draft" `Quick test_passthrough_medium_risk_draft
        ] )
    ; ( "risk_downgrade"
      , [ test_case
            "medium risk passthrough"
            `Quick
            test_risk_downgrade_medium_is_passthrough
        ; test_case "high risk -> draft" `Quick test_risk_downgrade_high
        ; test_case "critical risk forbids" `Quick test_risk_forbids_critical
        ] )
    ; ( "capability_limit"
      , [ test_case
            "read-only tools -> diagnose"
            `Quick
            test_capability_limit_read_only_tools
        ; test_case
            "workspace tools -> draft"
            `Quick
            test_capability_limit_workspace_tools
        ] )
    ; ( "no_upgrade"
      , [ test_case "diagnose stays diagnose" `Quick test_never_upgrades_diagnose
        ; test_case "draft stays draft" `Quick test_never_upgrades_draft
        ] )
    ; "determinism", [ test_case "same inputs, same output" `Quick test_deterministic ]
    ]
;;
