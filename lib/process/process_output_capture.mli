(** File preservation alongside the process runner's bounded previews.
    One capture belongs to one actual process attempt. Files are private and
    remain owned by the caller after this module closes them. *)

type source =
  | Complete_file of { path : string; byte_length : int }
  | Incomplete_file of { path : string; byte_length : int }
  | Capture_failed of { path : string option; message : string }

type files = { stdout : source; stderr : source }
type stream = Stdout | Stderr
type t

val with_capture : capture_dir:string -> (t -> 'a) -> 'a * files
(** Create fresh 0600 stream files below [capture_dir], creating that
    directory lazily. Close descriptors on every exit, including cancellation;
    preserve the original cancellation and leave partial files for evidence.
    File I/O errors become [Capture_failed] and never prevent [f] from running.
    The caller must eventually publish or remove the returned files. *)

val append : t -> stream:stream -> string -> unit
(** Preserve a raw pipe chunk. I/O failure is sticky, and does not raise into
    the child runner or stop pipe draining. Each stream has one producer. *)

val end_of_stream : t -> stream:stream -> unit
(** Record an observed pipe EOF and close that stream. Only successful close
    after this call can produce [Complete_file]. *)

val unavailable : t -> message:string -> unit
(** Record that execution switched to a path without authoritative chunk/EOF
    delivery, such as completion-captured Unix fallback. Never label its
    retained previews or any earlier attempt's bytes complete. *)
