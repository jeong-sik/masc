(** Tests for [Task.Args.parse_task_contract] — the canonical optional
    [contract] argument parser shared by the public masc_task_create facade and,
    after de-duplication, the keeper-internal keeper_task_create path.

    Regression guard for the keeper-path bug (incident: keeper:umberto): an
    OMITTED optional [contract] was wrongly rejected via a catch-all that
    conflated [None] (key omitted) with a wrong-typed value. The fix
    deletes the drifted keeper-local copy and routes through this canonical
    parser, which handles [None | Some `Null -> Ok None]. *)

open Alcotest

module T = Masc.Task.Args

(* The incident: an omitted optional contract must parse to [Ok None], not an
   Error. [Json_util.assoc_member_opt] returns [None] for an absent key. *)
let test_omitted_contract () =
  match T.parse_task_contract (`Assoc []) with
  | Ok None -> ()
  | Ok (Some _) -> fail "omitted contract must parse to Ok None, got Ok (Some _)"
  | Error e ->
      fail (Printf.sprintf "omitted contract must be Ok None, got Error %s" e)

(* An LLM caller that sends a JSON null contract for an unset optional field
   must also parse to [Ok None]. *)
let test_explicit_null_contract () =
  match T.parse_task_contract (`Assoc [ ("contract", `Null) ]) with
  | Ok None -> ()
  | Ok (Some _) -> fail "explicit null contract must parse to Ok None"
  | Error e ->
      fail
        (Printf.sprintf "explicit null contract must be Ok None, got Error %s" e)

(* Every [task_contract] field carries a [@default], so an empty object is a
   valid contract payload. *)
let test_object_contract () =
  match T.parse_task_contract (`Assoc [ ("contract", `Assoc []) ]) with
  | Ok (Some _) -> ()
  | Ok None -> fail "object contract must parse to Ok (Some _)"
  | Error e ->
      fail
        (Printf.sprintf "object contract must be Ok (Some _), got Error %s" e)

(* A present-but-non-object contract is an Error. The catch-all must not swallow
   this into a silent default; the canonical parser additionally names the
   received JSON kind in its message. *)
let test_wrong_type_contract () =
  match T.parse_task_contract (`Assoc [ ("contract", `String "nope") ]) with
  | Error _ -> ()
  | Ok _ -> fail "non-object contract must be Error, not Ok"

let test_public_contract_rejects_removed_field () =
  match
    T.parse_task_contract
      (`Assoc [ "contract", `Assoc [ "links", `Assoc [] ] ])
  with
  | Error _ -> ()
  | Ok _ -> fail "public contract input must reject the removed [links] field"

let test_persisted_contract_accepts_removed_field () =
  match Masc_domain.task_contract_of_yojson (`Assoc [ "links", `Assoc [] ]) with
  | Ok _ -> ()
  | Error detail ->
    fail
      (Printf.sprintf
         "persisted contract carrying removed [links] must still decode: %s"
         detail)

let test_public_contract_rejects_duplicate_field () =
  match
    T.parse_task_contract
      (`Assoc
        [ ( "contract"
          , `Assoc [ "strict", `Bool true; "strict", `Bool false ] )
        ])
  with
  | Error _ -> ()
  | Ok _ -> fail "public contract input must reject duplicate fields"

let test_current_contract_shape_decodes () =
  match
    T.parse_task_contract
      (`Assoc
        [ ( "contract"
          , `Assoc
              [ "strict", `Bool true
              ; "completion_contract", `List [ `String "done" ]
              ; "required_evidence", `List [ `String "test" ]
              ; "inspect_gate_evidence", `List [ `String "review" ]
              ; "verify_gate_evidence", `List [ `String "ci" ]
              ] )
        ])
  with
  | Ok (Some contract) ->
    check bool "strict" true contract.strict;
    check (list string) "completion contract" [ "done" ] contract.completion_contract
  | Ok None -> fail "current contract object must decode to Some"
  | Error detail -> fail (Printf.sprintf "current contract must decode: %s" detail)

let () =
  run "Task.Args"
    [ ( "parse_task_contract"
      , [ test_case "omitted -> Ok None (regression)" `Quick test_omitted_contract
        ; test_case "explicit null -> Ok None" `Quick test_explicit_null_contract
        ; test_case "object -> Ok (Some _)" `Quick test_object_contract
        ; test_case "wrong type -> Error" `Quick test_wrong_type_contract
        ; test_case "public removed field -> Error" `Quick
            test_public_contract_rejects_removed_field
        ; test_case "persisted removed field still decodes" `Quick
            test_persisted_contract_accepts_removed_field
        ; test_case "public duplicate field -> Error" `Quick
            test_public_contract_rejects_duplicate_field
        ; test_case "current contract shape -> Ok" `Quick
            test_current_contract_shape_decodes
        ] )
    ]
