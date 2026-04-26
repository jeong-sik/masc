(** Diagnose runtime base-path facts with a single authoritative [.masc] root.

    The runtime no longer treats a cwd-local [.masc] tree as a second live
    authority. Cwd-relative fields remain {b observational only} so health
    and startup payloads can explain where the process was launched from
    without reviving stale-path warnings or abort paths. *)

(** {1 Diagnostic record}

    All fields are observed at detection time; the record is immutable. *)
type t =
  { process_cwd : string
  ; input_base_path : string option
  ; effective_base_path : string
  ; effective_masc_root : string
  ; env_masc_base_path : string option
  ; resolution_source : string option
  ; effective_has_masc_dir : bool
  ; effective_legacy_dirs : string list
    (** Subset of {["perpetual"; "resident-keepers"; "rooms"]} present
          under [effective_masc_root]. *)
  ; roots_diverge : bool
    (** [true] when the normalised process cwd differs from
          [effective_base_path]. *)
  ; strict_mode_requested : bool
  ; startup_rejected : bool
  ; startup_abort_eligible : bool
  ; warning : string option
  }

(** {1 Detection} *)

(** [detect ?cwd ?env_masc_base_path ?strict ?input_base_path
    ?resolution_source ~effective_base_path ~effective_masc_root ()]
    observes paths from disk + env and returns a populated {!t}.

    - [cwd] defaults to [Sys.getcwd ()].
    - [strict] defaults to the [MASC_BASE_PATH_STRICT] env flag
      (accepts [1|true|yes]).
    - [resolution_source] falls back to
      [MASC_BASE_PATH_RESOLUTION_SOURCE] env var.

    All paths are normalised through [Unix.realpath] with best-effort
    fallback to the absolute form. *)
val detect
  :  ?cwd:string
  -> ?env_masc_base_path:string
  -> ?strict:bool
  -> ?input_base_path:string
  -> ?resolution_source:string
  -> effective_base_path:string
  -> effective_masc_root:string
  -> unit
  -> t

(** Reserved for future strict-mode enforcement; currently always [false]. *)
val strict_violation : t -> bool

(** {1 Reporting} *)

(** Multi-line startup output suitable for [Log.Server.info] — skips
    fields that are [None] or uninformative. *)
val startup_lines : t -> string list

(** Emit [diag.warning] once per process lifetime at WARN (or DEBUG
    after the first call). No-op when [warning = None]. *)
val log_startup_warning : t -> unit

(** JSON serialisation including [strict_violation]. Option fields are
    omitted when [None] (not emitted as [null]). *)
val to_yojson : t -> Yojson.Safe.t
