(** One entry for each file or directory, found by the name the file system
    gives it and not by the way a caller spelled its path.

    What is kept in memory about a file, and the lock its writers take,
    belong to the file. Two callers that spell one file in two ways (a
    relative path, a symbolic link on the way, another letter case on a file
    system that folds case) have to reach one entry: with an entry for each
    spelling, a row written through one spelling would leave the other's
    kept value as it was.

    A registry never drops an entry. Their number is bounded by the files the
    process has asked about. *)

type name =
  | Existing of string
      (** Something is at the path. This is the name the file system gives it
          ([realpath]): symbolic links are followed and each piece is the
          directory entry's own name, so on a file system that folds letter
          case [keepers/Alpha] and [keepers/alpha] get one name. Two paths
          are one file exactly when they get the same name. *)
  | Not_yet of string
      (** Nothing is at the path. The nearest ancestor that exists is named
          by the file system and the pieces below it are as spelled. The
          answer can change once the file is made, for example when another
          spelling makes it first. *)

val name : string -> name
(** Ask the file system what it calls an absolute path. This makes system
    calls, one for each piece of the path. *)

type 'a t

val create : (unit -> 'a) -> 'a t
(** A registry whose entries are made by the function, one for each name,
    the first time the name is asked for. The function runs under the
    registry's lock: it must not wait, and it must not raise. *)

(** The entry of a path, and what the answer rests on. *)
type 'a resolved =
  { entry : 'a
  ; existed : bool  (** Whether something was at the path when it was given. *)
  ; removals : int  (** The removals told before it ({!removed}). *)
  }

val resolve : 'a t -> string -> 'a resolved
(** The entry of an absolute path.

    The entry of each spelling whose file existed is remembered: a file that
    exists keeps its name until it is removed, so a spelling costs the system
    calls once and none after that. A spelling whose file does not exist yet
    is asked again each time, because its answer changes when the file is
    made. *)

val another_entry_now : 'a t -> 'a resolved -> string -> 'a option
(** Called after a change of the path's file that was made under
    [resolved.entry]: the entry the path has now, when it is another one.

    A file that did not exist when the entry was chosen was made by the
    change, and another spelling can have made it first under another name; a
    file removed since and made again can have another name too. The change
    then went by the other entry unseen, and the caller forgets what both
    entries keep.

    [None] without asking the file system when the file existed and no
    removal was told since. *)

val removed : 'a t -> unit
(** Files with entries were removed or renamed away by code that did not go
    through {!another_entry_now}. Every remembered name goes: an answer the
    file system gave before a removal is not used after it. Which files went
    is not looked at. The entries stay. *)

val entries : 'a t -> 'a list
(** Every entry there is, in no order. *)

val has_entry : 'a t -> string -> bool
(** Whether the name the file system gives an absolute path has an entry.
    For tests. *)
