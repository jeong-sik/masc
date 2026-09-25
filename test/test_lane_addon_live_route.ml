(* GET /api/v1/lane-addons/live, stage 1 of RFC
   machine-spectating-goes-through-lanes (§2.1, §5): the MSX and DOS machine
   change counters and the read route over them. Drives the real Msx_lane
   with no ROM (the bus reads 0xFF), the real Dos_lane with hand-assembled
   COM programs, and the real lane-addon router. *)

open Alcotest
module Lane = Msx_lane
module Routes = Server_routes_http_routes_lane_addons
module Sources = Masc.Lane_addon_sources

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

(* The lock-free mark must be the one a locked read reports. *)
let published_matches what =
  let m = mark () in
  check bool (what ^ ": the published mark is the locked one") true
    (Lane.current_publication () = Lane.Stable m)

let rises what before =
  let after = count () in
  check bool (what ^ " raises the change count") true (after > before);
  published_matches what;
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
    let previous = c in
    let c = rises "a chord press" c in
    check int "a chord publishes one completed mark" (previous + 1) c;
    ok "sequence press"
      (Lane.press ~who:"live-test" ~keys:[space; return] ~hold_frames:1 ~step_frames:2
         ~sequence:true);
    let previous = c in
    let c = rises "a sequence press" c in
    check int "a multi-tap press publishes one completed mark" (previous + 1) c;
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
    let before_eject = mark () in
    ok "eject" (Lane.eject ());
    check bool "an ejected machine publishes no mark" true
      (Lane.current_publication () = Lane.No_screen);
    check bool "an ejected machine reads as nothing loaded" true
      (match Lane.live ~since:(Some { before_eject with Lane.count = c }) with
       | Lane.Nothing_loaded -> true
       | Lane.Unchanged _ | Lane.Changed _ -> false);
    ok "reload" (Lane.load ~ledger_dir ~roms_dir:None ~cart_path:None ~disk_path:None);
    let c = rises "eject and a new load (the count is never reused)" c in
    (* A press that raises: the ledger file is now a directory, so recording
       the first edge raises before any frame runs, and the keys go back up.
       Nothing a watcher sees moved, so the count stays. No test can make a
       later edge fail; a raise after frames ran finds the count moved because
       the enclosing operation publishes its final mark when it releases the
       machine lock. *)
    let ledger_path = Filename.concat ledger_dir "ledger.jsonl" in
    Sys.remove ledger_path;
    Sys.mkdir ledger_path 0o755;
    (match
       Lane.press ~who:"live-test" ~keys:[space; return] ~hold_frames:1 ~step_frames:2
         ~sequence:true
     with
     | exception Sys_error _ -> ()
     | Ok _ | Error _ -> fail "a press over a directory ledger must raise");
    stays "a press that raised before any frame" c;
    published_matches "a press that raised before any frame")

let test_since_answers_unchanged () =
  with_machine (fun ~dir:_ ~ledger_dir:_ ->
    let m = mark () in
    (match Lane.live ~since:(Some m) with
     | Lane.Unchanged same ->
         check int "unchanged carries the count" m.Lane.count same.Lane.count;
         check string "unchanged carries the incarnation" m.Lane.incarnation
           same.Lane.incarnation
     | Lane.Changed _ | Lane.Nothing_loaded -> fail "the current count must answer unchanged");
    (match Lane.live ~since:(Some { m with Lane.incarnation = "another-incarnation" }) with
     | Lane.Changed _ -> ()
     | Lane.Unchanged _ | Lane.Nothing_loaded ->
         fail "the same count under another incarnation must get the frame");
    (match Lane.live ~since:(Some { m with Lane.count = m.Lane.count - 1 }) with
     | Lane.Changed (again, frame) ->
         check int "an older count gets the current count" m.Lane.count again.Lane.count;
         check int "the frame is width*height*3 RGB bytes"
           (frame.Lane.width * frame.Lane.height * 3) (String.length frame.Lane.rgb)
     | Lane.Unchanged _ | Lane.Nothing_loaded -> fail "an older count must get the frame");
    ok "step" (Lane.step ~frames:1);
    match Lane.live ~since:(Some m) with
    | Lane.Changed (after, _) ->
        check bool "a step makes the old count stale" true (after.Lane.count > m.Lane.count)
    | Lane.Unchanged _ | Lane.Nothing_loaded -> fail "a step must change the answer")

