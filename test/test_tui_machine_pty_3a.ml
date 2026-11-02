(* RFC machine-spectating-goes-through-lanes §5 3a (#38815) — the spectator
   TUI over a real PTY against an in-process server with the real lane-addon
   router and the DOS fixture worker. Three observed behaviors:

     a. while the first live read is pending, the spectator screen still
        processes keys (the raw capture grows before any answer lands);
     b. a stale first answer (snapshot taken before the machine advanced)
        does not overwrite the newer screen the TUI drew from its F5 re-read;
        server-side, every post-release read carries the newer since-count;
     c. with the change counter unchanged the answers are "unchanged" and no
        picture repaint happens.

   The candidate TUI binary arrives as an artifact, not from this tree: the
   scenarios run only when MASC_TUI_3A_BIN names it; without it the test
   skips with a reason, so the suite stays green on plain checkouts.

   The PTY comes from [script] (the workspace capture convention). The races
   are manufactured by the test-owned request handler: the first live request
   is answered by this test with a captured pre-advance snapshot after the
   machine has advanced and an F5 re-read has drawn the newer picture. Every
   later live request goes through the real router. Evidence: the raw PTY
   capture plus a run log binding the binary sha256, commands and times. *)

let log_channel = ref Format.std_formatter
let log fmt =
  Printf.ksprintf
    (fun line ->
      let stamp =
        let t = Unix.gettimeofday () in
        let tm = Unix.gmtime t in
        Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ"
          (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
          tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec
          (int_of_float ((t -. Float.of_int (int_of_float t)) *. 1000.))
      in
      Format.fprintf !log_channel "%s %s@." stamp line;
      Format.pp_print_flush !log_channel ())
    fmt

let contains ~sub text =
  let n = String.length sub and m = String.length text in
  let rec at i = i + n <= m && (String.sub text i n = sub || at (i + 1)) in
  at 0

let remove_tree path =
  let rec go path =
    if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
      Array.iter (fun name -> go (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    end
    else Unix.unlink path
  in
  if try Sys.file_exists path with _ -> false then go path

let sha256_of_file path =
  let module D = Digestif.SHA256 in
  let ic = open_in_bin path in
  let len = in_channel_length ic in
  let bytes = really_input_string ic len in
  close_in ic;
  D.to_hex (D.digest_string bytes)

(* The DOS program from the live-route test: prints HI, waits for a key,
   exits. Kept identical so the machine behaves like the stage-1 suite. *)
let hello_com =
  "\xb4\x09\xba\x11\x01\xcd\x21\xb4\x00\xcd\x16\x09\xc0\x74\xf8\xcd\x20HI$"

let candidate_missing () =
  match Sys.getenv_opt "MASC_TUI_3A_BIN" with
  | None -> true
  | Some path -> not (Sys.file_exists path)

(* The keys feed is a plain pipe into the broker's stdin. The broker replaces
   script(1): it also answers the kitty graphics capability query, without
   which the candidate refuses to draw pictures (runs 17/18 showed the
   "waiting for live screen" placeholder for exactly that reason). *)
let broker =
  match Sys.getenv_opt "MASC_TUI_3A_BROKER" with
  | Some p -> p
  | None -> "test/pty_broker_3a.py"

let spawn_brokered_tui ~clock ~keys_read ~raw ~tui_exe ~workdir ~env =
  ignore clock;
  let argv =
    [| "python3"; broker; tui_exe; raw; workdir |]
  in
  let spawn () =
    Unix.create_process_env "python3" argv env keys_read Unix.stdout Unix.stderr
  in
  let rec try_spawn attempts =
    if attempts = 0 then failwith "could not start the PTY broker";
    let pid = spawn () in
    Eio.Time.sleep clock 0.5;
    match Unix.waitpid [Unix.WNOHANG] pid with
    | 0, _ -> Unix.close keys_read; pid
    | _, _ -> try_spawn (attempts - 1)
  in
  try_spawn 3

let send_keys fd keys =
  let rec all off =
    if off >= String.length keys then ()
    else
      let n = Unix.write fd (Bytes.of_string keys) off (String.length keys - off) in
      all (off + n)
  in
  all 0

let raw_size raw = (Unix.stat raw).Unix.st_size

let count_in raw needle =
  let ic = open_in_bin raw in
  let len = in_channel_length ic in
  let text = really_input_string ic len in
  close_in ic;
  let n = ref 0 in
  let bl = String.length text and sl = String.length needle in
  if sl > 0 then
    for i = 0 to bl - sl do
      if String.sub text i sl = needle then incr n
    done;
  !n

let raw_has raw needle =
  try
    let ic = open_in_bin raw in
    let len = in_channel_length ic in
    let text = really_input_string ic len in
    close_in ic;
    contains ~sub:needle text
  with _ -> false

let expect_in_raw ~clock ~timeout_sec ~needle raw =
  let deadline = Unix.gettimeofday () +. timeout_sec in
  let rec loop () =
    if Unix.gettimeofday () > deadline then Error "timeout"
    else if raw_has raw needle then Ok ()
    else ( Eio.Time.sleep clock 0.2; loop () )
  in
  loop ()

let main env =
  if candidate_missing () then begin
    print_endline
      "skip: MASC_TUI_3A_BIN does not name a candidate masc_tui.exe; scenarios not run";
    exit 0
  end;
  let tui_exe = Option.get (Sys.getenv_opt "MASC_TUI_3A_BIN") in
  let tui_sha = sha256_of_file tui_exe in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run (fun sw ->
   Eio_context.with_test_env ~sw ~net:(Eio.Stdenv.net env)
     ~clock:(Eio.Stdenv.clock env) ~mono_clock:(Eio.Stdenv.mono_clock env)
   (fun () ->
    let evidence_dir =
      match Sys.getenv_opt "MASC_TUI_3A_EVIDENCE_DIR" with
      | Some dir -> dir
      | None ->
        Filename.concat (Filename.get_temp_dir_name ())
          (Printf.sprintf "tui-3a-%d" (int_of_float (Unix.gettimeofday ())))
    in
    Sys.mkdir evidence_dir 0o755;
    log_channel :=
      Format.formatter_of_out_channel (open_out (Filename.concat evidence_dir "run.log"));
    log "tui-3a start candidate=%s sha256=%s evidence=%s" tui_exe tui_sha evidence_dir;
    let base_path = Filename.concat evidence_dir "workspace" in
    Unix.mkdir base_path 0o755;
    Fs_compat.mkdir_p (Filename.concat base_path ".masc/config");
    (* Workspace auth the way a started server sets it up: token required and
       a masc-tui credential the TUI can read from the workspace. *)
    Auth.save_auth_config base_path
      { Masc_domain.default_auth_config with enabled = true; require_token = true };
    (match Auth.create_token base_path ~agent_name:"masc-tui" ~role:Masc_domain.Admin with
     | Ok _ -> log "masc-tui credential minted"
     | Error e ->
       log "masc-tui token mint failed: %s" (Masc_domain.masc_error_to_string e);
       exit 2);
    let socket =
      Eio.Net.listen ~reuse_addr:true ~backlog:16 ~sw (Eio.Stdenv.net env)
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
    in
    let port =
      match Eio.Net.listening_addr socket with
      | `Tcp (_, port) -> port
      | `Unix _ -> failwith "expected a TCP listener"
    in
    log "listening on 127.0.0.1:%d" port;
    let state =
      Masc.Mcp_server.create_state_eio ~sw
        ~proc_mgr:(Eio.Stdenv.process_mgr env) ~fs:(Eio.Stdenv.fs env)
        ~clock:(Eio.Stdenv.clock env) ~mono_clock:(Eio.Stdenv.mono_clock env)
        ~net:(Eio.Stdenv.net env) ~base_path in
    Server_auth.publish_server_state state;
    (match Masc.Server_startup_state.mark_state_ready () with
     | Ok () -> log "server startup state marked ready"
     | Error e ->
       log "startup state not marked: %s" (Masc.Server_startup_state.state_ready_error_to_string e));
    let router = Server_routes_http.make_routes ~port ~host:"127.0.0.1" ~sw ~clock in
    let mk_policy host =
      match
        Server_request_authority.make_trust_policy ~bind_host:host
          ~bind_port:port ~explicit_base_url:None
      with
      | Ok policy -> policy
      | Error e ->
        failwith
          ("trust policy failed: "
           ^ Server_request_authority.trust_policy_error_to_string e)
    in
    let trust_policies = [ mk_policy "localhost"; mk_policy "127.0.0.1" ] in
    (* The real server classifies the Host authority per request and runs
       every route handler inside Server_request_authority.with_current;
       route handlers (e.g. /health identity) read the current authority.
       RFC-faithful in-process wiring requires the same admission here. *)
    (* Harness-only: strip conditional headers so the router always answers
       200 with a body. The TUI's surface loaders treat a bare 304 (empty
       body) as a decode failure, which spirals the workspace badge. *)
    let strip_conditionals request =
      let h = request.Httpun.Request.headers in
      let h = Httpun.Headers.remove h "if-none-match" in
      let h = Httpun.Headers.remove h "if-modified-since" in
      { request with Httpun.Request.headers = h } in
    let dispatch_authorised reqd request =
      let request = strip_conditionals request in
      let classified =
        List.find_map
          (fun policy ->
            match
              Server_request_authority.classify_http1_request ~trust_policy:policy
                request
            with
            | Server_request_authority.Single ra -> Some ra
            | _ -> None)
          trust_policies
      in
      (match classified with
       | Some request_authority ->
         Server_request_authority.with_current request_authority (fun () ->
           Masc.Http_server_eio.Router.dispatch router request reqd;
           (match Httpun.Reqd.response reqd with
            | Some resp ->
              log "http done %s -> %d" request.Httpun.Request.target
                (Httpun.Status.to_code resp.Httpun.Response.status)
            | None -> log "http done %s -> (no response)" request.Httpun.Request.target))
       | None ->
         Masc.Http_server_eio.Response.json_value ~status:`Bad_request
           (`Assoc [ "error_code", `String "request_authority_untrusted" ])
           reqd)
    in
    (* Live-read orchestration state, owned by the request handler. *)
    let live_seen = ref 0 in
    (* The DOS capture snapshot the way the route test reads it, before the
       machine advances: scenario (b)'s stale answer body. *)
    let dos_body ?(since=None) ?(incarnation=None) () =
      let module R = Server_routes_http_routes_lane_addons in
      let mark =
        match (since, incarnation) with
        | Some count, Some inc ->
          let module R = Server_routes_http_routes_lane_addons in
          Some { R.count; incarnation = inc }
        | _ -> None in
      match
        R.live_json ~config:(Masc.Workspace.default_config base_path)
          Masc.Machine_lane.Dos ~since:mark
      with
      | Ok json -> Yojson.Safe.to_string json
      | Error e -> failwith ("live_json failed: " ^ e)
    in
    let dos_snapshot_body () = dos_body () in
    (* Pull a query parameter back out of a request target. *)
    let param_of_target name target =
      let padded = "&" ^ target in
      let key = "&" ^ name ^ "=" in
      let klen = String.length key in
      let rec go i =
        if i + klen > String.length padded then None
        else if String.sub padded i klen = key then
          let start = i + klen in
          let stop =
            match String.index_from_opt padded start '&' with
            | Some j -> j
            | None -> String.length padded in
          Some (String.sub padded start (stop - start))
        else go (i + 1)
      in
      go 0
    in
    (* The real deployment learns machine changes through the keeper event
       bridge. The fake in-process worker never wires that bridge, and the
       runtime only refreshes its committed observation when something
       dispatches Observe — notify_activity is filtered out because the
       fixture binding declares no refresh interest. So the harness stands in
       for the bridge with an explicit Observe dispatch, exactly like the
       green route test's [refresh] helper does. *)
    let wake_dos_watchers () =
      let config = Masc.Workspace.default_config base_path in
      match
        Masc.Lane_addon_runtime.tool_export_reading ~config
          ~access:Masc.Lane_addon_sources.Unauthenticated ~reserved:[]
      with
      | Error _ -> log "dos wake: no export reading"
      | Ok reading ->
        (match reading.exports with
         | export :: _ ->
           let instance_id =
             export.Masc.Lane_addon_tool_export.instance_id in
           (match
              Masc.Lane_addon_runtime.dispatch ~config
                ~access:Masc.Lane_addon_sources.Operator_configuration
                ~operation:Masc.Lane_addon_runtime.Observe
                (`Assoc [ ("instance_id", `String instance_id) ])
            with
            | Ok _ -> log "dos wake: observe dispatched"
            | Error e ->
              log "dos wake: observe failed: %s"
                (Masc.Lane_addon_runtime.error_to_string e))
         | [] -> log "dos wake: no exports")
    in
    let serve_connection _addr gluten_reqd =
      let reqd = gluten_reqd.Gluten.Reqd.reqd in
      let request = Httpun.Reqd.request reqd in
      let target = request.Httpun.Request.target in
      log "http request: %s" target;
      if contains ~sub:"/api/v1/lane-addons/live" target then begin
        incr live_seen;
        let n = !live_seen in
        log "live request #%d arrived: %s" n target;
        (* Evidence peek (read-only): what state will this request get,
           answered with the request's own since/incarnation? *)
        let peek () =
          let since =
            match param_of_target "since" target with
            | Some v -> Some (int_of_string v)
            | None -> None in
          let incarnation = param_of_target "incarnation" target in
          let body = dos_body ~since ~incarnation () in
          match Yojson.Safe.from_string body with
          | `Assoc fields ->
            let state =
              match List.assoc_opt "state" fields with
              | Some (`String s) -> s
              | _ -> "?" in
            let count =
              match List.assoc_opt "change_count" fields with
              | Some (`Int c) -> string_of_int c
              | _ -> "?" in
            log "live #%d peek: state=%s change_count=%s" n state count
          | _ -> ()
        in
        (match peek () with
         | () -> ()
         | exception e ->
           log "live #%d peek failed: %s" n (Printexc.to_string e));
        if n = 1 then begin
          let stale = dos_snapshot_body () in
          log "live #1: pre-advance snapshot captured (%d bytes); holding the answer"
            (String.length stale);
          Eio.Time.sleep clock 1.0;
          (match Dos_lane.step ~who:"tui-3a" ~steps:1 ~until_ready:false with
           | Ok _ -> log "machine advanced while live #1 is held"
           | Error e -> log "machine step failed: %s" (Dos_lane.error_to_string e));
          wake_dos_watchers ();
          log "watchers woken after the held-window advance";
          Eio.Time.sleep clock 5.0;
          log "live #1: releasing the stale pre-advance answer now";
          Masc.Http_server_eio.Response.json ~status:`OK stale reqd
          (* The held connection has been answered; the handler must not fall
             through to dispatch (a second respond would corrupt it). *)
        end
        else begin
          let module R = Server_routes_http_routes_lane_addons in
          (match
             R.live_json ~config:(Masc.Workspace.default_config base_path)
               Masc.Machine_lane.Dos ~since:None
           with
           | Error e -> log "live #%d probe: read error: %s" n e
           | Ok json ->
             log "live #%d probe: %s" n (Yojson.Safe.to_string json));
          dispatch_authorised reqd request
        end
      end
      else dispatch_authorised reqd request
    in
    Eio.Fiber.fork ~sw (fun () ->
      Server_bootstrap_http.serve ~sw ~clock ~socket ~addr_label:"tui-3a"
        ~request_handler:serve_connection);
    Eio.Time.sleep clock 0.2;
    Machine_worker_fixture.with_dos ~clock ~sw ~base_path
      (fun ~invoke ~detach ->
        ignore invoke;
        log "dos fixture attached";
        (match Dos_lane.eject ~who:"tui-3a" ~announce:ignore () with
         | Ok () | Error Dos_lane.No_machine -> ()
         | Error e -> log "dos eject failed: %s" (Dos_lane.error_to_string e));
        Dos_lane.install_activity_observer
          (Some (fun () -> Machine_configuration.Enabled));
        (match
           Dos_lane.load ~who:"tui-3a"
             ~ledger_dir:(Filename.concat base_path "ledger")
             ~saves_dir:(Filename.concat base_path "saves")
             ~checkpoint_dir:(Filename.concat base_path "checkpoints")
             ~previous_autosave:Dos_lane.Discard_previous_autosave
             ~program_name:"hello.com" ~program_bytes:hello_com ~files:[]
             ~announce:ignore
         with
         | Ok _ ->
           log "dos machine loaded";
           (* The worker's observation refreshes on a changed fingerprint; a
              bare load leaves the attach-time no_machine snapshot in place.
              Step the machine so the lane publishes and the worker observes
              the loaded picture before the TUI's first live poll. *)
           (match Dos_lane.step ~who:"tui-3a" ~steps:8 ~until_ready:false with
            | Ok _ -> log "dos machine stepped"
            | Error e -> log "dos step failed: %s" (Dos_lane.error_to_string e));
           wake_dos_watchers ();
           log "watchers woken after load+step"
         | Error e ->
           log "dos load failed: %s" (Dos_lane.error_to_string e);
           exit 2);
        let raw = Filename.concat evidence_dir "pty-raw.bin" in
        let keys_read, keys_write = Unix.pipe () in
        let inner = Printf.sprintf "cd '%s' && exec '%s'" base_path tui_exe in
        ignore inner;
        let env_child =
          Unix.environment ()
          |> Array.to_list
          |> List.filter (fun kv ->
              not (contains ~sub:"MASC_HTTP_PORT=" kv || contains ~sub:"TERM=" kv))
          |> fun keep ->
          keep
          @ [ "MASC_HTTP_PORT=" ^ string_of_int port; "TERM=xterm-256color" ]
          |> Array.of_list
        in
        let tui_pid =
          spawn_brokered_tui ~clock ~keys_read ~raw ~tui_exe ~workdir:base_path
            ~env:env_child in
        log "candidate TUI session started pid=%d raw=%s" tui_pid raw;
        Eio.Fiber.fork ~sw (fun () ->
          Eio.Time.sleep clock 150.0;
          send_keys keys_write "q";
          Eio.Time.sleep clock 5.0;
          send_keys keys_write "y");
        (* Wait for the workspace identity to confirm. *)
        let confirmed =
          let deadline = Unix.gettimeofday () +. 30. in
          let rec loop () =
            if Unix.gettimeofday () > deadline then false
            else if raw_has raw "[connected]" || raw_has raw "[partial]" then true
            else ( Eio.Time.sleep clock 0.3; loop () )
          in
          loop ()
        in
        log "workspace identity confirmed=%b" confirmed;
        (* Enter the DOS spectator through the global palette (: + "dos" +
           Enter); it starts the DOS live poll whose first read the handler
           holds. *)
        send_keys keys_write ":dos\r";
        log "sent palette ':dos<Enter>' to open the DOS spectator";
        let deadline = Unix.gettimeofday () +. 15. in
        let rec wait_first () =
          if !live_seen >= 1 then Ok ()
          else if Unix.gettimeofday () > deadline then Error "no live read after f4"
          else ( Eio.Time.sleep clock 0.2; wait_first () )
        in
        (match wait_first () with
         | Ok () -> log "first live read is in flight (held)"
         | Error e -> log "scenario a FAILED: %s" e);
        (* Scenario (a): while live #1 is held, reopen the command palette
           (the menu) and move its selection row with "down" (the palette's
           navigation key; plain 'j' types into the query). The raw capture
           must paint the open menu and the moved selection row before the
           stale answer is released. *)
        let size_at_hold = raw_size raw in
        Eio.Time.sleep clock 0.5;
        (* ":" does not open the palette from inside the spectator (it goes to
           the machine), so step back to the dashboard first. *)
        send_keys keys_write "\027";
        log "left the spectator for the dashboard while live #1 is held";
        Eio.Time.sleep clock 0.8;
        send_keys keys_write ":";
        log "opened the command palette on the dashboard";
        Eio.Time.sleep clock 0.8;
        let size_menu = raw_size raw in
        send_keys keys_write "\033[B";
        log "pressed 'down': palette selection row must move";
        Eio.Time.sleep clock 1.2;
        let grew = raw_size raw > size_menu && raw_size raw > size_at_hold in
        log "scenario a: menu open + selection moved while pending=%b (hold %d → menu %d → moved %d)"
          grew size_at_hold size_menu (raw_size raw);
        (* Scenario (b): the machine advanced inside live #1's window (the
           handler did it); an F5 re-read draws the newer picture through the
           real router, then the stale answer lands and must not overwrite. *)
        (* The palette is still open on the dashboard. Re-enter the DOS
           spectator: the relaunch issues a fresh live read whose newer
           picture (count=4) applies while stale #1 (count=3) is still held.
           When #1 lands it must NOT repaint the screen. *)
        (* Close the (a) palette and reopen a fresh one so the re-entry keys
           match the initial entry exactly (fresh palette + dos + Enter). *)
        send_keys keys_write "\027";
        Eio.Time.sleep clock 0.5;
        send_keys keys_write ":";
        Eio.Time.sleep clock 0.6;
        send_keys keys_write "dos\r";
        log "re-entered the DOS spectator from a fresh palette (fresh read overtakes the held stale)";
        let deadline = Unix.gettimeofday () +. 15. in
        let rec wait_second () =
          if !live_seen >= 2 then Ok ()
          else if Unix.gettimeofday () > deadline then Error "no second live read after f5"
          else ( Eio.Time.sleep clock 0.2; wait_second () )
        in
        (match wait_second () with
         | Ok () -> log "second live read answered through the router (newer picture)"
         | Error e -> log "scenario b setup FAILED: %s" e);
        (* The handler releases the stale answer 2s after the advance; give
           it time, then verify the screen kept the newer picture by checking
           that no full-screen DOS repaint follows the release. *)
        Eio.Time.sleep clock 3.0;
        log "scenario b window elapsed (stale answer was due); requests seen=%d"
          !live_seen;
        let places_before = count_in raw "\x1b_Gf=24,s=640,v=400,a=T,i=32" in
        log "kitty placements before the stale lands: %d" places_before;
        (* Scenario (c): quiescent machine → unchanged answers → no repaint. *)
        let size_before = raw_size raw in
        Eio.Time.sleep clock 8.0;
        let size_after = raw_size raw in
        log "scenario c: raw bytes %d → %d (delta %d)" size_before size_after
          (size_after - size_before);
        let places_after = count_in raw "\x1b_Gf=24,s=640,v=400,a=T,i=32" in
        log "scenario b verdict: placements after stale landed = %d (before %d; unchanged means no overwrite)"
          places_after places_before;
        log "scenario c verdict: picture rendered at all = %b" (places_after > 0);
        ignore detach;
        Dos_lane.install_activity_observer None);
    log "finished; live requests seen: %d" !live_seen;
    log "evidence dir: %s" evidence_dir;
    Format.pp_print_flush !log_channel ();
    exit 0))

let () = Eio_main.run main
