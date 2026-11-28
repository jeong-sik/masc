(* The [Sqlite3] that masc's own libraries see.

   Every library under lib/ that runs SQL lists masc.sqlite_file instead of
   sqlite3 and opens this module with [-open Masc_sqlite3] in its dune flags.
   [Sqlite3] there is the sqlite3 binding with one change: [db_open] takes no
   [`READONLY] mode, and none of the URI, VFS, cache or mutex options. A
   writer opens with [db_open path] or [db_open ~mode:`NO_CREATE path]; a
   reader opens with [Sqlite_file.open_reader], which decides from the store's
   journal whether READONLY is safe (#36195). A new READONLY open in those
   libraries is a type error, not a review finding.

   The binding itself is a hidden dependency of those libraries
   ([implicit_transitive_deps false]), so the original [Sqlite3.db_open] is
   unreachable from them. A test that builds fixtures with READONLY lists
   sqlite3 itself.

   HIGH-RISK-UNREVIEWED: storage-integrity boundary (#36195); a person reviews
   a change here before it merges. *)

module Sqlite3 = struct
  include Sqlite3

  let db_open ?mode path =
    Sqlite3.db_open
      ?mode:(mode : [ `NO_CREATE ] option :> [ `READONLY | `NO_CREATE ] option)
      path
  ;;
end
