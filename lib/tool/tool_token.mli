
(** Tool_token — parse-once proof that a tool name exists in a dispatch table.

    [private] type: fields are readable but construction requires [mint].
    This enforces "Parse, Don't Validate" at I/O boundaries — callers
    must validate the tool name once at entry, then pass the token
    instead of a raw string.

    Phase 1A of Tool Gate architecture (#4381). *)

type t = private { name : string; minted_at : float }
(** Immutable token. [name] is the validated tool name.
    [minted_at] is [Unix.gettimeofday ()] at mint time (diagnostic). *)

val mint_with : validate:(string -> bool) -> name:string -> (t, string) Result.t
(** [mint_with ~validate ~name] returns [Ok token] when [validate name] is
    [true]. Use when the validation source is not a single Hashtbl
    (e.g., checking multiple registries). *)
