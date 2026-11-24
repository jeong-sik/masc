(* HIGH-RISK-UNREVIEWED: see the interface. *)

module Http = Http_server_eio

let page_path = Account_page.console_path
let dashboard_path = "/dashboard"
let dashboard_deep_link_prefix = dashboard_path ^ "/"
let dashboard_assets_prefix = dashboard_path ^ "/assets/"
let console_redirect_target = dashboard_path ^ "#account"
let legacy_assets_prefix = page_path ^ "/assets/"
let base_sheet_path = page_path ^ "/base.css"

(* Unified dashboard SPA root inside the dashboard bundle, plus legacy account
   console assets kept readable for already-loaded tabs. *)
let dashboard_bundle_page = "index.html"
let dashboard_bundle_assets = "assets/"
let legacy_bundle_assets = "accounts/assets/"

let policy =
  "default-src 'none'; script-src 'self'; script-src-attr 'none'; style-src 'self'; \
   style-src-attr 'unsafe-inline'; object-src 'none'; img-src 'self' data:; font-src 'self'; \
   connect-src 'self'; "
  ^ Account_page.formless_limits
;;

let no_store = "cache-control", "no-store"

(* A link of the console that leaves this origin (the login page of a
   provider) carries no Referer. The home page of the server says the same
   ([Auth_preview]). *)
let referrer_policy = "referrer-policy", "same-origin"

let unreadable_reason : Web_dashboard.asset_load_error -> string = function
  | Web_dashboard.Asset_not_manifested ->
    Printf.sprintf "the dashboard bundle of this server holds no %s" dashboard_bundle_page
  | Web_dashboard.Asset_build_unavailable -> "this launch has no dashboard bundle"
  | Web_dashboard.Asset_binding_invalid (_ : Build_identity.dashboard_asset_invalid_reason) ->
    "the dashboard bundle bound to this launch is not valid"
  | Web_dashboard.Asset_installed_invalid (_ : Installed_dashboard.error) ->
    "the installed dashboard bundle is not valid"
  | Web_dashboard.Asset_exact_read_failed detail -> detail
;;

let unreadable () =
  match Web_dashboard.load_dashboard_asset dashboard_bundle_page with
  | Ok (_ : Web_dashboard.loaded_asset) -> None
  | Error error -> Some (unreadable_reason error)
;;

(* The page that stands in for the dashboard when the bundle cannot give it.
   It names no file and no reason: anyone who reaches the listener reads it.
   The server writes the reason to its log once, when it starts
   ([Server_accounts.run]); a request to this open route writes none, so a
   bundle that breaks after the start leaves no line. *)
let unavailable ~nonce reqd =
  Http.Response.html
    ~status:`Service_unavailable
    ~headers:
      [ no_store
      ; referrer_policy
      ; ( "content-security-policy"
        , Printf.sprintf
            "default-src 'none'; %s; %s"
            (Account_page.style_source ~nonce)
            Account_page.formless_limits )
      ]
    (Account_page.document
       ~nonce
       ~title:"MASC 대시보드"
       (String.concat
          "\n"
          [ "<main>"
          ; "<div class=\"narrow\">"
          ; "<div class=\"card\">"
          ; "<h1>지금은 이 화면을 열 수 없어요</h1>"
          ; "<p>서버가 이 화면의 파일을 읽지 못했어요. 이 서버를 운영하는 사람에게 알려 주세요.</p>"
          ; "<p><a class=\"button primary block\" href=\"/\">처음 화면으로</a></p>"
          ; "</div>"
          ; "</div>"
          ; "</main>"
          ]))
    reqd
;;

let dashboard_page (_ : Httpun.Request.t) reqd =
  match Web_dashboard.load_dashboard_asset dashboard_bundle_page with
  | Ok { Web_dashboard.body; version = _ } ->
    Http.Response.html
      ~headers:[ no_store; referrer_policy; "content-security-policy", policy ]
      body
      reqd
  | Error (_ : Web_dashboard.asset_load_error) -> unavailable ~nonce:(Csp_nonce.draw ()) reqd
;;

let dashboard_deep_link request reqd =
  let req_path = Http.Request.path request in
  if Server_routes_http_runtime.is_dashboard_spa_deep_link req_path
  then dashboard_page request reqd
  else Http.Response.not_found reqd
;;

let console_redirect (_ : Httpun.Request.t) reqd =
  let headers =
    Httpun.Headers.of_list
      [ "location", console_redirect_target
      ; no_store
      ; referrer_policy
      ; "content-length", "0"
      ]
  in
  Http_reqd.respond_with_string reqd (Httpun.Response.create ~headers `See_other) ""
;;

(* A file the bundle cannot give now. The answer of the operator dashboard
   points at a health field this server does not have. *)
let asset_unavailable reqd =
  Http.Response.text ~status:`Service_unavailable "This file cannot be read now." reqd
;;

(* The path of a request is the target as it came, not decoded
   ([Http.Request.path]), and the check takes it as a list of segments: a
   segment that is empty, "." or ".." is refused, so the name stays below the
   assets prefix. A file of the build carries the policy of the page:
   a browser that opens one as a document (an .html or .svg of a later build)
   runs on this origin under the same limits as the page. *)
let serve_prefixed_asset ~route_prefix ~bundle_prefix request reqd =
  let path = Http.Request.path request in
  let prefix_len = String.length route_prefix in
  let filename = String.sub path prefix_len (String.length path - prefix_len) in
  let relative = bundle_prefix ^ filename in
  if Web_dashboard.is_public_asset_relative_path filename
     && Web_dashboard.is_public_asset_relative_path relative
  then
    Server_routes_http_pages.serve_dashboard_asset
      ~headers:[ "content-security-policy", policy ]
      ~unavailable:asset_unavailable
      relative
      request
      reqd
  else Http.Response.not_found reqd
;;

let dashboard_asset request reqd =
  serve_prefixed_asset
    ~route_prefix:dashboard_assets_prefix
    ~bundle_prefix:dashboard_bundle_assets
    request
    reqd
;;

let legacy_console_asset request reqd =
  serve_prefixed_asset
    ~route_prefix:legacy_assets_prefix
    ~bundle_prefix:legacy_bundle_assets
    request
    reqd
;;

let base_sheet_etag = Http.Response.etag_of_body Account_page.base_sheet

(* The address of the sheet is fixed in the page of the build, and its bytes
   change with the binary, so a browser asks again on every use. *)
let base_sheet request reqd =
  Http.Response.bytes_cached
    ~etag:base_sheet_etag
    ~cache_control:"no-cache"
    ~request
    ~content_type:"text/css; charset=utf-8"
    Account_page.base_sheet
    reqd
;;

let favicon (_ : Httpun.Request.t) reqd =
  Http.Response.bytes
    ~headers:[ "content-security-policy", "default-src 'none'" ]
    ~content_type:"image/svg+xml"
    Server_routes_http_pages.favicon_svg
    reqd
;;

let add_routes router =
  router
  |> Server_route.get Server_route.Always_public dashboard_path dashboard_page
  |> Server_route.prefix_get Server_route.Always_public dashboard_assets_prefix dashboard_asset
  |> Server_route.prefix_get Server_route.Always_public dashboard_deep_link_prefix dashboard_deep_link
  |> Server_route.get Server_route.Always_public "/favicon.ico" favicon
  |> Server_route.get Server_route.Always_public "/favicon.svg" favicon
  |> Server_route.get Server_route.Always_public page_path console_redirect
  |> Server_route.get Server_route.Always_public base_sheet_path base_sheet
  |> Server_route.prefix_get Server_route.Always_public legacy_assets_prefix legacy_console_asset
;;
