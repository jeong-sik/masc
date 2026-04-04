(** Meta_cognition — room-level read model derived from existing artifacts.

    Facade module: re-exports sub-modules for backward compatibility.
    All callers can continue using [Meta_cognition.snapshot_json] etc.

    Implementation split into:
    - {!Meta_cognition_types} — types and leaf utilities
    - {!Meta_cognition_rules} — signal detection rules
    - {!Meta_cognition_snapshot} — data loading and JSON builders
    - {!Meta_cognition_parse} — summary JSON parsing
    - {!Meta_cognition_interpret} — salience interpretation engine
    - {!Meta_cognition_digest} — board digest management

    @since God file decomposition *)

include Meta_cognition_types
include Meta_cognition_rules
include Meta_cognition_snapshot
include Meta_cognition_parse
include Meta_cognition_interpret
include Meta_cognition_digest
