(** One Lane Add-on declaration file: an immediate child of the resolved
    [lane-addons] configuration directory whose name ends in {!suffix}.

    A package Lane is named by its file, not by the [id] written inside it. A
    file that fails to parse can have no readable id, and two files that
    declare the same id are both excluded by the loader
    ([Lane_addon_config.load]); each is still an installation the operator
    saved. *)

type t = private string
(** The file name without {!suffix}. Never empty, never contains ['/']. *)

val suffix : string
(** The suffix every declaration file name carries. *)

val of_file_name : string -> t option
(** [Some] for a file name that ends in {!suffix} and whose name before it
    is accepted by {!of_name}; [None] for anything else. *)

val of_name : string -> t option
(** [Some] for a non-empty name without ['/'], the form a Lane id's wire
    string carries after [package/]; [None] for anything else. *)

val to_string : t -> string
