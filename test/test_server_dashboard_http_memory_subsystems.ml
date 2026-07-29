open Alcotest

module Json = Yojson.Safe.Util
module Memory_subsystems = Server_dashboard_http_memory_subsystems
module Delegation_request = Masc.Keeper_delegation_request
module Delegation_store = Masc.Keeper_delegation_request_store

let request target =
  Httpun.Request.create ~headers:(Httpun.Headers.of_list []) `GET target
;;

let temp_dir () =
  Filename.temp_dir "memory_subsystems_dashboard_test" ""
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

let test_http_json_surfaces_delegation_requests () =
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
      let config = Workspace_utils.default_config dir in
      let delegation =
        Delegation_request.make ~requester:"planner"
          ~topic:"Review non-dashboard rendering"
          ~reason:"existing channels lose rich blocks"
          ()
      in
      (match Delegation_store.write_request ~base_path:dir delegation with
       | Ok _ -> ()
       | Error msg -> fail msg);
      let json =
        Memory_subsystems.dashboard_memory_subsystems_http_json
          ~config
          (request "/dashboard/memory-subsystems?limit=100")
      in
      let requests = Json.(json |> member "delegation_requests") in
      check int "delegation total" 1 Json.(requests |> member "total" |> to_int);
      check int "delegation shown" 1 Json.(requests |> member "shown" |> to_int);
      check string "delegation index path"
        (Delegation_store.index_path ~base_path:dir)
        Json.(requests |> member "index_path" |> to_string);
      let item =
        match Json.(requests |> member "items" |> to_list) with
        | [ item ] -> item
        | _ -> fail "expected one delegation request"
      in
      check string "delegation id" delegation.id
        Json.(item |> member "id" |> to_string);
      check string "delegation requester" "planner"
        Json.(item |> member "requester" |> to_string);
      check string "task seed suffix" "TASK_SEED.md"
        (Filename.basename Json.(item |> member "task_seed_md_path" |> to_string)))
;;

let () =
  Eio_main.run @@ fun _env ->
  Alcotest.run
    "server_dashboard_http_memory_subsystems"
    [ ( "json"
      , [ test_case
            "surfaces delegation requests"
            `Quick
            test_http_json_surfaces_delegation_requests
        ] )
    ]
;;
