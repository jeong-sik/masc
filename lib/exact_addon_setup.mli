(** [masc exact-addon-setup]: install the Exact worker packages this masc
    carries (RFC server-carries-its-exact-worker-packages 3.3).

    For each package in {!Lane_addon_carried.all} it writes
    [<base>/.masc/packages/<name>-<revision>/] when that folder does not exist
    ({!Lane_addon_carried.install}). It then builds the Docker image the
    package's manifest names from {!Lane_addon_carried.image_inputs}, with
    {!Lane_addon_carried.image_digest} as its {!Lane_addon_carried.image_label}
    label. An image that already holds that label is not built again.

    It writes no declaration and starts nothing. A declaration uses a package
    with [package = "<name>"]. A package that fails does not stop the others. *)

type scope =
  | Every_carried
  | Declared
      (** Only the packages the workspace's Lane declarations name with
          [package] ({!Lane_addon_config.declared_carried}). A workspace
          without a config root declares none. *)

type image_outcome =
  | Built
  | Already_built  (** The image already held the label of these inputs. *)

type installed = {
  manifest_path : string;
  folder : Lane_addon_carried.folder_outcome;
  image : string;  (** The image the manifest names. *)
  image_outcome : image_outcome;
}

type failure =
  | Folder of Lane_addon_carried.install_error
  | Manifest_unloadable of { path : string; reason : string }
  | Image_not_built of { image : string; reason : string }

type report = { package : Lane_addon_carried.id; result : (installed, failure) result }

type outcome = {
  reports : report list;  (** One per package [scope] selects, in {!Lane_addon_carried.all} order. *)
  unread : Lane_addon_config.issue list;
      (** With [Declared], the declarations whose package choice was not read. *)
}

type error =
  | Base_path_not_absolute of string
  | Config_root_invalid of string

val run : base_path:string -> docker:string -> scope:scope -> (outcome, error) result
(** [docker] is the Docker command; a name without [/] is looked up on [PATH]. *)

val error_message : error -> string

val report_line : report -> string
(** One line naming the package and what happened to it. *)

val unread_line : Lane_addon_config.issue -> string
