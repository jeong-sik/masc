(** RFC-0047 PR-2 invariant: every [Keeper_turn_terminal.t]
    constructed via the public surface populates [disposition]
    consistently with the legacy [code] string field, i.e.

      t.disposition = Keeper_turn_disposition.of_wire t.code

    PR-3 swaps the consumer side ([severity / summary / next_action])
    to read [disposition] directly; this PR establishes the
    invariant. *)

module T = Masc.Keeper_turn_terminal
module D = Masc.Keeper_turn_disposition

let check_invariant label (t : T.t) =
  let expected = D.of_wire (T.code t) in
  Alcotest.(check bool)
    (Printf.sprintf "%s: disposition derived from code" label)
    true
    (D.equal expected t.disposition)
;;

(* Cover every public constructor + assorted wire shapes (canonical
   app codes, legacy persisted wires, sdk-error wires, and unmapped
   strings) so the invariant survives PR-4's removal of the
   [normalize_code] producer-side preprocessor. *)
let constructor_cases : (string * T.t) list =
  [ "success", T.success ()
  ; "of_code/explicit", T.of_code "post_commit_ambiguous"
  ; "of_code/runtime_stop_not_final/completed", T.of_code "completed"
  ; "of_code/sdk_error/api_error_timeout", T.of_code "api_error_timeout"
  ; "of_code/sdk_error/api_error_overloaded", T.of_code "api_error_overloaded"
  ; ( "of_code/sdk_error/agent_error_max_turns"
    , T.of_code "agent_error_max_turns_exceeded:turns=10,limit=10" )
  ; "of_code/unknown", T.of_code "totally_unmapped"
  ; "of_code/empty", T.of_code ""
  ; "of_code/turn_wall_clock", T.of_code "turn_wall_clock_timeout"
  ; "of_code/turn_overflow_failure", T.of_code "turn_overflow_failure"
  ]
;;

let test_invariant () =
  List.iter (fun (label, t) -> check_invariant label t) constructor_cases
;;

let test_of_failure_post_commit_ambiguous () =
  (* of_failure with post_commit_ambiguous=true short-circuits to a
     specific code regardless of the SDK error. *)
  let err = Agent_sdk.Error.Internal "x" in
  let t = T.of_failure ~post_commit_ambiguous:true ~raw_error:"" err in
  check_invariant "of_failure/post_commit_ambiguous" t
;;

let test_to_json_keeps_code_field () =
  (* Wire stability: PR-2 must not change the JSON field set. *)
  let t = T.of_code "success" in
  let json = T.to_json t in
  match json with
  | `Assoc fields ->
    let keys = List.map fst fields |> List.sort String.compare in
    Alcotest.(check (list string))
      "JSON fields unchanged"
      [ "code"; "disposition"; "next_action"; "severity"; "source"; "summary" ]
      keys
  | _ -> Alcotest.fail "expected JSON object"
;;

let test_of_code_default_source_is_wire_code () =
  let t = T.of_code "success" in
  Alcotest.(check string) "default source" "wire_code" t.source
;;

let test_runtime_completed_is_not_final_success () =
  let terminal = T.of_code "completed" in
  Alcotest.(check bool)
    "runtime completed disposition is unknown"
    false
    (D.is_success terminal.disposition);
  Alcotest.(check string)
    "unknown runtime wire is preserved"
    "completed"
    (T.code terminal)
;;

let () =
  Alcotest.run
    "keeper_turn_terminal_disposition_field"
    [ ( "PR-2 invariant: disposition derived from code"
      , [ Alcotest.test_case
            "every public constructor preserves invariant"
            `Quick
            test_invariant
        ; Alcotest.test_case
            "of_failure/post_commit_ambiguous preserves invariant"
            `Quick
            test_of_failure_post_commit_ambiguous
        ] )
    ; ( "wire stability"
      , [ Alcotest.test_case
            "to_json field set unchanged"
            `Quick
            test_to_json_keeps_code_field
        ; Alcotest.test_case
            "of_code default source is wire_code"
            `Quick
            test_of_code_default_source_is_wire_code
        ; Alcotest.test_case
            "runtime completed is not final success"
            `Quick
            test_runtime_completed_is_not_final_success
        ] )
    ]
;;
