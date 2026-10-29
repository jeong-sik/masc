open Alcotest
open Masc
module Http = Http_server_eio
module Precondition = Request_workspace_precondition
module Guard = Server_workspace_precondition

let served = { Precondition.base_path = "/srv/work"; masc_root = "/srv/work/.masc" }
let other_base_path = "/srv/other"
let routed_path = "/workspace-precondition-probe"

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

(* A decision as a client tells it apart: the refusal code, or whether the
   request goes on. *)
let label = function
  | Precondition.No_precondition -> "no_precondition"
  | Precondition.Precondition_met -> "precondition_met"
  | Precondition.Refused refusal -> Precondition.refusal_code refusal
;;

let parse expected_base_path expected_masc_root =
  match Precondition.parse ~expected_base_path ~expected_masc_root with
  | Ok None -> "no_precondition"
  | Ok (Some _) -> "parsed"
  | Error refusal -> Precondition.refusal_code refusal
;;

let decide ?(served = Some served) ?(ready = true) expected =
  label (Precondition.decide expected ~served ~ready)
;;

let precondition_headers ?(base_path = served.base_path) ?(masc_root = served.masc_root) () =
  [ Precondition.expected_base_path_header, base_path
  ; Precondition.expected_masc_root_header, masc_root
  ]
;;

let headers_for (workspace : Precondition.workspace) =
  precondition_headers ~base_path:workspace.base_path ~masc_root:workspace.masc_root ()
;;

let test_absent_precondition_is_not_checked () =
  check string "no header" "no_precondition" (parse [] [])
;;

let test_both_headers_parse_to_the_expected_workspace () =
  match Precondition.parse ~expected_base_path:[ served.base_path ] ~expected_masc_root:[ served.masc_root ] with
  | Ok (Some expected) ->
    check string "base path" served.base_path expected.base_path;
    check string "masc root" served.masc_root expected.masc_root
  | Ok None | Error _ -> fail "a well-formed pair did not parse"
;;

let test_malformed_precondition_is_refused () =
  List.iter
    (fun (name, base_paths, masc_roots) ->
      check string name "invalid_workspace_precondition" (parse base_paths masc_roots))
    [ "base path alone", [ served.base_path ], []
    ; "masc root alone", [], [ served.masc_root ]
    ; "base path twice", [ served.base_path; served.base_path ], [ served.masc_root ]
    ; "masc root twice", [ served.base_path ], [ served.masc_root; served.masc_root ]
    ; "empty base path", [ "" ], [ served.masc_root ]
    ; "relative masc root", [ served.base_path ], [ "work/.masc" ]
    ]
;;

let test_served_workspace_meets_the_precondition () =
  check string "same paths" "precondition_met" (decide served)
;;

let test_another_workspace_is_refused () =
  List.iter
    (fun (name, expected) -> check string name "workspace_precondition_failed" (decide expected))
    [ "another base path", { served with Precondition.base_path = other_base_path }
    ; "another masc root", { served with masc_root = Filename.concat other_base_path ".masc" }
    ; "a trailing slash is another spelling", { served with base_path = served.base_path ^ "/" }
    ];
  check
    string
    "a mismatch is refused before readiness"
    "workspace_precondition_failed"
    (decide ~ready:false { served with base_path = other_base_path })
;;

let test_booting_server_refuses_a_precondition () =
  check string "no server state" "server_booting" (decide ~served:None served);
  check string "not ready" "server_booting" (decide ~ready:false served)
;;

