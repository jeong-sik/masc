(* HIGH-RISK-UNREVIEWED: see the interface. *)

module Http = Http_server_eio

let page_path = "/accounts/console"
let assets_prefix = page_path ^ "/assets/"
let base_sheet_path = page_path ^ "/base.css"

(* Where the build of the console lies in the dashboard bundle
   (dashboard/vite.accounts.config.ts writes it there). *)
let bundle_page = "accounts/index.html"
let bundle_assets = "accounts/assets/"

let policy =
  "default-src 'none'; script-src 'self'; style-src 'self'; style-src-attr 'none'; connect-src 'self'; "
  ^ Account_page.formless_limits
;;

let no_store = "cache-control", "no-store"

(* A link of the console that leaves this origin (the login page of a
   provider) carries no Referer, so the other site does not learn the address
   of this server. The pages the server writes itself say the same. *)
let referrer_policy = "referrer-policy", "same-origin"

let unreadable_reason : Web_dashboard.asset_load_error -> string = function
  | Web_dashboard.Asset_not_manifested ->
    Printf.sprintf "the dashboard bundle of this server holds no %s" bundle_page
  | Web_dashboard.Asset_build_unavailable -> "this launch has no dashboard bundle"
  | Web_dashboard.Asset_binding_invalid (_ : Build_identity.dashboard_asset_invalid_reason) ->
    "the dashboard bundle bound to this launch is not valid"
  | Web_dashboard.Asset_installed_invalid (_ : Installed_dashboard.error) ->
    "the installed dashboard bundle is not valid"
  | Web_dashboard.Asset_exact_read_failed detail -> detail
;;

let unreadable () =
  match Web_dashboard.load_dashboard_asset bundle_page with
  | Ok (_ : Web_dashboard.loaded_asset) -> None
  | Error error -> Some (unreadable_reason error)
;;

(* The page that stands in for the console when the bundle cannot give it.
   It names no file and no reason: anyone who reaches the listener reads it,
   and the reason is in the log of the server. *)
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
       ~title:"MASC 내 계정"
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

let page ~draw (_ : Httpun.Request.t) reqd =
  match Web_dashboard.load_dashboard_asset bundle_page with
  | Ok { Web_dashboard.body; version = _ } ->
    Http.Response.html
      ~headers:[ no_store; referrer_policy; "content-security-policy", policy ]
      body
      reqd
  | Error (_ : Web_dashboard.asset_load_error) -> unavailable ~nonce:(draw ()) reqd
;;

(* A file of the build that the bundle lists and cannot give. The answer of
   the operator dashboard points at a health field this server does not
   have. *)
let asset_unavailable reqd =
  Http.Response.text ~status:`Service_unavailable "This file cannot be read now." reqd
;;

(* The path of a request is the target as it came, not decoded
   ([Http.Request.path]), and the check takes it as a list of segments: a
   segment that is empty, "." or ".." is refused, so the name stays below the
   assets of the console. *)
let asset request reqd =
  let path = Http.Request.path request in
  let prefix = String.length assets_prefix in
  let relative = bundle_assets ^ String.sub path prefix (String.length path - prefix) in
  if Web_dashboard.is_public_asset_relative_path relative
  then
    Server_routes_http_pages.serve_dashboard_asset
      ~unavailable:asset_unavailable
      relative
      request
      reqd
  else Http.Response.not_found reqd
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

let add_routes ~draw router =
  router
  |> Server_route.get Server_route.Always_public page_path (page ~draw)
  |> Server_route.get Server_route.Always_public base_sheet_path base_sheet
  |> Server_route.prefix_get Server_route.Always_public assets_prefix asset
;;
