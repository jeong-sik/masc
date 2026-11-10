(* The account server of a multi-account installation (plan S1a): what its
   table may hold, and the server itself, started on the installation that the
   entry of the boot judged, on real files in a temporary directory and a
   loopback port. Its access is published once per process, so one case
   starts it, and the executable does not link masc_test_deps, which publishes
   the access of a single user. *)

open Masc
module Read = Authz_boot_mode_read

let workspace =
  match Authz_types.Workspace_id.of_string "workspace-1" with
  | Ok id -> id
  | Error _ -> Alcotest.fail "fixture id rejected by Authz_id"
;;

let at_ms = 1_700_000_000_000

let rec remove_tree path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Unix.chmod path 0o700;
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | { Unix.st_kind = Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK; _ }
    -> Sys.remove path
;;

(* ---- what the table may hold ---- *)

let nothing _request _reqd = ()
let nothing_with_state _state _request _reqd = ()

let kind_label router =
  match Server_accounts.route_of_another_kind router with
  | None -> "served"
  | Some (Server_accounts.Route_of_another_kind { path; access }) ->
    Printf.sprintf "%s is %s" path (Yojson.Safe.to_string (Route_access.to_json access))
  | Some
      (( Server_accounts.Zone_not_opened _
       | Server_accounts.Access_not_published _
       | Server_accounts.Https_listener_refused _
       | Server_accounts.Trust_policy_refused _ ) as refusal) ->
    "another refusal: " ^ Server_accounts.refusal_to_string refusal
;;

let test_table_kinds () =
  Alcotest.(check string) "the table of the account server" "served" (kind_label (Server_accounts.routes ()));
  Alcotest.(check string)
    "a route that authenticates a browser session itself"
    "served"
    (kind_label
       (Server_accounts.routes ()
        |> Server_route.post
             (Server_route.Self_authenticated Route_access.Browser_session)
             "/auth/logout"
             nothing));
  Alcotest.(check string)
    "a route behind a wrapper of the single-user server"
    {|/api/v1/status is {"kind":"read_auth"}|}
    (kind_label
       (Server_accounts.routes ()
        |> Server_route.get Server_route.Read_auth "/api/v1/status" nothing_with_state));
  Alcotest.(check string)
    "the dev-token route of the single-user server"
    {|/api/v1/dashboard/dev-token is {"kind":"self_authenticated","reason":"loopback_dev_token"}|}
    (kind_label
       (Server_accounts.routes ()
        |> Server_route.get
             (Server_route.Self_authenticated Route_access.Loopback_dev_token)
             "/api/v1/dashboard/dev-token"
             nothing))
;;

(* ---- the server ---- *)

let write_file path text =
  Fs_compat.mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel text);
  Unix.chmod path 0o600
;;

(* A port that was free a moment ago. *)
let free_port () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close socket)
    (fun () ->
      Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
      match Unix.getsockname socket with
      | Unix.ADDR_INET ((_ : Unix.inet_addr), port) -> port
      | Unix.ADDR_UNIX (_ : string) -> Alcotest.fail "a TCP socket has no path")
;;

let loopback =
  match Server_bootstrap_http.parse_bind_address "127.0.0.1" with
  | Ok address -> address
  | Error error -> Alcotest.fail (Server_bootstrap_http.bind_address_error_to_string error)
;;

let max_response_bytes = 1 lsl 20

(* The status line, the header lines up to the empty one, and the rest. *)
let response =
  let open Eio.Buf_read.Syntax in
  let rec past_headers () =
    let* line = Eio.Buf_read.line in
    if String.equal line "" then Eio.Buf_read.return () else past_headers ()
  in
  let* status_line = Eio.Buf_read.line in
  let* () = past_headers () in
  let+ body = Eio.Buf_read.take_all in
  status_line, body
;;

(* One HTTP/1.1 request on a connection of its own: the status and the body. *)
let request ~net ~port ?host ~meth path =
  let host = Option.value host ~default:(Printf.sprintf "127.0.0.1:%d" port) in
  Eio.Switch.run (fun sw ->
    let flow = Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port)) in
    Eio.Flow.copy_string
      (Printf.sprintf "%s %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n" meth path host)
      flow;
    let status_line, body = Eio.Buf_read.parse_exn ~max_size:max_response_bytes response flow in
    match String.split_on_char ' ' status_line with
    | (_ : string) :: status :: (_ : string list) ->
      (match int_of_string_opt status with
       | Some status -> status, body
       | None -> Alcotest.failf "no status in %S" status_line)
    | [] | [ (_ : string) ] -> Alcotest.failf "no status in %S" status_line)
