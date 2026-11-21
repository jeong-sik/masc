(** A store this build cannot decode is settled once, at boot: examined
    without being touched, refused unless the operator accepted the
    quarantine, and moved aside only then. The goal store is only
    read: boot logs one INFO line when it cannot read it, never refuses or
    moves it, and leaves its bytes as they were. *)

open Alcotest
open Masc
module D = Keeper_durable_store

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Sys.readdir path
    |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK ->
    Unix.unlink path
;;

let with_workspace operation =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  (* Preparation checks the config base path against its realpath; on macOS
     the temp dir is reached through the /var -> /private/var symlink. *)
  let root = Unix.realpath (Filename.temp_dir "store-boot-reconcile-" "") in
  let config = Workspace.default_config root in
  let config_root = Filename.concat (Filename.concat root ".masc") "config" in
  Fs_compat.mkdir_p config_root;
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
    Masc_test_deps.with_process_env "MASC_CONFIG_DIR" (Some config_root) (fun () ->
      Masc_test_deps.with_process_env "MASC_BASE_PATH" (Some root) (fun () ->
        ignore (Workspace.init config ~agent_name:(Some "test"));
        operation config)))
;;

let write_bytes path bytes =
  Fs_compat.mkdir_p (Filename.dirname path);
  let oc = open_out_bin path in
  output_string oc bytes;
  close_out oc
;;

let test_preflight_reads_admission_queue_without_consuming () =
  with_workspace @@ fun config ->
  let module Queue = Keeper_memory_admission_queue in
  let base_path = config.Workspace.base_path in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let scan = match D.reader D.Id.Memory_admission_queue with
    | D.Preflight_only scan -> scan
    | D.Refuse_boot _ | D.Degrade_typed _ -> fail "admission queue is preflight-only" in
  let fact : Keeper_memory_os_types.fact =
    { claim = "Keep deployment context separate."; category = Fact;
      first_seen = 1.; last_seen = 1.;
      origin = {kind = Authored; trace_id = "admission-preflight"};
      basis = Observed Transcript } in
  (match Queue.append ~keepers_dir ~keeper_id:"pending" ~request_id:"request" fact with
   | Ok _ -> () | Error detail -> fail (Queue.append_error_to_string detail));
  let path = Queue.path ~keepers_dir ~keeper_id:"pending" in
  let before = Fs_compat.load_file path in
  (match D.run scan ~base_path with
   | Ok {D.rows = 1; refused = 0; _} -> ()
   | Ok _ -> fail "pending queue was not decoded" | Error detail -> fail detail);
  check string "preflight never acknowledges pending input" before (Fs_compat.load_file path);
  write_bytes path {|{"generation":"queue","last_sequence":0,"pending":{}}|};
  let malformed = Fs_compat.load_file path in
  (match D.run scan ~base_path with
   | Ok {D.rows = 1; refused = 1; first_refusal = Some detail; _} ->
     check bool "refusal identifies the keeper" true (String.starts_with ~prefix:"pending: " detail)
   | Ok _ -> fail "malformed queue silently passed" | Error detail -> fail detail);
  check string "refused input remains intact" malformed (Fs_compat.load_file path);
  write_bytes path {|{"generation":"queue","last_sequence":0,"pending":[]}|};
  (match D.run scan ~base_path with
   | Ok {D.rows = 1; refused = 0; _} -> ()
   | Ok _ -> fail "empty existing queue was not decoded" | Error detail -> fail detail)
;;

(* Every store the deploy preflight reads that refuses a row, in [Id.all]
   order, as [validate-stores] reads them. *)
let preflight_refusals ~base_path =
  List.filter_map
    (fun id ->
       match D.preflight_scan id with
       | None -> None
       | Some scan ->
         (match D.run scan ~base_path with
          | Ok { D.refused = 0; _ } -> None
          | Ok report -> Some (D.name id, report)
          | Error detail -> failf "%s: scan failed: %s" (D.name id) detail))
    D.Id.all
