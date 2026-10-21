open Alcotest
open Masc
module Preparation = Masc_tui_credential_preparation
module Credential = Masc_tui_credential

let rec remove_tree path =
  if Sys.is_directory path then begin
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  end else Sys.remove path

let bootstrap_across_owned_preparations () =
  let base_path = Filename.temp_file "tui-credential-preparation" "" in
  Sys.remove base_path;
  Unix.mkdir base_path 0o700;
  let previous_token = Sys.getenv_opt Credential.token_env_var in
  Unix.unsetenv Credential.token_env_var;
  Fun.protect ~finally:(fun () ->
    (match previous_token with
     | None -> Unix.unsetenv Credential.token_env_var
     | Some token -> Unix.putenv Credential.token_env_var token);
    remove_tree base_path) (fun () ->
  Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    Eio_guard.enable ();
    Eio.Switch.on_release sw Eio_guard.disable;
    let preparation = Preparation.create () in
    Masc_tui_http.install_credential_preparation preparation;
    let host = "127.0.0.1" and port = 8935 in
    let install () = Masc_tui_http.install_operator_token ~base_path ~host ~port in
    let allowed, allow = Eio.Promise.create () in
    let entered, enter = Eio.Promise.create () in
    let original = match Preparation.start preparation ~sw:(Some sw)
        ~purpose:Initial ~base_path ~host ~port
        ~install:(fun () ->
          Eio.Promise.resolve enter ();
          Eio.Promise.await allowed;
          install ()) with
      | Some request -> request
      | None -> fail "initial preparation was not admitted" in
    Eio.Promise.await entered;
    (* The production installer is still held before entry. Another UI-domain
       task can edit a draft while initial HTTP ordering remains unsettled. *)
    let draft = Masc_tui_message_input.create () in
    Masc_tui_message_input.insert draft "original operator draft";
    check bool "input edit survives pending preparation" true
      (Masc_tui_message_input.contents draft = "original operator draft"
       && not (Preparation.initial_settled preparation));
    check bool "no credential footprint before producer entry" false
      (Sys.file_exists (Auth.auth_dir base_path));
    Eio.Promise.resolve allow ();
    let rec await () = match Preparation.status preparation with
      | Awaiting_ui completion -> completion
      | Preparing _ -> Eio.Fiber.yield (); await ()
      | Not_requested | Settled -> fail "original preparation disappeared" in
    let unconsumed = await () in
    Preparation.await_initial preparation;
    check bool "worker return does not settle initial UI ordering" false
      (Preparation.initial_settled preparation);
    check bool "completion retains original owner" true (unconsumed.request == original);
    (match Preparation.take_completed preparation with
     | Some { outcome = Observed Credential.Workspace_pending; _ } -> ()
     | Some { outcome = Observed (Credential.Held | Not_required | Mint_failed _
           | Minted (First_token | Replaces_expired | Replaces_mismatched)); _ }
     | Some { outcome = Not_started _ | Unobserved _; _ }
     | None -> fail "missing workspace did not retain its original outcome");
    check bool "initial outcome was consumed" true (Preparation.initial_settled preparation);
    (* A server/operator creates this workspace between the two preparations.
       The retry uses the same real installer, not a supplied minted result. *)
    Fs_compat.mkdir_p (Auth.auth_dir base_path);
    let config = Auth.load_auth_config base_path in
    Auth.save_auth_config base_path { config with enabled = true; require_token = true };
    let retry_allowed, allow_retry = Eio.Promise.create () in
    let retry_entered, enter_retry = Eio.Promise.create () in
    ignore (Preparation.start preparation ~sw:(Some sw) ~purpose:Workspace_retry
      ~base_path ~host ~port ~install:(fun () ->
        Eio.Promise.resolve enter_retry ();
        Eio.Promise.await retry_allowed;
        install ()) : Preparation.request option);
    Eio.Promise.await retry_entered;
    let headers, have_headers = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      Eio.Promise.resolve have_headers (Masc_tui_http.auth_headers ()));
    (* The real request builder waits for the installer; input editing does
       not have to wait and cannot send a premature tokenless header. *)
    Masc_tui_message_input.append draft " while access is preparing";
    Eio.Promise.resolve allow_retry ();
    let headers = Eio.Promise.await headers in
    check bool "request captured the installed bearer" true
      (List.mem_assoc "Authorization" headers);
    ignore (await () : Preparation.completion);
    (match Preparation.take_completed preparation with
     | Some { outcome = Observed (Credential.Minted Credential.First_token); _ } -> ()
     | Some { outcome = Observed (Credential.Held | Not_required | Workspace_pending
           | Mint_failed _ | Minted (Replaces_expired | Replaces_mismatched)); _ }
     | Some { outcome = Not_started _ | Unobserved _; _ }
     | None -> fail "retry did not observe its actual credential mint");
    (match Masc_tui_http.operator_token () with
     | None -> fail "minted bearer was not installed"
     | Some token ->
         (match Auth.verify_token base_path ~agent_name:Credential.agent_name ~token with
          | Ok _ -> ()
          | Error _ -> fail "installed bearer does not verify against this workspace"));
    check string "operator draft retained across real bootstrap"
      "original operator draft while access is preparing"
      (Masc_tui_message_input.contents draft))))

let () = run "tui_credential_preparation"
  ["bootstrap", [test_case "pending input and original outcomes across workspace bootstrap"
    `Quick bootstrap_across_owned_preparations]]
