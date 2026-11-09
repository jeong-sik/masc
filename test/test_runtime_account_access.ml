(* Whether a CLI may start on an account, by the access a process published.
   The access is published once per process, so the executable has one case
   and it runs in order: before the publication, the publication, after it.
   The single user comes from the real tool judgment of a fresh temporary
   base path, and the account is a real capture of a temporary home. *)

module Access = Runtime_account_access
module Account = Runtime_official_account

let rec remove_tree path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | { Unix.st_kind = Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK; _ }
    -> Sys.remove path
;;

let requests =
  [ ( "Keeper turn"
    , Access.Keeper_turn
        { keeper_name = "keeper-1"
        ; channel = Authz_types.Channel.Autonomous
        ; runtime_id = "runtime-1"
        } )
  ; "operator call", Access.Operator_call
  ]
;;

let test_published_once () =
  Eio_main.run (fun _env ->
    let root = Filename.temp_dir "runtime-account-access-" "" in
    Fun.protect
      ~finally:(fun () -> remove_tree root)
      (fun () ->
        let base_path = Filename.concat root "base" in
        let home = Filename.concat root "claude-home" in
        Unix.mkdir base_path 0o700;
        Unix.mkdir home 0o700;
        let single_user =
          match
            Authz_boot_mode_read.tool
              ~base_path
              ~config_dir:(Some (Filename.concat root "config"))
          with
          | Ok single_user -> single_user
          | Error (first, _) -> Alcotest.failf "the tool judgment refused: %s" first
        in
        let captured =
          match Account.capture ~client:Account.Claude_code ~declaration:(Some home) with
          | Ok captured -> captured
          | Error detail -> Alcotest.failf "the capture failed: %s" detail
        in
        let sealed = Access.seal captured in
        List.iter
          (fun (label, request) ->
            match Access.authorize request sealed with
            | Error Access.Not_published -> ()
            | Ok (_ : Account.claude_code Access.authorized) ->
              Alcotest.failf "a %s was authorized before the publication" label)
          requests;
        (match Access.publish (Access.Single_user single_user) with
         | Ok () -> ()
         | Error error -> Alcotest.fail (Access.publish_error_to_string error));
        let allowed () =
          List.iter
            (fun (label, request) ->
              match Access.authorize request sealed with
              | Ok authorized ->
                Alcotest.(check bool)
                  (label ^ " starts on the sealed account")
                  true
                  (Account.same (Access.account authorized) captured)
              | Error refusal ->
                Alcotest.failf "a %s was refused: %s" label (Access.refusal_to_string refusal))
            requests
        in
        allowed ();
        (match Access.publish (Access.Single_user single_user) with
         | Error Access.Already_published -> ()
         | Ok () -> Alcotest.fail "a second publication was taken");
        allowed ()))
;;

let () =
  Alcotest.run
    "runtime_account_access"
    [ "access", [ Alcotest.test_case "published once" `Quick test_published_once ] ]
;;
