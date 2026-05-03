
(** Dashboard projection for TLA+ specs.

    Enumerates [*.tla] files under {!specs_dir} (env [MASC_SPECS_DIR], default
    ["specs"]) along with their companion [.cfg] files.  Surfaces formal
    verification coverage in the dashboard without re-running TLC.

    Contracts:
    - Read-only scan: {!list_specs} walks at most two directory levels under
      [specs_dir] and performs one [stat] per file.
    - Returns [[]] when [specs_dir] is missing (runtime deployment without the
      repo checked out); {!specs_json} then reports [count = 0] and
      [specs_dir = null].
    - Entries sorted by [(category, name)] for stable dashboard polling.

    @since 0.9.6 *)

type spec_entry = {
  name : string;          (** File stem without extension (e.g. ["CascadeStrategy"]). *)
  path : string;          (** Path relative to [specs_dir] (e.g. ["boundary/CascadeStrategy.tla"]). *)
  category : string;      (** ["boundary"] | ["bug-models"] | ["other"]. *)
  has_clean_cfg : bool;   (** [<name>.cfg] is present next to the [.tla]. *)
  has_buggy_cfg : bool;   (** [<name>-buggy.cfg] is present next to the [.tla]. *)
  mtime : float;          (** Unix timestamp of the [.tla] file. *)
}

val specs_dir : unit -> string
(** Resolved specs directory.  Reads [MASC_SPECS_DIR], falls back to ["specs"]
    (relative to the current working directory). *)

val list_specs : unit -> spec_entry list
(** Enumerate all [.tla] files under {!specs_dir}.  Returns [[]] when the
    directory does not exist.  Sort order: [(category, name)] ascending. *)

val specs_json : unit -> Yojson.Safe.t
(** JSON bundle suitable for [/api/v1/verification/specs].

    Shape:
    {[
      {
        "updated_at": "2026-04-17T00:00:00Z",
        "specs_dir": "/abs/path/to/specs" | null,
        "count": 12,
        "entries": [
          { "name": "CascadeStrategy",
            "path": "boundary/CascadeStrategy.tla",
            "category": "boundary",
            "has_clean_cfg": true,
            "has_buggy_cfg": true,
            "mtime_iso": "2026-04-15T12:34:56Z" }, ...
        ]
      }
    ]}
*)

type tlc_status =
  | Tlc_passed
  | Tlc_violated
  | Tlc_running
  | Tlc_queued
  | Tlc_error
  | Tlc_not_run

type tlc_result_entry = {
  spec_name : string;
  cfg_name : string;
  category : string;
  status : tlc_status;
  states_explored : int option;
  distinct_states : int option;
  diameter : int option;
  last_run_at : float option;
  violation : string option;
  log_path : string option;
}

val tlc_results_dir : unit -> string
(** Directory containing TLC logs. Reads [MASC_TLC_RESULTS_DIR], falling back
    to the host temporary directory. This matches [specs/Makefile], which
    writes logs as [tlc-<cfg-stem>.log]. *)

val list_tlc_results : unit -> tlc_result_entry list
(** Project every discovered clean / buggy cfg to its last observed TLC result.
    Missing logs are reported as [Tlc_not_run]; this function never runs TLC. *)

val tlc_results_json : unit -> Yojson.Safe.t
(** JSON bundle suitable for [/api/v1/verification/tlc-results]. *)
