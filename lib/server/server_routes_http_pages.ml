
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
    <div id="workspace"></div>
    <script nonce="|};
    nonce;
    {|">
      window.addEventListener("load", function () {
        var loading = document.getElementById("loading-wrapper");
        if (loading) {
          loading.classList.add("fadeOut");
        }
        var root = document.getElementById("workspace");
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
  Option.map (fun root -> Filename.concat root "graphiql") (assets_root ())

let graphiql_asset_path name =
  Option.map (fun root -> Filename.concat root name) (graphiql_asset_root ())

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

(* Static asset bodies (GraphiQL / Playground) served on the HTTP handler
   fiber.  [Fs_compat.load_file] is Eio-native when the global fs is wired
   (prod boot), so the file read no longer blocks the whole domain. *)
let read_file path =
  try Ok (Fs_compat.load_file path)
  with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Error (Printexc.to_string exn)

let serve_graphiql_asset name _request reqd =
  match Option.map read_file (graphiql_asset_path name) with
  | Some (Ok body) ->
      Http.Response.bytes ~content_type:(asset_content_type name) body reqd
  | None | Some (Error _) ->
      Http.Response.not_found reqd

(** Local GraphQL Playground assets *)
let playground_asset_root () =
  Option.map (fun root -> Filename.concat root "playground") (assets_root ())

let playground_asset_path name =
  Option.map (fun root -> Filename.concat root name) (playground_asset_root ())

let serve_playground_asset name _request reqd =
  match Option.map read_file (playground_asset_path name) with
  | Some (Ok body) ->
      Http.Response.bytes ~content_type:(asset_content_type name) body reqd
  | None | Some (Error _) ->
      Http.Response.not_found reqd

(* The tag policy lives with the responder that emits it, so the HTML route
   here and the JSON responses share one definition rather than two copies
   that agree until one is edited. *)
let dashboard_etag_hex_chars = Http.Response.etag_hex_chars
let dashboard_etag_of_body = Http.Response.etag_of_body

let dashboard_index_cache_control = "no-store, max-age=0, must-revalidate"

let serve_dashboard_index request reqd =
  match Web_dashboard.load_dashboard_asset "index.html" with
  | Ok body ->
      Http.Response.html_cached
        ~etag:(dashboard_etag_of_body body)
        ~request body reqd
  | Error _ ->
    Http.Response.html
      ~status:`Service_unavailable
      "<!doctype html><html lang=\"en\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>Dashboard unavailable</title><body><p>Dashboard assets unavailable. Inspect <code>/health</code> dashboard_surface.recovery.</p></body></html>"
      reqd

let is_compressible_asset name =
  Filename.check_suffix name ".js"
  || Filename.check_suffix name ".css"
  || Filename.check_suffix name ".svg"
  || Filename.check_suffix name ".html"
  || Filename.check_suffix name ".json"
  || Filename.check_suffix name ".map"

let serve_dashboard_static name request reqd =
  match Web_dashboard.load_dashboard_asset name with
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
        Http_response_payload.compress_body
          ~compress:(is_compressible_asset name)
          ~accept_encoding:(Httpun.Headers.get request.Httpun.Request.headers "accept-encoding")
          body
      in
      let headers = ("cache-control", cache_control) :: encoding_headers in
      Http.Response.bytes ~headers ~content_type final_body reqd
  | Error error ->
    (match Web_dashboard.asset_error_http_status error with
     | `Not_found -> Http.Response.not_found reqd
     | `Service_unavailable ->
       Http.Response.text
         ~status:`Service_unavailable
         "Dashboard assets unavailable; inspect /health dashboard_surface.recovery"
         reqd)

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
  match current_server_state () with
  | Some s -> Ok s
  | None -> Error "server state not initialized"

let server_state_error_json message =
  Yojson.Safe.to_string (`Assoc [ ("error", `String message) ])

(* DET-OK: the non-determinism is the point. A CSP nonce must differ per
   response, so a deterministic value would defeat the header. It is confined
   to one output boundary — the response's CSP header and the matching script
   tag — and nothing branches on it, parses it, or stores it.

   The ratchet flags these two lines as new debt because they moved here; they
   are unchanged from the copy that lived in handle_get_graphql, and the H2
   gateway now calls this instead of keeping a second copy.

   Scope limit, deliberately not claimed above: Random is a PRNG, not a
   CSPRNG, so this nonce is unguessable only to the extent the seed is. That
   property predates this function and is not what DET-OK asserts. *)
let fresh_graphql_csp_nonce () =
  (* DET-OK: per-response CSP nonce, rationale above. *)
  let rng = Random.State.make_self_init () in
  let bytes = Bytes.init 16 (fun _ -> Char.chr (Random.State.int rng 256)) in
  Base64.encode_string (Bytes.to_string bytes)

let handle_get_graphql _request reqd =
  let nonce = fresh_graphql_csp_nonce () in
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
        let response = Graphql_api.handle_request ~config:(Mcp_server.workspace_config state) body_str in
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
