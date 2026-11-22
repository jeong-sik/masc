(** The Exact worker packages this server carries (RFC
    server-carries-its-exact-worker-packages 3.1 and 3.2).

    A declaration names one with [package = "<name>"]. The server resolves it
    to the folder [<packages>/<name>-<revision>], and attaches it only when
    that folder holds exactly the files this binary carries. A server build
    and the packages it carries come from one commit, so they speak the same
    Exact protocol. *)

type id = Candle_appraiser | Hitl_auto_judge

val all : id list

val name : id -> string
(** The package id its manifest declares, such as [hitl-auto-judge]. *)

val of_name : string -> id option

type file = { path : string; contents : string }
(** [path] is relative to the package folder and uses [/] between segments. *)

val package_files : id -> file list
(** The carried package in path order: every [.toml], [.json] and [.py] file
    under it and its [Dockerfile]. *)

val shared_files : file list
(** [exact_worker.py] and [protocol.py] in path order. Every carried image
    copies them beside the package (see the package's [Dockerfile]). *)

val revision : id -> (string, string) result
(** The [revision] of the carried manifest. It names the installed folder,
    so a revision that is not one path segment is refused. *)

val folder : packages:string -> id -> (string, string) result
(** [<packages>/<name>-<revision>]. *)

type installation_error =
  | Not_installed of { folder : string }
  | Differs of { folder : string; detail : string }
      (** The folder exists and holds other files or other bytes. *)
  | Carried_package_invalid of string
      (** This binary's own copy has no usable revision. *)

val installed_manifest : packages:string -> id -> (string, installation_error) result
(** The [lane.toml] path in {!folder} when the folder holds the carried
    package files with the same bytes and nothing else. A symbolic link or
    other non-regular entry in the folder makes it differ. *)

val installation_error_to_string : id -> installation_error -> string

(** {1 Installing}

    [masc exact-addon-setup] writes each folder and builds each image (RFC
    3.3). The image holds only the shared modules; the worker reads the
    package's own files from its folder, mounted at [/addon]. *)

type folder_outcome =
  | Written  (** The folder did not exist; this call wrote it. *)
  | Already_installed  (** The folder already held the carried files. *)

type install_error =
  | Folder_differs of { folder : string; detail : string }
      (** The folder holds other files. It is never rewritten: a worker can
          have it mounted, and the same revision name with other contents
          means one of the two is not this server's package. *)
  | Folder_unwritable of { folder : string; reason : string }
  | No_usable_revision of string

val install : packages:string -> id -> (string * folder_outcome, install_error) result
(** Write {!folder} when it does not exist: the files go into a folder beside
    it, which is then renamed into place, so a half-written folder never has
    the package's name. The answer is the folder's [lane.toml] path. *)

val install_error_to_string : id -> install_error -> string

val image_label : string
(** The image label that holds {!image_digest}. *)

val image_inputs : id -> file list
(** What the package's image is built from, laid out as its build context,
    in path order: its [Dockerfile] and {!shared_files}. *)

val image_digest : id -> string
(** SHA-256 of {!image_inputs}: each path, the length of its bytes, and the
    bytes. *)
