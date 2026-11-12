(* Whether a CLI may start on an account, by the access a process published.
   The access is published once per process, so the executable has one case
   and it runs in order: before the publication, the publication, after it.
   The single user comes from the real tool judgment of a fresh temporary
   base path, and the account is a real capture of a temporary home. *)

module Access = Runtime_account_access
module Account = Runtime_official_account
module Layout = Runtime_account_home_layout

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
        ; pat = Authz_types.Pat_binding.Not_pat
        ; runtime_id = "runtime-1"
        } )
  ; "operator call", Access.Operator_call
  ]
;;

let hosts =
  [ "Antigravity", Access.Antigravity
  ; "Vibe", Access.Vibe
  ; "An API provider of the runtime table", Access.Api_provider
  ; "A model-list request", Access.Model_list
  ; "The Files API", Access.Files_api
  ; "The replacement catalog", Access.Replacement_catalog
  ; "A web search provider", Access.Web_search
  ; "The cloud backend of SystemOne", Access.Systemone_cloud
  ; "A voice endpoint", Access.Voice_endpoint
  ]
;;

let postures =
  Runtime_native_tools.[ Native_none; Native_read; Native_full ]
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
            | Error refusal ->
              Alcotest.failf
                "a %s was refused for another reason: %s"
                label
                (Access.refusal_to_string refusal)
            | Ok (_ : Account.claude_code Access.authorized) ->
              Alcotest.failf "a %s was authorized before the publication" label)
          requests;
        List.iter
          (fun (label, client) ->
            match Access.authorize_host client with
            | Error Access.Not_published -> ()
            | Error refusal ->
              Alcotest.failf
                "%s was refused for another reason: %s"
                label
                (Access.refusal_to_string refusal)
            | Ok (_ : Access.host_account) ->
              Alcotest.failf "%s was allowed before the publication" label)
          hosts;
        (match Access.host_access () with
         | Error Access.Host_unpublished -> ()
         | Error Access.Host_not_shared ->
           Alcotest.fail "the accounts of the host were not shared before the publication"
         | Ok (_ : Access.host_account) ->
           Alcotest.fail "the accounts of the host were shared before the publication");
        List.iter
          (fun posture ->
            match Access.authorize_native posture with
            | Error Access.Native_unpublished -> ()
            | Error refusal ->
              Alcotest.failf
                "a turn with native %s tools was refused for another reason: %s"
                (Runtime_native_tools.to_string posture)
                (Access.native_refusal_to_string refusal)
            | Ok () ->
              Alcotest.failf
                "a turn with native %s tools was allowed before the publication"
                (Runtime_native_tools.to_string posture))
          postures;
        (match Access.publish (Access.Single_user single_user) with
         | Ok () -> ()
         | Error error -> Alcotest.fail (Access.publish_error_to_string error));
        let allowed_but_native () =
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
            requests;
          (* A single user shares the accounts of the host (plan D3b). *)
          List.iter
            (fun (label, client) ->
              match Access.authorize_host client with
              | Ok (_ : Access.host_account) -> ()
              | Error refusal ->
                Alcotest.failf "%s was refused: %s" label (Access.refusal_to_string refusal))
            hosts;
          (match Access.host_access () with
           | Ok (_ : Access.host_account) -> ()
           | Error (Access.Host_unpublished | Access.Host_not_shared) ->
             Alcotest.fail "a single user does not share the accounts of the host")
        in
        let allowed () =
          allowed_but_native ();
          (* The one person of a single-user process owns every home its
             native tools can read (plan D3c), while no person left a runtime
             root under the workspace. *)
          List.iter
            (fun posture ->
              match Access.authorize_native posture with
              | Ok () -> ()
              | Error refusal ->
                Alcotest.failf
                  "a turn with native %s tools was refused: %s"
                  (Runtime_native_tools.to_string posture)
                  (Access.native_refusal_to_string refusal))
            postures
        in
        allowed ();
        (match Access.publish (Access.Single_user single_user) with
         | Error Access.Already_published -> ()
         | Ok () -> Alcotest.fail "a second publication was taken");
        allowed ();
        (* Plan F3a-3: what a person left under the workspace is read at each
           start. The same published process answers by the directory. *)
        let person_root =
          match Authz_types.Account_home_namespace.of_string "ns-left-behind" with
          | Ok namespace -> Layout.person_runtime_root ~base_path ~namespace
          | Error (_ : Authz_id.error) -> Alcotest.fail "the namespace is no id"
        in
        let persons = Filename.dirname person_root in
        let native label expected =
          List.iter
            (fun posture ->
              let answer =
                match Access.authorize_native posture with
                | Ok () -> `Allowed
                | Error (Access.Native_tools_reach_person_homes refused) ->
                  Alcotest.(check string)
                    (label ^ ": the refusal names the posture it refused")
                    (Runtime_native_tools.to_string posture)
                    (Runtime_native_tools.to_string refused);
                  `Homes_remain
                | Error (Access.Person_homes_unread { posture = refused; unread = (_ : Unix.error) }) ->
                  Alcotest.(check string)
                    (label ^ ": the refusal names the posture it refused")
                    (Runtime_native_tools.to_string posture)
                    (Runtime_native_tools.to_string refused);
                  `Unread
                | Error
                    ((Access.Native_unpublished | Access.Native_tools_reach_other_homes _) as
                     refusal) ->
                  Alcotest.failf
                    "%s: a single user got the refusal of another process: %s"
                    label
                    (Access.native_refusal_to_string refusal)
              in
              let wanted =
                match posture with
                | Runtime_native_tools.Native_none -> `Allowed
                | Runtime_native_tools.Native_read | Runtime_native_tools.Native_full -> expected
              in
              if answer <> wanted
              then
                Alcotest.failf
                  "%s: a turn with native %s tools was judged otherwise"
                  label
                  (Runtime_native_tools.to_string posture))
            postures
        in
        let masc_dir = Filename.dirname persons in
        (match Unix.mkdir masc_dir 0o700 with
         | () -> ()
         | exception Unix.Unix_error (Unix.EEXIST, _, _) -> ());
        Unix.mkdir persons 0o700;
        native "the directory of the persons, emptied" `Homes_remain;
        Unix.mkdir person_root 0o700;
        native "a runtime root of a person" `Homes_remain;
        (* The other decisions of a single user do not change with it. *)
        allowed_but_native ();
        (* Vibe takes no posture from its caller and passes the same decision
           before it starts anything. *)
        (match Access.authorize_host Access.Vibe with
         | Error refusal -> Alcotest.fail (Access.refusal_to_string refusal)
         | Ok host ->
           let config : Runtime_vibe_cli.config =
             { cli_path = Filename.concat root "no-vibe"
             ; workdir = root
             ; trust_workdir = false
             ; model = None
             ; time_limit_s = None
             }
           in
           (match Runtime_vibe_cli.run ~host config ~prompt:"unused" with
            | Error
                (Runtime_vibe_cli.Native_tools_refused
                   (Access.Native_tools_reach_person_homes Runtime_native_tools.Native_full)) -> ()
            | Error error ->
              Alcotest.failf "Vibe ended otherwise: %s" (Runtime_vibe_cli.error_to_string error)
            | Ok (_ : Runtime_vibe_cli.run) -> Alcotest.fail "Vibe ran beside a person root"));
        Unix.rmdir person_root;
        native "the root removed and the directory left" `Homes_remain;
        Unix.rmdir persons;
        native "the directory removed" `Allowed;
        Out_channel.with_open_bin persons (fun (_ : Out_channel.t) -> ());
        native "a file of that name" `Homes_remain;
        Sys.remove persons;
        (* A path to the name that cannot be read gives no answer. *)
        let aside = masc_dir ^ ".aside" in
        Unix.rename masc_dir aside;
        Out_channel.with_open_bin masc_dir (fun (_ : Out_channel.t) -> ());
        native "a file where the directory of MASC is" `Unread;
        Sys.remove masc_dir;
        Unix.rename aside masc_dir;
        allowed ()))
;;

let () =
  Alcotest.run
    "runtime_account_access"
    [ "access", [ Alcotest.test_case "published once" `Quick test_published_once ] ]
;;
