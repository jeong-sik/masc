(** task-1664 (audit Wave F1): pin that the three bool-only pause sites
    record a typed [Keeper_latched_reason.t] in keeper_meta, that the
    reason survives serialization and the operator-pause merge, and that
    the status bridge surfaces it.

    Sites under test:
    - gRPC pause directive ([Keeper_keepalive.process_directive "pause"]
      -> [directive_paused_meta]) -> [Operator_paused {grpc_directive}]
    - keeper_down retain ([Keeper_turn_lifecycle.handle_keeper_down_config],
      remove_meta=false) -> [Operator_paused {keeper_down}]
    - dead-tombstone cleanup
      ([Keeper_supervisor_cleanup_tombstone.cleanup_dead_tombstone])
      -> [Dead_tombstone]

    Observability only: these tests assert the {i reason} annotation, not
    any change to the pause/resume decision (which stays carried by
    [meta.paused]). *)

open Alcotest
module Keeper_meta_contract = Masc.Keeper_meta_contract
module Keeper_meta_json = Masc.Keeper_meta_json
module Keeper_meta_json_parse = Masc.Keeper_meta_json_parse
module Keeper_meta_store = Masc.Keeper_meta_store
module Keeper_registry = Masc.Keeper_registry
module Keeper_keepalive = Masc.Keeper_keepalive
module Keeper_turn_lifecycle = Masc.Keeper_turn_lifecycle
module Keeper_status_bridge = Masc.Keeper_status_bridge
module Keeper_supervisor_cleanup_tombstone = Masc.Keeper_supervisor_cleanup_tombstone
module Keeper_types_profile = Masc.Keeper_types_profile

