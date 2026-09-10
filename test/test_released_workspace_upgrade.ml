open Alcotest
open Masc
module U = Released_workspace_upgrade

let fixture a p =
  Printf.sprintf
    {|# Preserve my prompt and model assignments.
[keeper]
name = "imp"
instructions = "Remember the user's context and ask before publishing."
autoboot_enabled = %b
proactive_enabled = %b
sandbox_profile = "microvm"
microvm_backend = "docker"
[keeper.tools]
native = "read"
|}
    a
    p
;;

let contents path = In_channel.with_open_bin path In_channel.input_all
let write path text = Out_channel.with_open_bin path (fun out -> output_string out text)

let plan path text =
  match U.assess_keeper ~path text with
  | U.Upgrade_available plan -> plan
  | _ -> fail "released explicit activation fields should be upgradeable"
;;

let with_workspace f =
  let root = Filename.temp_file "released-workspace" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  let root = Unix.realpath root in
  let rec clean path =
    match Unix.lstat path with
    | { st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun name -> clean (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    | _ -> Unix.unlink path
  in
  Fun.protect
    ~finally:(fun () -> clean root)
    (fun () ->
       let base_path = Filename.concat root "workspace" in
       let run_dir = Filename.concat root "run" in
       Unix.mkdir base_path 0o700;
       Unix.mkdir run_dir 0o700;
       let directory = Filename.concat base_path ".masc/config/keepers" in
       Fs_compat.mkdir_p directory;
       f ~base_path ~run_dir (Filename.concat directory "imp.toml"))
;;

let test_known_mappings () =
  List.iter
    (fun (a, p, mode) ->
       let value = plan "/fixture/imp.toml" (fixture a p) |> U.plan_to_json in
       check
         string
         "equivalent activation contract"
         mode
         Yojson.Safe.Util.(value |> member "activation_mode" |> to_string))
    [ false, false, "manual"; true, false, "on_demand"; true, true, "autonomous" ];
  List.iter
    (fun body ->
       check
         bool
         "ambiguous or unknown state is not guessed"
         true
         (U.assess_keeper ~path:"/fixture/imp.toml" body = U.Manual_repair_required))
    [ fixture false true
    ; fixture true true ^ "\nunknown_key = true\n"
    ; "[keeper]\nname=\"imp\"\ninstructions=\"prompt\"\nautoboot_enabled=true\n"
    ; "[keeper]\n\
       name=\"imp\"\n\
       instructions=\"prompt\"\n\
       autoboot_enabled=true\n\
       proactive_enabled=true\n\
       activation_mode=\"manual\"\n"
    ]
;;

let test_backup_apply_and_restart_restore () =
  with_workspace (fun ~base_path ~run_dir path ->
    let original = fixture true false in
    write path original;
    let unrelated = Filename.concat base_path ".masc/runtime.toml" in
    write unrelated "keep chosen runtime and ordered fallback bytes\n";
    let receipt =
      match U.apply ~run_dir ~base_path (plan path original) with
      | Ok receipt -> receipt
      | Error error -> fail (U.error_message error)
    in
    check
      bool
      "current native declaration parser accepts upgrade"
      true
      (match
         Keeper_types_profile.materialization_defaults_of_content ~path (contents path)
       with
       | Ok _ -> true
       | Error _ -> false);
    check
      string
      "runtime fallback untouched"
      "keep chosen runtime and ordered fallback bytes\n"
      (contents unrelated);
    let json = U.receipt_to_json receipt in
    let backup = Yojson.Safe.Util.(json |> member "backup_path" |> to_string) in
    check string "original backup exact bytes" original (contents backup);
    check int "backup is private" 0o600 ((Unix.stat backup).st_perm land 0o777);
    let backup_id = Filename.basename (Filename.dirname backup) in
    let reopened =
      match U.load_recovery ~base_path ~backup_id with
      | Ok receipt -> receipt
      | Error error -> fail (U.error_message error)
    in
    (match
       U.For_testing.restore_with_parent_sync
         ~sync_parent:(fun _ -> raise (Sys_error "fixture fsync failure"))
         ~run_dir
         ~base_path
         reopened
     with
     | Ok restored ->
       check
         bool
         "visible restore reports failed durability confirmation"
         false
         restored.durability_confirmed
     | Error error -> fail (U.error_message error));
    check
      string
      "restart recovery restores exact original prompt and values"
      original
      (contents path);
    check string "backup remains after restoration" original (contents backup))
;;

let test_conflict_and_active_server () =
  with_workspace (fun ~base_path ~run_dir path ->
    let original = fixture false false in
    write path original;
    let assessed = plan path original in
    write path (original ^ "# concurrent user edit\n");
    check
      bool
      "stale assessment rejected"
      true
      (U.apply ~run_dir ~base_path assessed = Error U.Source_changed);
    write path original;
    match Server_startup_takeover.acquire_base_path_lock ~run_dir base_path with
    | Base_path_acquired lease ->
      Fun.protect
        ~finally:(fun () -> Server_startup_takeover.release_base_path_lease lease)
        (fun () ->
           check
             bool
             "active server owns same lease"
             true
             (U.apply ~run_dir ~base_path assessed = Error U.Workspace_in_use);
           check string "live workspace never rewritten" original (contents path))
    | _ -> fail "fixture lease unavailable")
;;

let () =
  run
    "released workspace upgrade"
    [ ( "known activation migration"
      , [ test_case
            "released mappings and unrepresentable states"
            `Quick
            test_known_mappings
        ; test_case
            "durable backup and restart recovery"
            `Quick
            test_backup_apply_and_restart_restore
        ; test_case
            "changed configuration and server ownership"
            `Quick
            test_conflict_and_active_server
        ] )
    ]
;;
