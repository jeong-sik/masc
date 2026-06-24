(** Db_op — typed SQL verb classifier tests (RFC eliminate-substring-
    destructive-classifier §3-A). Asserts the four [sql_destructive] catalogue
    patterns classify Destructive, that reads/mutations do not, and the
    documented edge cases (comments, multi-statement, quoted ';', CTE
    limitation). *)

open Masc_exec

let destructive label sql =
  match Db_op.of_command sql with
  | Ok op -> Alcotest.(check bool) (label ^ " is destructive") true (Db_op.is_destructive op)
  | Error _ -> Alcotest.failf "%s: expected Ok Destructive, got Error" label
;;

let not_destructive label sql =
  match Db_op.of_command sql with
  | Ok op ->
    Alcotest.(check bool) (label ^ " is NOT destructive") false (Db_op.is_destructive op)
  | Error _ -> () (* an unrecognized/empty verb floors nothing — acceptable *)
;;

(* The exact config/destructive_ops.toml sql_destructive catalogue. *)
let test_catalogue_patterns_destructive () =
  destructive "drop table" "drop table users";
  destructive "drop database" "drop database prod";
  destructive "truncate table" "truncate table users";
  destructive "delete from" "delete from users where id = 1"
;;

(* Typed classifier is MORE complete than the substring catalogue. *)
let test_more_complete_than_substring () =
  destructive "drop index" "DROP INDEX idx_users";
  destructive "drop view" "drop view v_active";
  destructive "drop schema" "DROP SCHEMA public CASCADE"
;;

let test_case_and_whitespace_insensitive () =
  destructive "upper" "DROP TABLE users";
  destructive "leading ws" "   \n\t delete   from logs";
  destructive "mixed" "TrUnCaTe TABLE t"
;;

let test_leading_comments_skipped () =
  destructive "line comment" "-- cleanup\nDROP TABLE staging";
  destructive "block comment" "/* migration */ TRUNCATE TABLE cache";
  destructive "comment chain" "  -- a\n  /* b */  delete from q"
;;

let test_multi_statement_strictest_wins () =
  destructive "select; drop" "SELECT 1; DROP TABLE t";
  destructive "insert; truncate" "insert into a values (1); truncate table a";
  not_destructive "select; insert" "SELECT 1; INSERT INTO a VALUES (2)"
;;

(* ';' inside a string literal must not split a statement into a bogus verb. *)
let test_semicolon_in_string_literal () =
  not_destructive "semicolon in value" "INSERT INTO t (s) VALUES ('a;b;c')";
  destructive "literal then drop" "INSERT INTO t VALUES ('x;y'); DROP TABLE t"
;;

let test_reads_and_mutations_not_destructive () =
  not_destructive "select" "select * from users";
  not_destructive "explain" "EXPLAIN ANALYZE SELECT 1";
  not_destructive "insert" "insert into t values (1)";
  not_destructive "update" "update t set x = 1 where id = 2";
  not_destructive "create" "create table t (id int)";
  not_destructive "show" "SHOW TABLES"
;;

(* Documented limitation: a destructive op nested in a leading non-destructive
   statement (CTE) is NOT detected by the leading-verb classifier. This test
   PINS the known gap so a future full-parser upgrade is a visible change, not a
   silent one. *)
let test_cte_nested_destructive_is_known_gap () =
  not_destructive
    "WITH ... DELETE (known leading-verb limitation)"
    "WITH doomed AS (SELECT id FROM t WHERE old) DELETE FROM t USING doomed"
;;

let test_unknown_and_empty () =
  (match Db_op.of_command "" with
   | Error `Empty -> ()
   | _ -> Alcotest.fail "empty SQL should be Error `Empty");
  match Db_op.of_command "FROBNICATE the widgets" with
  | Error (`Unknown_verb v) -> Alcotest.(check string) "unknown verb lowercased" "frobnicate" v
  | _ -> Alcotest.fail "unknown leading verb should be Error `Unknown_verb"
;;

let () =
  Alcotest.run
    "db_op"
    [ ( "classify"
      , [ Alcotest.test_case "catalogue patterns destructive" `Quick test_catalogue_patterns_destructive
        ; Alcotest.test_case "more complete than substring" `Quick test_more_complete_than_substring
        ; Alcotest.test_case "case/whitespace insensitive" `Quick test_case_and_whitespace_insensitive
        ; Alcotest.test_case "leading comments skipped" `Quick test_leading_comments_skipped
        ; Alcotest.test_case "multi-statement strictest wins" `Quick test_multi_statement_strictest_wins
        ; Alcotest.test_case "semicolon in string literal" `Quick test_semicolon_in_string_literal
        ; Alcotest.test_case "reads/mutations not destructive" `Quick test_reads_and_mutations_not_destructive
        ; Alcotest.test_case "CTE nested destructive is known gap" `Quick test_cte_nested_destructive_is_known_gap
        ; Alcotest.test_case "unknown and empty" `Quick test_unknown_and_empty
        ] )
    ]
;;
