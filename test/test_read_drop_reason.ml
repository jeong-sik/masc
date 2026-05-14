(** RFC-0044 PR-1 invariants for [Read_drop_reason]:

    1. Round-trip: [of_wire (to_wire t) = t] for every canonical
       constructor; [Other s] survives unchanged.
    2. Byte-for-byte wire compatibility with the legacy [string]
       constants in [Core.Safe_ops]
       ([persistence_read_drop_reason_list_dir_error],
       [_entry_load_error], [_invalid_payload]).

    PR-2 will swap [report_persistence_read_drop ~reason:string] to
    accept [t]; this test guards that the wire never drifts during
    that swap. *)

module R = Read_drop_reason
module Safe = Safe_ops

let canonical : (string * R.t) list =
  [ "List_dir_error", R.List_dir_error
  ; "Entry_load_error", R.Entry_load_error
  ; "Invalid_payload", R.Invalid_payload
  ; "Json_syntax_error", R.Json_syntax_error
  ; "Lock_contention", R.Lock_contention
  ; "Schema_version_mismatch", R.Schema_version_mismatch
  ; "Decompression_error", R.Decompression_error
  ; "Path_normalization_error", R.Path_normalization_error
  ; "Stat_error", R.Stat_error
  ]
;;

let test_canonical_round_trip () =
  List.iter
    (fun (label, t) ->
       let wire = R.to_wire t in
       let parsed = R.of_wire wire in
       Alcotest.(check bool) (label ^ " round-trip") true (R.equal t parsed))
    canonical
;;

let test_other_round_trip () =
  let exotic = R.Other "freshly_invented_reason" in
  let wire = R.to_wire exotic in
  Alcotest.(check string) "Other wire = payload" "freshly_invented_reason" wire;
  Alcotest.(check bool) "Other round-trip" true (R.equal exotic (R.of_wire wire))
;;

let test_unknown_wire_becomes_other () =
  match R.of_wire "totally_new_label" with
  | R.Other s -> Alcotest.(check string) "unknown → Other s" "totally_new_label" s
  | _ -> Alcotest.fail "expected Other for unknown wire"
;;

let test_legacy_constants_byte_compat () =
  (* The three pre-RFC string constants in Safe_ops must be the wire
     forms of the corresponding typed constructors so PR-2 can swap
     callers without changing Prometheus label cardinality. *)
  Alcotest.(check string)
    "list_dir_error matches Safe_ops constant"
    Safe.persistence_read_drop_reason_list_dir_error
    (R.to_wire R.List_dir_error);
  Alcotest.(check string)
    "entry_load_error matches Safe_ops constant"
    Safe.persistence_read_drop_reason_entry_load_error
    (R.to_wire R.Entry_load_error);
  Alcotest.(check string)
    "invalid_payload matches Safe_ops constant"
    Safe.persistence_read_drop_reason_invalid_payload
    (R.to_wire R.Invalid_payload)
;;

let () =
  Alcotest.run
    "read_drop_reason"
    [ ( "round-trip"
      , [ Alcotest.test_case
            "canonical constructors round-trip"
            `Quick
            test_canonical_round_trip
        ; Alcotest.test_case "Other s round-trips verbatim" `Quick test_other_round_trip
        ; Alcotest.test_case
            "unknown wire deserialises to Other"
            `Quick
            test_unknown_wire_becomes_other
        ] )
    ; ( "byte invariant vs Safe_ops constants"
      , [ Alcotest.test_case
            "Safe_ops legacy constants byte-equal to to_wire"
            `Quick
            test_legacy_constants_byte_compat
        ] )
    ]
;;
