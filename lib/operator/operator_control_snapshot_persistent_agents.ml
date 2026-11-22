(** Persistent (keeper) agents snapshot row builder, extracted from
    [operator_control_snapshot.ml] (godfile decomp).

    [persistent_agents_json ~keeper_names ~keeper_rows] produces a
    `{ count; items }` JSON object describing the persistent keeper agents.
    It projects the Keeper rows the snapshot has just built onto the
    operator snapshot schema, for the Keepers named in [keeper_names]
    (lossless filter — values are forwarded through `field_or_null`, no
    field synthesis). It reads nothing itself.

    Each item carries `runtime_class="keeper"` plus the standard
    operator-dashboard keeper fields. *)

module String_set = Set.Make (String)

let persistent_agents_json ~keeper_names ~keeper_rows =
  let wanted_set = String_set.of_list keeper_names in
  let rows =
    keeper_rows
    |> List.filter_map (function
      | `Assoc fields ->
        (match List.assoc_opt "name" fields with
         | Some (`String name) when String_set.mem name wanted_set ->
           let field_or_null key =
             match List.assoc_opt key fields with
             | Some value -> value
             | None -> `Null
           in
           Some
             (`Assoc
                ([ "runtime_class", `String "keeper"
                 ; "name", field_or_null "name"
                 ; "trace_id", field_or_null "trace_id"
                 ; "goal", field_or_null "goal"
                 ; "status", field_or_null "status"
                 ; "turn_count", field_or_null "turn_count"
                 ; "runtime_id", field_or_null "runtime_id"
                 ; "runtime_canonical", field_or_null "runtime_canonical"
                 ; ( "selected_runtime_canonical"
                   , field_or_null "selected_runtime_canonical" )
                 ; "primary_model", field_or_null "primary_model"
                 ; "next_model_hint", field_or_null "next_model_hint"
                 ; "updated_at", field_or_null "updated_at"
                 ; "created_at", field_or_null "created_at"
                 ]
                 (* Lossless filter (module contract): keeper_rows is the
                    freshly computed keepers projection, so the measured
                    context fields forward verbatim like every other field —
                    synthesizing typed absence here would contradict the
                    canonical row and trip false diagnostics. *)
                 @ [ "context_ratio", field_or_null "context_ratio"
                   ; "context_tokens", field_or_null "context_tokens"
                   ; "context_max", field_or_null "context_max"
                   ; "context_source", field_or_null "context_source"
                   ; "context_provenance", field_or_null "context_provenance"
                   ; "estimated_context_ratio", field_or_null "estimated_context_ratio"
                   ; ( "context_metrics_unavailable"
                     , field_or_null "context_metrics_unavailable" )
                   ; ( "context_metrics_unavailable_reason"
                     , field_or_null "context_metrics_unavailable_reason" )
                   ; "context", field_or_null "context"
                   ]
                 @ [ "last_turn_usage", field_or_null "last_turn_usage" ]))
         | _ -> None)
      | _ -> None)
  in
  `Assoc [ "count", `Int (List.length rows); "items", `List rows ]
;;
