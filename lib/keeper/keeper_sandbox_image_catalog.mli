(** Which image a Keeper's [sandbox_image] name means on this host.

    A Keeper names an image by a short name ([base], [ocaml]). The catalog
    repository's [config/sandbox-images.toml] supplies the names. The host's
    [sandbox-image-builds.toml] stores only promoted builds: for each name and image
    store, the one tag that name starts from. A registry is not involved.

    {v
    [images.ocaml.apple_container]      # built and promoted on this host
    reference = "masc-sandbox-ocaml:20260924T1130Z-3f9a1c07"
    v}

    [masc sandbox-image] refuses a tag its store already has, so a build it
    makes arrives under a new reference, and the runtime tells a running
    guest apart from the promoted build by reference alone. A tag moved to
    other content outside masc (the image removed and rebuilt, [docker tag],
    [msb load]) goes unnoticed: the catalog records no content identity.
    Going back is a promote of an earlier tag the store still has.

    RFC keeper-sandbox-images-have-versions (#38699) §2.3. Parsing is strict:
    an unknown key or a store this runtime does not know is an error, not a
    default. *)

type store =
  | Docker_daemon
  | Microvm of Keeper_microvm_backend.t
      (** Each microVM runtime keeps an image store of its own. *)

val store_to_string : store -> string
(** ["docker"], or the backend's own spelling ([apple_container], …). *)

val store_of_string : string -> store option

type pinned = private
  { reference : string
        (** [repository:tag]: a tag after the last [':'], only characters
            that need no quoting, never a digest reference and never
            starting with ['-']. *)
  }
(** Only {!parse} and {!promote} make one, so a [pinned] is always valid. *)

val is_name : string -> bool
(** Whether a string is a catalog name: words of lowercase letters and digits
    joined by single ['-'], the directory names under [sandbox-images/]. *)

val name_error : field:string -> string -> string option
(** [None] for a catalog name; otherwise why [value], read from [field], is
    not one. A Keeper names its image by catalog name, so a tag here (it has a
    [':']) is refused where it is read rather than looked up and missed. *)

val is_reference : string -> bool
(** Whether a string is a [repository:tag] {!pinned} accepts. A caller that
    hands a reference to an image store's CLI checks it first, so a value
    shaped like a flag never reaches that argv. *)

type entry =
  { name : string
  ; promoted : (store * pinned) list  (** Empty until this host builds one. *)
  }

type t

val entries : t -> entry list
(** Shipped names in file order. Host builds for names removed from the shipped
    catalog are excluded. *)

val orphaned_builds : t -> entry list
(** Host builds whose names are no longer shipped. They cannot resolve or be
    promoted, but are retained on save so a catalog update cannot erase them.
    Operators can inspect and remove the stale entries deliberately. *)

type parse_error =
  | Toml_syntax of string
  | Expected_table of { path : string list }
  | Unknown_key of { path : string list; key : string }
  | Invalid_name of string
  | Unknown_store of { image : string; store : string }
  | Missing_field of { path : string list; field : string }
  | Expected_string of { path : string list; field : string }
  | Invalid_reference of { path : string list; value : string }
      (** Not [repository:tag] as {!pinned} describes it. *)
  | Shipped_build of { name : string }
  | Host_name_without_build of { name : string }

val parse_error_to_string : parse_error -> string

val parse : string -> (t, parse_error) result

type resolution =
  | Resolved of pinned
  | Unknown_image of { name : string; known : string list }
      (** The catalog has no such name. [known] lists the names it has. *)
  | Not_built_on_host of { name : string; store : store }
      (** The name exists, and nothing has been promoted for this store. *)

val resolve : t -> name:string -> store:store -> resolution

val shipped_file_name : string
(** ["sandbox-images.toml"]: the image names, embedded from [config/] and read
    from the binary. *)

val file_name : string
(** ["sandbox-image-builds.toml"], directly under the config root: this
    host's promoted builds. A different name from {!shipped_file_name}, so the
    config root's copy of the shipped names never stands where the builds
    file is read. *)

type load_error =
  | Unreadable of { path : string; detail : string }
  | Invalid of { path : string; error : parse_error }

val load_error_to_string : load_error -> string

val load : config_root:string -> shipped:string -> (t, load_error) result
(** Read names from [shipped] on every load, and promotions from the host
    file when it exists. Host builds for names no longer shipped are retained
    as {!orphaned_builds}; builds in [shipped] fail. *)

type snapshot
(** The catalog file's bytes as they were read, or its absence. {!save}
    compares against it. *)

val load_for_change :
  config_root:string -> shipped:string -> (t * snapshot, load_error) result
(** Read shipped names and host builds together, returning the host-file
    snapshot for compare-and-replace. If the host has not saved a build yet,
    the snapshot is absent. *)

(** {1 Changing what a name means on this host} *)

type change_error =
  | No_such_image of { name : string; known : string list }
  | Invalid_pin of parse_error

val change_error_to_string : change_error -> string

val promote :
  t -> name:string -> store:store -> reference:string -> (t, change_error) result
(** Make [reference] the build [name] starts from on [store], in place of
    the one it had. Promoting the current build again changes nothing, and
    promoting an earlier tag is how a name goes back to it. The name must
    already be in the catalog: names come from the repository, builds from
    the host. Whether [store] holds [reference] is the caller's question;
    the catalog cannot ask a store. *)

val to_toml : t -> string
(** The host file, containing only promoted store tables. Unbuilt names are
    supplied by [shipped] during {!load}. *)

type save_error =
  | Changed_since_read of { path : string }
      (** Another writer changed the file after [expected] was read. Nothing
          was written. *)
  | Unwritable of { path : string; detail : string }
      (** The target was not replaced. *)
  | Written_but_durability_unconfirmed of { path : string; detail : string }
      (** Rename happened but parent sync failed. Inspect the file before a
          retry, especially before another promote. *)
  | Saved_but_unlock_failed of { path : string; detail : string }
      (** The new catalog was written. Lock release failed afterward; inspect
          the file before retrying, particularly before another promote. *)

val save_error_to_string : save_error -> string

val save : config_root:string -> expected:snapshot -> t -> (unit, save_error) result
(** Replace the file with {!to_toml} atomically (payload sync, rename, then
    parent-directory sync), but
    only if it still holds what [expected] read. A process lock covers the
    comparison and replacement, so concurrent writers cannot both pass the
    same expected snapshot. *)

module For_testing : sig
  val save_with :
    write:(string -> string -> (unit, Fs_compat.atomic_replace_failure) result) ->
    config_root:string -> expected:snapshot -> t -> (unit, save_error) result
end
