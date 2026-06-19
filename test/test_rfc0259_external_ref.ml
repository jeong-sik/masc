(** RFC-0259 P1 — external_ref classification + volatile valid_until.

    Pins the two type-level guarantees P1 ships:
    1. [parse_external_ref] deterministically classifies the first PR/issue/task
       id a claim names (and only an explicit marker, never a bare "#123").
    2. [fact_valid_until] gives an externally-referenced claim a finite horizon
       (closing gap #4: immortal volatile facts) while leaving non-referenced
       durable claims durable — and round-trips through the JSON codec. *)

module Types = Masc.Keeper_memory_os_types

let now = 1_000_000.0

(* ---------- parse_external_ref ---------- *)

let ref_testable =
  Alcotest.testable
    (fun ppf -> function
      | None -> Format.fprintf ppf "None"
      | Some (r : Types.external_ref) ->
        Format.fprintf
          ppf
          "Some(%s #%s)"
          (Types.external_ref_kind_to_string r.kind)
          r.id)
    ( = )
;;

let check_ref name expected claim =
  Alcotest.check ref_testable name expected (Types.parse_external_ref claim)
;;

let test_parse_pr () =
  check_ref "PR marker" (Some { Types.kind = Pr; id = "21515" }) "PR #21515 is merged";
  check_ref "lowercase pr" (Some { Types.kind = Pr; id = "5" }) "fixing pr #5 now";
  check_ref "pull request" (Some { Types.kind = Pr; id = "99" }) "pull request #99 blocked";
  check_ref "no space" (Some { Types.kind = Pr; id = "7" }) "pr#7 landed"
;;

let test_parse_issue () =
  check_ref "issue marker" (Some { Types.kind = Issue; id = "123" }) "issue #123 is open";
  check_ref "issue no space" (Some { Types.kind = Issue; id = "8" }) "issue#8"
;;

let test_parse_task () =
  check_ref "task marker" (Some { Types.kind = Task; id = "1418" }) "task-1418 needs work"
;;

let test_parse_none () =
  check_ref "no reference" None "deployment uses blue-green";
  (* bare "#123" is ambiguous (PR vs issue) → left unclassified on purpose *)
  check_ref "bare hash ambiguous" None "see #123 for details";
  check_ref "marker without digits" None "the PR # is unknown"
;;

let test_parse_first () =
  (* the earliest-positioned reference wins (RFC-0259: "the first id") *)
  check_ref
    "first of many"
    (Some { Types.kind = Pr; id = "21515" })
    "PR #21515 supersedes issue #99"
;;

(* ---------- fact_valid_until ---------- *)

let opt_float = Alcotest.(option (float 0.001))

let test_valid_until_volatile () =
  (* gap #4 closed: an externally-referenced Fact is NOT durable *)
  Alcotest.check
    opt_float
    "ref forces finite TTL"
    (Some (now +. Types.volatile_ref_ttl_seconds))
    (Types.fact_valid_until
       ~now
       ~external_ref:(Some { Types.kind = Pr; id = "1" })
       Types.Fact)
;;

let test_valid_until_durable_preserved () =
  (* a durable claim with no external referent stays durable (RFC-0247) *)
  Alcotest.check
    opt_float
    "durable Fact stays durable"
    None
    (Types.fact_valid_until ~now ~external_ref:None Types.Fact)
;;

let test_valid_until_ephemeral () =
  Alcotest.check
    opt_float
    "ephemeral keeps its TTL"
    (Some (now +. 86_400.0))
    (Types.fact_valid_until ~now ~external_ref:None Types.Ephemeral)
;;

(* ---------- JSON round-trip ---------- *)

let sample_fact ~external_ref =
  { Types.claim = "PR #21515 is merged"
  ; category = Types.Fact
  ; source = { Types.trace_id = "t"; turn = 1; tool_call_id = None }
  ; observed_by = []
  ; external_ref
  ; first_seen = now
  ; valid_until = Types.fact_valid_until ~now ~external_ref Types.Fact
  ; last_verified_at = Some now
  ; schema_version = Types.schema_version
  }
;;

let roundtrip f =
  match Types.fact_of_json (Types.fact_to_json f) with
  | Some f' -> f'
  | None -> Alcotest.fail "fact_of_json returned None"
;;

let test_roundtrip_some () =
  let f = sample_fact ~external_ref:(Some { Types.kind = Pr; id = "21515" }) in
  let f' = roundtrip f in
  Alcotest.check
    ref_testable
    "external_ref preserved"
    (Some { Types.kind = Pr; id = "21515" })
    f'.Types.external_ref
;;

let test_roundtrip_none () =
  let f = sample_fact ~external_ref:None in
  let f' = roundtrip f in
  Alcotest.check ref_testable "no ref stays none" None f'.Types.external_ref
;;

let test_roundtrip_legacy () =
  (* a legacy row with no external_ref key decodes to None — the disk codec does
     not re-parse (classification is a producer-boundary property). *)
  let json =
    `Assoc
      [ "claim", `String "PR #999 merged"
      ; "category", `String "fact"
      ; "source", `Assoc [ "trace_id", `String "t"; "turn", `Int 1 ]
      ; "first_seen", `Float now
      ; "schema_version", `String Types.schema_version
      ]
  in
  match Types.fact_of_json json with
  | Some f -> Alcotest.check ref_testable "legacy no-key -> None" None f.Types.external_ref
  | None -> Alcotest.fail "legacy decode failed"
;;

let () =
  Alcotest.run
    "rfc0259_external_ref"
    [ ( "parse"
      , [ Alcotest.test_case "pr" `Quick test_parse_pr
        ; Alcotest.test_case "issue" `Quick test_parse_issue
        ; Alcotest.test_case "task" `Quick test_parse_task
        ; Alcotest.test_case "none" `Quick test_parse_none
        ; Alcotest.test_case "first-wins" `Quick test_parse_first
        ] )
    ; ( "valid_until"
      , [ Alcotest.test_case "volatile" `Quick test_valid_until_volatile
        ; Alcotest.test_case "durable-preserved" `Quick test_valid_until_durable_preserved
        ; Alcotest.test_case "ephemeral" `Quick test_valid_until_ephemeral
        ] )
    ; ( "roundtrip"
      , [ Alcotest.test_case "some" `Quick test_roundtrip_some
        ; Alcotest.test_case "none" `Quick test_roundtrip_none
        ; Alcotest.test_case "legacy" `Quick test_roundtrip_legacy
        ] )
    ]
;;