;;

let show_refusals refusals =
  String.concat "; "
    (List.map
       (fun (name, report) ->
          Printf.sprintf "%s rows=%d refused=%d" name report.D.rows report.D.refused)
       refusals)
;;

(* #32504: Memory's events and absorbed-fact sidecars sit beside its snapshot
   and journal, in the keepers directory every Memory reader and writer is
   handed. Their preflight scans walked the runtime keepers directory
   instead, where no writer puts them, so they read no row of a live
   workspace. A keeper here has both directories, as a live keeper does. *)
let test_preflight_reads_memory_sidecars_where_memory_writes_them () =
  with_workspace
  @@ fun config ->
  let module Types = Keeper_memory_os_types in
  let module Events = Keeper_memory_os_events in
  let module Absorbed = Keeper_memory_absorbed in
  let base_path = config.Workspace.base_path in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let keeper_id = "sidecars" in
  Fs_compat.mkdir_p keepers_dir;
  Fs_compat.mkdir_p (Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) keeper_id);
  let fact claim =
    Types.observed ~claim ~category:Types.Fact ~now:10.
      ~origin:{ kind = Types.Authored; trace_id = "sidecar-preflight" }
  in
  let kept = fact "kept memory" and absorbing = fact "absorbing memory" in
  (match
     Events.append_all ~keepers_dir ~keeper_id
       [ { Events.recorded_at = 20.; memory_id = Types.memory_id kept; trace_id = "sidecar-preflight"
         ; kind = Events.Retrieved { query = "sidecar preflight" } } ]
   with
   | [] -> ()
   | error :: _ -> fail (Events.append_error_to_string error));
  (match
     Absorbed.append_all ~keepers_dir ~keeper_id
       [ { Absorbed.recorded_at = 20.; trace_id = "sidecar-preflight"; memory_id = Types.memory_id kept
         ; into = Types.memory_id absorbing; fact = kept } ]
   with
   | Ok () -> ()
   | Error error -> fail (Absorbed.append_error_to_string error));
  let with_unreadable_line path =
    let bytes = Fs_compat.load_file path ^ "{\"unknown\":true}\n" in
    write_bytes path bytes;
    bytes
  in
  let events = with_unreadable_line (Events.path_for_keepers_dir ~keepers_dir ~keeper_id) in
  let absorbed = with_unreadable_line (Absorbed.path_for_keepers_dir ~keepers_dir ~keeper_id) in
  (match preflight_refusals ~base_path with
   | [ (first, { D.rows = 2; refused = 1; first_refusal = Some first_detail; _ })
     ; (second, { D.rows = 2; refused = 1; first_refusal = Some second_detail; _ }) ] ->
     check (list string) "the absorbed-fact and events stores refuse, nothing else"
       [ D.name D.Id.Memory_absorbed; D.name D.Id.Memory_os_events ] [ first; second ];
     List.iter
       (fun detail ->
          check bool ("the refusal names the keeper: " ^ detail) true
            (String.starts_with ~prefix:(keeper_id ^ " line ") detail))
       [ first_detail; second_detail ]
   | refusals ->
     failf "expected two stores to refuse one of two rows each, got [%s]"
       (show_refusals refusals));
  check string "the events sidecar is left as it was" events
    (Fs_compat.load_file (Events.path_for_keepers_dir ~keepers_dir ~keeper_id));
  check string "the absorbed-fact sidecar is left as it was" absorbed
    (Fs_compat.load_file (Absorbed.path_for_keepers_dir ~keepers_dir ~keeper_id))
;;

let () =
  run
    "keeper_store_boot_reconcile_admission_preflight"
    [ ( "one list"
      , [ test_case "admission preflight decodes and preserves pending input" `Quick
            test_preflight_reads_admission_queue_without_consuming
        ; test_case "the preflight reads Memory sidecars where Memory writes them" `Quick
            test_preflight_reads_memory_sidecars_where_memory_writes_them
        ] )
    ]
;;
