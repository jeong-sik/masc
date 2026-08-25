(** Whether a language server can answer about references outside one file.

    A language server that has no index does not say so — it answers with the
    occurrences it can see, which is the ones in the file it was given. On a
    two-file project that was one occurrence where the truth was three. A short
    list reads like an answer, so this is checked before the question is asked
    rather than after it is answered. *)

type presence =
  | Present
      (** The artifact is there, or this language needs none. *)
  | Missing of
      { build_command : string
      ; searched : string
      }
      (** Nothing to answer from. [build_command] is what produces it and
          [searched] is where this looked, so a caller can act rather than
          wonder. *)

(** [check ~language ~project_root] looks for the artifact
    {!Lsp_process_manager.reference_index_of_language} names, under
    [project_root].

    Symlinks are not followed, so a linked build directory cannot send the
    walk in a circle. Measured worst case — a 26 GB [_build] with no index in
    it, which is the case that cannot short-circuit — 0.43 s. *)
val check
  :  language:Lsp_process_manager.language
  -> project_root:string
  -> presence
