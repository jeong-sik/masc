(** The registry's advertised default must be the value a fresh runtime uses.

    [Keeper_runtime_setting_registry] restates each setting's default as a
    display string, separately from the module that resolves it. Nothing
    compared the two, and both copies drifted:

    - [MASC_WEB_SEARCH_CACHE_TTL_SEC] was raised from 30 s to 900 s in
      [Env_config_runtime] (the 30 s window expired before a keeper research
      loop could repeat a query inside one turn). The registry kept
      advertising 30.0, so the operator surface named a third of a minute for
      a cache that holds fifteen.
    - [KeeperKeepalive.interval_sec]'s own doc comment said "Default: 30"
      against a resolved 300 — the constant it calls "the foundational timing
      constant" for every keeper cycle, off by 10x.

    These compare the registry row against the module that owns the value, so
    a change to one side without the other fails here rather than reaching an
    operator reading the settings surface.

    Coverage is the settings whose owner is exposed with a resolvable path;
    the rest still restate a literal nothing checks. Extending this list is
    cheaper than the census that found these two. *)

open Alcotest
module Registry = Masc.Keeper_runtime_setting_registry

let find env_name =
  match
    List.find_opt
      (fun (s : Registry.setting) -> String.equal s.env_name env_name)
      Registry.all
  with
  | Some setting -> setting
  | None -> failf "%s is absent from Keeper_runtime_setting_registry.all" env_name
;;

(* Read as the registry displays it: the advertised string, not a parse of it.
   A row that displays "30.0" for a 900.0 value is wrong however it parses. *)
let check_display env_name ~owner =
  let declared = (find env_name).default_display in
  check string (env_name ^ " default matches its owner") owner declared
;;

(* These are read at module initialisation from an unset environment in the
   test process, so each is the default the registry claims to describe. *)
let test_keepalive_defaults_match_their_owner () =
  check_display
    "MASC_KEEPER_HEARTBEAT_INTERVAL_SEC"
    ~owner:(string_of_int Masc.Env_config_keeper.KeeperKeepalive.interval_sec);
  check_display
    "MASC_KEEPER_SLEEP_CHUNK_SEC"
    ~owner:
      (Printf.sprintf "%.1f" Masc.Env_config_keeper.KeeperKeepalive.sleep_chunk_sec);
  check_display
    "MASC_KEEPER_RATE_LIMIT_BACKOFF_CAP_SEC"
    ~owner:
      (Printf.sprintf
         "%.1f"
         Masc.Env_config_keeper.KeeperKeepalive.rate_limit_backoff_cap_sec)
;;

let test_snapshot_default_matches_its_owner () =
  check_display
    "MASC_KEEPER_SNAPSHOT_SEC"
    ~owner:(string_of_int Masc.Env_config_keeper.KeeperRuntime.snapshot_sec)
;;

(* The one that actually drifted. It is a thunk rather than a value, so it
   reads the environment at call time; unset in this process, it returns the
   default the registry row is describing. *)
let test_web_search_cache_ttl_matches_its_owner () =
  check_display
    "MASC_WEB_SEARCH_CACHE_TTL_SEC"
    ~owner:
      (Printf.sprintf
         "%.1f"
         (Masc.Env_config_runtime.Tools.web_search_cache_ttl_sec ()))
;;

let () =
  run
    "Setting registry default parity"
    [ ( "owner_parity"
      , [ test_case
            "keepalive timings match their owner"
            `Quick
            test_keepalive_defaults_match_their_owner
        ; test_case
            "snapshot interval matches its owner"
            `Quick
            test_snapshot_default_matches_its_owner
        ; test_case
            "web search cache ttl matches its owner"
            `Quick
            test_web_search_cache_ttl_matches_its_owner
        ] )
    ]
;;
