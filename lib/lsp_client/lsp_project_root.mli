(** The directory a language server should be rooted at for a given file.

    A Keeper's sandbox root is not that directory. Keeper clones live at
    [repos/<id>/] under [.masc/playground/<keeper>], so rooting a language
    server at the sandbox root roots it one level above every project in it —
    the same shape as the [git/diff] route that ran git at the playground root
    and reported no changes for a modified clone. The root is found by walking
    up from the file, not by taking the boundary. *)

type resolution =
  | Project_root of string
      (** The nearest ancestor of the file, at or below the boundary, holding
          one of the language's project markers. *)
  | No_project_root of
      { file : string
      ; markers : string list
      }
      (** No ancestor up to the boundary holds a marker. The file is inside the
          sandbox but not inside a project this language server can be rooted
          at, so its answers about other files would be empty for a reason
          that has nothing to do with the code. *)
  | Outside_boundary of
      { file : string
      ; boundary : string
      }
      (** The file is not under the boundary. Callers resolve the path against
          the sandbox first, so this says the two disagree — it is never an
          invitation to walk past the boundary. *)

(** [resolve ~language ~file ~boundary] finds the project root for [file].

    Both paths are canonicalized with [Fs_compat.realpath_lenient] before they
    are compared, so [/tmp] and [/private/tmp] are one location rather than
    two. The walk stops at [boundary] inclusive and never goes above it. *)
val resolve
  :  language:Lsp_process_manager.language
  -> file:string
  -> boundary:string
  -> resolution
