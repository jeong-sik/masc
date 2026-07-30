(** Explicit-validity contract for Memory OS facts. *)

open Alcotest

module Types = Masc.Keeper_memory_os_types

let now = 1_000_000.0

let fact ~claim_kind ~category ?(first_seen = now -. 60.0) ?(valid_until = None)
    ?(last_verified_at = Some (now -. 60.0)) () : Types.fact =
  { Types.claim = "typed memory context"
  ; category
  ; claim_kind
  ; source = { Types.trace_id = "trace-x"; turn = 1; tool_call_id = None }
  ; first_seen
  ; valid_until
  ; last_verified_at
  ; schema_version = Types.schema_version
  ; claim_id = None
  }
;;

let test_absence_never_infers_validity () =
  List.iter
    (fun (claim_kind, category) ->
       let memory = fact ~claim_kind ~category () in
       check
         (option (float 0.001))
         "no inferred validity"
         None
         (Types.fact_effective_valid_until memory))
    [ Some Types.External_state, Types.Blocker
    ; Some Types.Self_observation, Types.Lesson
    ; Some Types.Durable_knowledge, Types.Fact
    ; Some Types.Diagnostic, Types.Ephemeral
    ; None, Types.Ephemeral
    ]
;;

let test_only_explicit_valid_until_controls_current () =
  let old_without_bound =
    fact
      ~claim_kind:(Some Types.External_state)
      ~category:Types.Blocker
      ~first_seen:(now -. 1_000_000.0)
      ()
  in
  check bool "old unbounded fact remains current" true (Types.fact_is_current ~now old_without_bound);
  let expired = { old_without_bound with Types.valid_until = Some (now -. 1.0) } in
  check bool "explicit past bound expires" false (Types.fact_is_current ~now expired);
  let current = { old_without_bound with Types.valid_until = Some now } in
  check bool "exact boundary is current" true (Types.fact_is_current ~now current)
;;

let () =
  run
    "keeper_memory_os_explicit_validity"
    [ ( "validity"
      , [ test_case "absence never infers validity" `Quick test_absence_never_infers_validity
        ; test_case
            "only explicit valid_until controls current"
            `Quick
            test_only_explicit_valid_until_controls_current
        ] )
    ]
;;
