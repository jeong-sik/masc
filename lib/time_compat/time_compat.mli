open Base
(** Time compatibility layer — transparent re-export of
    {!Mcp_protocol_eio.Time_compat}.

    All existing [Time_compat.now ()], [Time_compat.sleep], etc. calls continue
    to work unchanged.

    @since 2.103.0 — migrated to the mcp-protocol-sdk shared module. *)

include module type of Mcp_protocol_eio.Time_compat
