open Alcotest

module Json = Yojson.Safe.Util
module Memory_subsystems = Server_dashboard_http_memory_subsystems
module Memory_io = Masc.Keeper_memory_os_io
module Types = Masc.Keeper_memory_os_types

let request target =
  Httpun.Request.create ~headers:(Httpun.Headers.of_list []) `GET target
;;

let check_include target expected =
  check
    bool
    target
    expected
    (Memory_subsystems.dashboard_memory_subsystems_include_entries (request target))
;;

let temp_dir () =
  let path = Filename.temp_file "memory_subsystems_dashboard_test" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path
;;

let rm_rf dir =
  let rec rm path =
    if Sys.file_exists path
    then
      if Sys.is_directory path
      then (
        Sys.readdir path |> Array.iter (fun entry -> rm (Filename.concat path entry));
        Unix.rmdir path)
      else Sys.remove path
  in
  try rm dir with
  | _ -> ()
;;

let test_include_entries_query_param () =
  check_include "/dashboard/memory-subsystems" false;
  check_include "/dashboard/memory-subsystems?include_memory_entries=1" true;
  check_include "/dashboard/memory-subsystems?include_memory_entries=true" true;
  check_include "/dashboard/memory-subsystems?include_memory_entries=yes" true;
  check_include "/dashboard/memory-subsystems?include_memory_entries=y" true;
  check_include "/dashboard/memory-subsystems?include_memory_entries=0" false;
  check_include "/dashboard/memory-subsystems?include_memory_entries=false" false;
  check_include "/dashboard/memory-subsystems?include_memory_entries=no" false;
  check_include "/dashboard/memory-subsystems?include_memory_entries=n" false
;;

let test_focus_entries_enables_memory_entries () =
  check_include "/dashboard/memory-subsystems?focus=entries" true;
  check_include "/dashboard/memory-subsystems?focus=%20entries%20" true;
  check_include "/dashboard/memory-subsystems?focus=episodes" false
;;

let test_http_json_explicitly_disabled_entries_surface () =
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
      let config = Workspace_utils.default_config dir in
      let json =
        Memory_subsystems.dashboard_memory_subsystems_http_json
          ~config
          ~include_memory_entries:false
          (request "/dashboard/memory-subsystems?limit=9999&focus=entries")
      in
      let memory_entries = Json.(json |> member "memory_entries") in
      check int "memory total" 0 Json.(memory_entries |> member "total" |> to_int);
      check
        int
        "memory filtered"
        0
        Json.(memory_entries |> member "filtered" |> to_int);
      check int "memory shown" 0 Json.(memory_entries |> member "shown" |> to_int);
      check int "limit clamped" 500 Json.(memory_entries |> member "limit" |> to_int);
      check
        int
        "items empty"
        0
        Json.(memory_entries |> member "items" |> to_list |> List.length))
;;

let fact ?(category = Types.Preference) ?(trace_id = "trace-user-model")
      ?(turn = 3) ?(first_seen = 10.0) ?last_verified_at claim
  : Types.fact
  =
  { claim
  ; category
  ; external_ref = None
  ; source = { trace_id; turn; tool_call_id = None }
  ; observed_by = []
  ; first_seen
  ; valid_until = None
  ; last_verified_at
  ; schema_version = Types.schema_version
  }
;;

let test_http_json_surfaces_user_model_projection () =
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
      let keepers_dir = Filename.concat dir "keepers" in
      Memory_io.For_testing.with_keepers_dir keepers_dir (fun () ->
        Memory_io.append_fact
          ~keeper_id:"sangsu"
          (fact ~category:Types.Preference ~last_verified_at:20.0
             "User prefers terse operational summaries");
        Memory_io.append_fact
          ~keeper_id:"sangsu"
          (fact ~category:Types.Constraint ~trace_id:"trace-constraint" ~turn:4
             "User requires worktree-first changes");
        Memory_io.append_fact
          ~keeper_id:"sangsu"
          (fact ~category:Types.Fact "The repo uses OCaml");
        let config = Workspace_utils.default_config dir in
        let json =
          Memory_subsystems.dashboard_memory_subsystems_http_json
            ~config
            ~include_memory_entries:false
            (request "/dashboard/memory-subsystems?limit=100")
        in
        let user_model = Json.(json |> member "user_model") in
        check string "schema" "masc.user_model.memory_projection.v1"
          Json.(user_model |> member "schema" |> to_string);
        check int "total" 2 Json.(user_model |> member "total" |> to_int);
        check int "shown" 2 Json.(user_model |> member "shown" |> to_int);
        let items = Json.(user_model |> member "items" |> to_list) in
        let claims =
          items |> List.map (fun item -> Json.(item |> member "claim" |> to_string))
        in
        check
          (list string)
          "preference and constraint only"
          [ "User prefers terse operational summaries"
          ; "User requires worktree-first changes"
          ]
          claims))
;;

let () =
  Eio_main.run @@ fun _env ->
  Alcotest.run
    "server_dashboard_http_memory_subsystems"
    [ ( "request"
      , [ test_case
            "include_memory_entries accepts explicit bool forms"
            `Quick
            test_include_entries_query_param
        ; test_case
            "focus entries enables memory entries"
            `Quick
            test_focus_entries_enables_memory_entries
        ] )
    ; ( "json"
      , [ test_case
            "explicit disabled entries keeps empty surface"
            `Quick
            test_http_json_explicitly_disabled_entries_surface
        ; test_case
            "surfaces user model projection"
            `Quick
            test_http_json_surfaces_user_model_projection
        ] )
    ]
;;
