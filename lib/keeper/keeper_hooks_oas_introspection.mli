(** Static hook-slot introspection for [Keeper_hooks_oas].

    Kept separate from the runtime hook factory so the OAS hook adapter stays
    below the godfile cap without changing the dashboard JSON contract. *)

val hook_introspection_json :
  denied_tools:string list ->
  ?max_cost_usd:float ->
  ?destructive_check:bool ->
  unit -> Yojson.Safe.t
(** JSON snapshot describing which hook slots are active for the dashboard
    diagnostics surface. *)