;;

exception Served

let multi_account_of ~base ~config =
  match Read.boot ~base_path:base ~config_dir:(Some config) ~anonymous_mutations:false with
  | Ok (Read.Multi_account multi_account) -> multi_account
  | Ok (Read.Single_user (_ : Read.single_user)) -> Alcotest.fail "the boot found a single user"
  | Error (first, rest) -> Alcotest.failf "the boot refused: %s" (String.concat "; " (first :: rest))
;;

let seconds_to_serve = 30.

(* No TLS listener and no public identity: the listener is the loopback port
   alone, whatever the shell of the run holds. An empty value is read as
   unset. *)
let test_serves_its_table_alone () =
  Unix.putenv "MASC_HTTPS_PORT" "0";
  Unix.putenv "MASC_HTTP_BASE_URL" "";
  Eio_main.run (fun env ->
        let root = Filename.temp_dir "server-accounts-" "" in
        Fun.protect
          ~finally:(fun () -> remove_tree root)
          (fun () ->
            let base = Filename.concat root "base" in
            let config = Filename.concat root "config" in
            Unix.mkdir base 0o700;
            (match
               Authz_bootstrap.fresh_bootstrap
                 { Authz_bootstrap.base_path = base
                 ; config_dir = Some config
                 ; external_store = Filename.concat (Filename.concat root "store") "external.jsonl"
                 ; workspace_id = workspace
                 ; now_ms = (fun () -> at_ms)
                 }
             with
             | Ok _ -> ()
             | Error error ->
               Alcotest.failf "bootstrap refused: %s" (Authz_bootstrap.error_to_string error));
            write_file
              (Auth.auth_config_file base)
              {|{"enabled":true,"require_token":true,"account_mode":"Multi_account"}|};
            let multi_account = multi_account_of ~base ~config in
            let port = free_port () in
            let net = Eio.Stdenv.net env in
            let serve sw =
              let ready, set_ready = Eio.Promise.create () in
              Eio.Fiber.fork ~sw (fun () ->
                match
                  Server_accounts.run
                    ~sw
                    ~env
                    ~address:loopback
                    ~port
                    ~on_ready:(Eio.Promise.resolve set_ready)
                    multi_account
                with
                | Ok () -> ()
                | Error refusal -> Alcotest.fail (Server_accounts.refusal_to_string refusal));
              Eio.Promise.await ready;
              let status, body = request ~net ~port ~meth:"GET" Server_health_paths.health in
              Alcotest.(check int) "GET /health" 200 status;
              (match Yojson.Safe.from_string body with
               | `Assoc fields ->
                 Alcotest.(check (option string))
                   "the account mode of the health answer"
                   (Some "Multi_account")
                   (match List.assoc_opt "account_mode" fields with
                    | Some (`String mode) -> Some mode
                    | Some _ | None -> None);
                 Alcotest.(check bool)
                   "the health answer says nothing of the paths of the workspace"
                   false
                   (List.mem_assoc "paths" fields)
               | _ -> Alcotest.failf "the health answer is not an object: %S" body
               | exception Yojson.Json_error detail -> Alcotest.failf "%s: %S" detail body);
              (* The routes of the single-user server are not in the table,
                 the ones it answers without a credential included. *)
              List.iter
                (fun (meth, path) ->
                   Alcotest.(check int)
                     (meth ^ " " ^ path)
                     404
                     (fst (request ~net ~port ~meth path)))
                [ "GET", "/api/v1/dashboard/dev-token"
                ; "GET", "/api/v1/status"
                ; "POST", "/mcp"
                ; "DELETE", "/mcp"
                ; "GET", "/ws"
                ; "GET", "/"
                ];
              Alcotest.(check int)
                "a method the table does not hold for a path it holds"
                405
                (fst (request ~net ~port ~meth:"OPTIONS" Server_health_paths.health));
              Alcotest.(check int)
                "a Host that is not the listener"
                400
                (fst (request ~net ~port ~host:"example.com" ~meth:"GET" Server_health_paths.health));
              raise Served
            in
            match
              Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) seconds_to_serve (fun () ->
                Eio.Switch.run serve)
            with
            | () -> Alcotest.fail "the server returned"
            | exception Served -> ()))
;;

let () =
  Alcotest.run
    "server_accounts"
    [ ( "account server"
      , [ Alcotest.test_case "the kinds its table may hold" `Quick test_table_kinds
        ; Alcotest.test_case "it serves its table alone" `Quick test_serves_its_table_alone
        ] )
    ]
;;
