(** Server_play_skills — the game guides an agent handed an invite link reads
    (RFC play-link-for-the-shared-machine §2.7).

    A guide is a Skill the DOS machine add-on publishes into the workspace
    Skill catalog, read from the same published snapshot a Keeper's
    [keeper_skill] reads ({!Server_skill_snapshot_runtime.lookup}). The add-on
    is attached under the declaration {!dos_machine_declaration}; its Skills
    carry the source id {!Lane_addon_runtime.skill_source_id} derives from it.
    Nothing here reads the repository's [addons/] directory, and nothing maps a
    program name to a Skill: the agent picks by description. *)

val dos_machine_declaration : string

val prefix : string
(** ["/play/skills/"]. A guide is [<prefix><name>.md]; one of its reference
    files is [<prefix><name>/references/<file>]. *)

type reference = private
  { file : string  (** The file's name in the Skill's [references/] directory. *)
  ; path : string  (** Built from the directory listing, never from a request. *)
  }

type references = private
  | Listed of
      { ownership_root : string
      ; max_bytes : int
      ; files : reference list
      }
      (** The regular [.md] files in [references/], by name. [ownership_root]
          is the add-on Skill source the snapshot scanned and [max_bytes] the
          workspace's Skill resource read bound, the two a Keeper's
          [keeper_skill] reads a resource file under. *)
  | References_unreadable of string
      (** Why they could not be listed. May name a host path: log it, never
          answer it. *)

type skill = private
  { name : string
  ; description : string
  ; body : string
        (** The SKILL.md text after its frontmatter, exactly as published:
            what a Keeper's [keeper_skill] call returns. *)
  ; references : references
  }

type unavailable =
  | Skills_unpublished
      (** No snapshot is published for this workspace yet. *)
  | Catalog_unreadable of string
      (** The workspace path is not a canonical workspace. May name a host
          path. *)
  | Not_attached
      (** The published snapshot carries no source of the DOS machine add-on
          declaration. *)

type catalog = (skill list, unavailable) result

val catalog : base_path:string -> catalog
(** The DOS machine add-on's Skills in the current published snapshot, by
    name. Lookup only: never publishes or creates a workspace slot. *)

val unreadable_details : catalog -> string list
(** The host-side reasons a catalog leaves out ([Catalog_unreadable], each
    [References_unreadable]), for the operator log. *)

val document_url : base:string -> string -> string
val reference_url : base:string -> skill:string -> string -> string

val guide_section : base:string -> catalog -> string
(** The [{{skills}}] text of [play.agent_guide]: one item per Skill with its
    description, its URL and its reference files' URLs, or a sentence saying
    why there are none. *)

type fetch =
  | Served of string
  | Not_found
      (** The path does not name a published guide or one of its reference
          files. Names are looked up in the catalog; a path is never built
          from the request. *)
  | Unavailable of unavailable
  | References_unavailable of string
  | Reference_too_large of
      { file : string
      ; bytes : int
      ; max_bytes : int
      }
  | Reference_unreadable of string
      (** May name a host path: log it, never answer it. *)

val fetch : catalog -> string -> fetch
(** [fetch catalog path] for a request path under {!prefix}. A reference file
    is read with no-follow ownership checks under the add-on source, at most
    [max_bytes]. *)
