(** [masc exact-addon-setup]: write the Exact worker packages this masc
    carries into the workspace and build their images
    ({!Masc.Exact_addon_setup}).

    With [declared] it installs only the packages the workspace's Lane
    declarations name with [package]. It prints one line per package and one
    per declaration it could not read. The exit code is [0] when every
    package it tried is installed, {!failed_package_exit} when one or more is
    not, and {!refused_exit} when nothing was tried. *)

val failed_package_exit : int
val refused_exit : int

val run : base_path:string -> declared:bool -> int
