(** Pure runtime TOML transformations. Callers own file reads and commits. *)

val update_runtime_assignment_text :
  string -> keeper_name:string -> runtime_id:string -> string
(** runtime.toml text with [keeper_name] assigned to [runtime_id] in
    [\[runtime.assignments\]]: the row is replaced or appended, the section
    is created when absent, every other line is kept. Keys are quoted, so a
    dotted keeper name stays one key. Pure; the commit is the caller's. *)

val remove_runtime_assignment_text : string -> keeper_name:string -> string
(** runtime.toml text without [keeper_name]'s row. Pure. *)

val update_egress_allow_text : string -> keeper_name:string -> allow:string list -> string
(** runtime.toml text with [keeper_name]'s [\[egress.keepers.<name>\]] table
    holding exactly [allow] (RFC-0415). The table is replaced or appended,
    every other line is kept, and the replacement is wholesale rather than a
    merge: an allowlist is the complete statement of what a keeper may reach,
    so a write that kept unnamed entries would leave an operator unable to
    remove one. Pure; the commit is the caller's. *)

val remove_egress_allow_text : string -> keeper_name:string -> string
(** runtime.toml text without [keeper_name]'s egress table. The keeper then
    has no allowlist, which admits nothing rather than everything. Pure. *)

(** A place in runtime.toml that can name a lane. [\[runtime\].media_failover]
    and [verifier_exact] slots name runtimes only and are not here. *)
type route_reference =
  | Keeper_assignment of string  (** [\[runtime.assignments\].<keeper>] *)
  | Default_runtime  (** [\[runtime\].default] *)
  | Fusion_seat of
      { preset : string
      ; seat : Fusion_policy.seat_kind
      }  (** a seat of [\[fusion.presets.<preset>\]] *)

val route_reference_to_string : route_reference -> string
(** The operator's name for the place, e.g. [\[fusion.presets.trio\].judge]. *)

val route_references :
  Runtime_schema.config ->
  (string * Fusion_policy.seat_kind * string) list ->
  (route_reference * string) list
(** Every place the config can name a lane, with the route it names. Keeper
    assignments, then the default, then the Fusion seats as given, which are
    {!Fusion_config.seat_routes_of_toml}'s (preset, seat, route). Seat routes
    are trimmed, as a Fusion run trims them before it resolves them. The lane
    rename and remove writers read references from here. *)

val contains_newline : string -> bool
val update_runtime_scalar_text : string -> key:string -> runtime_id:string option -> string
val update_runtime_string_array_text : string -> key:string -> values:string list -> string
val table_path_under : string -> string -> string
val lane_table_path : string -> string
val validated_lane_id : string -> (string, string) result
val validated_lane_candidates : string list -> (string list, string) result
val lane_is_declared : Runtime_schema.config -> string -> bool
val write_lane_candidates : content:string -> lane_id:string -> runtime_ids:string list -> string
val lane_references :
  Runtime_schema.config -> (string * Fusion_policy.seat_kind * string) list ->
  lane_id:string -> route_reference list
val lane_edit_toml : string -> (Otoml.t, string) result
val lane_fusion_seats :
  Otoml.t -> lane_id:string -> ((string * Fusion_policy.seat_kind * string) list, string) result
val rename_fusion_seats :
  string -> Otoml.t -> route_reference list -> lane_id:string -> new_lane_id:string ->
  (string, string) result
