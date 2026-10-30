(** Server_play_skills — the game guides an agent handed an invite link reads
    (RFC play-link-for-the-shared-machine §2.7).

    A guide is a Skill of the attached shared DOS machine: the installation
    that serves the DOS screen tool, found as the seat and the moves find it
    ({!Machine_addon_host.shared_skill_owner}). Its Skills are read from the
    published Skill snapshot a Keeper's [keeper_skill] reads
    ({!Server_skill_snapshot_runtime.lookup}), and only the ones a Keeper's
    effective lookup also returns: a workspace Skill of the same name wins.
    Nothing here reads the repository's [addons/] directory, and nothing maps
    a program name to a Skill: the agent picks by description. *)

val prefix : string
(** ["/play/skills/"]. A guide is [<prefix><name>/SKILL.md]; one of its
    reference files is [<prefix><name>/references/<file>], where a relative
    [references/<file>] link in the guide resolves. *)

type skill = private
  { name : string
  ; description : string
  ; body : string
        (** The SKILL.md text after its frontmatter, exactly as published:
            what a Keeper's [keeper_skill] call returns. *)
  ; ownership_root : string  (** The add-on Skill source the snapshot scanned. *)
  ; directory : string  (** The Skill's directory in that source. *)
  ; max_bytes : int  (** The workspace's Skill resource read bound. *)
  }

type unavailable =
  | Skills_unpublished  (** No snapshot is published for this workspace yet. *)
  | Catalog_unreadable of string
      (** The workspace path is not a canonical workspace. May name a host
          path: log it, never answer it. *)
  | Machine_not_attached
      (** No single attached shared installation serves the DOS screen tool. *)
  | Skills_not_in_effect
      (** The workspace Skill configuration was refused or unreadable, or sets
          no [[skills]] table, so the snapshot holds no add-on Skills. *)
  | Source_unavailable of string
      (** The snapshot holds the machine's Skill source but did not scan it as
          a directory. May name a host path. *)

type catalog = (skill list, unavailable) result

val catalog : config:Workspace.config -> catalog
(** The machine's Skills in the current published snapshot, by name. Lookup
    only: never publishes, reconciles or creates a workspace slot. An attached
    machine whose source the snapshot does not hold publishes none ([Ok []]). *)

val unavailable_detail : unavailable -> string option
(** The host-side reason behind an unavailable catalog, for the operator log. *)

val document_url : base:string -> string -> string
val reference_url : base:string -> skill:string -> string -> string

val guide_section : base:string -> catalog -> string
(** The [{{skills}}] text of [play.agent_guide], from snapshot data only: one
    item per Skill with its description and URL, or a sentence saying why
    there are none. *)

type fetch =
  | Served of string
  | Served_without_references of
      { body : string
      ; detail : string  (** May name a host path. *)
      }
      (** A guide whose reference files could not be listed. *)
  | Not_found
      (** The path does not name a published guide or one of its reference
          files. Names are looked up in what was published and listed; a path
          is never built from the request. *)
  | Unavailable of unavailable
  | References_unreadable of string  (** May name a host path. *)
  | Reference_too_large of
      { file : string
      ; bytes : int
      ; max_bytes : int
      }
  | Reference_unreadable of string  (** May name a host path. *)

val fetch : base:string -> catalog -> string -> fetch
(** [fetch ~base catalog path] for a request path under {!prefix}. A guide is
    served with its reference files' URLs (under [base]) appended. Reference
    files are listed for that one Skill only, as the regular [.md] files of
    its [references/] directory, and read with no-follow ownership checks
    under the add-on source, at most [max_bytes]. *)
