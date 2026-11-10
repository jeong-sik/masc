(* masc auth off on real files in a fresh temporary directory (design 10.5,
   plan F3a-2). Installations are made by the real activation, as masc auth
   bootstrap makes them. The Off writes only where the log made Multi_account
   and the external store matches it, and then a boot reads row 4 or row 9.
   The config directory is an argument, so no case reads or writes the install
   record of the operator. *)

module B = Authz_boot_mode
module H = Authz_high_water
module I = Authz_install_record
module L = Authz_log
module Off = Authz_off
module Read = Authz_boot_mode_read

let at_ms = 1_700_000_000_000

let rec remove_tree path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | { Unix.st_kind = Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK; _ }
    -> Sys.remove path
;;

type dirs =
  { base : string  (** The base path. It exists. *)
  ; config : string  (** The [masc] config directory. It does not exist. *)
  ; store : string  (** Where the activation puts the store. *)
  }

(* The zones are [Eio.Mutex]es, so every case runs in an event loop.
   Directories are 0700, which the owner check of the install record needs. *)
let with_dirs f =
  Eio_main.run (fun _env ->
    let root = Filename.temp_dir "authz-off-" "" in
    Fun.protect
      ~finally:(fun () -> remove_tree root)
      (fun () ->
        let base = Filename.concat root "base" in
        Unix.mkdir base 0o700;
        f
          { base
          ; config = Filename.concat root "config"
          ; store = Filename.concat (Filename.concat root "store") "external.jsonl"
          }))
;;

let write_file path text =
  Fs_compat.mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel text);
  Unix.chmod path 0o600
;;

let read_file path = In_channel.with_open_bin path In_channel.input_all
let log_path dirs = L.path_of_base_path ~base_path:dirs.base
let write_config dirs text = write_file (Auth.auth_config_file dirs.base) text
let asks_multi_account = {|{"enabled":true,"require_token":true,"account_mode":"Multi_account"}|}
let asks_nothing = {|{"enabled":true,"require_token":true}|}

(* masc auth bootstrap: the bootstrap and the first Admin invitation. *)
let activated dirs =
  write_config dirs asks_multi_account;
  match
    Authz_activation.activate
      ~base_path:dirs.base
      ~config_dir:(Some dirs.config)
      ~external_store:dirs.store
      ~anonymous_mutations:false
      ~now_ms:(fun () -> at_ms)
  with
  | Ok { Authz_activation.workspace_id; invitation = (_ : Authz_activation.invitation) } ->
    workspace_id
  | Error error -> Alcotest.failf "activation refused: %s" (Authz_activation.error_to_string error)
;;

let turn_off dirs =
  Off.turn_off ~base_path:dirs.base ~config_dir:(Some dirs.config) ~now_ms:(fun () -> at_ms + 1)
;;

let error_name : Off.error -> string = function
  | Off.Never_activated -> "Never_activated"
  | Off.Already_off -> "Already_off"
  | Off.Log_unreadable _ -> "Log_unreadable"
  | Off.Store_absent -> "Store_absent"
  | Off.Store_mismatch _ -> "Store_mismatch"
  | Off.Store_unreadable _ -> "Store_unreadable"
  | Off.Zone_not_opened _ -> "Zone_not_opened"
  | Off.Mode_moved _ -> "Mode_moved"
  | Off.Body_not_built _ -> "Body_not_built"
  | Off.Commit_failed _ -> "Commit_failed"
;;

let turned_off_exn name dirs =
  match turn_off dirs with
  | Ok workspace_id -> workspace_id
  | Error error -> Alcotest.failf "%s: refused: %s" name (Off.error_to_string error)
;;

let check_refused name expected dirs =
  match turn_off dirs with
  | Ok (_ : Authz_types.Workspace_id.t) -> Alcotest.failf "%s: the Off was written" name
  | Error error -> Alcotest.(check string) name expected (error_name error)
;;

let input dirs = Read.input ~base_path:dirs.base ~config_dir:(Some dirs.config) ~anonymous_mutations:false

