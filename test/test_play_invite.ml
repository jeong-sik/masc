(* RFC play-link-for-the-shared-machine §2.4 and §5: issuing, listing and
   revoking invites against a real credential store in a temp workspace. *)

open Alcotest
module I = Masc.Play_invite

let remove_tree path =
  let rec go path =
    if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
      Array.iter (fun name -> go (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    end
    else Unix.unlink path
  in
  go path

let with_workspace f =
  let dir = Filename.temp_dir "play-invite-" "" in
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () -> f dir)

let set_auth base_path ~enabled ~require_token =
  Auth.save_auth_config base_path
    { Masc_domain.default_auth_config with enabled; require_token }

let ready base_path = set_auth base_path ~enabled:true ~require_token:true

let name raw =
  match I.Name.of_string raw with
  | Ok name -> name
  | Error message -> failf "%S: %s" raw message

let base = "http://127.0.0.1:8935"

let issue ?(public_base_url = Some base) ?(keeper_names = Ok []) ?(hours = 2) base_path raw =
  I.issue ~base_path ~public_base_url ~keeper_names ~name:(name raw) ~hours

let players base_path =
  Auth.list_credentials base_path
  |> List.filter (fun (c : Masc_domain.agent_credential) -> c.role = Masc_domain.Player)
  |> List.map (fun (c : Masc_domain.agent_credential) -> c.agent_name)

let token_of_link link =
  match String.index_opt link '#' with
  | Some i -> String.sub link (i + 1) (String.length link - i - 1)
  | None -> failf "no token after # in %S" link

let issue_error_to_string = function
  | I.Not_ready gaps -> "not_ready " ^ String.concat "," (List.map I.readiness_gap_to_string gaps)
  | I.Name_taken by -> "name_taken " ^ I.taken_by_to_string by
  | I.Keeper_names_unreadable detail -> "keepers_unreadable " ^ detail
  | I.Hours_out_of_range hours -> "hours " ^ string_of_int hours
  | I.Credential_not_saved err -> "not_saved " ^ Masc_domain.masc_error_to_string err

let refused what expected = function
  | Ok _ -> failf "%s: an invite was issued" what
  | Error err -> check string what expected (issue_error_to_string err)

let test_name_grammar () =
  List.iter
    (fun raw -> check bool ("accepts " ^ raw) true (Result.is_ok (I.Name.of_string raw)))
    [ "minsu"; "guest1"; "a"; String.make I.max_name_length 'a' ];
  List.iter
    (fun raw -> check bool (Printf.sprintf "refuses %S" raw) true (Result.is_error (I.Name.of_string raw)))
    [ ""; "Minsu"; "1abc"; "a-b"; "a_b"; "a b"; "a.b"; String.make (I.max_name_length + 1) 'a'; "철수" ]

let test_every_gap_is_named () =
  with_workspace (fun base_path ->
    set_auth base_path ~enabled:false ~require_token:false;
    refused "auth off, token optional, no base URL"
      "not_ready auth_disabled,token_not_required,no_public_base_url"
      (issue ~public_base_url:None base_path "minsu");
    set_auth base_path ~enabled:true ~require_token:false;
    refused "token optional" "not_ready token_not_required" (issue base_path "minsu");
    ready base_path;
    refused "no base URL" "not_ready no_public_base_url" (issue ~public_base_url:None base_path "minsu");
    check (list string) "no refusal wrote a credential" [] (players base_path))

let test_issue_mints_an_expiring_player () =
  with_workspace (fun base_path ->
    ready base_path;
    match issue base_path "minsu" with
    | Error err -> failf "not issued: %s" (issue_error_to_string err)
    | Ok issued ->
      check string "the name" "minsu" (I.Name.to_string issued.I.name);
      let prefix = base ^ "/play#" in
      check string "the link opens the play page" prefix
        (String.sub issued.I.link 0 (String.length prefix));
      (match Auth.find_credential_by_token base_path ~token:(token_of_link issued.I.link) with
       | Error err -> failf "the link's token does not resolve: %s" (Masc_domain.masc_error_to_string err)
       | Ok cred ->
         check string "the token belongs to the invite" "minsu" cred.Masc_domain.agent_name;
         check string "as a player" "player" (Masc_domain.agent_role_to_string cred.Masc_domain.role);
         check (option string) "and it expires when the answer says" (Some issued.I.expires_at)
           cred.Masc_domain.expires_at))

let test_a_taken_name_is_refused () =
  with_workspace (fun base_path ->
    ready base_path;
    refused "a keeper's name" "name_taken keeper" (issue ~keeper_names:(Ok [ "minsu" ]) base_path "minsu");
    (* "Minsu" and "minsu" share agents/minsu.json: the keeper booting later
       would overwrite the invite. *)
    refused "a keeper's name in other capitals" "name_taken keeper"
      (issue ~keeper_names:(Ok [ "Minsu" ]) base_path "minsu");
    let _ = Auth.create_token base_path ~agent_name:"codex" ~role:Masc_domain.Worker in
    refused "a credential's name" "name_taken credential" (issue base_path "codex");
    check (option string) "the worker keeps its credential" (Some "worker")
      (Option.map
         (fun (c : Masc_domain.agent_credential) -> Masc_domain.agent_role_to_string c.role)
         (Auth.load_credential base_path "codex"));
    refused "an unlisted fleet" "keepers_unreadable no keepers dir"
      (issue ~keeper_names:(Error "no keepers dir") base_path "minsu");
    refused "zero hours" "hours 0" (issue ~hours:0 base_path "minsu");
    refused "more than a year" "hours 8761" (issue ~hours:8761 base_path "minsu");
    check (list string) "no refusal wrote a player" [] (players base_path))

let test_list_marks_expiry () =
  with_workspace (fun base_path ->
    ready base_path;
    (match issue ~hours:1 base_path "minsu" with
     | Ok _ -> ()
     | Error err -> failf "not issued: %s" (issue_error_to_string err));
    let _ = Auth.create_token base_path ~agent_name:"codex" ~role:Masc_domain.Worker in
    let now = Unix.gettimeofday () in
    let listed at =
      match I.list ~base_path ~now:at with
      | Ok invites -> List.map (fun { I.invite_name; expired; _ } -> invite_name, expired) invites
      | Error (I.Invalid_expiry (Masc_domain.Credential_expiry.Invalid_timestamp stamp)) -> fail ("invalid expiry: " ^ stamp)
      | Error (I.Credentials_unavailable error) -> fail (Masc_domain.masc_error_to_string error)
    in
    check (list (pair string bool)) "only players, live" [ "minsu", false ] (listed now);
    check (list (pair string bool)) "expired two hours on" [ "minsu", true ]
      (listed (now +. (2. *. 3600.))))

let test_unreadable_names_remain_occupied () =
  with_workspace (fun base_path ->
    ready base_path;
    (* Create the store, then replace only this name's file. A corrupt file,
       dangling link or directory is not permission to hand the name out. *)
    ignore (Auth.create_token base_path ~agent_name:"minsu" ~role:Masc_domain.Player);
    let path = Auth.credential_file base_path "minsu" in
    Out_channel.with_open_text path (fun channel -> output_string channel "{");
    refused "invalid JSON still owns the name" "name_taken credential" (issue base_path "minsu");
    check string "the corrupt file stays untouched" "{" (In_channel.with_open_text path In_channel.input_all);
    Unix.unlink path;
    Unix.symlink (path ^ ".absent") path;
    refused "a dangling symlink owns the name" "name_taken credential" (issue base_path "minsu");
    check string "the dangling link stays untouched" (path ^ ".absent") (Unix.readlink path);
    Unix.unlink path;
    Unix.mkdir path 0o700;
    refused "a directory owns the name" "name_taken credential" (issue base_path "minsu");
    check bool "the directory stays untouched" true ((Unix.lstat path).Unix.st_kind = Unix.S_DIR))

let test_revoke () =
  with_workspace (fun base_path ->
    ready base_path;
    let token =
      match issue base_path "minsu" with
      | Ok issued -> token_of_link issued.I.link
      | Error err -> failf "not issued: %s" (issue_error_to_string err)
    in
    check bool "revoked" true (I.revoke ~base_path ~name:(name "minsu") ~after_revoke:Fun.id = Ok I.Deleted);
    check bool "the bearer stops resolving" true
      (Result.is_error (Auth.find_credential_by_token base_path ~token));
    check bool "a second revoke finds it gone" true
      (I.revoke ~base_path ~name:(name "minsu") ~after_revoke:Fun.id = Ok I.Already_gone);
    let _ = Auth.create_token base_path ~agent_name:"codex" ~role:Masc_domain.Worker in
    check bool "a worker's credential is not an invite" true
      (I.revoke ~base_path ~name:(name "codex") ~after_revoke:Fun.id = Error (I.Not_an_invite Masc_domain.Worker));
    check bool "and stays" true (Option.is_some (Auth.load_credential base_path "codex")))

let test_revoke_rejects_forged_uuid_binding () =
  with_workspace (fun base_path ->
    ready base_path;
    let create who role = match Auth.create_token base_path ~agent_name:who ~role with
      | Ok value -> value
      | Error error -> fail (Masc_domain.masc_error_to_string error) in
    let _invite_token, invite = create "minsu" Masc_domain.Player in
    let other_token, other = create "other" Masc_domain.Worker in
    let uuid_path (credential : Masc_domain.agent_credential) = match credential.id with
      | Some id -> Auth.credential_file base_path (Masc_domain.Credential_id.to_string id)
      | None -> fail "fixture needs UUID-backed credentials" in
    let invite_path=uuid_path invite and other_path=uuid_path other in
    (* Keep the invite owner/role, but forge its embedded ID to name another
       owner's actual UUID file. The name redirect still points to invite_path. *)
    let forged={invite with id=other.id} in
    Out_channel.with_open_text invite_path (fun channel ->
      output_string channel (Yojson.Safe.to_string (Masc_domain.agent_credential_to_yojson forged)));
    let paths=[Auth.credential_file base_path "minsu";invite_path;
      Auth.credential_file base_path "other";other_path] in
    let bytes path=In_channel.with_open_text path In_channel.input_all in
    let before=List.map bytes paths in
    let effects=ref 0 in
    (match I.revoke ~base_path ~name:(name "minsu")
       ~after_revoke:(fun _ -> incr effects) with
     | Error (I.Credential_not_deleted _) -> ()
     | Ok () | Error _ -> fail "forged UUID binding must refuse deletion");
    check int "invalid ownership invokes no controller effect" 0 !effects;
    check (list string) "both owners' redirects and UUID records remain exact" before (List.map bytes paths);
    (match Auth.find_credential_by_token base_path ~token:other_token with
     | Ok credential -> check string "unrelated owner still authenticates" "other" credential.Masc_domain.agent_name
     | Error error -> fail (Masc_domain.masc_error_to_string error)))

let () =
  run "play-invite"
    [ ( "invite"
      , [ test_case "names are lowercase letters and digits" `Quick test_name_grammar
        ; test_case "every missing setting is named" `Quick test_every_gap_is_named
        ; test_case "an invite is an expiring player credential" `Quick
            test_issue_mints_an_expiring_player
        ; test_case "a taken name, an unlisted fleet or a bad window is refused" `Quick
            test_a_taken_name_is_refused
        ; test_case "the list shows players and their expiry" `Quick test_list_marks_expiry
        ; test_case "unreadable names remain occupied" `Quick test_unreadable_names_remain_occupied
        ; test_case "forged UUID binding preserves both owners" `Quick test_revoke_rejects_forged_uuid_binding
        ; test_case "revoke deletes only an invite" `Quick test_revoke
        ] )
    ]
