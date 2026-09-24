(** Which image a Keeper's [sandbox_image] name means on this host.

    A Keeper names an image by a short name ([base], [ocaml]). The catalog
    file [sandbox-images.toml] in the config root says, for each name and
    each image store, which build is current: its tag and its digest, plus
    the one it replaced. The repository ships the names with no builds; a
    host fills in what it has built, so the catalog is per host. A registry
    is not involved, and a digest is only true where that image was built.

    {v
    [images.base]                       # a name, nothing built here yet

    [images.ocaml.apple_container]      # built and promoted on this host
    reference = "masc-sandbox-ocaml:20260924T1130Z-3f9a1c07"
    digest    = "sha256:…"
    previous  = { reference = "…", digest = "sha256:…" }
    v}

    RFC keeper-sandbox-images-have-versions (#38699) §2.3. Parsing is strict:
    an unknown key, a store this runtime does not know, or a malformed digest
    is an error, not a default. *)

type store =
  | Docker_daemon
  | Microvm of Keeper_microvm_backend.t
      (** Each microVM runtime keeps an image store of its own. *)

val store_to_string : store -> string
(** ["docker"], or the backend's own spelling ([apple_container], …). *)

val store_of_string : string -> store option

type pinned =
  { reference : string  (** [name:tag], as the store lists it. *)
  ; digest : string  (** [sha256:<64 lowercase hex>], the image index digest. *)
  }

type promotion =
  { current : pinned
  ; previous : pinned option  (** What [current] replaced, kept for a rollback. *)
  }

type entry =
  { name : string
  ; promoted : (store * promotion) list  (** Empty until this host builds one. *)
  }

type t

val entries : t -> entry list
(** In file order. *)

type parse_error =
  | Toml_syntax of string
  | Expected_table of { path : string list }
  | Unknown_key of { path : string list; key : string }
  | Invalid_name of string
  | Unknown_store of { image : string; store : string }
  | Missing_field of { path : string list; field : string }
  | Expected_string of { path : string list; field : string }
  | Invalid_digest of { path : string list; value : string }
  | Invalid_reference of { path : string list; value : string }
      (** Empty, or a character outside [A-Z a-z 0-9 . _ / : @ -]. *)

val parse_error_to_string : parse_error -> string

val parse : string -> (t, parse_error) result

type resolution =
  | Resolved of pinned
  | Unknown_image of { name : string; known : string list }
      (** The catalog has no such name. [known] lists the names it has. *)
  | Not_built_on_host of { name : string; store : store }
      (** The name exists, and nothing has been promoted for this store. *)

val resolve : t -> name:string -> store:store -> resolution

val file_name : string
(** ["sandbox-images.toml"], directly under the config root. *)

type load_error =
  | Missing of { path : string }
  | Unreadable of { path : string; detail : string }
  | Invalid of { path : string; error : parse_error }

val load_error_to_string : load_error -> string

val load : config_root:string -> (t, load_error) result

val load_or_shipped :
  config_root:string -> shipped:string option -> (t, load_error) result
(** The host's catalog, or, when this host has not written one yet, the
    [shipped] text: the copy of [config/sandbox-images.toml] the binary
    carries. A host's own file is never merged with the shipped one. *)

(** {1 Changing what a name means on this host} *)

type change_error =
  | No_such_image of { name : string; known : string list }
  | Invalid_pin of parse_error
  | Nothing_to_roll_back of { name : string; store : store }

val change_error_to_string : change_error -> string

val promote :
  t -> name:string -> store:store -> reference:string -> digest:string ->
  (t, change_error) result
(** Make [reference]/[digest] the current build of [name] for [store], and
    keep the build it replaces as [previous]. Promoting the current build
    again changes nothing. The name must already be in the catalog: names
    come from the repository, builds from the host. *)

val rollback : t -> name:string -> store:store -> (t, change_error) result
(** Swap the current build with [previous]. A second rollback undoes the
    first. *)

val to_toml : t -> string
(** The catalog as the file {!parse} reads, names in order, one table per
    promoted store. {!parse} of the result gives back the same catalog. *)

type save_error = Unwritable of { path : string; detail : string }

val save_error_to_string : save_error -> string

val save : config_root:string -> t -> (unit, save_error) result
(** Write {!to_toml} beside the file and rename it into place, so a reader
    never sees half a catalog. *)
