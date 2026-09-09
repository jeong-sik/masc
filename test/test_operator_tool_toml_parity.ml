(** The publication order of [Operator_tool.schemas] and
    [Operator_tool.remote_schemas].

    Everything else this suite held was a copy: the declarations live in
    [config/tools/*.toml], the published values are those files decoded, and
    the expected descriptions and schemas were literals read off the same
    values before the move.

    Order is not in the TOML. It is the order of the OCaml lists, and #34379
    is the open question about what changed it, so it stays. *)

open Alcotest


(* The order is Tool_name.Operator_name.all, the variant's declaration order
   since #33597 derived the advertised and remote surfaces from the type. *)
let expected =
  [ "masc_operator_action"
  ; "masc_operator_board_attention_quarantine_requeue"
  ; "masc_operator_confirm"
  ; "masc_operator_digest"
  ; "masc_operator_judgment_write"
  ; "masc_operator_snapshot"
  ; "masc_operator_task_recovery_resolve"
  ]
;;

(* judgment_write stays local-only. *)
let expected_remote_order =
  [ {|masc_operator_action|}
  ; {|masc_operator_board_attention_quarantine_requeue|}
  ; {|masc_operator_confirm|}
  ; {|masc_operator_digest|}
  ; {|masc_operator_snapshot|}
  ; {|masc_operator_task_recovery_resolve|}
  ]
;;

let published_remote = Operator_tool.remote_schemas


let published = Operator_tool.schemas




(* The order is what a model reads the tool list in, so a reordering is a
   change to the surface even when every schema still matches. *)
let test_the_published_order_is_unchanged () =
  check
    (list string)
    "Operator_tool.schemas in order"
    expected
    (List.map (fun (s : Masc_domain.tool_schema) -> s.name) published)
;;


let test_the_remote_order_is_unchanged () =
  check
    (list string)
    "Operator_tool.remote_schemas in order"
    expected_remote_order
    (List.map (fun (s : Masc_domain.tool_schema) -> s.name) published_remote)
;;

let () =
  run
    "operator_tool_toml_parity"
    [ ( "order"
      , [ test_case "published order" `Quick test_the_published_order_is_unchanged
        ; test_case "remote order" `Quick test_the_remote_order_is_unchanged
        ] )
    ]
;;
