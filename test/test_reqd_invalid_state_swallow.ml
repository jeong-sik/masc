(* test/test_reqd_invalid_state_swallow.ml

   Regression guard for the 2026-05-05 cycle9 FATAL incident:

   [httpun.Reqd.respond_with_string: invalid state, currently handling error]

   When a client disconnects during a long OAS turn (≥40s), httpun's
   error_handler fires and transitions the Reqd into "handling error" state.
   Any subsequent call to [Httpun.Reqd.respond_with_string] on the same Reqd
   raises [Failure "...invalid state..."].

   Before the fix:
   - [http_server_eio.ml] called [Httpun.Reqd.respond_with_string] directly
     with no guard.  The [Failure] escaped through [make_extended_handler]'s
     [with exn -> Http.Response.internal_error] fallback — because that fallback
     itself calls [respond_with_string], which also fails, and the secondary
     [Failure] was unhandled.
   - More critically, [server_mcp_transport_http.ml] forks a fiber with
     [runtime.sw] (a server-level switch) for the actual OAS POST handling.
     When [respond_with_string] raised [Failure] in that fiber, it failed
     [runtime.sw], which is NOT wrapped by the per-connection try/with.
     This propagated to the server-level Eio switch → [try_start] catch-all
     → "[FATAL] Unhandled exception" → [exit 1] → cycle restart.

   The fix:
   1. [lib/http_server_eio.ml]: [safe_respond_with_string] wrapper — all
      response helpers ([Response.text], [Response.json], etc.) and the
      [Request.respond_error] family go through this wrapper.
   2. [bin/main_eio.ml]: [safe_reqd_respond] local helper guards every direct
      [Httpun.Reqd.respond_with_string] call; [make_extended_handler] re-raises
      [Eio.Cancel.Cancelled] instead of swallowing it; the error fallback has
      a redundant guard for defence-in-depth.
   3. [lib/server/server_mcp_transport_http_respond.ml]: safe wrapper added to
      all MCP error response factories (the helpers called from the forked fiber).
   4. [lib/server/server_mcp_transport_http.ml]: safe wrapper used for all
      direct [respond_with_string] calls in the critical POST/GET/DELETE
      handlers (especially the OAS-executing forked fiber at [Eio.Fiber.fork
      ~sw:(runtime.sw)]).
   This test asserts the presence of these defensive patterns in the source so
   a future refactor that silently removes them fails CI before it can re-arm
   the FATAL restart loop. *)

let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> In_channel.input_all ic)

let assert_contains ~label haystack needle =
  let n = String.length needle in
  let h = String.length haystack in
  let rec scan i =
    if i + n > h then false
    else if String.sub haystack i n = needle then true
    else scan (i + 1)
  in
  if not (scan 0) then
    failwith
      (Printf.sprintf
         "[%s] expected source to contain %S — reqd invalid state \
          swallow regression: see 2026-05-05 cycle9 FATAL incident"
         label needle)

let assert_not_contains ~label haystack needle =
  let n = String.length needle in
  let h = String.length haystack in
  let rec scan i =
    if i + n > h then false
    else if String.sub haystack i n = needle then true
    else scan (i + 1)
  in
  if scan 0 then
    failwith
      (Printf.sprintf "[%s] source must not contain fail-open marker %S" label needle)

let count_occurrences haystack needle =
  let n = String.length needle in
  let h = String.length haystack in
  if n = 0 then 0
  else (
    let count = ref 0 in
    for i = 0 to h - n do
      if String.sub haystack i n = needle then incr count
    done;
    !count)

let resolve_path candidates =
  match List.find_opt Sys.file_exists candidates with
  | Some p -> p
  | None ->
      let exe = Sys.executable_name in
      failwith
        (Printf.sprintf
           "no candidate path resolved (cwd=%s, exe=%s, tried: %s)"
           (Sys.getcwd ()) exe
           (String.concat ", " candidates))

