
open Server_auth

module Http = Http_server_eio

let graphql_headers origin =
  [("content-type", "application/json")]
  @ cors_headers origin

(** GraphQL Playground HTML (GET /graphql) *)
let graphql_playground_html ~nonce =
  String.concat "" [
    {|
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="initial-scale=1" />
    <title>MASC GraphQL Playground</title>
    <link rel="stylesheet" href="/static/css/middleware.css" />
  </head>
  <body>
    <style>
      html { font-family: "Open Sans", sans-serif; overflow: hidden; }
      body { margin: 0; background: #172a3a; }
      .playgroundIn { animation: playgroundIn .5s ease-out forwards; }
      @keyframes playgroundIn {
        from { opacity: 0; transform: translateY(10px); }
        to { opacity: 1; transform: translateY(0); }
      }
    </style>
    <style>
      .fadeOut { animation: fadeOut .5s ease-out forwards; }
      @keyframes fadeIn {
        from { opacity: 0; transform: translateY(-10px); }
        to { opacity: 1; transform: translateY(0); }
      }
      @keyframes fadeOut {
        from { opacity: 1; transform: translateY(0); }
        to { opacity: 0; transform: translateY(-10px); }
      }
      @keyframes appearIn {
        from { opacity: 0; transform: translateY(0); }
        to { opacity: 1; transform: translateY(0); }
      }
      @keyframes scaleIn {
        from { transform: scale(0); }
        to { transform: scale(1); }
      }
      @keyframes innerDrawIn {
        0% { stroke-dashoffset: 70; }
        50% { stroke-dashoffset: 140; }
        100% { stroke-dashoffset: 210; }
      }
      @keyframes outerDrawIn {
        0% { stroke-dashoffset: 76; }
        100% { stroke-dashoffset: 152; }
      }
      #loading-wrapper {
        position: absolute;
        width: 100vw;
        height: 100vh;
        display: flex;
        align-items: center;
        justify-content: center;
        flex-direction: column;
      }
      .logo {
        width: 75px;
        height: 75px;
        margin-bottom: 20px;
        opacity: 0;
        animation: fadeIn .5s ease-out forwards;
      }
      .text {
        font-size: 32px;
        font-weight: 200;
        text-align: center;
        color: rgba(255, 255, 255, .6);
        opacity: 0;
        animation: fadeIn .5s ease-out forwards;
      }
      .text strong { font-weight: 400; }
    </style>
    <div id="loading-wrapper">
      <svg class="logo" viewBox="0 0 128 128" xmlns:xlink="http://www.w3.org/1999/xlink">
        <title>GraphQL Playground Logo</title>
        <defs>
          <linearGradient id="linearGradient-1" x1="4.86%" x2="96.21%" y1="0%" y2="99.66%">
            <stop stop-color="#E00082" stop-opacity=".8" offset="0%"></stop>
            <stop stop-color="#E00082" offset="100%"></stop>
          </linearGradient>
        </defs>
        <g>
          <rect id="Gradient" width="127.96" height="127.96" y="1" fill="url(#linearGradient-1)" rx="4"></rect>
          <path id="Border" fill="#E00082" fill-rule="nonzero" d="M4.7 2.84c-1.58 0-2.86 1.28-2.86 2.85v116.57c0 1.57 1.28 2.84 2.85 2.84h116.57c1.57 0 2.84-1.26 2.84-2.83V5.67c0-1.55-1.26-2.83-2.83-2.83H4.67zM4.7 0h116.58c3.14 0 5.68 2.55 5.68 5.7v116.58c0 3.14-2.54 5.68-5.68 5.68H4.68c-3.13 0-5.68-2.54-5.68-5.68V5.68C-1 2.56 1.55 0 4.7 0z"></path>
          <path class="bglIGM" x="64" y="28" fill="#fff" d="M64 36c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8"></path>
          <path class="ksxRII" x="95.98500061035156" y="46.510000228881836" fill="#fff" d="M89.04 50.52c-2.2-3.84-.9-8.73 2.94-10.96 3.83-2.2 8.72-.9 10.95 2.94 2.2 3.84.9 8.73-2.94 10.96-3.85 2.2-8.76.9-10.97-2.94"></path>
          <path class="cWrBmb" x="95.97162628173828" y="83.4900016784668" fill="#fff" d="M102.9 87.5c-2.2 3.84-7.1 5.15-10.94 2.94-3.84-2.2-5.14-7.12-2.94-10.96 2.2-3.84 7.12-5.15 10.95-2.94 3.86 2.23 5.16 7.12 2.94 10.96"></path>
          <path class="Wnusb" x="64" y="101.97999572753906" fill="#fff" d="M64 110c-4.43 0-8-3.6-8-8.02 0-4.44 3.57-8.02 8-8.02s8 3.58 8 8.02c0 4.4-3.57 8.02-8 8.02"></path>
          <path class="bfPqf" x="32.03982162475586" y="83.4900016784668" fill="#fff" d="M25.1 87.5c-2.2-3.84-.9-8.73 2.93-10.96 3.83-2.2 8.72-.9 10.95 2.94 2.2 3.84.9 8.73-2.94 10.96-3.85 2.2-8.74.9-10.95-2.94"></path>
          <path class="edRCTN" x="32.033552169799805" y="46.510000228881836" fill="#fff" d="M38.96 50.52c-2.2 3.84-7.12 5.15-10.95 2.94-3.82-2.2-5.12-7.12-2.92-10.96 2.2-3.84 7.12-5.15 10.95-2.94 3.83 2.23 5.14 7.12 2.94 10.96"></path>
          <path class="iEGVWn" stroke="#fff" stroke-width="4" stroke-linecap="round" stroke-linejoin="round" d="M63.55 27.5l32.9 19-32.9-19z"></path>
          <path class="bsocdx" stroke="#fff" stroke-width="4" stroke-linecap="round" stroke-linejoin="round" d="M96 46v38-38z"></path>
          <path class="jAZXmP" stroke="#fff" stroke-width="4" stroke-linecap="round" stroke-linejoin="round" d="M96.45 84.5l-32.9 19 32.9-19z"></path>
          <path class="hSeArx" stroke="#fff" stroke-width="4" stroke-linecap="round" stroke-linejoin="round" d="M64.45 103.5l-32.9-19 32.9 19z"></path>
          <path class="bVgqGk" stroke="#fff" stroke-width="4" stroke-linecap="round" stroke-linejoin="round" d="M32 84V46v38z"></path>
          <path class="hEFqBt" stroke="#fff" stroke-width="4" stroke-linecap="round" stroke-linejoin="round" d="M31.55 46.5l32.9-19-32.9 19z"></path>
          <path class="dzEKCM" id="Triangle-Bottom" stroke="#fff" stroke-width="4" d="M30 84h70" stroke-linecap="round"></path>
          <path class="DYnPx" id="Triangle-Left" stroke="#fff" stroke-width="4" d="M65 26L30 87" stroke-linecap="round"></path>
          <path class="hjPEAQ" id="Triangle-Right" stroke="#fff" stroke-width="4" d="M98 87L63 26" stroke-linecap="round"></path>
        </g>
      </svg>
      <div class="text">Loading <strong>GraphQL Playground</strong></div>
    </div>
    <div id="root"></div>
    <script nonce="|};
    nonce;
    {|">
      window.addEventListener("load", function () {
        var loading = document.getElementById("loading-wrapper");
        if (loading) {
          loading.classList.add("fadeOut");
        }
        var root = document.getElementById("root");
        if (!root) {
          return;
        }
        root.classList.add("playgroundIn");
        GraphQLPlayground.init(root, {
          endpoint: "/graphql",
          settings: { "request.credentials": "same-origin" }
        });
      });
    </script>
    <script src="/static/js/middleware.js"></script>
  </body>
</html>
|};
  ]

let graphql_csp_header nonce =
  Printf.sprintf
    "default-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; \
     connect-src 'self'; img-src 'self' data:; \
     script-src 'self' 'nonce-%s' 'unsafe-eval'; \
     style-src 'self' 'unsafe-inline'; \
     font-src 'self' data:; \
     worker-src 'self' blob:"
    nonce

let assets_root = Web_dashboard.assets_root

(** Local GraphiQL assets *)
let graphiql_asset_root () =
  Filename.concat (assets_root ()) "graphiql"

let graphiql_asset_path name =
  Filename.concat (graphiql_asset_root ()) name

let asset_content_type name =
  if Filename.check_suffix name ".css" then
    "text/css; charset=utf-8"
  else if Filename.check_suffix name ".js" then
    "application/javascript; charset=utf-8"
  else if Filename.check_suffix name ".html" then
    "text/html; charset=utf-8"
  else if Filename.check_suffix name ".svg" then
    "image/svg+xml"
  else if Filename.check_suffix name ".png" then
    "image/png"
  else if Filename.check_suffix name ".jpg" || Filename.check_suffix name ".jpeg" then
    "image/jpeg"
  else if Filename.check_suffix name ".webp" then
    "image/webp"
  else if Filename.check_suffix name ".json" then
    "application/json"
  else if Filename.check_suffix name ".woff2" then
    "font/woff2"
  else if Filename.check_suffix name ".map" then
    "application/json"
  else
    "application/octet-stream"

let read_file path =
  try Ok (In_channel.with_open_bin path In_channel.input_all)
  with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Error (Printexc.to_string exn)

let serve_graphiql_asset name _request reqd =
  let path = graphiql_asset_path name in
  match read_file path with
  | Ok body ->
      Http.Response.bytes ~content_type:(asset_content_type name) body reqd
  | Error _ ->
      Http.Response.not_found reqd

(** Local GraphQL Playground assets *)
let playground_asset_root () =
  Filename.concat (assets_root ()) "playground"

let playground_asset_path name =
  Filename.concat (playground_asset_root ()) name

let serve_playground_asset name _request reqd =
  let path = playground_asset_path name in
  match read_file path with
  | Ok body ->
      Http.Response.bytes ~content_type:(asset_content_type name) body reqd
  | Error _ ->
      Http.Response.not_found reqd

(** Dashboard SPA assets (Preact + HTM, built by Vite) *)
let dashboard_asset_root () =
  Filename.concat (assets_root ()) "dashboard"

let dashboard_index_path () =
  Filename.concat (dashboard_asset_root ()) "index.html"

let dashboard_etag () =
  try
    let st = Unix.stat (dashboard_index_path ()) in
    let hash =
      Digest.string (string_of_float st.Unix.st_mtime) |> Digest.to_hex
    in
    String.sub hash 0 12
  with
  | Unix.Unix_error (err, _, _) ->
      Log.Pages.warn "dashboard_etag stat failed: %s" (Unix.error_message err);
      "none"
  | exn ->
      Log.Pages.warn "dashboard_etag unexpected: %s" (Printexc.to_string exn);
      "none"

let dashboard_index_cache_control = "no-store, max-age=0, must-revalidate"

let serve_dashboard_index request reqd =
  match read_file (dashboard_index_path ()) with
  | Ok body ->
      Http.Response.html_cached
        ~etag:(dashboard_etag ())
        ~request body reqd
  | Error _ ->
      Http.Response.html
        "<!doctype html><html lang=\"en\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>Dashboard not found</title><body><p>Dashboard build not found. Run: <code>cd dashboard &amp;&amp; pnpm run build</code></p></body></html>"
        reqd

let is_compressible_asset name =
  Filename.check_suffix name ".js"
  || Filename.check_suffix name ".css"
  || Filename.check_suffix name ".svg"
  || Filename.check_suffix name ".html"
  || Filename.check_suffix name ".json"
  || Filename.check_suffix name ".map"

let serve_dashboard_static name request reqd =
  let path = Filename.concat (dashboard_asset_root ()) name in
  match read_file path with
  | Ok body ->
      let content_type = asset_content_type name in
      (* Vite hashed assets are immutable; index.html is not *)
      let cache_control =
        if Filename.check_suffix name ".html" then
          dashboard_index_cache_control
        else
          "public, max-age=31536000, immutable"
      in
      let final_body, encoding_headers =
        if is_compressible_asset name && Http.Compression.accepts_zstd request then
          let (compressed, did_compress) = Http.Compression.compress_zstd ~level:3 body in
          if did_compress then
            (compressed, [("content-encoding", "zstd"); ("vary", "Accept-Encoding")])
          else
            (body, [])
        else
          (body, [])
      in
      let headers = ("cache-control", cache_control) :: encoding_headers in
      Http.Response.bytes ~headers ~content_type final_body reqd
  | Error _ ->
      Http.Response.not_found reqd

(** Dashboard Bonsai island (Jane Street Bonsai + js_of_ocaml).
    Coexists with the Preact SPA under [/dashboard/b/*] until the migration is
    complete. See planning/claude-plans/masc-mcp-eventual-parrot.md. *)
let bonsai_asset_root () =
  Filename.concat (assets_root ()) "dashboard_bonsai"

(* Bundle version — mtime of main.bc.js, appended to the script src as a
   query string so the browser refetches whenever the bundle is rebuilt.
   Cache-Control on the bundle itself stays [immutable] (1 year) for cheap
   reloads of unchanged code; the URL change is what defeats the cache. *)
let bonsai_asset_mtime filename =
  let path = Filename.concat (bonsai_asset_root ()) filename in
  try
    let st = Unix.stat path in
    Printf.sprintf "%d" (Float.to_int st.st_mtime)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | _ -> "0"

let bonsai_bundle_version () = bonsai_asset_mtime "main.bc.js"
let bonsai_tokens_version () = bonsai_asset_mtime "colors_and_type.css"

let bonsai_index_html () =
  (* [colors_and_type.css] is the MASC Design System SSOT — :root palette,
     font stacks, and utility primitives. Served from assets/dashboard_bonsai/
     (copied there by `make bonsai-dashboard`). If the file isn't present,
     the <link> 404s and the inline <style> fallback keeps the page readable. *)
  Printf.sprintf
    {|<!doctype html>
<html lang="ko" data-theme="dark-fantasy">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>masc-mcp · Bonsai</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Cinzel:wght@400;500;600;700&family=EB+Garamond:ital,wght@0,400;0,600;1,400&family=JetBrains+Mono:wght@400;500;700&family=Noto+Sans+KR:wght@300;400;500;700&display=swap">
<link rel="stylesheet" href="/dashboard/b/assets/colors_and_type.css?v=%s">
<style>
  /* Shell defaults — Design System SSOT lives in colors_and_type.css.
     The grain overlay is a fixed, non-interactive pseudo-element on body.
     Taken from MASC Design System ui_kits/dashboard_v2 — creates the
     "oil-painting" Disco-Elysium feel by multiply-blending fractalNoise
     SVG at 35%% opacity. Cheap: one inline data-URI, no HTTP, no JS. */
  html, body { background: #0a0706; margin: 0; min-height: 100vh; }
  body {
    color: var(--text-primary, #b8a488);
    background:
      radial-gradient(ellipse 60%% 40%% at 12%% 8%%, rgba(212,169,64,0.05), transparent 55%%),
      radial-gradient(ellipse 40%% 50%% at 92%% 95%%, rgba(160,24,24,0.06), transparent 60%%),
      linear-gradient(170deg, #0e0a08 0%%, #140c08 60%%, #080504 100%%);
  }
  body::before {
    content: "";
    position: fixed;
    inset: 0;
    pointer-events: none;
    z-index: 0;
    background-image: url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='220' height='220'><filter id='n'><feTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='2' seed='5'/><feColorMatrix values='0 0 0 0 0.1  0 0 0 0 0.08  0 0 0 0 0.06  0 0 0 0.6 0'/></filter><rect width='100%%25' height='100%%25' filter='url(%%23n)' opacity='0.35'/></svg>");
    mix-blend-mode: multiply;
  }
  #app { position: relative; z-index: 1; }
</style>
</head>
<body>
<div id="app"></div>
<script src="/dashboard/b/assets/main.bc.js?v=%s"></script>
</body>
</html>
|}
    (bonsai_tokens_version ())
    (bonsai_bundle_version ())

let serve_bonsai_index _request reqd =
  Http.Response.html (bonsai_index_html ()) reqd

(** [GET /dashboard/b/api/keepers/summary] — projection consumed by
    Bonsai focus card / roster / swimlane / context pressure chart.
    This endpoint must stay scoped to the live server [base_path]; returning
    static fixture rows here makes Bonsai look like an SSOT while showing a
    different keeper universe than the operator dashboard. *)
let iso8601_utc_now () =
  let open Unix in
  let t = gmtime (gettimeofday ()) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (t.tm_year + 1900) (t.tm_mon + 1) t.tm_mday
    t.tm_hour t.tm_min t.tm_sec

let bonsai_keeper_status_of_phase phase =
  let module K = Masc_dashboard_api_types.Keepers in
  let open Keeper_state_machine in
  match phase with
  | Running -> K.Live
  | Failing | Overflowed | Compacting | HandingOff | Draining | Paused
  | Restarting ->
      Warn
  | Offline | Stopped | Crashed | Dead -> Dead

let bonsai_ctx_pct (meta : Keeper_types.keeper_meta) =
  match meta.max_context_override with
  | Some max_tokens when max_tokens > 0 && meta.runtime.usage.last_total_tokens > 0 ->
      let pct =
        (meta.runtime.usage.last_total_tokens * 100) / max_tokens
      in
      min 100 (max 0 pct)
  | _ -> 0

let latest_tool_name (entry : Keeper_registry.registry_entry) =
  let latest =
    Keeper_registry.StringMap.fold
      (fun tool_name tool_entry acc ->
        match acc with
        | None -> Some (tool_name, tool_entry.Keeper_types.last_used_at)
        | Some (_, ts) when tool_entry.Keeper_types.last_used_at > ts ->
            Some (tool_name, tool_entry.Keeper_types.last_used_at)
        | Some _ -> acc)
      entry.tool_usage
      None
  in
  Option.map fst latest

let keepers_summary_from_registry ~base_path
    : Masc_dashboard_api_types.Keepers.response =
  let module K = Masc_dashboard_api_types.Keepers in
  let entries =
    Keeper_registry.all ~base_path ()
    |> List.sort (fun (a : Keeper_registry.registry_entry) b ->
           String.compare a.name b.name)
  in
  let keepers =
    List.map
      (fun (entry : Keeper_registry.registry_entry) ->
        let meta = entry.meta in
        K.
          { name = entry.name
          ; stat = Keeper_state_machine.phase_to_string entry.phase
          ; status = bonsai_keeper_status_of_phase entry.phase
          ; ctx_pct = bonsai_ctx_pct meta
          ; turn = meta.runtime.usage.total_turns
          ; turn_cap = 60
          ; mem_kb = 0
          ; latency_ms = meta.runtime.usage.last_latency_ms
          ; last_tool = latest_tool_name entry
          ; lane_frames = []
          ; ctx_history = []
          })
      entries
  in
  let cycle =
    List.fold_left
      (fun acc (entry : Keeper_registry.registry_entry) ->
        max acc entry.meta.runtime.usage.total_turns)
      0
      entries
  in
  K.{
    keepers;
    cycle;
    room = Some (Filename.basename base_path);
    generated_at = iso8601_utc_now ();
  }

let bonsai_api_keepers_summary request reqd =
  match !server_state with
  | None ->
      respond_public_read_json
        ~status:`Internal_server_error
        request
        reqd
        (Yojson.Safe.to_string
           (`Assoc [ ("error", `String "server state not initialized") ]))
  | Some state ->
      let resp =
        keepers_summary_from_registry ~base_path:state.room_config.base_path
      in
      let body =
        Yojson.Safe.to_string
          (Masc_dashboard_api_types.Keepers.response_to_yojson resp)
      in
      respond_public_read_json request reqd body

let serve_bonsai_static name request reqd =
  let path = Filename.concat (bonsai_asset_root ()) name in
  match read_file path with
  | Ok body ->
      let content_type = asset_content_type name in
      let cache_control =
        if Filename.check_suffix name ".html" then
          dashboard_index_cache_control
        else
          "public, max-age=31536000, immutable"
      in
      let final_body, encoding_headers =
        if is_compressible_asset name && Http.Compression.accepts_zstd request then
          let (compressed, did_compress) = Http.Compression.compress_zstd ~level:3 body in
          if did_compress then
            (compressed, [("content-encoding", "zstd"); ("vary", "Accept-Encoding")])
          else
            (body, [])
        else
          (body, [])
      in
      let headers = ("cache-control", cache_control) :: encoding_headers in
      Http.Response.bytes ~headers ~content_type final_body reqd
  | Error _ ->
      Http.Response.not_found reqd

let favicon_svg = {|
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <rect width="64" height="64" rx="12" fill="#0f172a"/>
  <circle cx="32" cy="32" r="18" fill="#1d4ed8"/>
  <path d="M22 42 L32 18 L42 42 Z" fill="#93c5fd"/>
</svg>
|}

let serve_favicon _request reqd =
  Http.Response.bytes ~content_type:"image/svg+xml" favicon_svg reqd

let http_status_of_graphql = function
  | `OK -> `OK
  | `Bad_request -> `Bad_request

(** Shared by HTTP/2 gateway handlers that require initialized server state. *)
let get_server_state_result () =
  match !server_state with
  | Some s -> Ok s
  | None -> Error "server state not initialized"

let server_state_error_json message =
  Yojson.Safe.to_string (`Assoc [ ("error", `String message) ])

let handle_get_graphql _request reqd =
  let nonce =
    let rng = Random.State.make_self_init () in
    let bytes = Bytes.init 16 (fun _ -> Char.chr (Random.State.int rng 256)) in
    Base64.encode_string (Bytes.to_string bytes)
  in
  let headers = [
    ("content-security-policy", graphql_csp_header nonce);
  ] in
  let body = graphql_playground_html ~nonce in
  Http.Response.html ~headers body reqd

let handle_post_graphql request reqd =
  let origin = get_origin request in
  Http.Request.read_body_async reqd (fun body_str ->
    match get_server_state_result () with
    | Error message ->
        respond_json_with_cors ~status:`Internal_server_error request reqd
          (server_state_error_json message)
    | Ok state ->
        let response = Graphql_api.handle_request ~config:state.room_config body_str in
        let status = http_status_of_graphql response.status in
        let headers = Httpun.Headers.of_list (
          ("content-length", string_of_int (String.length response.body))
          :: graphql_headers origin
        ) in
        let http_response = Httpun.Response.create ~headers status in
        Httpun.Reqd.respond_with_string reqd http_response response.body
  )

let handle_graphql request reqd =
  match Http.Request.method_ request with
  | `GET -> handle_get_graphql request reqd
  | `POST -> handle_post_graphql request reqd
  | _ -> Http.Response.method_not_allowed reqd