let contains ~sub text =
  let n = String.length sub and m = String.length text in
  let rec at i = i + n <= m && (String.sub text i n = sub || at (i + 1)) in
  at 0

let test_decode_live_query () =
  let decode = Routes.decode_live_query in
  List.iter
    (fun reader ->
      let kind = Sources.kind_of_live_reader reader in
      let wire = Sources.kind_to_string kind in
      check bool (wire ^ " maps back to its live reader") true
        (Sources.kind_of_string wire = Some kind
         && Sources.live_screen_of_kind kind = Some reader))
    [Routes.Msx_screen; Routes.Dos_screen];
  check bool "msx_capture with no since" true
    (decode ["source_kind", "msx_capture"] = Ok (Routes.Msx_screen, None));
  check bool "msx_capture with a since" true
    (decode ["since", "7"; "incarnation", "inc-a"; "source_kind", "msx_capture"]
     = Ok (Routes.Msx_screen, Some { Routes.count = 7; incarnation = "inc-a" }));
  check bool "dos_capture decodes to the DOS screen" true
    (decode ["source_kind", "dos_capture"; "since", "0"; "incarnation", "inc-b"]
     = Ok (Routes.Dos_screen, Some { Routes.count = 0; incarnation = "inc-b" }));
  let refused what fields expected =
    match decode fields with
    | Ok _ -> fail (what ^ " must be refused")
    | Error message ->
        check bool (what ^ ": " ^ message) true
          (contains ~sub:expected message)
  in
  List.iter
    (fun kind -> refused kind ["source_kind", kind] "live accepts msx_capture and dos_capture")
    ["snapshot_file"; "lane_output"; "browser_document"];
  refused "an unknown kind" ["source_kind", "vcr_capture"] "unknown source_kind";
  refused "a missing kind" [] "requires source_kind";
  let with_inc fields = ("incarnation", "inc-a") :: fields in
  refused "a negative since" (with_inc ["source_kind", "msx_capture"; "since", "-1"]) "since";
  refused "a text since" (with_inc ["source_kind", "msx_capture"; "since", "latest"]) "since";
  refused "a hex since" (with_inc ["source_kind", "msx_capture"; "since", "0x10"]) "since";
  refused "an underscored since" (with_inc ["source_kind", "msx_capture"; "since", "1_000"]) "since";
  refused "a since past the largest int"
    (with_inc ["source_kind", "msx_capture"; "since", "99999999999999999999999"]) "too large";
  refused "an empty incarnation"
    ["source_kind", "msx_capture"; "since", "7"; "incarnation", ""] "incarnation must be non-empty";
  refused "a since without an incarnation" ["source_kind", "msx_capture"; "since", "7"] "together";
  refused "an incarnation without a since" ["source_kind", "msx_capture"; "incarnation", "inc-a"]
    "together";
  refused "a repeated kind" ["source_kind", "msx_capture"; "source_kind", "msx_capture"]
    "duplicate";
  refused "an unknown parameter" ["source_kind", "msx_capture"; "until", "3"] "unknown live parameter"

(* ---- DOS ------------------------------------------------------------------ *)

(* Prints HI, waits for a key, exits. The same bytes as test_dos_tools's.

   org 0x100: mov ah,9 / mov dx,msg / int 21h
              wait: mov ah,0 / int 16h / or ax,ax / jz wait
              int 20h / "HI$" *)
