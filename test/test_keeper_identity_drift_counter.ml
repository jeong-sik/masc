open Alcotest

module KES = Masc_mcp.Keeper_exec_shared
module Keeper_registry = Masc_mcp.Keeper_registry

let temp_dir () =
  let d = Filename.temp_file "keeper_identity_drift_" "" in
  Unix.unlink d;
  Unix.mkdir d 0o755;
  d
;;

let cleanup_dir path =
  let rec rm target =
    if Sys.file_exists target then
      if Sys.is_directory target then begin
        Sys.readdir target |> Array.iter (fun name -> rm (Filename.concat target name));
        Unix.rmdir target
      end else
        Unix.unlink target
  in
  try rm path with _ -> ()
;;

let make_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String ("agent-" ^ name));
          ("trace_id", `String ("trace-" ^ name));
          ("allowed_paths", `List [ `String "*" ]);
        ])
  with
  | Ok meta -> meta
  | Error e -> failwith ("make_meta failed: " ^ e)
;;

let counter_value ~source_layer ~field =
  Masc_mcp.Prometheus.metric_value_or_zero
    Masc_mcp.Keeper_metrics.metric_keeper_path_resolver_identity_mismatch
    ~labels:[ ("source_layer", source_layer); ("field", field) ]
    ()
;;

let is_error_json raw =
  String.length raw > 0
  && (String.starts_with ~prefix:"{\"ok\":false" raw
      || String.starts_with ~prefix:"{\"error\"" raw)
;;

(* ── find_registry_meta tests ─────────────────────────────────────────── *)

let test_find_registry_meta_missing () =
  Keeper_registry.clear ();
  let before = counter_value ~source_layer:"test_layer" ~field:"registry_missing" in
  let result =
    KES.find_registry_meta ~keeper_name:"nonexistent-keeper" ~source_layer:"test_layer"
  in
  check bool "missing returns None" true (Option.is_none result);
  check (float 0.0001) "registry_missing counter +1"
    (before +. 1.0)
    (counter_value ~source_layer:"test_layer" ~field:"registry_missing")
;;

let test_find_registry_meta_mismatch () =
  Keeper_registry.clear ();
  let base = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
       let meta = make_meta "real-name" in
       (* Register under a different name than meta.name *)
       ignore (Keeper_registry.register ~base_path:base "alias-name" meta);
       let before = counter_value ~source_layer:"test_layer" ~field:"name_mismatch" in
       let result =
         KES.find_registry_meta ~keeper_name:"alias-name" ~source_layer:"test_layer"
       in
       check bool "mismatch returns Some" true (Option.is_some result);
       check (float 0.0001) "name_mismatch counter +1"
         (before +. 1.0)
         (counter_value ~source_layer:"test_layer" ~field:"name_mismatch"))
;;

let test_find_registry_meta_match () =
  Keeper_registry.clear ();
  let base = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
       let meta = make_meta "matched-name" in
       ignore (Keeper_registry.register ~base_path:base "matched-name" meta);
       let before_missing =
         counter_value ~source_layer:"test_layer" ~field:"registry_missing"
       in
       let before_mismatch =
         counter_value ~source_layer:"test_layer" ~field:"name_mismatch"
       in
       let result =
         KES.find_registry_meta ~keeper_name:"matched-name" ~source_layer:"test_layer"
       in
       check bool "match returns Some" true (Option.is_some result);
       check (float 0.0001) "registry_missing counter unchanged"
         before_missing
         (counter_value ~source_layer:"test_layer" ~field:"registry_missing");
       check (float 0.0001) "name_mismatch counter unchanged"
         before_mismatch
         (counter_value ~source_layer:"test_layer" ~field:"name_mismatch"))
;;

(* ── with_registry_meta tests ─────────────────────────────────────────── *)

let test_with_registry_meta_missing () =
  Keeper_registry.clear ();
  let result =
    KES.with_registry_meta ~keeper_name:"missing-keeper" ~source_layer:"test_layer"
      (fun _meta -> {|{"ok":true}|})
  in
  check bool "missing returns error JSON" true (is_error_json result)
;;

let test_with_registry_meta_match () =
  Keeper_registry.clear ();
  let base = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
       let meta = make_meta "found-keeper" in
       ignore (Keeper_registry.register ~base_path:base "found-keeper" meta);
       let result =
         KES.with_registry_meta ~keeper_name:"found-keeper" ~source_layer:"test_layer"
           (fun meta -> Printf.sprintf {|{"ok":true,"name":"%s"}|} meta.name)
       in
       check string "match returns f meta result"
         {|{"ok":true,"name":"found-keeper"}|}
         result)
;;

let () =
  run
    "Keeper_identity_drift_counter"
    [ ( "find_registry_meta"
      , [ test_case "missing entry increments registry_missing" `Quick
            test_find_registry_meta_missing
        ; test_case "name mismatch increments name_mismatch" `Quick
            test_find_registry_meta_mismatch
        ; test_case "matching entry does not increment counters" `Quick
            test_find_registry_meta_match
        ] )
    ; ( "with_registry_meta"
      , [ test_case "missing entry returns error JSON" `Quick
            test_with_registry_meta_missing
        ; test_case "matching entry returns f result" `Quick
            test_with_registry_meta_match
        ] )
    ]
;;