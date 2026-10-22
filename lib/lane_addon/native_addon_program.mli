(** The host programs native Add-ons run through, and how MASC finds them.

    The server starts native workers with these programs, and
    [masc browser-lane-setup] reports which of them it finds, so both read the
    names and the lookup here. *)

type t =
  | Launcher  (** Starts every native Add-on worker inside its admission. *)
  | Browser_process_owner  (** Owns the browsers a browser Add-on starts. *)

val all : t list
(** Every program, in declaration order. *)

val name : t -> string
(** The executable name, e.g. ["masc-native-addon-launcher"]. *)

val locate : t -> (string, string) result
(** The real path of the first executable [name] beside the running MASC
    executable (its real path, then the path it was started as), then on
    [PATH]. [Error] names the program when it is in none of those places. *)

val command_ready : package_directory:string -> string -> bool
(** Whether a package's worker command can be started: a relative command
    containing [/] is read from [package_directory]; any other is looked up
    as a command on [PATH]. *)
