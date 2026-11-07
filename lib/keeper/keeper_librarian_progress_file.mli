(** The file both Librarian progress stores share
    ({!Keeper_librarian_progress}, {!Keeper_librarian_official_progress}): one
    JSON object per keeper, read whole and replaced atomically.

    A store owns its path, its codec and its [subject], the phrase its error
    messages begin with. This module owns what happens around the bytes: the
    error types, the read of a file that may be absent, and the atomic
    replace. *)

type read_error =
  | Unreadable of
      { path : string
      ; message : string
      }
  | Not_json of
      { path : string
      ; message : string
      }
  | Malformed of
      { path : string
      ; error : Keeper_memory_os_types.wire_error
      }

type write_error =
  | Invalid_progress of Keeper_memory_os_types.wire_error
  | Write_failed of
      { path : string
      ; message : string
      }

val read_error_to_string : subject:string -> read_error -> string
val write_error_to_string : subject:string -> write_error -> string

(** [Ok None] when there is no file. A file that exists but cannot be read or
    decoded is an [Error]; it is never taken as "no file". *)
val read :
  path:string ->
  of_json:(Yojson.Safe.t -> ('a, Keeper_memory_os_types.wire_error) result) ->
  ('a option, read_error) result

(** Checks the value with [validate], creates the parent directory, and
    replaces the file ({!Fs_compat.save_file_atomic_strict}). A value
    [validate] refuses is not written. *)
val write :
  path:string ->
  validate:('a -> ('a, Keeper_memory_os_types.wire_error) result) ->
  to_json:('a -> Yojson.Safe.t) ->
  'a ->
  (unit, write_error) result
