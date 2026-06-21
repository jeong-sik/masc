(* server_dashboard_verify_resource — read-only verification of operator-supplied
   Settings resources (RFC-0273 §3.4). See the .mli for the boundary rationale
   (caller-supplied value => SSRF / info-disclosure surface => CanAdmin-gated at
   the route, stricter than the server-config runtime-probe). *)

type kind =
  | Mcp_endpoint
  | Gate_url
  | Worktree_path

let kind_of_string raw =
  match String.trim raw with
  | "mcp_endpoint" -> Ok Mcp_endpoint
  | "gate_url" -> Ok Gate_url
  | "worktree_path" -> Ok Worktree_path
  | other -> Error (Printf.sprintf "unknown verify kind: %s" other)

let string_of_kind = function
  | Mcp_endpoint -> "mcp_endpoint"
  | Gate_url -> "gate_url"
  | Worktree_path -> "worktree_path"

type outcome = {
  ok : bool;
  detail : string;
  http_status : int option;
  target : string;
}

(* Deterministic test injection for the HTTP path, mirroring
   Server_dashboard_http_runtime_info.set_dashboard_runtime_provider_http_get_for_tests. *)
let http_get_hook : (url:string -> (int, string) result) option ref = ref None
let set_http_get_for_tests hook = http_get_hook := Some hook
let clear_http_get_for_tests () = http_get_hook := None

let verify_timeout_sec = 5.0

(* HTTP(S) reachability for a caller-supplied URL. The server issues the GET, so
   the route gates this behind operator auth. URL scheme is restricted to
   http/https and the echoed [target] is userinfo/query/fragment-stripped — both
   reuse the canonical dashboard helpers (no reimplementation). *)
let verify_http ~value =
  let target = Server_dashboard_http_runtime_info.dashboard_runtime_url_for_json value in
  if not (Server_dashboard_http_runtime_info.dashboard_runtime_http_url_valid value)
  then { ok = false; detail = "http/https URL이 아닙니다"; http_status = None; target }
  else begin
    let status_of url =
      match !http_get_hook with
      | Some hook -> hook ~url
      | None ->
        (match Eio_context.get_clock () with
         | Error msg -> Error (Printf.sprintf "eio clock 없음: %s" msg)
         | Ok clock ->
           (match
              Masc_http_client.get_sync ~clock ~timeout_sec:verify_timeout_sec ~url
                ~headers:[] ()
            with
            | Ok (status, _body) -> Ok status
            | Error e -> Error e))
    in
    match status_of value with
    | Error e ->
      { ok = false; detail = Printf.sprintf "도달 불가: %s" e; http_status = None; target }
    | Ok status ->
      (* Honest classification: any received status proves the host responded,
         but only 2xx/3xx counts as a healthy endpoint. 4xx (wrong path / auth)
         and 5xx (server error) are surfaced as failures with the status so the
         operator is not shown a green "✓" for a misconfigured URL. *)
      let ok, detail =
        if status >= 200 && status < 400 then true, Printf.sprintf "정상 (HTTP %d)" status
        else if status >= 500 then false, Printf.sprintf "서버 오류 (HTTP %d)" status
        else false, Printf.sprintf "응답함, but HTTP %d" status
      in
      { ok; detail; http_status = Some status; target }
  end

(* Expand a leading "~" to $HOME for the worktree basepath (e.g. "~/wt").
   Reading $HOME is the one environment boundary here; the None case (HOME unset)
   is handled explicitly — the path is left literal, which then fails the
   existence check honestly rather than being silently substituted. *)
let expand_home path =
  let path = String.trim path in
  match Sys.getenv_opt "HOME" with
  | Some home when String.equal path "~" -> home
  | Some home when String.length path >= 2 && String.equal (String.sub path 0 2) "~/" ->
    Filename.concat home (String.sub path 2 (String.length path - 2))
  | Some _ | None -> path

let is_directory path = try Sys.is_directory path with Sys_error _ -> false

(* Filesystem existence for a caller-supplied directory path. Info-disclosure
   surface (reveals what exists on the host), so gated at the route. *)
let verify_path ~value =
  let expanded = expand_home value in
  if String.equal expanded "" then
    { ok = false; detail = "빈 경로"; http_status = None; target = value }
  else if not (Sys.file_exists expanded) then
    { ok = false; detail = "경로 없음"; http_status = None; target = value }
  else if not (is_directory expanded) then
    { ok = false; detail = "디렉터리 아님"; http_status = None; target = value }
  else { ok = true; detail = "경로 존재"; http_status = None; target = value }

let verify ~kind ~value =
  match kind with
  | Mcp_endpoint | Gate_url -> verify_http ~value
  | Worktree_path -> verify_path ~value

let to_json ~kind outcome =
  `Assoc
    [ ("ok", `Bool outcome.ok)
    ; ("kind", `String (string_of_kind kind))
    ; ("detail", `String outcome.detail)
    ; ("target", `String outcome.target)
    ; ( "http_status"
      , match outcome.http_status with Some status -> `Int status | None -> `Null )
    ]

let parse_request body =
  match Yojson.Safe.from_string body with
  | exception _ -> Error "invalid JSON body"
  | json ->
    let field name =
      match json with
      | `Assoc fields -> List.assoc_opt name fields
      | _ -> None
    in
    (match field "kind", field "value" with
     | Some (`String kind_str), Some (`String value) ->
       (match kind_of_string kind_str with
        | Ok kind -> Ok (kind, value)
        | Error e -> Error e)
     | Some (`String _), _ -> Error "missing or non-string \"value\""
     | _, _ -> Error "missing or non-string \"kind\"")
