open Alcotest

(** RFC-0085 PR-7 — Retroactive regression test.

    Original PR-7 (#15468, user-identified legacy) deleted the
    [retired_pg_env_keys] list constant and the [clear_retired_pg_envs]
    function from [lib/server/server_runtime_bootstrap.ml].  The list
    held Postgres env keys (MASC_POSTGRES_URL, DATABASE_URL, ...) that
    were already deprecated; the clearing function was a no-op safety
    net.  User pinpointed: "이거 자체가 ... 안하는거잖아 우리 이거
    레거시임.. 폭파야."

    Shipped without test; pin now so neither symbol can sneak back. *)

let file = "lib/server/server_runtime_bootstrap.ml"

let test_retired_pg_env_keys_gone () =
  let n = Ast_grep.count_value_bindings ~module_path:file ~name:"retired_pg_env_keys" in
  check int "retired_pg_env_keys binding should be deleted" 0 n
;;

let test_clear_retired_pg_envs_gone () =
  let n =
    Ast_grep.count_value_bindings ~module_path:file ~name:"clear_retired_pg_envs"
  in
  check int "clear_retired_pg_envs function should be deleted" 0 n
;;

let test_postgres_env_string_literal_gone () =
  (* The deleted list held "MASC_POSTGRES_URL" as a string literal.
     Verify no lingering reference in this file. *)
  let n =
    Ast_grep.count_string_literals ~module_path:file ~needle:"MASC_POSTGRES_URL"
  in
  check int "MASC_POSTGRES_URL string literal should not survive" 0 n
;;

let () =
  run
    "rfc-0085-pr-7-retired-pg-envs-purge"
    [ ( "deletion"
      , [ test_case
            "retired_pg_env_keys deleted"
            `Quick
            test_retired_pg_env_keys_gone
        ; test_case
            "clear_retired_pg_envs deleted"
            `Quick
            test_clear_retired_pg_envs_gone
        ; test_case
            "MASC_POSTGRES_URL literal gone"
            `Quick
            test_postgres_env_string_literal_gone
        ] )
    ]
;;
