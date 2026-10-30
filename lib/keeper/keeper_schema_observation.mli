(** Diagnostic identity adapter for the descriptor selected by the real bridge.
    Weak physical descriptor keys and typed Add-on owner keys never retain the
    descriptor, export, handler, schema or owner in observer events. *)
val with_definition : Keeper_tool_descriptor.t -> (unit -> 'a) -> 'a
(** Runs the operation once. Unbound/disabled observation skips both registries.
    This is identity evidence, not a descriptor-to-schema memo or a lifetime
    guarantee. Owner hashing is deliberately constant because the public owner
    API exposes equality only; its lookup cost belongs to observer overhead. *)
