(* RFC-0374 — the deterministic half of the capability probe lane.

   Deliberately has no dependency on the turn driver, the runners, the chat
   store, or the checkpoint store. That absence is the point of the module:
   it is what lets a caller ask about the tool surface without the question
   becoming part of the keeper's history.

   Every "does this reach the model" decision is delegated to
   [Keeper_tool_descriptor.keeper_model_names], which is the projection the
   real surface is built from. Re-deriving it here from
   [keeper_model_projection] alone looked equivalent and was not: that field
   is only consulted after [model_schema_errors] clears, so a descriptor with
   a broken schema is withheld from the model while its projection variant
   still says [Preferred_public_name]. A probe that read the variant directly
   would have reported such a tool as reachable. *)

type verdict =
  | Projected of { model_facing_name : string }
  | Not_a_descriptor
  | Operator_only
  | Aliased of { projected_by : string }
  | Withheld_by_schema_error of { errors : string list }

let verdict_to_string = function
  | Projected { model_facing_name } ->
    Printf.sprintf "projected as %s" model_facing_name
  | Not_a_descriptor -> "no descriptor declares this name"
  | Operator_only -> "operator-only, withheld from the keeper model"
  | Aliased { projected_by } ->
    Printf.sprintf "transport alias; projected by %s" projected_by
  | Withheld_by_schema_error { errors } ->
    Printf.sprintf
      "declared model-facing but withheld: %s"
      (String.concat "; " errors)
;;

(* Operator-authored probe lists name tools inconsistently -- a public name in
   one row, the internal name in the next -- so resolution accepts either.
   This is name resolution, not a fallback: both strings are declared by the
   same descriptor, so neither is a guess. *)
let declares name (d : Keeper_tool_descriptor.t) =
  String.equal d.public_name name || String.equal d.internal_name name
;;

let probe_surface ~tool =
  match List.find_opt (declares tool) (Keeper_tool_descriptor.all_descriptors ()) with
  | None -> Not_a_descriptor
  | Some descriptor ->
    (match Keeper_tool_descriptor.keeper_model_names descriptor with
     | model_facing_name :: _ -> Projected { model_facing_name }
     | [] ->
       (* The SSOT withholds it. Which of the two reasons applies is not
          recoverable from the empty list, so ask the same two predicates the
          SSOT asked, in the same order it asked them. *)
       (match
          ( Keeper_tool_descriptor.model_schema_errors descriptor
          , descriptor.keeper_model_projection )
        with
        | (_ :: _ as errors), _ -> Withheld_by_schema_error { errors }
        | [], Operator_only -> Operator_only
        | [], Transport_alias { projected_by } -> Aliased { projected_by }
        | [], (Preferred_public_name | Internal_name) ->
          (* keeper_model_names returns a name for these once the schema
             clears, so reaching here means the SSOT changed shape and this
             module has drifted from it. Say so rather than inventing a
             verdict. *)
          Withheld_by_schema_error
            { errors =
                [ "descriptor projects a model-facing name but the surface \
                   withheld it; Keeper_capability_probe has drifted from \
                   Keeper_tool_descriptor.keeper_model_names"
                ]
            }))
;;

let model_facing_names () =
  Keeper_tool_descriptor.model_visible_schemas ()
  |> List.map (fun (schema : Masc_domain.tool_schema) -> schema.name)
;;
