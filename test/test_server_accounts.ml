(* The account server of a multi-account installation (plan S1a): what its
   table may hold, and the server itself, started on the installation that the
   entry of the boot judged, on real files in a temporary directory and a
   loopback port. Its access is published once per process, so one case
   serves, the case whose boot stops does so before the publication, and the
   executable does not link masc_test_deps, which publishes the access of a
   single user. *)

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

let kind_label register =
  match Server_account_table.checked register with
  | Ok (_ : Server_account_table.t) -> "served"
  | Error { Server_account_table.path; access } ->
    Printf.sprintf "%s is %s" path (Yojson.Safe.to_string (Route_access.to_json access))
;;

(* A public route, as the probes of the account server are registered. That
   the table of the server itself is taken is the boot of the case below. *)
let public router =
  Server_route.get Server_route.Always_public Server_health_paths.health nothing router
;;

let test_table_kinds () =
  Alcotest.(check string) "a public route" "served" (kind_label public);
  Alcotest.(check string)
    "a route that authenticates a browser session itself"
    "served"
    (kind_label (fun router ->
       public router
       |> Server_route.post
            (Server_route.Self_authenticated Route_access.Browser_session)
            "/auth/logout"
            nothing));
  Alcotest.(check string)
    "a route behind a wrapper of the single-user server"
    {|/api/v1/status is {"kind":"read_auth"}|}
    (kind_label (fun router ->
       public router |> Server_route.get Server_route.Read_auth "/api/v1/status" nothing_with_state));
  Alcotest.(check string)
    "the dev-token route of the single-user server"
    {|/api/v1/dashboard/dev-token is {"kind":"self_authenticated","reason":"loopback_dev_token"}|}
    (kind_label (fun router ->
       public router
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

type installation =
  { base : string
  ; config : string
  ; store : string
  ; multi_account : Read.multi_account
  }

(* An activated installation that the entry of the boot judged. No TLS
   listener, no public identity and the default HTTP mode: the listener is
   the loopback port alone, whatever the shell of the run holds. An empty
   value is read as unset. *)
let with_installation f =
  Unix.putenv "MASC_HTTPS_PORT" "0";
  Unix.putenv "MASC_HTTP_BASE_URL" "";
  Unix.putenv "MASC_USE_H2" "auto";
  Eio_main.run (fun env ->
    let root = Filename.temp_dir "server-accounts-" "" in
    Fun.protect
      ~finally:(fun () -> remove_tree root)
      (fun () ->
        let base = Filename.concat root "base" in
        let config = Filename.concat root "config" in
        let store = Filename.concat (Filename.concat root "store") "external.jsonl" in
        Unix.mkdir base 0o700;
        (match
           Authz_bootstrap.fresh_bootstrap
             { Authz_bootstrap.base_path = base
             ; config_dir = Some config
             ; external_store = store
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
        f env { base; config; store; multi_account = multi_account_of ~base ~config }))
;;

let uncertain_label : Authz_zone.uncertain -> string = function
  | Authz_zone.Log_is_stopped _ -> "the log is stopped"
  | Authz_zone.Store_is_stopped _ -> "the store is stopped"
  | Authz_zone.Files_disagree _ -> "the files disagree"
  | Authz_zone.Store_answers_nothing -> "the store answers nothing"
;;

let mode_label : Authz_mode_state.t -> string = function
  | Authz_mode_state.Not_bootstrapped -> "not bootstrapped"
  | Authz_mode_state.Multi_account (_ : Authz_types.Workspace_id.t) -> "multi-account"
  | Authz_mode_state.Off (_ : Authz_types.Workspace_id.t) -> "off"
;;

let refusal_label : Server_accounts.refusal -> string = function
  | Server_accounts.Http_mode_refused _ -> "HTTP mode refused"
  | Server_accounts.Zone_not_opened _ -> "zone not opened"
  | Server_accounts.Zone_not_trusted uncertain -> "zone not trusted: " ^ uncertain_label uncertain
  | Server_accounts.Zone_not_multi_account mode -> "zone not multi-account: " ^ mode_label mode
  | Server_accounts.Route_of_another_kind _ -> "route of another kind"
  | Server_accounts.Https_listener_refused _ -> "HTTPS listener refused"
  | Server_accounts.Listener_not_bound { host; port = _; reason = _ } ->
    "listener not bound on " ^ host
  | Server_accounts.Access_not_published _ -> "access not published"
  | Server_accounts.Trust_policy_refused _ -> "trust policy refused"
;;

(* The three cases below stop before the access of the process is published,
   so the case that serves can still publish it. *)
let boot_outcome env ~port multi_account =
  Eio.Switch.run (fun sw ->
    match Server_accounts.run ~sw ~env ~address:loopback ~port multi_account with
    | Ok () -> "served"
    | Error refusal -> refusal_label refusal)
;;

(* The judgment read a store that matched the log. A store that is gone when
   the zone opens is the store of row 8, and the boot stops as that row
   stops. *)
let test_stops_when_the_store_changed () =
  with_installation (fun env { base = _; config = _; store; multi_account } ->
    Sys.remove store;
    Alcotest.(check string)
      "the boot over a store that is gone"
      "zone not trusted: the store answers nothing"
      (boot_outcome env ~port:(free_port ()) multi_account))
;;

(* The judgment read a log in Multi_account. An Off that is written before
   the zone opens leaves a zone that can be trusted and that serves no
   account. *)
let test_stops_when_the_accounts_were_turned_off () =
  with_installation (fun env { base; config; store = _; multi_account } ->
    (match
       Authz_off.turn_off ~base_path:base ~config_dir:(Some config) ~now_ms:(fun () -> at_ms + 1)
     with
     | Ok (_ : Authz_types.Workspace_id.t) -> ()
     | Error error -> Alcotest.failf "the Off was refused: %s" (Authz_off.error_to_string error));
    Alcotest.(check string)
      "the boot over a log that was turned off"
      "zone not multi-account: off"
      (boot_outcome env ~port:(free_port ()) multi_account))
;;

let recorded_port ~base =
  match Workspace_connection.read ~base_path:base with
  | Ok recorded -> Option.map Workspace_connection.to_int recorded
  | Error error -> Alcotest.fail (Workspace_connection.error_message error)
;;

(* A port that another socket listens on. *)
let test_stops_when_the_port_is_taken () =
  with_installation (fun env { base; config = _; store = _; multi_account } ->
    let taken = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    Fun.protect
      ~finally:(fun () -> Unix.close taken)
      (fun () ->
        Unix.bind taken (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
        Unix.listen taken 1;
        let port =
          match Unix.getsockname taken with
          | Unix.ADDR_INET ((_ : Unix.inet_addr), port) -> port
          | Unix.ADDR_UNIX (_ : string) -> Alcotest.fail "a TCP socket has no path"
        in
        Alcotest.(check string)
          "the boot on a port that is taken"
          "listener not bound on 127.0.0.1"
          (boot_outcome env ~port multi_account);
        (* A boot that stopped leaves no port for the CLI of the workspace. *)
        Alcotest.(check (option int)) "no port is recorded" None (recorded_port ~base)))
;;

let json_of label body =
  match Yojson.Safe.from_string body with
  | json -> json
  | exception Yojson.Json_error detail -> Alcotest.failf "%s: %s: %S" label detail body
;;

let test_serves_its_table_alone () =
  with_installation (fun env { base; config = _; store = _; multi_account } ->
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
      (match json_of "GET /health" body with
       | `Assoc fields ->
         Alcotest.(check (option string))
           "the account mode of the health answer"
           (Some "Multi_account")
           (match List.assoc_opt "account_mode" fields with
            | Some (`String mode) -> Some mode
            | Some _ | None -> None);
         (* Anyone who reaches the listener reads this answer, so the test
            names all of it: a field of the host or of the workspace (the
            build record carries the path of the executable) does not come in
            unnoticed. *)
         Alcotest.(check (list string))
           "the health answer holds the server, its version and the mode, and no more"
           [ "account_mode"; "server"; "version" ]
           (List.sort String.compare (List.map fst fields));
         Alcotest.(check bool)
           "every field of the health answer is a string"
           true
           (List.for_all
              (fun ((_ : string), value) ->
                match value with
                | `String (_ : string) -> true
                | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _ -> false)
              fields)
       | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
         Alcotest.failf "the health answer is not an object: %S" body);
      (* The probes say that the listener answers and that a decision can
         rest on the zone, and nothing of the process: the whole answer is
         compared. *)
      List.iter
        (fun (path, expected) ->
          let status, body = request ~net ~port ~meth:"GET" path in
          Alcotest.(check int) ("GET " ^ path) 200 status;
          Alcotest.(check string)
            ("the whole answer of " ^ path)
            expected
            (Yojson.Safe.to_string (json_of path body)))
        [ Server_health_paths.liveness, {|{"live":true}|}
        ; Server_health_paths.readiness, {|{"ready":true}|}
        ];
      (* The routes of the single-user server are not in the table, the ones
         it answers without a credential included. *)
      List.iter
        (fun (meth, path) ->
          Alcotest.(check int) (meth ^ " " ^ path) 404 (fst (request ~net ~port ~meth path)))
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
      (* The CLI of the workspace finds the port without being told. *)
      Alcotest.(check (option int)) "the port the workspace records" (Some port) (recorded_port ~base);
      raise Served
    in
    match
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) seconds_to_serve (fun () ->
        Eio.Switch.run serve)
    with
    | () -> Alcotest.fail "the server returned"
    | exception Served -> ())
;;

let () =
  Alcotest.run
    "server_accounts"
    [ ( "account server"
      , [ Alcotest.test_case "the kinds its table may hold" `Quick test_table_kinds
        ; Alcotest.test_case "the boot stops when the store changed" `Quick test_stops_when_the_store_changed
        ; Alcotest.test_case
            "the boot stops when the accounts were turned off"
            `Quick
            test_stops_when_the_accounts_were_turned_off
        ; Alcotest.test_case "the boot stops when the port is taken" `Quick test_stops_when_the_port_is_taken
        ; Alcotest.test_case "it serves its table alone" `Quick test_serves_its_table_alone
        ] )
    ]
;;