let () =
  let parent p = Filename.dirname p in
  let exe = Sys.executable_name in
  let project_root =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root when Sys.file_exists (Filename.concat root "dune-project") -> root
    | _ -> parent (parent (parent (parent exe)))
  in

  (* ---- lib/http_server_eio.ml ----------------------------------------- *)
  let http_src =
    resolve_path
      [ Filename.concat project_root "lib/http_server_eio.ml"
      ; "lib/http_server_eio.ml"
      ; "../lib/http_server_eio.ml"
      ]
    |> read_file
  in

  (* Anchor H1: the safe wrapper function must exist. *)
  assert_contains
    ~label:"H1: safe_respond_with_string function"
    http_src
    "safe_respond_with_string";

  (* Anchor H2: the incident reference comment must be present so a partial
     revert that drops the explanation still fails. *)
  assert_contains
    ~label:"H2: cycle9 incident reference in http_server_eio"
    http_src
    "2026-05-05 OAS cancellation race";

  (* Anchor H3: Cancelled is re-raised (never swallowed) in the safe wrapper. *)
  assert_contains
    ~label:"H3: Cancelled re-raised in safe_respond_with_string"
    http_src
    "Eio.Cancel.Cancelled _ as e -> raise e";

  (* ---- bin/main_eio.ml -------------------------------------------------- *)
  let main_src =
    resolve_path
      [ Filename.concat project_root "bin/main_eio.ml"
      ; "bin/main_eio.ml"
      ; "../bin/main_eio.ml"
      ]
    |> read_file
  in

  (* Anchor M1: the local safe helper must exist. *)
  assert_contains
    ~label:"M1: safe_reqd_respond helper in main_eio"
    main_src
    "safe_reqd_respond";

  (* Anchor M2: Cancelled re-raised in make_extended_handler catch-all. *)
  assert_contains
    ~label:"M2: Cancelled re-raise in make_extended_handler"
    main_src
    "Re-raise cancellation so Eio structured concurrency propagates cleanly";

  (* Anchor M3: defence-in-depth guard on the error fallback. The
     [safe_reqd_respond] doc comment must keep the "guards" anchor so a
     future refactor that drops the wrapper is forced to update this
     test rather than silently re-introducing the cycle9 race. *)
  assert_contains
    ~label:"M3: defence-in-depth guard on error fallback"
    main_src
    "safe_reqd_respond reqd response body] guards all direct";

  assert_contains
    ~label:"M4: keeper bootstrap fail-closed message"
    main_src
    "keeper bootstrap failed; refusing to continue without keepers";

  assert_not_contains
    ~label:"M5: keeper bootstrap must not continue without keepers"
    main_src
    "keeper bootstrap failed (continuing without keepers)";

  (* ---- lib/server/server_mcp_transport_http_respond.ml ------------------ *)
  let mcp_respond_src =
    resolve_path
      [ Filename.concat project_root
          "lib/server/server_mcp_transport_http_respond.ml"
      ; "lib/server/server_mcp_transport_http_respond.ml"
      ; "../lib/server/server_mcp_transport_http_respond.ml"
      ]
    |> read_file
  in

  (* Anchor MR1: safe wrapper in the respond module. *)
  assert_contains
    ~label:"MR1: safe_respond_with_string in _respond.ml"
    mcp_respond_src
    "safe_respond_with_string reqd response body";

  (* Anchor MR2: incident reference in the respond module. *)
  assert_contains
    ~label:"MR2: incident reference in _respond.ml"
    mcp_respond_src
    "2026-05-05 OAS cancel race";
  assert_contains
    ~label:"MR3: SSE register error helper emits fresh session id"
    mcp_respond_src
    "let new_session_id = Mcp_session.generate ()";
  assert_contains
    ~label:"MR4: SSE register error responds Not_found before stream open"
    mcp_respond_src
    "Httpun.Response.create ~headers `Not_found";

  (* ---- lib/server/server_mcp_transport_http.ml -------------------------- *)
  let mcp_http_src =
    resolve_path
      [ Filename.concat project_root
          "lib/server/server_mcp_transport_http.ml"
      ; "lib/server/server_mcp_transport_http.ml"
      ; "../lib/server/server_mcp_transport_http.ml"
      ]
    |> read_file
  in

  (* Anchor MT1: safe wrapper helper present in the main transport module. *)
  assert_contains
    ~label:"MT1: safe_respond_with_string helper in _http.ml"
    mcp_http_src
    "safe_respond_with_string reqd response body";

  (* Anchor MT2: incident reference in the main transport module. *)
  assert_contains
    ~label:"MT2: incident reference in _http.ml"
    mcp_http_src
    "2026-05-05 OAS cancel race";

  (* Anchor MT3: the forked-fiber (critical) path no longer has a direct
     Httpun.Reqd.respond_with_string call (beyond the safe-wrapper definition).
     We allow up to 2: the docstring reference and the single call inside
     safe_respond_with_string's try body. *)
  let direct_count =
    count_occurrences mcp_http_src "Httpun.Reqd.respond_with_string"
  in
  if direct_count > 2 then
    failwith
      (Printf.sprintf
         "[MT3] found %d direct Httpun.Reqd.respond_with_string calls in \
          server_mcp_transport_http.ml; expected at most 2 (docstring + \
          safe_respond_with_string try body). Regression: 2026-05-05 cycle9 \
          FATAL."
         direct_count);

  let generic_sse_register_error_count =
    count_occurrences mcp_http_src
      "respond_sse_register_error ~deps ~origin ~protocol_version reqd msg"
  in
  if generic_sse_register_error_count <> 1 then
    failwith
      (Printf.sprintf
         "[MT4] expected generic SSE register failure to use \
          respond_sse_register_error exactly once before opening a 200 stream; \
          found %d"
         generic_sse_register_error_count);

  (* ---- lib/server/server_mcp_transport_http_agui.ml --------------------- *)
  let mcp_agui_src =
    resolve_path
      [ Filename.concat project_root
          "lib/server/server_mcp_transport_http_agui.ml"
      ; "lib/server/server_mcp_transport_http_agui.ml"
      ; "../lib/server/server_mcp_transport_http_agui.ml"
      ]
    |> read_file
  in

  let agui_sse_register_error_count =
    count_occurrences mcp_agui_src
      "respond_sse_register_error ~deps ~origin ~protocol_version reqd msg"
  in
  if agui_sse_register_error_count <> 2 then
    failwith
      (Printf.sprintf
         "[AG1] expected observer and presence SSE register failures to use \
          respond_sse_register_error before opening 200 streams; found %d"
         agui_sse_register_error_count);

  (* ---- lib/server/server_routes_http_keeper_stream.ml ------------------- *)
  let keeper_stream_src =
    resolve_path
      [ Filename.concat project_root
          "lib/server/server_routes_http_keeper_stream.ml"
      ; "lib/server/server_routes_http_keeper_stream.ml"
      ; "../lib/server/server_routes_http_keeper_stream.ml"
      ]
    |> read_file
  in

  (* Anchor KS1: client transport disconnect is a stream-consumer event, not
     a keeper_msg cancellation. The accepted request must remain resumable via
     request_id polling. *)
  assert_contains
    ~label:"KS1: stream disconnect has its own worker event"
    keeper_stream_src
    "Stream_client_disconnected";
  assert_contains
    ~label:"KS2: disconnect log says request continues"
    keeper_stream_src
    "request continues for polling";
  assert_contains
    ~label:"KS3a: worker owns connector user-line recording decision"
    keeper_stream_src
    "process_single_turn ~connector_user_line_recorded_upstream:false";
  assert_contains
    ~label:"KS3b: worker uses server switch"
    keeper_stream_src
    "~state ~clock ~sw";
  assert_contains
    ~label:"KS4: disconnect watcher uses stream switch"
    keeper_stream_src
    "~client_disconnects:(Some (stream_sw, client_disconnects))";
  let keeper_cancel_count =
    count_occurrences keeper_stream_src "Keeper_msg_async.cancel"
  in
  if keeper_cancel_count > 1 then
    failwith
      (Printf.sprintf
         "[KS5] found %d Keeper_msg_async.cancel calls in \
          server_routes_http_keeper_stream.ml; expected only the explicit \
          cancel endpoint. Client transport disconnect must not cancel the \
          accepted keeper_msg request."
         keeper_cancel_count);

  print_endline "test_reqd_invalid_state_swallow: OK"
