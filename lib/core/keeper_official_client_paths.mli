(** Shared storage authority for the official-client runtime and its outbox.
    Paths retain the same BasePath representation as {!Common}; no filesystem
    lookup or additional canonicalization is performed. *)

val state_dir : base_path:string -> keeper_name:string -> (string, string) result
(** Existing portable Keeper-name admission and runtime state directory. *)

val outbox_dir : base_path:string -> keeper_name:string -> (string, string) result

val consumed_results_dir : base_path:string -> keeper_name:string -> (string, string) result
(** Original results whose delivery was acknowledged. They remain durable
    artifact owners and are not loaded as pending deliveries. *)

type tool_result_source
(** One exact direct file path in a Keeper's pending or consumed result directory.
    Filesystem ownership and symlink admission remain the scanner's authority;
    this token does not validate JSON or its filename digest. *)

val tool_result_source : base_path:string -> path:string -> tool_result_source option
(** [None] outside the exact directories produced by {!outbox_dir} and
    {!consumed_results_dir}, including nonportable Keeper names or extra path
    components. Both locations use the same strict receipt codec. *)

val tool_result_source_path : tool_result_source -> string
