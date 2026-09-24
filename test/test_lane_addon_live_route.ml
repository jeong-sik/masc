(* GET /api/v1/lane-addons/live, stage 1 of RFC
   machine-spectating-goes-through-lanes (§2.1, §5): the MSX machine change
   counter and the read route over it. Drives the real Msx_lane with no ROM
   (the bus reads 0xFF) and the real lane-addon router. *)

open Alcotest
module Lane = Msx_lane
module Routes = Server_routes_http_routes_lane_addons

let remove_tree path =
  let rec go path =
    if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
      Array.iter (fun name -> go (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    end
    else Unix.unlink path
  in
  go path

let with_dir prefix f =
  let dir = Filename.temp_dir prefix "" in
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () -> f dir)

let eject_if_loaded () =
  match Lane.eject () with
  | Ok () | Error Lane.No_machine -> ()
  | Error e -> fail (Lane.error_to_string e)

let ok what = function
  | Ok _ -> ()
  | Error e -> fail (what ^ ": " ^ Lane.error_to_string e)

(* A machine whose ledger lives in [dir]/ledger, ejected afterwards. *)
let with_machine f =
  with_dir "msx-live-" (fun dir ->
    let ledger_dir = Filename.concat dir "ledger" in
    Fun.protect ~finally:eject_if_loaded (fun () ->
      ok "load" (Lane.load ~ledger_dir ~roms_dir:None ~cart_path:None ~disk_path:None);
      f ~dir ~ledger_dir))

let mark () =
  match Lane.live ~since:None with
  | Lane.Changed (mark, _) -> mark
  | Lane.Unchanged _ -> fail "a read without since answered unchanged"
  | Lane.Nothing_loaded -> fail "no machine is loaded"

let count () = (mark ()).Lane.count

let rises what before =
  let after = count () in
  check bool (what ^ " raises the change count") true (after > before);
  after

let stays what before = check int (what ^ " leaves the change count") before (count ())

let space = Result.get_ok (Lane.key_of_string "space")
let return = Result.get_ok (Lane.key_of_string "return")

let test_counter_moves_on_every_change () =
  eject_if_loaded ();
  check bool "no machine reads as nothing loaded" true
    (match Lane.live ~since:None with
     | Lane.Nothing_loaded -> true
     | Lane.Unchanged _ | Lane.Changed _ -> false);
  with_machine (fun ~dir ~ledger_dir ->
    let c = count () in
    ok "step" (Lane.step ~frames:1);
    let c = rises "step" c in
    ok "step_until_change" (Lane.step_until_change ~max_frames:2);
    let c = rises "step_until_change" c in
    ok "chord press"
      (Lane.press ~who:"live-test" ~keys:[space] ~hold_frames:1 ~step_frames:2 ~sequence:false);
    let c = rises "a chord press" c in
    ok "sequence press"
      (Lane.press ~who:"live-test" ~keys:[space; return] ~hold_frames:1 ~step_frames:2
         ~sequence:true);
    let c = rises "a sequence press" c in
    ok "step_frame" (Lane.step_frame ~frames:1);
    let c = rises "step_frame (the tick)" c in
    (* Reads and refusals leave it. *)
    let checkpoint = Filename.concat dir "slot.json" in
    ok "save" (Lane.save ~path:checkpoint);
    stays "save" c;
    ok "screen" (Lane.screen ());
    ok "capture_with_identity" (Lane.capture_with_identity ());
    stays "reads" c;
    check bool "a zero-frame step is refused" true (Result.is_error (Lane.step ~frames:0));
    check bool "a hold longer than the press is refused" true
      (Result.is_error
         (Lane.press ~who:"live-test" ~keys:[space] ~hold_frames:3 ~step_frames:2
            ~sequence:false));
    stays "a refusal" c;
    let incarnation = (mark ()).Lane.incarnation in
    ok "restore" (Lane.restore ~path:checkpoint ~ledger_dir);
    let c = rises "restore" c in
    check bool "restore names a new incarnation" true
      (not (String.equal incarnation (mark ()).Lane.incarnation));
    ok "eject" (Lane.eject ());
    check bool "an ejected machine reads as nothing loaded" true
      (match Lane.live ~since:(Some c) with
       | Lane.Nothing_loaded -> true
       | Lane.Unchanged _ | Lane.Changed _ -> false);
    ok "reload" (Lane.load ~ledger_dir ~roms_dir:None ~cart_path:None ~disk_path:None);
    let c = rises "eject and a new load (the count is never reused)" c in
    (* A press that raises: the ledger file is now a directory, so recording
       the first edge raises, before any frame runs. No test can make a later
       edge fail, so this pins the order instead: the count moves before the
       press touches the machine, so a raise after frames ran finds it moved
       too. *)
    let ledger_path = Filename.concat ledger_dir "ledger.jsonl" in
    Sys.remove ledger_path;
    Sys.mkdir ledger_path 0o755;
    (match
       Lane.press ~who:"live-test" ~keys:[space; return] ~hold_frames:1 ~step_frames:2
         ~sequence:true
     with
     | exception Sys_error _ -> ()
     | Ok _ | Error _ -> fail "a press over a directory ledger must raise");
    ignore (rises "a press that raised" c : int))

let test_since_answers_unchanged () =
  with_machine (fun ~dir:_ ~ledger_dir:_ ->
    let m = mark () in
    (match Lane.live ~since:(Some m.Lane.count) with
     | Lane.Unchanged same ->
         check int "unchanged carries the count" m.Lane.count same.Lane.count;
         check string "unchanged carries the incarnation" m.Lane.incarnation
           same.Lane.incarnation
     | Lane.Changed _ | Lane.Nothing_loaded -> fail "the current count must answer unchanged");
    (match Lane.live ~since:(Some (m.Lane.count - 1)) with
     | Lane.Changed (again, frame) ->
         check int "an older count gets the current count" m.Lane.count again.Lane.count;
         check int "the frame is width*height*3 RGB bytes"
           (frame.Lane.width * frame.Lane.height * 3) (String.length frame.Lane.rgb)
     | Lane.Unchanged _ | Lane.Nothing_loaded -> fail "an older count must get the frame");
    ok "step" (Lane.step ~frames:1);
    match Lane.live ~since:(Some m.Lane.count) with
    | Lane.Changed (after, _) ->
        check bool "a step makes the old count stale" true (after.Lane.count > m.Lane.count)
    | Lane.Unchanged _ | Lane.Nothing_loaded -> fail "a step must change the answer")

let contains ~sub text =
  let n = String.length sub and m = String.length text in
  let rec at i = i + n <= m && (String.sub text i n = sub || at (i + 1)) in
  at 0

let test_decode_live_query () =
  let decode = Routes.decode_live_query in
  check bool "msx_capture with no since" true
    (decode ["source_kind", "msx_capture"] = Ok (Routes.Msx_screen, None));
  check bool "msx_capture with a since" true
    (decode ["since", "7"; "source_kind", "msx_capture"] = Ok (Routes.Msx_screen, Some 7));
  let refused what fields expected =
    match decode fields with
    | Ok _ -> fail (what ^ " must be refused")
    | Error message ->
        check bool (what ^ ": " ^ message) true
          (contains ~sub:expected message)
  in
  List.iter
    (fun kind -> refused kind ["source_kind", kind] "has no screen")
    ["snapshot_file"; "lane_output"; "browser_document"];
  refused "an unknown kind" ["source_kind", "vcr_capture"] "unknown source_kind";
  refused "a missing kind" [] "requires source_kind";
  refused "a negative since" ["source_kind", "msx_capture"; "since", "-1"] "since";
  refused "a text since" ["source_kind", "msx_capture"; "since", "latest"] "since";
  refused "a repeated kind" ["source_kind", "msx_capture"; "source_kind", "msx_capture"]
    "duplicate";
  refused "an unknown parameter" ["source_kind", "msx_capture"; "until", "3"] "unknown live parameter"

(* ---- the route, through the real router and auth -------------------------- *)

let loopback_request_authority () =
  match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8935 with
  | Ok authority -> authority
  | Error `Malformed -> fail "failed to construct loopback request authority"

let dispatch_get ~sw ~clock ~state ~authorization ~target =
  Server_request_authority.with_current (loopback_request_authority ()) (fun () ->
    let router = Routes.add_routes ~sw ~clock (Masc.Http_server_eio.Router.create ()) in
    Server_auth.publish_server_state state;
    let response_buf = Buffer.create 4096 in
    let conn =
      Httpun.Server_connection.create (fun reqd ->
        Masc.Http_server_eio.Router.dispatch router (Httpun.Reqd.request reqd) reqd)
    in
    let request_str =
      Printf.sprintf
        "GET %s HTTP/1.1\r\n\
         Host: 127.0.0.1:8935\r\n\
         Origin: http://127.0.0.1:8935\r\n\
         %s\r\n"
        target
        (match authorization with
         | Some token -> Printf.sprintf "Authorization: Bearer %s\r\n" token
         | None -> "")
    in
    let bytes = Bigstringaf.of_string ~off:0 ~len:(String.length request_str) request_str in
    ignore (Httpun.Server_connection.read_eof conn bytes ~off:0 ~len:(Bigstringaf.length bytes));
    let rec flush () =
      match Httpun.Server_connection.next_write_operation conn with
      | `Write iovecs ->
          let written =
            List.fold_left
              (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
                Buffer.add_string response_buf
                  (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
                total + iov.len)
              0 iovecs
          in
          Httpun.Server_connection.report_write_result conn (`Ok written);
          flush ()
      | `Yield | `Close _ -> ()
    in
    flush ();
    Server_auth.clear_server_state ();
    Buffer.contents response_buf)

let status_of_response response =
  match String.split_on_char ' ' response with
  | _ :: status :: _ -> int_of_string status
  | _ -> failf "could not parse response status: %S" response

let body_json response =
  let separator = "\r\n\r\n" in
  let rec find i =
    if i + 4 > String.length response then failf "no body in %S" response
    else if String.sub response i 4 = separator then i + 4
    else find (i + 1)
  in
  let start = find 0 in
  Yojson.Safe.from_string (String.sub response start (String.length response - start))

let member name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let string_member name json =
  match member name json with Some (`String s) -> s | _ -> failf "no string %s" name

let int_member name json =
  match member name json with Some (`Int n) -> n | _ -> failf "no int %s" name

(* Every file under [root], relative, sorted. *)
let tree root =
  let rec go relative acc =
    let path = Filename.concat root relative in
    if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then
      Array.fold_left
        (fun acc name -> go (Filename.concat relative name) acc)
        acc (Sys.readdir path)
    else relative :: acc
  in
  List.sort String.compare
    (Array.fold_left (fun acc name -> go name acc) [] (Sys.readdir root))

let test_live_route () =
  with_dir "lane-live-route-" (fun base_path ->
    Auth.save_auth_config base_path
      { Masc_domain.default_auth_config with enabled = true; require_token = true };
    let token =
      match Auth.create_token base_path ~agent_name:"tui-watcher" ~role:Masc_domain.Admin with
      | Ok (token, _) -> token
      | Error err -> failf "create_token failed: %s" (Masc_domain.masc_error_to_string err)
    in
    let state = Masc.Mcp_server.For_testing.create_state ~base_path in
    Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
        let clock = (Eio.Stdenv.clock env :> float Eio.Time.clock_ty Eio.Resource.t) in
        let get ?(authorization = Some token) target =
          dispatch_get ~sw ~clock ~state ~authorization ~target
        in
        let live = "/api/v1/lane-addons/live?source_kind=msx_capture" in
        eject_if_loaded ();
        let refused = get ~authorization:None live in
        check int "no credential is refused" 401 (status_of_response refused);
        let nothing = get live in
        check int "no machine is still a 200" 200 (status_of_response nothing);
        check string "no machine is a typed answer" "no_machine"
          (string_member "state" (body_json nothing));
        with_machine (fun ~dir:_ ~ledger_dir:_ ->
          let first = get live in
          check int "a loaded machine answers 200" 200 (status_of_response first);
          let json = body_json first in
          check string "no since gets the frame" "changed" (string_member "state" json);
          check string "the answer names its source kind" "msx_capture"
            (string_member "source_kind" json);
          let n = int_member "change_count" json in
          let incarnation = string_member "incarnation" json in
          let screen = match member "screen" json with Some s -> s | None -> fail "no screen" in
          check string "the screen is rgb8" "rgb8" (string_member "format" screen);
          check int "the pixels are width*height*3 bytes"
            (int_member "width" screen * int_member "height" screen * 3)
            (String.length (Base64.decode_exn (string_member "rgb_base64" screen)));
          let files_before = tree base_path in
          let same = get (live ^ "&since=" ^ string_of_int n) in
          let json = body_json same in
          check string "since at the current count is unchanged" "unchanged"
            (string_member "state" json);
          check int "unchanged carries the count" n (int_member "change_count" json);
          check string "unchanged carries the incarnation" incarnation
            (string_member "incarnation" json);
          check bool "unchanged sends no screen" true (member "screen" json = None);
          ok "step" (Lane.step ~frames:1);
          let moved = body_json (get (live ^ "&since=" ^ string_of_int n)) in
          check string "a step makes the old since stale" "changed" (string_member "state" moved);
          check bool "the new count is larger" true (int_member "change_count" moved > n);
          List.iter
            (fun (target, what) ->
              check int what 400 (status_of_response (get target)))
            [ "/api/v1/lane-addons/live?source_kind=snapshot_file", "a screenless kind is a 400"
            ; "/api/v1/lane-addons/live?source_kind=browser_document", "a browser document is a 400"
            ; "/api/v1/lane-addons/live?source_kind=vcr_capture", "an unknown kind is a 400"
            ; "/api/v1/lane-addons/live", "a missing kind is a 400"
            ; live ^ "&since=soon", "a text since is a 400" ];
          check (list string) "live reads write no file under the workspace" files_before
            (tree base_path)))))

let () =
  run "lane addon live route"
    [ ( "change counter"
      , [ test_case "every path that runs or replaces the machine raises it" `Quick
            test_counter_moves_on_every_change
        ; test_case "since at the current count answers unchanged" `Quick
            test_since_answers_unchanged ] )
    ; ( "route"
      , [ test_case "the query decodes into a typed source" `Quick test_decode_live_query
        ; test_case "auth, unchanged, frame, 400 and no store writes" `Quick test_live_route ] )
    ]
