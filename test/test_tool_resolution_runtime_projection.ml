open Alcotest

module TR = Masc_mcp.Keeper_tool_resolution

(** RFC-0084 §1.4, §6.2 — runtime routing projection.

    [Keeper_tool_resolution.runtime_decision] is the SSOT entry for runtime
    tool-name routing. [Keeper_tool_resolution.canonical_tool_name] is the
    pure string projection over that typed decision.

    Test corpus: a deterministic set of names covering the four outcome
    variants (Mcp_mapped, Route_hit, Already_internal, Miss) plus a few
    edge cases (empty string, all-internal, all-public).

    For each name, assert:
      canonical_string(Keeper_tool_resolution.runtime_decision name)
        = Keeper_tool_resolution.canonical_tool_name name
*)

let names_to_probe =
  [ "tool_execute"
  ; "tool_edit_file"
  ; "masc_keeper_msg"
  ; "masc_keeper_sandbox_start"
  ; "masc_status"
  ; "masc_add_task"
  ; "mcp__masc__tool_execute"
  ; "mcp__masc__masc_status"
  ; "mcp__masc__masc_keeper_msg"
  ; "_definitely_unknown_tool_zzz"
  ; ""
  ]
;;

(** Pretty-printer for [runtime_decision_outcome] used as Alcotest
    [testable]. We compare via Stdlib.( = ) (structural equality) since
    the type is a closed sum of records with string fields — no fragile
    abstract types. *)
let pp_outcome fmt o =
  match o with
  | TR.Mcp_mapped { stripped; internal } ->
    Format.fprintf fmt "Mcp_mapped(%s -> %s)" stripped internal
  | TR.Route_hit { internal } -> Format.fprintf fmt "Route_hit(%s)" internal
  | TR.Already_internal { canonical } -> Format.fprintf fmt "Already_internal(%s)" canonical
  | TR.Miss -> Format.fprintf fmt "Miss"
;;

let canonical_string name = function
  | TR.Mcp_mapped { internal; _ } -> internal
  | TR.Route_hit { internal } -> internal
  | TR.Already_internal { canonical } -> canonical
  | TR.Miss -> name

let test_parity_each_name () =
  List.iter
    (fun name ->
      let by_resolution = TR.runtime_decision name in
      let by_projection = TR.canonical_tool_name name in
      (check string)
        (Printf.sprintf "runtime_decision %S = canonical projection" name)
        by_projection
        (canonical_string name by_resolution))
    names_to_probe
;;

let test_parity_unknown_is_miss () =
  let name = "_definitely_unknown_tool_zzz" in
  let by_resolution = TR.runtime_decision name in
  match by_resolution with
  | TR.Miss -> ()
  | other ->
    failf
      "expected Miss for unknown name, got: %s"
      (Format.asprintf "%a" pp_outcome other)
;;

let test_parity_mcp_prefix_strips () =
  let name = "mcp__masc__tool_execute" in
  let by_resolution = TR.runtime_decision name in
  match by_resolution with
  | TR.Mcp_mapped { stripped; internal } ->
    (check string) "stripped form" "tool_execute" stripped;
    (check string) "internal form" "tool_execute" internal
  | TR.Already_internal { canonical } ->
    (* Some configurations route mcp_-prefixed internal names directly. *)
    (check string) "canonical form" "tool_execute" canonical
  | other ->
    failf
      "expected Mcp_mapped or Already_internal for mcp__masc__tool_execute, got: %s"
      (Format.asprintf "%a" pp_outcome other)
;;

let () =
  Alcotest.run
    "RFC-0084 runtime routing projection"
    [ ( "runtime-decision-parity"
      , [ test_case "parity-each-name" `Quick test_parity_each_name
        ; test_case "parity-unknown-is-miss" `Quick test_parity_unknown_is_miss
        ; test_case "parity-mcp-prefix-strips" `Quick test_parity_mcp_prefix_strips
        ] )
    ]
;;
