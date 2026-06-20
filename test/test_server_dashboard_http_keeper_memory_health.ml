(** Regression tests for the keeper memory-health dashboard helper. *)

module Types = Masc.Keeper_memory_os_types
module Io = Masc.Keeper_memory_os_io
module Health = Masc.Server_dashboard_http_keeper_memory_health

let fresh_dir prefix =
  let path = Filename.temp_file prefix ".dir" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path
;;

let fact ~now claim =
  { Types.claim
  ; Types.category = Types.Fact
  ; Types.external_ref = None
  ; Types.source = { Types.trace_id = "health-test"; Types.turn = 1; Types.tool_call_id = None }
  ; Types.observed_by = []
  ; Types.first_seen = now
  ; Types.valid_until = None
  ; Types.last_verified_at = Some now
  ; Types.schema_version = Types.schema_version
  }
;;

let keeper_ids json =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "keepers" fields with
     | Some (`List keepers) ->
       List.filter_map
         (function
           | `Assoc keeper_fields ->
             (match List.assoc_opt "keeper_id" keeper_fields with
              | Some (`String id) -> Some id
              | _ -> None)
           | _ -> None)
         keepers
     | _ -> [])
  | _ -> []
;;

let with_env name value f =
  let old = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv name (Option.value old ~default:"");
      Config_dir_resolver.reset ())
    f
;;

let test_uses_explicit_base_path_not_ambient_resolver () =
  Eio_main.run
  @@ fun _env ->
  let now = 1_700_000_000.0 in
  let target_base = fresh_dir "masc-memory-health-target" in
  let ambient_base = fresh_dir "masc-memory-health-ambient" in
  let target_keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:target_base
  in
  let ambient_keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:ambient_base
  in
  Io.rewrite_facts_atomically
    ~keepers_dir:target_keepers_dir
    ~keeper_id:"target"
    [ fact ~now "target workspace fact" ];
  Io.rewrite_facts_atomically
    ~keepers_dir:ambient_keepers_dir
    ~keeper_id:"ambient"
    [ fact ~now "ambient workspace fact" ];
  with_env "MASC_BASE_PATH" ambient_base (fun () ->
    let json = Health.keeper_memory_health_http_json ~base_path:target_base in
    Alcotest.(check (list string)) "explicit base-path keeper ids" [ "target" ] (keeper_ids json))
;;

let () =
  Alcotest.run
    "server_dashboard_http_keeper_memory_health"
    [ ( "paths"
      , [ Alcotest.test_case
            "uses explicit request base path instead of ambient resolver"
            `Quick
            test_uses_explicit_base_path_not_ambient_resolver
        ] )
    ]
