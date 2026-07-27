open Alcotest

module Floor = Masc.Keeper_shutdown_generation_floor

let rec remove_tree path =
  match Unix.lstat path with
  | stat ->
    (match stat.Unix.st_kind with
     | Unix.S_DIR ->
       Sys.readdir path
       |> Array.iter (fun leaf -> remove_tree (Filename.concat path leaf));
       Unix.rmdir path
     | _ -> Unix.unlink path)
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let with_base prefix fn =
  let base_path = Filename.temp_file prefix ".tmp" in
  Sys.remove base_path;
  Unix.mkdir base_path 0o700;
  Unix.mkdir (Filename.concat base_path ".masc") 0o700;
  Fun.protect ~finally:(fun () -> remove_tree base_path) (fun () -> fn base_path)
;;

let require_ok = function
  | Ok value -> value
  | Error error -> fail (Floor.error_to_string error)
;;

let save_raw path content =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () ->
       output_string channel content;
       close_out channel);
  Unix.chmod path 0o600
;;

let floor_path config ~keeper_id =
  Filename.concat
    (Floor.For_testing.root_path config)
    (Floor.For_testing.authority_leaf ~keeper_id)
;;

let test_missing_is_no_evidence () =
  with_base "masc_shutdown_floor_missing_" @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  match Floor.point_read config ~keeper_id:"keeper-a" () with
  | Ok None -> ()
  | Ok (Some floor) ->
    failf "missing floor returned generation %Ld" (Floor.generation floor)
  | Error error -> fail (Floor.error_to_string error)
;;

let test_monotonic_point_read () =
  with_base "masc_shutdown_floor_monotonic_" @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let first =
    Floor.record_exact config ~keeper_id:"keeper-a" ~generation:7L ()
    |> require_ok
  in
  let lower =
    Floor.record_exact config ~keeper_id:"keeper-a" ~generation:4L ()
    |> require_ok
  in
  let higher =
    Floor.record_exact config ~keeper_id:"keeper-a" ~generation:9L ()
    |> require_ok
  in
  check int64 "first floor" 7L (Floor.generation first);
  check int64 "lower record cannot regress" 7L (Floor.generation lower);
  check int64 "higher record advances" 9L (Floor.generation higher);
  match Floor.point_read config ~keeper_id:"keeper-a" () |> require_ok with
  | Some observed -> check int64 "point-read floor" 9L (Floor.generation observed)
  | None -> fail "recorded floor disappeared"
;;

let test_concurrent_records_converge_to_max () =
  with_base "masc_shutdown_floor_concurrent_" @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  Eio.Fiber.both
    (fun () ->
      ignore
        (Floor.record_exact config ~keeper_id:"keeper-a" ~generation:7L ()
         |> require_ok))
    (fun () ->
      ignore
        (Floor.record_exact config ~keeper_id:"keeper-a" ~generation:9L ()
         |> require_ok));
  match Floor.point_read config ~keeper_id:"keeper-a" () |> require_ok with
  | Some observed -> check int64 "maximum floor wins" 9L (Floor.generation observed)
  | None -> fail "concurrent floor disappeared"
;;

let test_malformed_current_fails_closed () =
  with_base "masc_shutdown_floor_invalid_" @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  ignore
    (Floor.record_exact config ~keeper_id:"keeper-a" ~generation:7L ()
     |> require_ok);
  save_raw
    (floor_path config ~keeper_id:"keeper-a")
    {|{"schema":"not-current","keeper_id":"keeper-a","generation":7,"checksum_sha256":"0"}|};
  match Floor.point_read config ~keeper_id:"keeper-a" () with
  | Error (Floor.Invalid_current _) -> ()
  | Error error -> failf "unexpected invalid-current error: %s" (Floor.error_to_string error)
  | Ok _ -> fail "malformed current evidence was accepted"
;;

let test_cluster_roots_are_independent () =
  with_base "masc_shutdown_floor_cluster_" @@ fun base_path ->
  let default_config = Masc.Workspace.default_config base_path in
  let cluster_config =
    { default_config with
      backend_config =
        { default_config.backend_config with cluster_name = "cluster-b" }
    }
  in
  ignore (Masc.Workspace.init default_config ~agent_name:None);
  ignore (Masc.Workspace.init cluster_config ~agent_name:None);
  ignore
    (Floor.record_exact
       default_config
       ~keeper_id:"keeper-a"
       ~generation:9L
       ()
     |> require_ok);
  (match Floor.point_read cluster_config ~keeper_id:"keeper-a" () |> require_ok with
   | None -> ()
   | Some observed ->
     failf
       "foreign cluster observed generation %Ld"
       (Floor.generation observed));
  ignore
    (Floor.record_exact
       cluster_config
       ~keeper_id:"keeper-a"
       ~generation:3L
       ()
     |> require_ok);
  let observed config =
    match Floor.point_read config ~keeper_id:"keeper-a" () |> require_ok with
    | Some floor -> Floor.generation floor
    | None -> fail "recorded cluster floor disappeared"
  in
  check int64 "default cluster floor" 9L (observed default_config);
  check int64 "named cluster floor" 3L (observed cluster_config)
;;

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Floor.For_testing.with_fd_backed_parent_opening @@ fun () ->
  run
    "keeper shutdown generation floor"
    [ ( "current schema"
      , [ test_case "missing is no evidence" `Quick test_missing_is_no_evidence
        ; test_case "monotonic point read" `Quick test_monotonic_point_read
        ; test_case "concurrent records converge" `Quick test_concurrent_records_converge_to_max
        ; test_case "malformed current fails closed" `Quick test_malformed_current_fails_closed
        ; test_case
            "cluster roots are independent"
            `Quick
            test_cluster_roots_are_independent
        ] )
    ]
;;
