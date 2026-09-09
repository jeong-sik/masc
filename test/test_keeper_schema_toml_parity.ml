(** The publication order of [Masc.Keeper_schema.schemas], and the
    masc_keeper_status bounds against their owner.

    One value moved rather than being pinned: masc_keeper_status declared an
    empty ["required"], which says nothing an absent one does not. Both readers
    already fold them together -- llm_provider/types.ml answers [None] and
    [`Null] with [Ok []], and tool_input_validation.ml treats a non-matching
    key the same way -- so it spent bytes in every turn's tool list to say
    nothing. The other four tools that emitted one were cleaned earlier; this
    was the last caller of [closed_object_schema] passing none.

    The descriptions and schemas this suite also pinned were literals read off
    the same published values before the declarations moved into
    [config/tools/*.toml] -- one producer against a snapshot of itself. Those
    cases are gone; what stays reads the published value. *)

open Alcotest


let published = Masc.Keeper_schema.schemas

let find name =
  match
    List.find_opt (fun (s : Masc_domain.tool_schema) -> String.equal s.name name) published
  with
  | Some schema -> schema
  | None -> failwith (name ^ " is absent from Keeper_schema.schemas")
;;

(* The order is what a model reads the tool list in, so a reordering is a
   change to the surface even when every schema still matches. *)
let test_the_published_order_is_unchanged () =
  check
    (list string)
    "Keeper_schema.schemas in order"
    [ "masc_keeper_audit"; "masc_keeper_clear"; "masc_keeper_delegate";
      "masc_keeper_delegate_cancel"; "masc_keeper_delegate_list";
      "masc_keeper_delegate_status"; "masc_keeper_down"; "masc_keeper_list";
      "masc_keeper_msg"; "masc_keeper_reset"; "masc_keeper_sandbox_start";
      "masc_keeper_sandbox_stop"; "masc_keeper_status"; "masc_keeper_up" ]
    (List.map (fun (s : Masc_domain.tool_schema) -> s.name) published)
;;


(* The one owner derivation in this file that nothing was checking.

   The sibling two the header names are pinned elsewhere —
   [Keeper_sandbox_control_contract.stop_scope_strings] in
   [test_enum_mirror_sync] and [test_keeper_tool_descriptor_registry_integrity],
   and the network-mode enum in the latter. masc_keeper_status had no such
   pin, so the TOML and [Keeper_status_options_defaults] agreed only by
   nobody having changed one of them. #32763 changed max_tail_bytes from a
   shared constant to its own literal; the value came out the same, and
   nothing here would have said otherwise if it had not. *)
let declared_int schema_name ~field ~key =
  match (find schema_name).input_schema with
  | `Assoc top ->
    (match List.assoc_opt "properties" top with
     | Some (`Assoc properties) ->
       (match List.assoc_opt field properties with
        | Some (`Assoc declaration) ->
          (match List.assoc_opt key declaration with
           | Some (`Int value) -> Some value
           | _ -> None)
        | _ -> None)
     | _ -> None)
  | _ -> None
;;

let test_status_bounds_match_their_owner () =
  let module D = Masc.Keeper_status_options_defaults in
  List.iter
    (fun (field, key, owned) ->
       check
         (option int)
         (Printf.sprintf "masc_keeper_status %s %s" field key)
         (Some owned)
         (declared_int "masc_keeper_status" ~field ~key))
    [ "tail_turns", "minimum", D.min_tail_turns
    ; "tail_turns", "maximum", D.max_tail_turns
    ; "tail_messages", "minimum", D.min_tail_messages
    ; "tail_messages", "maximum", D.max_tail_messages
    ; "tail_bytes", "minimum", D.min_tail_bytes
    ; "tail_bytes", "maximum", D.max_tail_bytes
    ]
;;

let () =
  run
    "keeper_schema_toml_parity"
    [ ( "order"
      , [ test_case "published order" `Quick test_the_published_order_is_unchanged
        ] )
    ; ( "owner_derivation"
      , [ test_case
            "masc_keeper_status bounds match their owner"
            `Quick
            test_status_bounds_match_their_owner
        ] )
    ]
;;
