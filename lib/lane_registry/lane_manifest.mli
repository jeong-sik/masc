(** What each built-in Lane is, derived from its id by exhaustive functions
    (RFC every-lane-is-one-row-in-one-registry §2.2). Nothing here is stored,
    so a new constructor in [Lane_id.builtin], [Standalone_lane.t],
    [Browser_lane.Lane_name.t], [Machine_lane.t] or
    [Tool_schemas_misc.misc_operation] does not compile until these functions
    say what it means. Whether a lane is required is
    [Standalone_lane.obligation]: only exact-output lanes can be. *)

val label : Lane_id.builtin -> string
(** The lane's name on operator surfaces. *)

val purpose : Lane_id.builtin -> string
(** One sentence on what the lane does. *)

val lanes_of_misc_operation : Tool_schemas_misc.misc_operation -> Lane_id.builtin list
(** The built-in lanes a misc tool acts on. A Browser tool lists every
    backend its [lane] argument accepts; which verbs each backend then admits
    stays with [Browser_lane]. The Lane Add-on tools ([masc_lane_*]) act on
    package installations and list none. *)

val tools : Lane_id.builtin -> Tool_schemas_misc.misc_operation list
(** Every misc tool whose {!lanes_of_misc_operation} names the lane, in
    [Tool_schemas_misc.misc_operations] order. *)
