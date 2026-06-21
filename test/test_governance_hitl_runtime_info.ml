open Alcotest

(* doc-03 P0#1 acceptance: runtime info surfaces whether HITL is enabled and why.
   These assertions pin the [masc.governance_hitl.v1] projection so the fail-closed
   default ([MASC_DISABLE_HITL] unset => HITL enabled) cannot silently regress. The
   underlying threshold logic is covered by test_governance_pipeline; this test pins
   that the runtime-info envelope actually reports it. *)

let member name = function
  | `Assoc fields ->
    (match List.assoc_opt name fields with
     | Some value -> value
     | None -> failf "missing field %s" name)
  | _ -> fail "expected JSON object"
;;

let string_field name json =
  match member name json with
  | `String value -> value
  | _ -> failf "field %s is not a string" name
;;

let bool_field name json =
  match member name json with
  | `Bool value -> value
  | _ -> failf "field %s is not a bool" name
;;

(* Mirror test_governance_pipeline's helper: restore the prior value (or clear)
   after the body so tests stay order-independent. *)
let with_env key value f =
  let old = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match old with
      | Some previous -> Unix.putenv key previous
      | None -> Unix.putenv key "")
    f
;;

let test_enabled_by_default () =
  with_env "MASC_DISABLE_HITL" "" (fun () ->
    let json = Server_dashboard_http_runtime_info.governance_hitl_json () in
    check string "schema" "masc.governance_hitl.v1" (string_field "schema" json);
    check bool "HITL enabled by default (fail-closed)" true (bool_field "enabled" json);
    check string "disable env key" "MASC_DISABLE_HITL"
      (string_field "disable_env_key" json);
    check string "default when unset" "enabled" (string_field "default_when_unset" json);
    check string "production confirm threshold" "critical"
      (string_field "production_confirm_threshold" json);
    check string "keeper production confirm threshold" "high"
      (string_field "keeper_production_confirm_threshold" json))
;;

let test_disabled_when_env_true () =
  with_env "MASC_DISABLE_HITL" "true" (fun () ->
    let json = Server_dashboard_http_runtime_info.governance_hitl_json () in
    check bool "HITL disabled by explicit env" false (bool_field "enabled" json);
    (match member "production_confirm_threshold" json with
     | `Null -> ()
     | _ -> fail "expected null production threshold when HITL disabled");
    (match member "keeper_production_confirm_threshold" json with
     | `Null -> ()
     | _ -> fail "expected null keeper threshold when HITL disabled"))
;;

let () =
  run
    "governance_hitl_runtime_info"
    [ ( "governance_hitl"
      , [ test_case "enabled by default" `Quick test_enabled_by_default
        ; test_case "disabled when env true" `Quick test_disabled_when_env_true
        ] )
    ]
;;
