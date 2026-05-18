(** RFC-0128 §5 Phase 3 — flat-file purge migration.

    Walks the Legacy flat [.masc-ide/{annotations,regions}.jsonl]
    stores and rewrites every record into the canonical-URL bucket
    resolved from its [file_path]. Records whose path cannot be
    assigned to a registered repository go to
    [.masc-ide/_orphan/].

    Idempotent: a second invocation finds an empty Legacy and
    produces a zero-count report. Safe to re-run after partial
    failure.

    Boundaries:
    - depends on [Repo_store.find_repo_by_path_prefix] to resolve
      [file_path] -> repository
    - depends on [Ide_paths.canonical_url_of_remote] to derive the
      slug from [repository.url]
    - does not call [Ide_meta_sync] (PR-1e removed it). *)

type migration_report =
  { annotations_total : int
  ; annotations_to_by_url : int
  ; annotations_to_orphan : int
  ; regions_total : int
  ; regions_to_by_url : int
  ; regions_to_orphan : int
  }

val zero_report : migration_report
(** Zero-count report. Useful as a fold seed or sanity-check baseline. *)

val migrate_flat_to_partitioned
  :  base_path:string
  -> ?dry_run:bool
  -> ?delete_legacy_after:bool
  -> unit
  -> migration_report
(** [migrate_flat_to_partitioned ~base_path ()] reads the Legacy
    flat stores and writes each annotation/region into the
    appropriate partition.

    [base_path] is the project root (the directory that contains
    [.masc/] and [.masc-ide/]); the same value passed to other
    [Repo_store] / [Ide_paths] APIs.

    [?dry_run] (default [false]): when [true], walks the records and
    returns the report without writing to disk or removing the
    Legacy files. Use this to preview the partition split before
    committing a destructive run.

    [?delete_legacy_after] (default [false]): when [true] AND the
    migration completed without raising, the Legacy
    [annotations.jsonl] and [regions.jsonl] are removed once their
    records are safely persisted under the new layout. The caller is
    expected to inspect a [dry_run] report first.

    Returns counts per record kind so the caller can present an
    operator-facing summary or assert in tests. *)
