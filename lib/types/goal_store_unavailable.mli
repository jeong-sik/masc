(** Goal_store_unavailable — the value a goal store this build cannot read
    produces (RFC-0444 §2.1).

    Defined here, below both [masc_workspace] and [masc_goal], so the
    task-creation contract in [masc_workspace] can carry it while the store
    that builds it ([Goal_store], in [masc_goal]) depends on
    [masc_workspace]. [Goal_store] re-exports every type with a manifest, so
    [Goal_store.Schema_rejected] and [Goal_store.unavailable] keep working. *)

type t =
  { file : string  (** The goals.json path. *)
  ; reason : reason
  ; mirror : mirror_status
      (** The .last-good mirror at the same moment. Shown, never served. *)
  ; reset_step : reset_step
  }

and nonregular_kind =
  | Nonregular_directory
  | Nonregular_character_device
  | Nonregular_block_device
  | Nonregular_symbolic_link
  | Nonregular_fifo
  | Nonregular_socket
(** A nonregular kind observed by the Goal reader. No open or read error is
    inferred from this observation. *)

and reason =
  | Missing_after_init  (** goals.json is absent and the mirror is not confirmed absent. *)
  | Unreadable of Unix.error
      (** An inspection, open or read error. Following [ENOENT], an observed
          non-directory ancestor can also be reported as [ENOTDIR]. *)
  | Nonregular of nonregular_kind
      (** The primary path or opened descriptor had this nonregular kind. *)
  | Not_json of string  (** The bytes are not JSON. *)
  | Schema_rejected of { field : string; detail : string }
      (** JSON, but this build's decoder refused [field] or a member at this location. *)

and mirror_status =
  | Mirror_absent
  | Mirror_unreadable of Unix.error
      (** The same error and ancestor-inspection meanings as {!Unreadable}. *)
  | Mirror_nonregular of nonregular_kind
      (** The mirror path or opened descriptor had this nonregular kind. *)
  | Mirror_decodes of { goal_count : int; updated_at : string }
      (** Evidence of how far the primary drifted from the last commit. *)
  | Mirror_rejected of reason

and reset_step =
  | Repair_field of string  (** Inspect and repair this named location. *)
  | Reset_goal_store  (** Move the store aside (RFC-0444 §2.6, PR-7). *)
  | Restore_permission  (** [Unreadable EACCES]. *)
  | Inspect_path  (** Inspect file paths, links and mounts before recovery. *)

(** {1 Wire names}

    The constructor name in lowercase snake case: the tokens the RFC-0444
    envelope carries in [reason], [mirror.status] and [reset_step]. *)

val reason_name : reason -> string
val mirror_status_name : mirror_status -> string
val reset_step_name : reset_step -> string

(** {1 Rendering} *)

val reason_to_string : reason -> string
val mirror_status_to_string : mirror_status -> string
val reset_step_to_string : reset_step -> string

val to_string : t -> string
(** One line naming the reason constructor, the field when there is one, the
    file, the mirror status and the reset step:
    [goal_store: unavailable reason=… file=… mirror=… reset=…]. For surfaces
    whose terminus is a string. Render at the very end; never branch on the
    output. *)

(** {1 Durable codec}

    Lossless, for the store that keeps a skipped verifier scan (RFC-0444
    PR-5). Every [Unix.error], observed nonregular kind, detail string and
    the mirror's inner reason round-trips; the wire envelope ({!Goal_unavailable_envelope} in
    masc_goal) is the lossy projection for tool results and HTTP bodies. The
    [kind] member of each nested object carries the wire name
    ({!reason_name} and siblings); a member this build does not know, or a
    kind it does not name, is refused. A [Unix.error] is an object whose
    [kind] is its lowercase name; [EUNKNOWNERR] alone adds an integer [code]
    member, so no member packs two facts into one string. *)

val record_to_yojson : t -> Yojson.Safe.t
val record_of_yojson : Yojson.Safe.t -> (t, string) result
