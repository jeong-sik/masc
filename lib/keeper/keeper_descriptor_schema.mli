(** Immutable SDK schemas for descriptor-owned Keeper model definitions.
    Callers retain responsibility for canonical descriptor admission. *)

val for_descriptor :
  Keeper_tool_descriptor.t -> (Agent_core.Types.tool_schema, string) result
(** Derive the sole model name, description and authoritative input schema
    from this descriptor, preserving the bridge's [strict=None]. A descriptor
    with no model projection is rejected.

    Static runtime handlers reuse successful schemas by physical descriptor
    identity. Distinct records remain distinct even when their IDs match.
    Add-on descriptors bypass this memo and construct a fresh schema each time.
    No handler, execution environment, owner or serialized string is retained.

    Construction and actual-constructor observation run outside the weak-table
    mutex. Concurrent first callers may construct independently, then return
    the winning published schema. Failed construction is not cached.
    Cache hits emit no constructor span; missing constructor rows therefore
    cannot be interpreted as zero work by the original observer analyzer. *)