let hello_com =
  "\xb4\x09\xba\x11\x01\xcd\x21\xb4\x00\xcd\x16\x09\xc0\x74\xf8\xcd\x20HI$"

(* lea ax, ax: an instruction the core does not implement. Cpu86 raises after
   fetching the opcode and the modrm byte and leaves IP past them, so the next
   run starts at the next instruction; past the image memory is zero, and
   00 00 (add [bx+si], al) runs fine. One copy per run attempt -- the load's
   boot, then one step -- makes every attempt fault at its first instruction
   and [steps] never move. *)
let fault_com = "\x8d\xc0\x8d\xc0"

let who = "live-test"
let dos_ok what = function
  | Ok _ -> ()
  | Error e -> fail (what ^ ": " ^ Dos_lane.error_to_string e)

let dos_eject_if_loaded () =
  match Dos_lane.eject ~who ~announce:ignore () with
  | Ok () | Error Dos_lane.No_machine -> ()
  | Error e -> fail (Dos_lane.error_to_string e)

let dos_load ~dir program_bytes =
  Dos_lane.load ~who ~ledger_dir:(Filename.concat dir "ledger")
    ~saves_dir:(Filename.concat dir "saves") ~program_name:"game.com" ~program_bytes
    ~files:[] ~announce:ignore

let with_dos f =
  with_dir "dos-live-" (fun dir ->
    Fun.protect ~finally:dos_eject_if_loaded (fun () -> f ~dir))

let dos_mark () =
  match Dos_lane.live ~since:None with
  | Dos_lane.Changed (mark, _) -> mark
  | Dos_lane.Unchanged _ -> fail "a read without since answered unchanged"
  | Dos_lane.Nothing_loaded -> fail "no DOS machine is loaded"

let dos_count () =
  let m = dos_mark () in
  check bool "the published DOS mark is the locked one" true
    (Dos_lane.current_publication () = Dos_lane.Stable m);
  m.Dos_lane.count

let dos_steps () =
  match Dos_lane.screen () with
  | Ok o -> o.Dos_lane.steps
  | Error e -> fail (Dos_lane.error_to_string e)

let dos_rises what before =
  let after = dos_count () in
  check bool (what ^ " raises the DOS change count") true (after > before);
  after

let dos_stays what before =
  check int (what ^ " leaves the DOS change count") before (dos_count ())

(* The mouse is not driven here: #38726 makes a click on a program that never
   asked for a mouse a refusal, so a click case would pin today's accepting
   shape. [click] marks through the same call as [step]. *)
