(** Process-local, non-blocking serialization for cooperative capability
    writers. Existing targets are keyed globally by their no-follow resource
    identity, so filesystem aliases share one lease without lexical
    normalization. An absent-target lease excludes new cooperative mutations
    below that parent until the publication protocol releases it. Existing
    mutations that linearized first may continue. Existing replacements take a
    short parent publication lease and reobserve their exact target binding
    immediately before rename; exclusive create leaves collision authority to
    the kernel. Unrelated siblings therefore remain concurrent. External
    unlink/rename remains an observation boundary, not an exclusion claim. *)

type key =
  | Existing_target of
      { target_dev : int64
      ; target_ino : int64
      ; parent_dev : int64
      ; parent_ino : int64
      }
  | Absent_target_parent of
      { parent_dev : int64
      ; parent_ino : int64
      }
  | Existing_publication_parent of
      { parent_dev : int64
      ; parent_ino : int64
      }

type t

(** [try_acquire key] has one linearization point under the registry mutex.
    Existing targets conflict with the same target identity or an absent-target
    lease for their parent. Absent targets conflict with another absent-target
    lease or an active existing-target publication for their parent. Existing
    publications conflict with an absent-target lease; multiple existing-target
    publications below the parent may coexist. *)
val try_acquire : key -> t option

val release : t -> unit
