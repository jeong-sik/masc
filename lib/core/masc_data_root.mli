(** Boot-pinned physical data root
    (RFC-checkpoint-pinned-root-containment PR-1, #25151).

    One process-wide fact: the physical location of the configured data
    root, resolved at server bootstrap while the directory tree is
    trusted. Containment checks that must detect an ancestor directory
    later swapped for a symlink compare against this pin — resolving the
    root freshly per call would follow the swapped link on both sides of
    the comparison and never fail.

    An unpinned process (tests, CLI tools, anything that never runs
    server bootstrap) keeps pre-pin semantics: {!pinned} returns [None]
    and consumers skip the upper-bound check. The pin is set-once: a
    second pin with the same physical root is an idempotent [Ok]; a
    second pin with a different root is refused, never silently
    repinned. *)

type pin_error =
  | Root_unresolvable of
      { path : string
      ; detail : string
      }
      (** [path] could not be resolved to a physical location. *)
  | Root_not_directory of { physical : string }
      (** The resolved location exists but is not a directory. *)
  | Repin_differs of
      { pinned : string
      ; requested_path : string
      ; requested_physical : string
      }
      (** A different root is already pinned for this process. *)

val pin_error_to_string : pin_error -> string

(** Resolve [path] to its physical location ([Unix.realpath]) and pin it
    for the process lifetime. Returns the physical root on success.
    Blocking syscalls; intended for the one-shot server bootstrap path. *)
val pin : string -> (string, pin_error) result

(** Physical pinned root, or [None] before {!pin} (unpinned posture). *)
val pinned : unit -> string option

(** Reset to the unpinned posture. Test harnesses that boot more than
    one server state per process must call this before each boot. *)
val clear_for_tests : unit -> unit
