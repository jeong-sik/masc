(** Explicit runtime contract helpers.

    Packages prompt/context composition and skill bundles into a first-class
    contract. Tool availability is the exact typed tool set supplied by the
    caller and is never filtered by this module.

    @stability Evolving
    @since 0.93.1 *)

(** {1 Types} *)

type trigger =
  { kind : string
  ; source : string option
  ; reason : string option
  ; payload : Yojson.Safe.t option
  }

type instruction_layer =
  { label : string option
  ; content : string
  }

type t =
  { runtime_awareness : string option
  ; trigger : trigger option
  ; instruction_layers : instruction_layer list
  ; skills : Skill.t list
  }

val context_key : string
val empty : t

(** {1 Builders} *)

val with_runtime_awareness : string -> t -> t

val with_trigger
  :  ?source:string
  -> ?reason:string
  -> ?payload:Yojson.Safe.t
  -> string
  -> t
  -> t

val add_instruction_layer : ?label:string -> string -> t -> t

(** Add a skill to the contract for {b runtime prompt composition}.
    The skill body is rendered as a [\[Skill: <name>\]] section inside the
    system prompt produced by {!compose_system_prompt}.

    This is distinct from {!Skill_registry.t}, which holds skills for
    discovery/metadata export only and never touches the system prompt. *)
val with_skill : Skill.t -> t -> t

(** Batch variant of {!with_skill}.  All skills are appended (deduped by
    path or name) and rendered into the system prompt. *)
val with_skills : Skill.t list -> t -> t

(** {1 Operations} *)

val merge : t -> t -> t
val is_empty : t -> bool

(** {1 Serialization} *)

val to_json : t -> Yojson.Safe.t

(** {1 Rendering} *)

val compose_system_prompt : ?base:string -> t -> string option
val context_with_contract : ?context:Context.t -> t -> Context.t option
