(** Upload bytes are read with the Keeper's file authority before the browser
    receives any command. The callback receives private immutable snapshots,
    retaining the source basenames. Snapshots claimed by WebDriver remain valid
    until confirmed browser session teardown; unclaimed files are cleaned when
    the callback exits. *)
val max_file_bytes : int

(** Why staging stopped. A path the caller named that the Keeper's read
    authority refuses carries that refusal's class. Everything after the paths
    resolved -- reading the bytes, a file over [max_file_bytes], the lease --
    reaches this module as one string from [Browser_lane.Upload_lease], so it
    is not claimed as the caller's to correct. *)
type staging_error =
  | Path_refused of Keeper_alerting_path.path_refusal
  | Staging_failed of string

val with_staged_paths :
  ?read_file:(host_path:string -> max_bytes:int -> (string, string) result) ->
  ?turn_sandbox_factory:Keeper_sandbox_factory.t ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  paths:string list ->
  (string list -> 'a) ->
  ('a, staging_error) result
(** [read_file] is an injectable backend byte reader for tests. Production uses
    [Keeper_sandbox_read_runner], including endpoint-owned trees, and never
    falls back to reading a same-named file on the server. Files larger than
    [max_file_bytes] are rejected, never uploaded as truncated prefixes. *)
