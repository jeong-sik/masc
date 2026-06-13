(** Workspace_utils — Shared helpers for the [Workspace] module.

    Pure facade — the .ml is 3 [include] statements bringing
    in 3 sub-modules.  This .mli mirrors the runtime with
    [include module type of] so callers can reach every sub-
    module symbol via {!Workspace_utils.X} and type identity is
    preserved end-to-end:

    - {!Workspace_utils_backend_setup} — backend probe + git-root
      detection helpers.
    - {!Workspace_utils_paths_backend} — base-path / data-path
      resolvers shared across workspace backends.
    - {!Workspace_utils_ops} — operations executed against the
      resolved workspace state (read / write / sync paths).

    Each sub-module has its own .mli; this facade re-exposes
    them as the [Workspace_utils] entry point.  Adding a new entry
    requires bumping the corresponding sub-module's .mli and
    extending its `include` here in the same commit so the
    facade and sub-modules stay in sync.

    Type identity is preserved across the runtime — callers
    can interleave {!Workspace_utils.X} and the source modules'
    [X] freely (the [config] type, for example, is the same
    nominal type whether reached via {!Workspace_utils.config} or
    {!Workspace_utils_paths_backend.config}). *)

include module type of struct
  include Workspace_utils_backend_setup
end

include module type of struct
  include Workspace_utils_paths_backend
end

include module type of struct
  include Workspace_utils_ops
end
