open Base
(** Time Compatibility Layer - re-exported from mcp-protocol-sdk.

    All existing [Time_compat.now ()], [Time_compat.sleep], etc.
    calls continue to work without changes.

    @since 2.103.0 - Migrated to mcp-protocol-sdk shared module *)
include Mcp_protocol_eio.Time_compat
