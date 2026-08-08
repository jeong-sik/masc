(** File-backed checkpoint persistence using [Eio.Path].

    Layout: [<base_dir>/<session_id>.json].
    Atomic writes via [.tmp] + rename.

    @stability Stable
    @since 0.93.1 *)

(** {1 Types} *)

(** Opaque checkpoint store handle. *)
type t

(** {1 Lifecycle} *)

(** Create a store backed by [base_dir].  Creates the directory if needed. *)
val create : Eio.Fs.dir_ty Eio.Path.t -> (t, Error.sdk_error) result

(** {1 Operations} *)

(** Save a checkpoint atomically (write to tmp, then rename). *)
val save : t -> Checkpoint.t -> (unit, Error.sdk_error) result

(** Load a checkpoint by session ID. *)
val load : t -> string -> (Checkpoint.t, Error.sdk_error) result

(** List all stored session IDs, sorted alphabetically. *)
val list : t -> (string list, Error.sdk_error) result

(** Delete a checkpoint by session ID. *)
val delete : t -> string -> (unit, Error.sdk_error) result

(** Check whether a checkpoint exists for the given session ID. *)
val exists : t -> string -> bool

(** Load the most recently created checkpoint. *)
val latest : t -> (Checkpoint.t, Error.sdk_error) result
