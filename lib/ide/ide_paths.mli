(** IDE store path SSOT.

    Centralises the [.masc-ide/] subdirectory name and store path
    construction used by the IDE annotation, region tracker, meta sync,
    and HTTP query modules.

    Replaces the previously scattered [Filename.concat _ ".masc-ide"]
    literal flagged in RFC-0084 §1.7 (Scattered hardcoded default). *)

val store_subdir : string
(** The literal subdirectory name [".masc-ide"]. *)

val store_path : base_dir:string -> string
(** [store_path ~base_dir] returns [base_dir/.masc-ide]. *)
