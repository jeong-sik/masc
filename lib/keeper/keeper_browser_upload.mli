(** Upload bytes are read with the Keeper's file authority before the browser
    receives any command. The callback receives private immutable snapshots,
    retaining the source basenames, valid only for the callback's duration. *)
val max_file_bytes : int

val with_staged_paths :
  ?read_file:(host_path:string -> max_bytes:int -> (string, string) result) ->
  ?turn_sandbox_factory:Keeper_sandbox_factory.t ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  paths:string list ->
  (string list -> 'a) ->
  ('a, string) result
(** [read_file] is an injectable backend byte reader for tests. Production uses
    [Keeper_sandbox_read_runner], including endpoint-owned trees, and never
    falls back to reading a same-named file on the server. Files larger than
    [max_file_bytes] are rejected, never uploaded as truncated prefixes. *)