let stop_label = function
  | Read.Boot_single_user -> "boot single user"
  | Read.Boot_after_off (_ : Authz_state.t) -> "boot single user after Off"
  | Read.Stop (Read.Refuse (first, rest)) ->
    "refuse: " ^ String.concat "; " (List.map B.refusal_to_string (first :: rest))
  | Read.Stop Read.Activation_requested -> "activation requested"
  | Read.Stop (Read.Multi_account_not_served mode) -> "not served: " ^ B.mode_to_string mode
;;

let check_refusal name expected dirs =
  match Read.decide (input dirs) with
  | Read.Stop (Read.Refuse (first, [])) when first = expected -> ()
  | other -> Alcotest.failf "%s: got %s" name (stop_label other)
;;

(* Row 4: the boot starts a single user that holds the Off of the workspace. *)
let check_boots_after_off name workspace_id dirs =
  match Read.boot ~base_path:dirs.base ~config_dir:(Some dirs.config) ~anonymous_mutations:false with
  | Error (first, _) -> Alcotest.failf "%s: the boot refused: %s" name first
  | Ok single_user ->
    (match Read.turned_off single_user with
     | None -> Alcotest.failf "%s: booted as a base path never set up" name
     | Some state ->
       (match state.Authz_state.mode with
        | Authz_mode_state.Off off ->
          Alcotest.(check bool)
            (name ^ ": Off of the activated workspace")
            true
            (Authz_types.Workspace_id.equal off workspace_id)
        | Authz_mode_state.Not_bootstrapped | Authz_mode_state.Multi_account _ ->
          Alcotest.failf "%s: the state is not the one after Off" name))
;;

let count_lines text = List.length (List.filter (fun line -> line <> "") (String.split_on_char '\n' text))

(* An active installation (row 7). The Off names its workspace, the store
   answers it, and config.json stays as the operator wrote it. *)
let an_active_installation_is_turned_off () =
  with_dirs (fun dirs ->
    let workspace_id = activated dirs in
    let records = count_lines (read_file (log_path dirs)) in
    let turned_off = turned_off_exn "the Off" dirs in
    Alcotest.(check bool)
      "the workspace of the activation"
      true
      (Authz_types.Workspace_id.equal turned_off workspace_id);
    Alcotest.(check int) "one record more" (records + 1) (count_lines (read_file (log_path dirs)));
    (match (input dirs).B.high_water with
     | B.Judged H.Matches -> ()
     | B.Judged (H.Absent | H.Mismatch _) | B.Store_unreadable _ ->
       Alcotest.fail "the store does not answer the Off");
    Alcotest.(check string) "config.json is not written" asks_multi_account (read_file (Auth.auth_config_file dirs.base));
    (* Row 9: config.json still asks for Multi_account, which is a reactivation. *)
    check_refusal "row 9" B.Reactivation_not_ready dirs;
    write_config dirs asks_nothing;
    check_boots_after_off "row 4" workspace_id dirs;
    (* A second Off writes nothing. *)
    let log = read_file (log_path dirs) in
    let store = read_file dirs.store in
    check_refused "a second Off" "Already_off" dirs;
    Alcotest.(check string) "the log is as it was" log (read_file (log_path dirs));
    Alcotest.(check string) "the store is as it was" store (read_file dirs.store))
;;

(* Row 3: an operator who took account_mode out first meets a boot that
   refuses, and turns the accounts off from there. *)
let a_lowered_config_is_turned_off () =
  with_dirs (fun dirs ->
    let workspace_id = activated dirs in
    write_config dirs asks_nothing;
    check_refusal "row 3" B.Downgraded_from_multi_account dirs;
    let (_ : Authz_types.Workspace_id.t) = turned_off_exn "the Off" dirs in
    check_boots_after_off "row 4" workspace_id dirs)
;;

let nothing_is_written_where_nothing_was_set_up () =
  with_dirs (fun dirs ->
    check_refused "no log" "Never_activated" dirs;
    Alcotest.(check bool) "no log is made" false (Sys.file_exists (log_path dirs));
    Alcotest.(check bool) "no config directory is made" false (Sys.file_exists dirs.config);
    (* A log with no lines has no mode event (design 5.1). *)
    write_file (log_path dirs) "";
    check_refused "an empty log" "Never_activated" dirs;
    Alcotest.(check string) "the empty log stays empty" "" (read_file (log_path dirs)))
