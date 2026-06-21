(** Verifies [Server_auth.record_dashboard_actor_fallback] keeps its warn-log
    dedup table bounded under an unbounded stream of distinct token-hash
    prefixes (the memory-growth scenario for stale/rotated client tokens). *)

open Alcotest

let test_warn_log_table_bounded () =
  Eio_main.run @@ fun _env ->
  let cap = Server_auth.stale_token_warn_log_max_entries in
  let inserted = cap + 500 in
  for i = 1 to inserted do
    Server_auth.record_dashboard_actor_fallback
      { Masc.Auth_error_kind.outcome = Masc.Auth_error_kind.Outcome_none
      ; token_hash_prefix = Printf.sprintf "prefix-%d" i
      }
  done;
  let count = Server_auth.stale_token_warn_log_entry_count () in
  check bool "table stays at or below the cap" true (count <= cap);
  (* If the evict call were missing the table would hold all [inserted]
     distinct prefixes; assert eviction actually fired. *)
  check bool "eviction happened (not unbounded)" true (count < inserted)

let () =
  run "server_auth_warn_log_bound"
    [ ( "dedup_table"
      , [ test_case "bounded under distinct-prefix churn" `Quick
            test_warn_log_table_bounded
        ] )
    ]
