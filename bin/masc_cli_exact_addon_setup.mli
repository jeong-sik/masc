(** [masc exact-addon-setup]: write the Exact worker packages this masc
    carries into the workspace and build their images
    ({!Masc.Exact_addon_setup}).

    It prints one line per package. The exit code is [0] when every package
    is installed, {!failed_package_exit} when one or more is not, and
    {!refused_exit} when nothing was tried. *)

val failed_package_exit : int
val refused_exit : int

val run : base_path:string -> int