;;

(* A store that does not answer the log leaves a boot that refuses after an
   Off (row 10), so nothing is written over it. *)
let nothing_is_written_over_a_store_that_does_not_answer () =
  with_dirs (fun dirs ->
    let (_ : Authz_types.Workspace_id.t) = activated dirs in
    let log = read_file (log_path dirs) in
    Sys.remove dirs.store;
    check_refused "the store is gone" "Store_absent" dirs;
    Alcotest.(check string) "the log is as it was" log (read_file (log_path dirs));
    Alcotest.(check bool) "no store is made" false (Sys.file_exists dirs.store));
  with_dirs (fun dirs ->
    let (_ : Authz_types.Workspace_id.t) = activated dirs in
    let log = read_file (log_path dirs) in
    let store = read_file dirs.store in
    (match I.locate ~config_dir:(Some dirs.config) ~base_path:dirs.base with
     | Ok (I.Located record) -> Sys.remove (I.file_path record)
     | Ok I.No_config_dir -> Alcotest.fail "the config directory is known"
     | Error error -> Alcotest.fail (I.locate_error_to_string error));
    check_refused "the install record is gone" "Store_absent" dirs;
    Alcotest.(check string) "the log is as it was" log (read_file (log_path dirs));
    Alcotest.(check string) "the store is as it was" store (read_file dirs.store))
;;

(* The log of another installation: its first record is not the one the store
   committed. *)
let nothing_is_written_over_a_store_that_does_not_match () =
  with_dirs (fun dirs ->
    let workspace_id = activated dirs in
    let other =
      match
        Authz_mode_event.to_body
          { Authz_mode_event.event = Authz_mode_event.Fresh_bootstrap; workspace_id }
      with
      | Ok body -> body
      | Error error -> Alcotest.failf "fixture body refused: %s" (Authz_body.error_to_string error)
    in
    let record =
      match
        Authz_record.make
          ~head:Authz_record.genesis
          ~at_ms:(at_ms + 1)
          ~author:Authz_records.Author.Local_operator
          ~kind:Authz_record.Kind.Mode_event
          ~body:other
      with
      | Ok record -> record
      | Error _ -> Alcotest.fail "fixture record refused"
    in
    write_file (log_path dirs) (Authz_record.to_line record ^ "\n");
    let log = read_file (log_path dirs) in
    let store = read_file dirs.store in
    check_refused "another log" "Store_mismatch" dirs;
    Alcotest.(check string) "the log is as it was" log (read_file (log_path dirs));
    Alcotest.(check string) "the store is as it was" store (read_file dirs.store))
;;

let nothing_is_written_over_a_log_that_cannot_be_read () =
  with_dirs (fun dirs ->
    let (_ : Authz_types.Workspace_id.t) = activated dirs in
    write_file (log_path dirs) "not a record\n";
    let store = read_file dirs.store in
    check_refused "a corrupt log" "Log_unreadable" dirs;
    Alcotest.(check string) "the log is as it was" "not a record\n" (read_file (log_path dirs));
    Alcotest.(check string) "the store is as it was" store (read_file dirs.store))
;;

let () =
  Alcotest.run
    "authz_off"
    [ ( "off"
      , [ Alcotest.test_case "an active installation" `Quick an_active_installation_is_turned_off
        ; Alcotest.test_case "a lowered config" `Quick a_lowered_config_is_turned_off
        ] )
    ; ( "refusals"
      , [ Alcotest.test_case "nothing set up" `Quick nothing_is_written_where_nothing_was_set_up
        ; Alcotest.test_case
            "a store that does not answer"
            `Quick
            nothing_is_written_over_a_store_that_does_not_answer
        ; Alcotest.test_case
            "a store that does not match"
            `Quick
            nothing_is_written_over_a_store_that_does_not_match
        ; Alcotest.test_case
            "a log that cannot be read"
            `Quick
            nothing_is_written_over_a_log_that_cannot_be_read
        ] )
    ]
;;
