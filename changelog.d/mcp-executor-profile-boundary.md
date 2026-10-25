### Fixed

- Enforce existing MCP tool-profile membership at the shared executor boundary so direct callers cannot bypass it; reject before tool hooks or effects and retain caller/audit attribution. Refs #25930, #22179.