let request ?(target = routed_path) headers =
  Httpun.Request.create ~headers:(Httpun.Headers.of_list headers) `GET target
;;

let check_request ?(path = routed_path) headers =
  label (Guard.check_request ~served:(fun () -> Some served) ~ready:true ~path (request ~target:path headers))
;;

let test_header_names_are_case_insensitive () =
  check
    string
    "mixed-case names"
    "precondition_met"
    (check_request
       [ String.uppercase_ascii Precondition.expected_base_path_header, served.base_path
       ; String.capitalize_ascii Precondition.expected_masc_root_header, served.masc_root
       ])
;;

let test_repeated_header_field_is_refused () =
  check
    string
    "two base path fields"
    "invalid_workspace_precondition"
    (check_request ((Precondition.expected_base_path_header, served.base_path) :: precondition_headers ()))
;;

let test_only_health_skips_the_check () =
  let another = precondition_headers ~base_path:other_base_path () in
  check string "health" "no_precondition" (check_request ~path:Server_health_paths.health another);
  List.iter
    (fun path -> check string path "workspace_precondition_failed" (check_request ~path another))
    [ Server_health_paths.liveness; Server_health_paths.readiness; routed_path ]
;;

(* The server's paths are resolved only for a request that names a
   workspace. *)
let test_served_workspace_is_read_only_for_a_wellformed_precondition () =
  let reads = ref 0 in
  let counted_served () =
    incr reads;
    Some served
  in
  List.iter
    (fun (name, headers, reads_expected) ->
      reads := 0;
      ignore
        (Guard.check_request ~served:counted_served ~ready:true ~path:routed_path (request headers)
          : Precondition.decision);
      check int name reads_expected !reads)
    [ "no header", [], 0
    ; "base path alone", [ Precondition.expected_base_path_header, served.base_path ], 0
    ; ( "repeated field"
      , (Precondition.expected_base_path_header, served.base_path) :: precondition_headers ()
      , 0 )
    ; "well-formed pair", precondition_headers (), 1
    ]
;;

let body_code body =
  Yojson.Safe.Util.(Yojson.Safe.from_string body |> member "code" |> to_string_option)
;;

let test_refusal_responses () =
  List.iter
    (fun (refusal, status, headers) ->
      let code = Precondition.refusal_code refusal in
      check int (code ^ " status") status (Httpun.Status.to_code (Guard.refusal_status refusal));
      check (list (pair string string)) (code ^ " headers") headers (Guard.refusal_headers refusal);
      check
        (option string)
        (code ^ " body code")
        (Some code)
        (body_code (Yojson.Safe.to_string (Guard.refusal_body refusal))))
    [ Precondition.Invalid_precondition "a header is empty", 400, []
    ; Precondition.Workspace_mismatch, 409, []
    ; Precondition.Server_booting, 503, [ "retry-after", "1" ]
    ]
;;

(* The entries read the server state and the startup readiness. *)
let with_server_state ~base_path f =
  let previous_state = Server_auth.For_testing.snapshot_server_state () in
  let previous_startup = Server_startup_state.snapshot () in
  Fun.protect
    ~finally:(fun () ->
      Server_auth.For_testing.restore_server_state previous_state;
      Server_startup_state.For_testing.restore previous_startup)
    (fun () ->
      Server_auth.For_testing.restore_server_state
        (Some (Mcp_server.For_testing.create_state ~base_path));
      f ())
;;

let set_ready ready =
  Server_startup_state.For_testing.restore
    { (Server_startup_state.snapshot ()) with state_ready = ready }
;;

(* What [/health] tells a client this server serves. *)
let health_workspace () =
  let paths = Server_routes_http_runtime.health_path_diagnostics () in
  { Precondition.base_path = paths.Server_base_path_diagnostics.effective_base_path
  ; masc_root = paths.effective_masc_root
  }
;;

let workspace = testable (fun ppf (w : Precondition.workspace) ->
  Format.fprintf ppf "%s %s" w.base_path w.masc_root) ( = )

(* A workspace directory replaced by a symlink after boot: /health and the
   check both resolve it again, so a client that follows /health is admitted
   and the path it had before is another workspace. *)
let test_health_and_the_check_name_the_same_workspace_after_a_retarget () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let root = Filename.temp_dir "workspace-retarget" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.clear_fs (); remove_tree root) @@ fun () ->
  let first = Filename.concat root "first" and second = Filename.concat root "second" in
  List.iter
    (fun dir ->
      Unix.mkdir dir 0o755;
      Unix.mkdir (Filename.concat dir ".masc") 0o755)
    [ first; second ];
  with_server_state ~base_path:first @@ fun () ->
  set_ready true;
  let decision (expected : Precondition.workspace) =
    label (Guard.check_current_request ~path:routed_path (request (headers_for expected)))
  in
  let before = health_workspace () in
  check (option workspace) "the check serves what /health reports" (Some before) (Guard.served_workspace ());
  check string "the reported workspace is admitted" "precondition_met" (decision before);
  Unix.rename first (first ^ ".moved");
  Unix.symlink second first;
  let after = health_workspace () in
  check bool "/health follows the new target" true (before <> after);
  check (option workspace) "the check follows it too" (Some after) (Guard.served_workspace ());
  check string "the workspace /health reports now is admitted" "precondition_met" (decision after);
  check string "the one it reported before is another workspace" "workspace_precondition_failed"
    (decision before)
;;

type reply =
  { status : int
  ; headers : (string * string) list
  ; body : string
  }

let header_end raw =
  let rec find index =
    if index + 4 > String.length raw
    then fail ("no HTTP/1.1 header end: " ^ raw)
    else if String.equal (String.sub raw index 4) "\r\n\r\n"
    then index
    else find (index + 1)
  in
  find 0
;;

let http1_reply raw =
  let head_end = header_end raw in
  match String.split_on_char '\n' (String.sub raw 0 head_end) with
  | [] -> fail "empty HTTP/1.1 reply"
  | status_line :: header_lines ->
    let status = int_of_string (List.nth (String.split_on_char ' ' status_line) 1) in
    let headers =
      List.filter_map
        (fun line ->
          match String.index_opt line ':' with
          | None -> None
          | Some colon ->
            Some
              ( String.lowercase_ascii (String.sub line 0 colon)
              , String.trim (String.sub line (colon + 1) (String.length line - colon - 1)) ))
        header_lines
    in
    { status; headers; body = String.sub raw (head_end + 4) (String.length raw - head_end - 4) }
;;

(* The HTTP/1.1 entry runs [guard_http1] in front of routing; a route here
   answers 404, as the HTTP/2 gateway's fallback does. *)
let http1_exchange ~env:_ headers =
  let output = Buffer.create 512 in
  let connection =
    Httpun.Server_connection.create (fun reqd ->
      let request = Httpun.Reqd.request reqd in
      Guard.guard_http1 ~path:(Http.Request.path request) request reqd ~admitted:(fun () ->
        Http.Response.json_value ~status:`Not_found (`Assoc [ "routed", `Bool true ]) reqd))
  in
  let raw_request =
    Printf.sprintf
      "GET %s HTTP/1.1\r\nHost: localhost:8935\r\n%sContent-Length: 0\r\n\r\n"
      routed_path
      (String.concat "" (List.map (fun (name, value) -> name ^ ": " ^ value ^ "\r\n") headers))
  in
  let input = Bigstringaf.of_string ~off:0 ~len:(String.length raw_request) raw_request in
  ignore (Httpun.Server_connection.read_eof connection input ~off:0 ~len:(Bigstringaf.length input));
  let rec drain () =
    match Httpun.Server_connection.next_write_operation connection with
    | `Write iovecs ->
      let written =
        List.fold_left
          (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
            Buffer.add_string output (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
            total + iov.len)
          0
          iovecs
      in
      Httpun.Server_connection.report_write_result connection (`Ok written);
      drain ()
    | `Yield | `Close _ -> ()
  in
  drain ();
  http1_reply (Buffer.contents output)
