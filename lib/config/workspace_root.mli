(** The workspace a command runs against, chosen once at its entry point.

    Order (RFC workspace-root-resolution §3.1):
    [--base-path] > [MASC_BASE_PATH] > a current directory holding
    [.masc/config] > the recorded default when it still holds [.masc/config].

    Named values ([Flag], [Environment]) are not required to be a workspace
    yet: [init], [setup] and [start] create one. Inferred values
    ([Current_directory], [Recorded]) are used only when [.masc/config] is a
    directory, because [<home>/.masc] also exists as a user skill location. The
    current directory is not searched upward. *)

type source =
  | Flag
  | Environment
  | Current_directory
  | Recorded of { record : string }

type t = private
  { root : string
        (** Absolute. The realpath when the directory exists; a named root that
            does not exist yet keeps its normalized absolute spelling. *)
  ; requested : string  (** What the flag, variable, cwd or record said. *)
  ; source : source
  }

type recorded =
  | No_record
  | Record of { record : string; path : string }

(** Everything [resolve] reads. [observe] fills it from the process; a test
    builds one directly. *)
type observation =
  { flag : string option
  ; environment : string option
  ; cwd : string option
  ; recorded : recorded
  ; is_workspace : string -> bool
  ; realpath : string -> string option
  }

type error =
  | No_workspace of
      { cwd : string option
      ; stale_record : (string * string) option
            (** [(record file, path it names)] when a record exists but its path
                is relative or holds no [.masc/config]. *)
      }

val resolve : observation -> (t, error) result
(** Pure. Blank flag or variable values count as absent. *)

val observe : flag:string option -> unit -> observation
(** Reads [MASC_BASE_PATH], the process cwd and the default-base-path record. A
    test executable does not read the operator's record
    ({!Env_config_core.persisted_default_base_path}). *)

val resolve_current : flag:string option -> (t, error) result
(** [resolve (observe ~flag ())]. *)

val source_label : source -> string
(** Observational label for diagnostics ([MASC_BASE_PATH_RESOLUTION_SOURCE]). *)

val error_message : error -> string
