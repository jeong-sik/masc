(** The one way masc opens a SQLite file to read it, and the journal mode its
    writer sets.

    A store names its file once, as a value of {!t}. Its writer sets that
    journal with {!set_journal}; its readers open with {!open_reader}. A store
    that changes its journal therefore changes how its readers open, too.

    HIGH-RISK-UNREVIEWED: storage-integrity boundary (#36195); a person reviews
    a change here before it merges. *)

(** How a store that masc writes journals its transactions. *)
type journal =
  | Wal  (** [PRAGMA journal_mode=WAL]. *)
  | Delete  (** Rollback journal: [PRAGMA journal_mode=DELETE]. *)

(** Who writes the file a reader opens. *)
type t =
  | Owned of journal
      (** masc writes this file, from this process, with this journal. *)
  | External
      (** Another program writes this file. masc only reads it. *)

(** Why {!set_journal} did not leave the file in the requested mode. *)
type journal_error =
  | Journal_pragma_failed of string
      (** SQLite could not run [PRAGMA journal_mode]. *)
  | Journal_kept of { requested : journal; reply : string }
      (** SQLite ran the pragma and answered with another mode. The pragma
          answers with the mode in force instead of failing, for example on a
          file system without shared memory for WAL. *)

val journal_error_to_string : journal_error -> string

val set_journal : Sqlite3.db -> journal -> (unit, journal_error) result
(** On a writer connection, runs [PRAGMA journal_mode] for [journal] and reads
    SQLite's reply. [Ok ()] only when the reply names [journal]. Call it outside
    a transaction: SQLite refuses to change the mode inside one. *)

val open_reader : t -> string -> (Sqlite3.db, string) result
(** Opens the existing file at the path to read it. A missing file is an
    error; it is never created.

    - [Owned Delete] opens the file read-write and sets [PRAGMA query_only=1].
      It never opens it READONLY. With the macOS system SQLite
      (/usr/lib/libsqlite3, 3.54.0), a READONLY connection that took the
      file's shared lock first makes another connection of this process fail
      to take the write lock: the lock call fails with EBADF, and SQLite
      reports SQLITE_IOERR_LOCK (3850). The Owner then fenced its chat store
      (#36195). query_only refuses every write through this connection. A hot
      journal left by a crash is rolled back here, as the writer's next open
      would do.
    - [Owned Wal] opens READONLY. In WAL mode the same interleaving did not
      fail.
    - [External] opens READONLY. masc never writes the file, so it must not
      roll back or checkpoint another program's journal, and a lock held by
      another process is reported as BUSY, not 3850.

    Every reader waits for a writer's lock up to 5000 ms ([busy_timeout])
    before it reports BUSY. When a setup step fails the handle is closed and
    the error names the step. Otherwise the caller closes the handle. *)
