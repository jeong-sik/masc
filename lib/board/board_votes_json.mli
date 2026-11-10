(** JSON row decoders and persisted row loaders for {!Board_votes}. *)

include module type of struct
  include Board_core
end

val visibility_of_string : string -> visibility option
val post_of_yojson : Yojson.Safe.t -> post option
(** Accepts only the exact current {!post_to_yojson} wire shape. *)

val comment_of_yojson : Yojson.Safe.t -> comment option
(** Accepts only the exact current {!comment_to_yojson} wire shape. *)

val load_source_rows :
  string ->
  decode:(Yojson.Safe.t -> 'a option) ->
  accept:('a -> unit) ->
  (unit, string * exn) result
(** Read every nonempty JSONL line, retaining the first invalid JSON or schema
    error with its line number instead of silently dropping that row. When
    more than one row is rejected the detail also carries the reject count. *)

val record_load_result :
  ((unit, string) result -> unit) ->
  ('a, string * exn) result ->
  ('a, string * exn) result
(** Store the last full-load outcome while returning the caller's count. *)

val log_loaded :
  noun:string ->
  loaded:int ->
  path:string ->
  elapsed:float ->
  (unit, string * exn) result ->
  unit
(** One owner for every "loaded N <noun>" line. The [Error] arm logs a
    warn naming the partial load: accepted rows stay in the store while
    the outcome is [Error]. *)

val load_persisted_posts : store -> (int, string * exn) result
(** Explicit startup/quiescent reload under persist then state locks. Success
    requires a physically valid initialization guard and a complete Present
    posts source; an initialized empty file returns [Ok 0]. Missing never grants
    posts authority. Repeated refusals retain the accepted guard history, and
    ordinary reload cannot settle an unknown write.

    Valid rows remain available for display after an ordinary guard refusal or
    malformed row. Complete display replaces memory; partial display merges its
    accepted rows. Display snapshots grant no negative evidence or write authority.
    Valid expired rows remain source rows. Retained reserved causes propagate
    unchanged after the current ordered diagnostic trace has been retained.
    An exception during model projection crosses the state mutex before it is
    recorded, preserving poisoning for an uncertain partial model mutation.
    Known read cleanup is finished after a normally returned state callback.
    Refused while deletion persistence is pending; open a fresh store instead
    of replacing just one part of its applied deletion model. *)

val load_persisted_comments : store -> (int, string * exn) result
(** Explicit source read and model publication under persist then state.
    First observed Missing comments are legitimate empty input. Missing after
    this store observed Present is refused. Complete reads replace comments
    and their index; partial rows and complete prefixes before torn tails
    remain display-only. Plain reload cannot settle unknown writes, acknowledge
    recovery receipts or finish model publication. The pending-deletion model
    restriction is the same as {!load_persisted_posts}. *)

val propagate_workspace_check :
  (unit, Board_workspace_binding.rejection) result -> unit
(** After recording an auxiliary family's load refusal, propagate any original
    reserved cause outside its broad file-read catch and Board locks. *)
