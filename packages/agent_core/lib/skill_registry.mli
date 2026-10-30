(** Skill registry for discovery and metadata export.

    Holds skills for Agent Card generation, A2A capability negotiation,
    and skill inventory queries.  Skills in the registry are {b not}
    injected into the agent's system prompt — they exist purely as
    metadata.  To compose a skill into the runtime prompt, use
    {!Contract.with_skill} (or {!Builder.with_skill}).

    Wraps a [Hashtbl.t] keyed by skill name. Decoding and filesystem effects
    stay at the runtime boundary; this module provides CRUD and a JSON
    observation projection.

    Thread-safety note: single-writer assumed (no [Eio.Mutex] needed).
    The registry is always owned by a single {!Agent.t} instance.

    @stability Evolving
    @since 0.93.1 *)

(** {1 Types} *)

(** Mutable skill registry. *)
type t

(** {1 CRUD} *)

(** Create an empty registry. *)
val create : unit -> t

(** Register a skill, replacing any existing entry with the same name. *)
val register : t -> Skill_document.t -> unit

(** Look up a skill by name. *)
val find : t -> string -> Skill_document.t option

(** Remove a skill by name. *)
val remove : t -> string -> unit

(** List all registered skills, sorted by name. *)
val list : t -> Skill_document.t list

(** List all registered skill names, sorted. *)
val names : t -> string list

(** Number of registered skills. *)
val count : t -> int

(** {1 JSON observation} *)

(** Project a single skill to JSON. *)
val skill_to_json : Skill_document.t -> Yojson.Safe.t

(** Project the entire registry to JSON (skills list + count). *)
val to_json : t -> Yojson.Safe.t