let test_dos_counter_moves_on_every_run () =
  dos_eject_if_loaded ();
  check bool "no DOS machine publishes no mark" true
    (Dos_lane.current_publication () = Dos_lane.No_screen);
  check bool "no DOS machine reads as nothing loaded" true
    (match Dos_lane.live ~since:None with
     | Dos_lane.Nothing_loaded -> true
     | Dos_lane.Unchanged _ | Dos_lane.Changed _ -> false);
  with_dos (fun ~dir ->
    dos_ok "load" (dos_load ~dir hello_com);
    let c = dos_count () in
    dos_ok "step" (Dos_lane.step ~who ~steps:1000 ~until_ready:true);
    let c = dos_rises "step" c in
    (* Reads and refusals leave it. *)
    dos_ok "screen" (Dos_lane.screen ());
    dos_ok "capture_with_identity" (Dos_lane.capture_with_identity ());
    dos_ok "pass" (Dos_lane.pass ~who ~to_:(Some who) ~announce:ignore);
    dos_stays "reads and a pass" c;
    check bool "an empty press is refused" true
      (Result.is_error (Dos_lane.press ~who ~keys:[] ~steps:1000));
    check bool "an unknown key is refused" true
      (Result.is_error (Dos_lane.press ~who ~keys:["hyperspace"] ~steps:1000));
    check bool "another caller is refused" true
      (Result.is_error (Dos_lane.step ~who:"someone-else" ~steps:1000 ~until_ready:true));
    dos_stays "a refusal" c;
    dos_ok "press" (Dos_lane.press ~who ~keys:["x"] ~steps:100_000);
    let c = dos_rises "press" c in
    (* The program took its key and exited; typing still runs the core (for
       no instructions) and still counts as an attempt. *)
    dos_ok "type_text" (Dos_lane.type_text ~who ~text:"y" ~steps:100_000);
    let c = dos_rises "type_text" c in
    dos_ok "eject" (Dos_lane.eject ~who ~announce:ignore ());
    check bool "an ejected DOS machine publishes no mark" true
      (Dos_lane.current_publication () = Dos_lane.No_screen);
    (* A program that faults at its first instruction: the boot and every
       step after it run zero instructions, so [steps] stays at 0, and the
       count still rises on each attempt. *)
    check bool "the faulting load reports the fault" true
      (match dos_load ~dir fault_com with
       | Error (Dos_lane.Guest_fault _) -> true
       | Ok _ | Error _ -> false);
    let c = dos_rises "a load after an eject (the count is never reused)" c in
    let steps = dos_steps () in
    check bool "the faulting step reports the fault" true
      (match Dos_lane.step ~who ~steps:1000 ~until_ready:false with
       | Error (Dos_lane.Guest_fault _) -> true
       | Ok _ | Error _ -> false);
    check int "a zero-step fault leaves steps" steps (dos_steps ());
    ignore (dos_rises "a run that faulted at its first instruction" c : int))

