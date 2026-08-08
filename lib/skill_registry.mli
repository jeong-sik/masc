(** Skill registry for discovery and metadata export.

    Holds skills for Agent Card generation, A2A capability negotiation,
    and skill inventory queries.  Skills in the registry are {b not}
    injected into the agent's system prompt — they exist purely as
    metadata.  To compose a skill into the runtime prompt, use
    {!Contract.with_skill} (or {!Builder.with_skill}).

    Wraps a [Hashtbl.t] keyed by skill name.  Unlike {!Skill} which is
    pure data, the registry provides CRUD, bulk loading from a directory,
    and JSON round-trip for persistence / agent card export.

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
val register : t -> Skill.t -> unit

(** Look up a skill by name. *)
val find : t -> string -> Skill.t option

(** Remove a skill by name. *)
val remove : t -> string -> unit

(** List all registered skills, sorted by name. *)
val list : t -> Skill.t list

(** List all registered skill names, sorted. *)
val names : t -> string list

(** Number of registered skills. *)
val count : t -> int

(** {1 Bulk Loading} *)

(** Load skills from a directory.  Returns the number loaded on success. *)
val load_from_dir : t -> ?scope:Skill.scope -> string -> (int, Error.sdk_error) result

(** {1 JSON Serialization} *)

(** Serialize a single skill to JSON. *)
val skill_to_json : Skill.t -> Yojson.Safe.t

(** Serialize the entire registry to JSON (skills list + count). *)
val to_json : t -> Yojson.Safe.t

(** Deserialize a single skill from JSON. *)
val skill_of_json : Yojson.Safe.t -> (Skill.t, Error.sdk_error) result

(** Deserialize a registry from JSON. *)
val of_json : Yojson.Safe.t -> (t, Error.sdk_error) result
