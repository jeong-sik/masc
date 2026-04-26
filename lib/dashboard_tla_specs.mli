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

type spec_entry =
  { name : string (** File stem without extension (e.g. ["CascadeStrategy"]). *)
  ; path : string
    (** Path relative to [specs_dir] (e.g. ["boundary/CascadeStrategy.tla"]). *)
  ; category : string (** ["boundary"] | ["bug-models"] | ["other"]. *)
  ; has_clean_cfg : bool (** [<name>.cfg] is present next to the [.tla]. *)
  ; has_buggy_cfg : bool (** [<name>-buggy.cfg] is present next to the [.tla]. *)
  ; mtime : float (** Unix timestamp of the [.tla] file. *)
  }

(** Resolved specs directory.  Reads [MASC_SPECS_DIR], falls back to ["specs"]
    (relative to the current working directory). *)
val specs_dir : unit -> string

(** Enumerate all [.tla] files under {!specs_dir}.  Returns [[]] when the
    directory does not exist.  Sort order: [(category, name)] ascending. *)
val list_specs : unit -> spec_entry list

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
val specs_json : unit -> Yojson.Safe.t