let temp_dir prefix =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.is_directory path
    then (
      Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Unix.unlink path
  in
  try rm dir with _ -> ()

let base_json name =
  `Assoc
    [ "name", `String name
    ; "agent_name", `String (name ^ "-agent")
    ; "trace_id", `String ("trace-" ^ name)
    ; "tool_access", `List []
    ]

let make_meta name =
  match Keeper_meta_json_parse.meta_of_json (base_json name) with
  | Ok meta -> meta
  | Error err -> failf "parse base meta: %s" err

let latched_reason_wire (meta : Keeper_meta_contract.keeper_meta) =
  match meta.latched_reason with
  | Some reason -> Some (Keeper_latched_reason.to_wire reason)
  | None -> None

let bridge_latched_reason config (meta : Keeper_meta_contract.keeper_meta) =
  match
    Keeper_status_bridge.attention_fields_json config meta
    |> List.assoc_opt "latched_reason"
  with
  | Some (`String value) -> Some value
  | Some `Null -> None
  | Some _ -> failf "latched_reason surfaced as a non-string, non-null JSON value"
  | None -> failf "attention_fields_json did not surface a latched_reason field"

(* ── Serialization + merge durability ───────────────────────── *)

let test_latched_reason_survives_serialization () =
  List.iter
    (fun (label, reason) ->
       let meta =
         { (make_meta "serial-keeper") with
           paused = true
         ; latched_reason = Some reason
         }
       in
       let reparsed =
         match Keeper_meta_json_parse.meta_of_json (Keeper_meta_json.meta_to_json meta) with
         | Ok m -> m
         | Error err -> failf "%s: roundtrip parse failed: %s" label err
       in
       check bool (label ^ ": paused survives") true reparsed.paused;
       check
         (option string)
         (label ^ ": latched_reason survives")
         (Some (Keeper_latched_reason.to_wire reason))
         (latched_reason_wire reparsed))
    [ "dead tombstone", Keeper_latched_reason.Dead_tombstone
    ; ( "operator paused"
      , Keeper_latched_reason.Operator_paused { operator_actor = "keeper_down" } )
    ]

let test_no_latched_reason_serializes_as_null () =
  let meta = make_meta "no-reason-keeper" in
  let json = Keeper_meta_json.meta_to_json meta in
  (match json with
   | `Assoc fields ->
     check
       bool
       "latched_reason present as JSON null when unset"
       true
       (List.assoc_opt "latched_reason" fields = Some `Null)
   | _ -> fail "meta_to_json did not produce an object");
  let reparsed =
    match Keeper_meta_json_parse.meta_of_json json with
    | Ok m -> m
    | Error err -> failf "roundtrip parse failed: %s" err
  in
  check (option string) "unset latched_reason round-trips to None" None
    (latched_reason_wire reparsed)

(* ── Status bridge surfacing ────────────────────────────────── *)

let test_status_bridge_surfaces_latched_reason () =
  let config = Masc.Workspace.default_config (temp_dir "masc-latched-bridge-") in
  Fun.protect
    ~finally:(fun () -> cleanup_dir config.base_path)
    (fun () ->
       let paused_meta =
         { (make_meta "bridge-keeper") with
           paused = true
         ; latched_reason =
             Some
               (Keeper_latched_reason.Operator_paused
                  { operator_actor = "keeper_down" })
         }
       in
       check
         (option string)
         "bridge surfaces the typed pause reason as its wire form"
         (Some "operator_paused:actor=keeper_down")
         (bridge_latched_reason config paused_meta);
       let unset_meta = { (make_meta "bridge-keeper-unset") with paused = true } in
       check
         (option string)
         "bridge surfaces null when no reason recorded"
         None
         (bridge_latched_reason config unset_meta))

(* ── Site 3: gRPC pause directive ───────────────────────────── *)

let test_grpc_pause_directive_records_reason () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir "masc-latched-grpc-directive-" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.clear ();
      cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let keeper_name = "grpc-directive-keeper" in
       let meta = make_meta keeper_name in
       Keeper_registry.clear ();
       ignore (Keeper_registry.register ~base_path:config.base_path keeper_name meta);
       Keeper_keepalive.process_directive ~agent_name:keeper_name "pause";
       (match Keeper_registry.get ~base_path:config.base_path keeper_name with
        | Some entry ->
          check bool "pause directive pauses keeper" true entry.meta.paused;
          check
            (option string)
            "pause directive records grpc_directive operator pause"
            (Some "operator_paused:actor=grpc_directive")
            (latched_reason_wire entry.meta)
        | None -> fail "expected registered keeper after pause directive");
       Keeper_keepalive.process_directive ~agent_name:keeper_name "resume";
       match Keeper_registry.get ~base_path:config.base_path keeper_name with
       | Some entry ->
         check bool "resume directive resumes keeper" false entry.meta.paused;
         check
           (option string)
           "resume clears the latched reason together with the pause bit"
           None
           (latched_reason_wire entry.meta)
       | None -> fail "expected registered keeper after resume directive")

(* ── Site 2: keeper_down retain (remove_meta=false) ─────────── *)

let test_keeper_down_retain_records_reason () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir "masc-latched-keeper-down-" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.clear ();
      cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       (* Avoid a leading "keeper-" — identity resolution strips that prefix
          and the write/read names would diverge. *)
       let keeper_name = "downretain-owner" in
       let meta = make_meta keeper_name in
       Keeper_registry.clear ();
       (match Keeper_meta_store.write_meta config meta with
        | Ok () -> ()
        | Error err -> failf "seed meta write: %s" err);
       ignore (Keeper_registry.register ~base_path:config.base_path keeper_name meta);
       let args =
         `Assoc
           [ "name", `String keeper_name
           ; "remove_meta", `Bool false
           ; "remove_session", `Bool false
           ]
       in
       let _result = Keeper_turn_lifecycle.handle_keeper_down_config ~config args in
       match Keeper_meta_store.read_meta config keeper_name with
       | Ok (Some persisted) ->
         check bool "keeper_down retain pauses keeper" true persisted.paused;
         check
           (option string)
           "keeper_down retain records keeper_down operator pause"
           (Some "operator_paused:actor=keeper_down")
           (latched_reason_wire persisted)
       | Ok None -> fail "expected retained keeper meta on disk"
       | Error err -> failf "read persisted meta: %s" err)

(* ── Site 1: dead-tombstone cleanup ─────────────────────────── *)

let run_dead_tombstone_cleanup_records_reason ?(paused = false) ?latched_reason keeper_name =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run
  @@ fun sw ->
  let base_path = temp_dir "masc-latched-tombstone-" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.clear ();
      cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let meta = { (make_meta keeper_name) with paused; latched_reason } in
       Keeper_registry.clear ();
       (match Keeper_meta_store.write_meta config meta with
        | Ok () -> ()
        | Error err -> failf "seed meta write: %s" err);
       let entry =
         Keeper_registry.register ~base_path:config.base_path keeper_name meta
       in
       let ctx : _ Keeper_types_profile.context =
         { config
         ; agent_name = "supervisor"
         ; sw
         ; clock = Eio.Stdenv.clock env
         ; proc_mgr = None
         ; net = None
         }
       in
       let events = ref [] in
       let publish_lifecycle ~event:_ name detail () =
         events := (name, detail) :: !events
       in
       Keeper_supervisor_cleanup_tombstone.cleanup_dead_tombstone
         ~publish_lifecycle
         ctx
         entry;
       check bool "dead-cleaned lifecycle event published" true (!events <> []);
       match Keeper_meta_store.read_meta config keeper_name with
       | Ok (Some persisted) ->
         check bool "dead tombstone persists paused=true" true persisted.paused;
         check
           (option string)
           "dead tombstone records the Dead_tombstone reason"
           (Some "dead_tombstone")
           (latched_reason_wire persisted)
       | Ok None -> fail "expected tombstone meta to remain on disk after cleanup"
       | Error err -> failf "read persisted meta: %s" err)

let test_dead_tombstone_cleanup_records_reason () =
  run_dead_tombstone_cleanup_records_reason "dead-tombstone-keeper"

let test_dead_tombstone_cleanup_overwrites_existing_pause_reason () =
  run_dead_tombstone_cleanup_records_reason
    ~paused:true
    ~latched_reason:
      (Keeper_latched_reason.Operator_paused { operator_actor = "keeper_down" })
    "dead-tombstone-paused-keeper"

let () =
  run
    "keeper_latched_reason_wiring"
    [ ( "serialization"
      , [ test_case "typed pause reason survives meta serialization" `Quick
            test_latched_reason_survives_serialization
        ; test_case "unset reason serializes as null and round-trips to None" `Quick
            test_no_latched_reason_serializes_as_null
        ] )
    ; ( "status bridge"
      , [ test_case "attention fields surface the typed pause reason wire" `Quick
            test_status_bridge_surfaces_latched_reason
        ] )
    ; ( "pause sites record reason"
      , [ test_case "gRPC pause directive records grpc_directive reason" `Quick
            test_grpc_pause_directive_records_reason
        ; test_case "keeper_down retain records keeper_down reason" `Quick
            test_keeper_down_retain_records_reason
        ; test_case "dead-tombstone cleanup records Dead_tombstone reason" `Quick
            test_dead_tombstone_cleanup_records_reason
        ; test_case "dead-tombstone cleanup overwrites existing pause reason" `Quick
            test_dead_tombstone_cleanup_overwrites_existing_pause_reason
        ] )
    ]
