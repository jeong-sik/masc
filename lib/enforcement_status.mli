(** Enforcement_status — closed sum for the [status] field of admin
    surface-enforcement rows emitted by {!Tool_misc_admin}'s
    [enforcement_summary_json].

    Each value reflects the runtime relationship between a configured
    policy surface and the dispatcher that consumes it:

    {ul
    {- [Conditional]: enforced only under a runtime gate (e.g. room
       auth enabled).}
    {- [Enforced]: unconditionally applied at the relevant dispatch
       site.}
    {- [Advisory_only]: stored in configuration but not wired into a
       runtime check (informational; deprecation-track candidate).}}

    Adding a new enforcement tier now forces the [to_label] match arm
    to be added, preventing silent vocabulary drift in the surface
    inventory wire format. *)

type t =
  | Conditional
  | Enforced
  | Advisory_only

val to_label : t -> string
(** Wire-format label, byte-identical to the prior inline literals. *)
