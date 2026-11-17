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

type error = Base_path_not_absolute of string

val run : base_path:string -> docker:string -> (report list, error) result
(** One report per package, in {!Lane_addon_carried.all} order. [docker] is
    the Docker command; a name without [/] is looked up on [PATH]. *)

val error_message : error -> string

val report_line : report -> string
(** One line naming the package and what happened to it. *)
