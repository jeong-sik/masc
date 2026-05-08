(** RFC-0047 PR-2 invariant: every [Keeper_turn_terminal.t]
    constructed via the public surface populates [disposition]
    consistently with the legacy [code] string field, i.e.

      t.disposition = Keeper_turn_disposition.of_wire t.code

    PR-3 swaps the consumer side ([severity / summary / next_action])
    to read [disposition] directly; this PR establishes the
    invariant. *)

module T = Masc_mcp.Keeper_turn_terminal
module D = Masc_mcp.Keeper_turn_disposition

let check_invariant label (t : T.t) =
  let expected = D.of_wire t.code in
  Alcotest.(check bool)
    (Printf.sprintf "%s: disposition derived from code" label)
    true
    (D.equal expected t.disposition)
;;

(* Cover every public constructor + every code path through
   [normalize_code]. *)
let constructor_cases : (string * T.t) list =
  [ "success", T.success ()
  ; "of_code/explicit", T.of_code "post_commit_ambiguous"
  ; "of_code/normalize/completed", T.of_code "completed"
  ; ( "of_code/normalize/contract_violation"
    , T.of_code "completion_contract_violation:require_tool_use" )
  ; "of_code/normalize/api_error_timeout", T.of_code "api_error_timeout"
  ; "of_code/api_error_overloaded", T.of_code "api_error_overloaded"
  ; ( "of_code/agent_error_max_turns"
    , T.of_code "agent_error_max_turns_exceeded:turns=10,limit=10" )
  ; "of_code/unknown", T.of_code "totally_unmapped"
  ; "of_legacy_error_text/empty", T.of_legacy_error_text ""
  ; ( "of_legacy_error_text/gh_repo"
    , T.of_legacy_error_text "gh_repo_context_missing_worktree" )
  ; "of_legacy_error_text/oas_timeout", T.of_legacy_error_text "oas_timeout_budget"
  ; ( "of_legacy_error_text/turn_wall_clock"
    , T.of_legacy_error_text "Turn wall-clock timeout fired" )
  ; ( "of_legacy_error_text/require_tool_use"
    , T.of_legacy_error_text "called no keeper tools and require_tool_use was set" )
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
      [ "code"; "next_action"; "severity"; "source"; "summary" ]
      keys
  | _ -> Alcotest.fail "expected JSON object"
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
        ] )
    ]
;;
