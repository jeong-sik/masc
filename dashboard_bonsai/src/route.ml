(** Client-side route SSOT.

    Server serves the same HTML shell at every [/dashboard/b/*] URL (catchall
    [prefix_get] in [lib/server/server_routes_http_routes_frontend.ml]). The
    Bonsai entry reads [window.location.pathname] and matches it against the
    variants here to pick which view to mount.

    Adding a tab = (1) add a variant, (2) extend [slug]/[label]/[path]/
    [of_path], (3) add it to [all] so the nav renders it, (4) flip
    [is_implemented] when the Bonsai view lands. *)

open! Core

type t =
  | Overview
  | Logs
  | Goals
  | Keepers
  | Observatory
  | Intervene
  | Tools
  | Sessions
  | Social_board
  | Dead_keepers
  | Archive_runs
  | Hello
[@@deriving sexp, compare, equal]

let slug = function
  | Overview -> "overview"
  | Logs -> "logs"
  | Goals -> "goals"
  | Keepers -> "keepers"
  | Observatory -> "observatory"
  | Intervene -> "intervene"
  | Tools -> "tools"
  | Sessions -> "sessions"
  | Social_board -> "social-board"
  | Dead_keepers -> "dead-keepers"
  | Archive_runs -> "archive-runs"
  | Hello -> "hello"
;;

(* User-facing short label. logs 탭은 한글 (h1은 영문 "THE WATCH"가 맡음). *)
let label = function
  | Overview -> "overview"
  | Logs -> "저널"
  | Goals -> "goals"
  | Keepers -> "keepers"
  | Observatory -> "observatory"
  | Intervene -> "intervene"
  | Tools -> "tools"
  | Sessions -> "sessions"
  | Social_board -> "social board"
  | Dead_keepers -> "dead keepers"
  | Archive_runs -> "archive runs"
  | Hello -> "hello"
;;

let path t = Printf.sprintf "/dashboard/b/%s" (slug t)

(* Bonsai로 이식된 탭 목록. 그 외는 placeholder (Phase 2+). *)
let is_implemented = function
  | Logs | Hello | Dead_keepers | Keepers | Archive_runs | Overview | Goals -> true
  | Observatory | Intervene | Tools | Sessions | Social_board -> false
;;

(* 사이드바 렌더 순서. design_v2 IA와 동일. Hello는 legacy라 nav에 노출 안 함. *)
let all : t list =
  [ Overview
  ; Logs
  ; Goals
  ; Keepers
  ; Observatory
  ; Intervene
  ; Tools
  ; Sessions
  ; Social_board
  ; Dead_keepers
  ; Archive_runs
  ]
;;

let of_path (path_str : string) : t =
  let trimmed =
    String.chop_prefix path_str ~prefix:"/dashboard/b/"
    |> Option.value ~default:path_str
  in
  (* strip trailing slash / query string *)
  let head =
    match String.lsplit2 trimmed ~on:'/' with
    | Some (h, _) -> h
    | None -> trimmed
  in
  let head =
    match String.lsplit2 head ~on:'?' with
    | Some (h, _) -> h
    | None -> head
  in
  match head with
  | "logs" -> Logs
  | "overview" -> Overview
  | "goals" -> Goals
  | "keepers" -> Keepers
  | "observatory" -> Observatory
  | "intervene" -> Intervene
  | "tools" -> Tools
  | "sessions" -> Sessions
  | "social-board" -> Social_board
  | "dead-keepers" -> Dead_keepers
  | "archive-runs" -> Archive_runs
  | "hello" -> Hello
  | "" -> Overview (* /dashboard/b/ → Overview *)
  | _ -> Overview (* unknown → Overview *)
;;
