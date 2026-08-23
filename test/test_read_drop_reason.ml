(** RFC-0044 PR-1 invariants for [Read_drop_reason]:

    1. Round-trip: [of_wire (to_wire t) = t] for every canonical
       constructor; [Other s] survives unchanged.
    2. Byte-for-byte wire compatibility with the legacy [string]
       constants in [Core.Safe_ops]
       ([Read_drop_reason.List_dir_error],
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
  ; (* RFC-0134 PR-1. *)
    "Concurrent_removal", R.Concurrent_removal
  ; "Transient_fd_pressure", R.Transient_fd_pressure
  ; (* RFC-0134, same not-a-loss family: the final line of an append-only
       file caught mid-write by a tail reader. *)
    "Tail_partial_write", R.Tail_partial_write
  ]
;;

(* [canonical] is hand-maintained, so a new constructor is only covered once
   it is listed above. This pins the count so adding a variant without
   listing it fails here rather than silently skipping the round-trip and
   wire-stability checks. *)
let test_canonical_covers_every_constructor () =
  Alcotest.(check int) "canonical entry count" 12 (List.length canonical)
;;

(* The reason exists to keep an append-race off the data-integrity counter,
   so the one thing that must never drift is its distinctness from
   [Entry_load_error]: the live decision-log reader picks between exactly
   these two by line position. *)
let test_tail_partial_write_is_its_own_reason () =
  Alcotest.(check string)
    "wire string"
    "tail_partial_write"
    (R.to_wire R.Tail_partial_write);
  Alcotest.(check bool)
    "round-trips"
    true
    (R.equal R.Tail_partial_write (R.of_wire (R.to_wire R.Tail_partial_write)));
  Alcotest.(check bool)
    "distinct from entry_load_error"
    false
    (R.equal R.Tail_partial_write R.Entry_load_error);
  (* This used to compare the variant's wire form against a string constant
     that Safe_ops exported. With one vocabulary there is nothing to compare
     it to, so pin the wire word itself — that is what leaves the process. *)
  Alcotest.(check string)
    "wire word"
    "tail_partial_write"
    (R.to_wire R.Tail_partial_write)
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

let test_rfc_0134_wire_strings () =
  (* RFC-0134 PR-1 §3.1 wire mapping is part of the public contract;
     PR-3 will switch caller behavior keyed on these exact byte
     strings (e.g. "concurrent_removal" must not get re-routed to the
     data-integrity counter). Pin them here so a typo in the
     serialiser cannot drift them silently. *)
  Alcotest.(check string)
    "Concurrent_removal wire = \"concurrent_removal\""
    "concurrent_removal"
    (R.to_wire R.Concurrent_removal);
  Alcotest.(check string)
    "Transient_fd_pressure wire = \"transient_fd_pressure\""
    "transient_fd_pressure"
    (R.to_wire R.Transient_fd_pressure)
;;

let test_rfc_0134_new_variants_disjoint () =
  (* The two new variants must not equal any pre-existing constructor
     under [equal] (which would silently merge counter buckets). *)
  let pre_existing =
    [ R.List_dir_error
    ; R.Entry_load_error
    ; R.Invalid_payload
    ; R.Json_syntax_error
    ; R.Lock_contention
    ; R.Schema_version_mismatch
    ; R.Decompression_error
    ; R.Path_normalization_error
    ; R.Stat_error
    ]
  in
  List.iter
    (fun pre ->
       Alcotest.(check bool)
         (Format.asprintf "Concurrent_removal <> %a" R.pp pre)
         false
         (R.equal R.Concurrent_removal pre);
       Alcotest.(check bool)
         (Format.asprintf "Transient_fd_pressure <> %a" R.pp pre)
         false
         (R.equal R.Transient_fd_pressure pre))
    pre_existing;
  Alcotest.(check bool)
    "Concurrent_removal <> Transient_fd_pressure"
    false
    (R.equal R.Concurrent_removal R.Transient_fd_pressure)
;;

let test_legacy_constants_byte_compat () =
  (* The three pre-RFC string constants in Safe_ops must be the wire
     forms of the corresponding typed constructors so PR-2 can swap
     callers without changing Otel_metric_store label cardinality. *)
  Alcotest.(check string)
    "list_dir_error wire word"
    "list_dir_error"
    (R.to_wire R.List_dir_error);
  Alcotest.(check string)
    "entry_load_error wire word"
    "entry_load_error"
    (R.to_wire R.Entry_load_error);
  Alcotest.(check string)
    "invalid_payload wire word"
    "invalid_payload"
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
    ; ( "rfc-0134 pr-1"
      , [ Alcotest.test_case
            "new variants emit stable wire strings"
            `Quick
            test_rfc_0134_wire_strings
        ; Alcotest.test_case
            "new variants are disjoint from pre-existing"
            `Quick
            test_rfc_0134_new_variants_disjoint
        ; Alcotest.test_case
            "tail_partial_write round-trips and stays off entry_load_error"
            `Quick
            test_tail_partial_write_is_its_own_reason
        ; Alcotest.test_case
            "canonical list covers every constructor"
            `Quick
            test_canonical_covers_every_constructor
        ] )
    ]
;;