(* The same program loaded twice boots the same way and can reach the same
   steps; a spectator holding the first machine's mark must still get the
   second machine's frame. *)
let test_dos_reload_is_not_unchanged () =
  with_dos (fun ~dir ->
    dos_ok "first load" (dos_load ~dir hello_com);
    let first = dos_mark () in
    let first_steps = dos_steps () in
    dos_ok "second load" (dos_load ~dir hello_com);
    let second = dos_mark () in
    check int "the same program boots to the same steps" first_steps (dos_steps ());
    check bool "each load names its own incarnation" false
      (String.equal first.Dos_lane.incarnation second.Dos_lane.incarnation);
    (match Dos_lane.live ~since:(Some first) with
     | Dos_lane.Changed (now, frame) ->
         check int "the reload's count comes back" second.Dos_lane.count now.Dos_lane.count;
         check int "the frame is width*height*3 RGB bytes"
           (frame.Dos_lane.width * frame.Dos_lane.height * 3) (String.length frame.Dos_lane.rgb)
     | Dos_lane.Unchanged _ | Dos_lane.Nothing_loaded ->
         fail "the first load's mark must not answer unchanged");
    (match Dos_lane.live ~since:(Some { second with Dos_lane.incarnation = first.Dos_lane.incarnation }) with
     | Dos_lane.Changed _ -> ()
     | Dos_lane.Unchanged _ | Dos_lane.Nothing_loaded ->
         fail "the current count under the old incarnation must get the frame");
    match Dos_lane.live ~since:(Some second) with
    | Dos_lane.Unchanged _ -> ()
    | Dos_lane.Changed _ | Dos_lane.Nothing_loaded -> fail "the current mark must answer unchanged")

(* [pass] runs [announce] while it holds the machine lock. The lane's mutex is
   an OCaml 5 error-checking mutex, so a read that took the lock here would
   raise Sys_error instead of answering. *)
let test_dos_mark_reads_while_the_lock_is_held () =
  with_dos (fun ~dir ->
    dos_ok "load" (dos_load ~dir hello_com);
    let before = dos_mark () in
    let seen = ref None in
    dos_ok "pass"
      (Dos_lane.pass ~who ~to_:(Some who)
         ~announce:(fun () -> seen := Some (Dos_lane.current_publication ())));
    check bool "the stable mark is readable under a held lock" true
      (!seen = Some (Dos_lane.Stable before)))

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
          check bool "an MSX answer carries no activity field (DOS-only for now)" true
            (member "activity" json = None);
          let n = int_member "change_count" json in
          let incarnation = string_member "incarnation" json in
          let screen = match member "screen" json with Some s -> s | None -> fail "no screen" in
          check string "the screen is rgb8" "rgb8" (string_member "format" screen);
          check int "the pixels are width*height*3 bytes"
            (int_member "width" screen * int_member "height" screen * 3)
            (String.length (Base64.decode_exn (string_member "rgb_base64" screen)));
          let files_before = tree base_path in
          let since n = "&since=" ^ string_of_int n ^ "&incarnation=" ^ incarnation in
          let same = get (live ^ since n) in
          let json = body_json same in
          check string "since at the current count is unchanged" "unchanged"
            (string_member "state" json);
          check int "unchanged carries the count" n (int_member "change_count" json);
          check string "unchanged carries the incarnation" incarnation
            (string_member "incarnation" json);
          check bool "unchanged sends no screen" true (member "screen" json = None);
          ok "step" (Lane.step ~frames:1);
          let moved = body_json (get (live ^ since n)) in
          check string "a step makes the old since stale" "changed" (string_member "state" moved);
          check bool "the new count is larger" true (int_member "change_count" moved > n);
          List.iter
            (fun (target, what) ->
              check int what 400 (status_of_response (get target)))
            [ "/api/v1/lane-addons/live?source_kind=snapshot_file", "a screenless kind is a 400"
            ; "/api/v1/lane-addons/live?source_kind=browser_document", "a browser document is a 400"
            ; "/api/v1/lane-addons/live?source_kind=vcr_capture", "an unknown kind is a 400"
            ; "/api/v1/lane-addons/live", "a missing kind is a 400"
            ; live ^ "&since=soon&incarnation=" ^ incarnation, "a text since is a 400"
            ; live ^ "&since=" ^ string_of_int n, "a since without its incarnation is a 400" ];
          check (list string) "live reads write no file under the workspace" files_before
            (tree base_path));
        let dos_live = "/api/v1/lane-addons/live?source_kind=dos_capture" in
        dos_eject_if_loaded ();
        (* Activity is process-global and never reset (Dos_lane.dos_lane.ml),
           so an earlier test case in this same binary may have left entries
           on it; this asserts the route reads exactly what Dos_lane itself
           holds at this instant, not that the feed starts empty. *)
        let activity_list json =
          match member "activity" json with
          | Some (`List l) -> l
          | _ -> fail "no activity list"
        in
        let no_machine_json = body_json (get dos_live) in
        check string "no DOS machine is a typed answer" "no_machine"
          (string_member "state" no_machine_json);
        check (list string) "no-machine activity matches Dos_lane.recent_activity"
          (List.map (fun e -> e.Lane_activity.who) (Dos_lane.recent_activity ()))
          (List.map (fun j -> string_member "who" j) (activity_list no_machine_json));
        with_dos (fun ~dir ->
          dos_ok "load" (dos_load ~dir hello_com);
          let json = body_json (get dos_live) in
          check string "no since gets the DOS frame" "changed" (string_member "state" json);
          check string "the answer names dos_capture" "dos_capture"
            (string_member "source_kind" json);
          let loaded_activity = activity_list json in
          check bool "activity is non-empty right after a load" true (loaded_activity <> []);
          let newest = List.hd loaded_activity in
          check string "the newest entry is who loaded it" who (string_member "who" newest);
          check bool "the newest entry names the load" true
            (let action = string_member "action" newest in
             String.length action >= 4 && String.sub action 0 4 = "load");
          let screen = match member "screen" json with Some s -> s | None -> fail "no screen" in
          check int "the DOS pixels are width*height*3 bytes"
            (int_member "width" screen * int_member "height" screen * 3)
            (String.length (Base64.decode_exn (string_member "rgb_base64" screen)));
          let since =
            "&since=" ^ string_of_int (int_member "change_count" json)
            ^ "&incarnation=" ^ string_member "incarnation" json in
          let current_mark =
            { Routes.count = int_member "change_count" json
            ; incarnation = string_member "incarnation" json } in
          let dos_since = Some current_mark in
          List.iter
            (fun source ->
              check bool "a running machine never answers unchanged from its old mark" true
                (match Routes.answer_from_publication source ~since:dos_since
                         (Machine_live_publication.Running current_mark) with
                 | Routes.Needs_locked_read -> true
                 | Routes.Answered _ -> false))
            [Routes.Msx_screen; Routes.Dos_screen];
          (* Decided while [pass] holds the machine lock: an unchanged answer
             must come from the published mark. Taking the lock on this
             thread raises (the stdlib mutex checks its owner). The request
             itself is not forked here: every authenticated GET suspends in
             the auth lookup's systhread file read before it reaches the
             route, so whether it finished before [announce] returned says
             nothing about the machine lock. *)
          let held = ref None in
          dos_ok "pass"
            (Dos_lane.pass ~who ~to_:(Some who)
               ~announce:(fun () ->
                 held := Some (Routes.live_from_published_mark Routes.Dos_screen ~since:dos_since)));
          (match !held with
           | Some (Routes.Answered json) ->
               check string "unchanged is decided under a held lock" "unchanged"
                 (string_member "state" json)
           | Some Routes.Needs_locked_read -> fail "a current since asked for the locked read"
           | None -> fail "announce did not run");
          let same = body_json (get (dos_live ^ since)) in
          check string "since at the current DOS count is unchanged" "unchanged"
            (string_member "state" same);
          check bool "unchanged sends no DOS screen" true (member "screen" same = None);
          (* The whole point of reading Dos_lane.recent_activity lock-free
             rather than gating it on the published mark: [pass] above moved
             no pixel, so the picture answers "unchanged" from the fast path
             above [dos_live]/[Eio_unix.run_in_systhread] entirely -- yet the
             activity feed still carries it, because [live_json] splices it
             onto every branch, not just the locked-read one. *)
          let unchanged_activity = List.hd (activity_list same) in
          check string "an unchanged answer still carries the pass" who
            (string_member "who" unchanged_activity);
          check bool "and names it" true
            (let action = string_member "action" unchanged_activity in
             String.length action >= 4 && String.sub action 0 4 = "pass");
          dos_ok "press" (Dos_lane.press ~who ~keys:["x"] ~steps:100_000);
          check bool "a moved DOS mark needs the locked read" true
            (match Routes.live_from_published_mark Routes.Dos_screen ~since:dos_since with
             | Routes.Needs_locked_read -> true
             | Routes.Answered _ -> false);
          check string "a press makes the old DOS since stale" "changed"
            (string_member "state" (body_json (get (dos_live ^ since))))))))

let () =
  run "lane addon live route"
    [ ( "change counter"
      , [ test_case "every path that runs or replaces the machine raises it" `Quick
            test_counter_moves_on_every_change
        ; test_case "since at the current count answers unchanged" `Quick
            test_since_answers_unchanged ] )
    ; ( "dos change counter"
      , [ test_case "every run attempt raises it, a zero-step fault too" `Quick
            test_dos_counter_moves_on_every_run
        ; test_case "the same program loaded twice is not unchanged" `Quick
            test_dos_reload_is_not_unchanged
        ; test_case "the published mark reads while the lock is held" `Quick
            test_dos_mark_reads_while_the_lock_is_held ] )
    ; ( "route"
      , [ test_case "the query decodes into a typed source" `Quick test_decode_live_query
        ; test_case "auth, unchanged, frame, 400, DOS, and no store writes" `Quick test_live_route ] )
    ]
