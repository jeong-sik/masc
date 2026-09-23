(** A Keeper's request to publish a new Skill package, and the answer.

    The Keeper tool lives below the server library and cannot call
    [Server_skill_editor.create] directly. It parses its arguments into
    {!request}, hands the request to
    {!Workspace_hooks.keeper_skill_publish_fn}, and the server installs the
    editor-backed implementation at boot. These types are the only thing both
    sides share. *)

(** Where the Keeper says the procedure actually worked: Memory fact ids, turn
    references, tool call references. A non-empty list of non-blank strings.
    The strings are recorded, never judged. *)
type evidence = private string list

type evidence_error =
  | Evidence_empty
  | Evidence_blank_entry of { index : int }

val evidence_of_list : string list -> (evidence, evidence_error) result
val evidence_to_list : evidence -> string list
val evidence_error_to_string : evidence_error -> string

type request =
  { actor : string  (** The publishing Keeper's name, written to the audit row. *)
  ; package_id : Skill_reference.package_id
  ; source_text : string  (** The whole [SKILL.md]. *)
  ; evidence : evidence
  }

type outcome =
  | Created_and_published of
      { reference : Skill_reference.t
      ; snapshot_revision : string
        (** The published catalog snapshot, rendered by the server with
            [Skill_catalog_snapshot.snapshot_revision_to_string]. Carried as
            text because this layer does not link the snapshot library;
            nothing branches on it. *)
      }
  | Created_but_shadowed of
      { reference : Skill_reference.t
      ; snapshot_revision : string
      ; winner : Skill_reference.identity
      }
      (** Written and published, but [winner], in an earlier source,
          declares the same name. Keeper turns list Skills by name and see
          [winner]; [reference] stays in the catalog as its shadow. *)
  | Created_but_unpublished of
      { reference : Skill_reference.t
      ; reason : string
      }
      (** [SKILL.md] was written, but the catalog snapshot that would make
          it visible was not published. *)

(** What kind of refusal the editor returned. The server derives it from the
    editor's own error variant, so the Keeper tool never reads [code]. *)
type refusal_cause =
  | Request_refused
      (** The request itself was refused before anything was written, for
          example an existing package, an invalid package id, or a document
          that does not parse. Corrected arguments may succeed. *)
  | Source_unavailable
      (** The workspace, catalog snapshot, or [project-agents] source is not
          ready or not writable. Nothing was written. *)
  | Write_outcome_unknown
      (** The write began and the editor cannot prove whether it committed. *)

type error =
  | Not_installed  (** No server installed the publisher (tests, non-server hosts). *)
  | Refused of
      { code : string  (** The editor's own [error_code]. *)
      ; message : string
      ; cause : refusal_cause
      }