;;

(* The real HTTP/2 gateway handler, driven through in-memory client and
   server connections. *)
let h2_exchange ~env headers =
  Eio.Switch.run
  @@ fun sw ->
  let trust_policy =
    match
      Server_request_authority.make_trust_policy
        ~bind_host:"localhost"
        ~bind_port:8935
        ~explicit_base_url:None
    with
    | Ok policy -> policy
    | Error error -> fail (Server_request_authority.trust_policy_error_to_string error)
  in
  let handler =
    Server_h2_gateway.make_request_handler ~routes:(Server_routes_http.make_routes ~port:0 ~host:"127.0.0.1" ~sw ~clock:(Eio.Stdenv.clock env))
      ~trust_policy
      ~sw
      ~request_sw:sw
      ~clock:(Eio.Stdenv.clock env)
      ~server_start_time:0.
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 54321))
  in
  let response = ref None in
  let body = Buffer.create 512 in
  let complete = ref false in
  let client = H2.Client_connection.create ~error_handler:(fun _ -> fail "H2 connection error") () in
  let request =
    H2.Request.create
      ~scheme:"http"
      `GET
      routed_path
      ~headers:(H2.Headers.of_list ((":authority", "localhost:8935") :: headers))
  in
  let writer =
    H2.Client_connection.request
      client
      request
      ~error_handler:(fun _ -> fail "H2 stream error")
      ~response_handler:(fun reply reader ->
        response := Some (H2.Status.to_code reply.H2.Response.status, H2.Headers.to_list reply.headers);
        let rec consume () =
          H2.Body.Reader.schedule_read
            reader
            ~on_eof:(fun () -> complete := true)
            ~on_read:(fun buffer ~off ~len ->
              Buffer.add_string body (Bigstringaf.substring buffer ~off ~len);
              consume ())
        in
        consume ())
  in
  H2.Body.Writer.close writer;
  let server = H2.Server_connection.create handler in
  let transfer next_write report_write read =
    let rec drain progressed =
      match next_write () with
      | `Write iovecs ->
        let written =
          List.fold_left
            (fun total (iov : Bigstringaf.t H2.IOVec.t) ->
              let rec feed off remaining =
                if remaining > 0
                then (
                  let consumed = read iov.buffer ~off ~len:remaining in
                  if consumed <= 0 then fail "H2 transfer made no progress";
                  feed (off + consumed) (remaining - consumed))
              in
              feed iov.off iov.len;
              total + iov.len)
            0
            iovecs
        in
        report_write (`Ok written);
        drain true
      | `Yield | `Close _ -> progressed
    in
    drain false
  in
  let rec pump () =
    let sent =
      transfer
        (fun () -> H2.Client_connection.next_write_operation client)
        (H2.Client_connection.report_write_result client)
        (H2.Server_connection.read server)
    in
    let received =
      transfer
        (fun () -> H2.Server_connection.next_write_operation server)
        (H2.Server_connection.report_write_result server)
        (H2.Client_connection.read client)
    in
    if !complete
    then ()
    else if sent || received
    then pump ()
    else fail "H2 exchange stalled before the response completed"
  in
  pump ();
  match !response with
  | Some (status, headers) -> { status; headers; body = Buffer.contents body }
  | None -> fail "H2 exchange has no response"
;;

let routed_status = 404

let check_reply name ~status ~code reply =
  check int (name ^ " status") status reply.status;
  match code with
  | None -> ()
  | Some code ->
    check (option string) (name ^ " code") (Some code) (body_code reply.body);
    check
      (option string)
      (name ^ " retry-after")
      (if String.equal code "server_booting" then Some "1" else None)
      (List.assoc_opt "retry-after" reply.headers)
;;

let check_entry exchange () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Filename.temp_dir "workspace-precondition" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.clear_fs (); remove_tree base_path) @@ fun () ->
  with_server_state ~base_path @@ fun () ->
  let reported = health_workspace () in
  List.iter
    (fun (name, ready, headers, status, code) ->
      set_ready ready;
      check_reply name ~status ~code (exchange ~env headers))
    [ "no precondition reaches routing", true, [], routed_status, None
    ; "the workspace /health reports reaches routing", true, headers_for reported, routed_status, None
    ; ( "another workspace"
      , true
      , headers_for { reported with base_path = other_base_path }
      , 409
      , Some "workspace_precondition_failed" )
    ; ( "base path alone"
      , true
      , [ Precondition.expected_base_path_header, reported.base_path ]
      , 400
      , Some "invalid_workspace_precondition" )
    ; "not ready", false, headers_for reported, 503, Some "server_booting"
    ];
  (* The same request, refused while booting, goes through once ready. *)
  set_ready false;
  check_reply "booting" ~status:503 ~code:(Some "server_booting") (exchange ~env (headers_for reported));
  set_ready true;
  check_reply "ready" ~status:routed_status ~code:None (exchange ~env (headers_for reported))
;;

let () =
  run
    "request workspace precondition"
    [ ( "parse"
      , [ test_case "absent precondition" `Quick test_absent_precondition_is_not_checked
        ; test_case "well-formed pair" `Quick test_both_headers_parse_to_the_expected_workspace
        ; test_case "malformed precondition" `Quick test_malformed_precondition_is_refused
        ] )
    ; ( "decision"
      , [ test_case "served workspace" `Quick test_served_workspace_meets_the_precondition
        ; test_case "another workspace" `Quick test_another_workspace_is_refused
        ; test_case "booting server" `Quick test_booting_server_refuses_a_precondition
        ] )
    ; ( "request"
      , [ test_case "case-insensitive names" `Quick test_header_names_are_case_insensitive
        ; test_case "repeated field" `Quick test_repeated_header_field_is_refused
        ; test_case "health is not checked" `Quick test_only_health_skips_the_check
        ; test_case "paths read only when asked" `Quick
            test_served_workspace_is_read_only_for_a_wellformed_precondition
        ; test_case "refusal responses" `Quick test_refusal_responses
        ] )
    ; ( "served workspace"
      , [ test_case "retargeted after boot" `Quick
            test_health_and_the_check_name_the_same_workspace_after_a_retarget
        ] )
    ; ( "entries"
      , [ test_case "HTTP/1.1" `Quick (check_entry http1_exchange)
        ; test_case "HTTP/2 gateway" `Quick (check_entry h2_exchange)
        ] )
    ]
;;
