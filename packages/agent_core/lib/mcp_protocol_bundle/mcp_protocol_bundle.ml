(** Dependency bundle for the pinned [mcp_protocol] package.

    This private library exists so that the canonical findlib names
    ([mcp_protocol], [mcp_protocol.eio], [mcp_protocol.http]) are declared
    in exactly one dune file. Internal consumers link against this bundle
    instead of repeating the upstream library names. *)
