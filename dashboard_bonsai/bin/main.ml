open! Core
open! Bonsai_web
open Js_of_ocaml

(* URL hash + localStorage 기반 data-theme 선택.

   우선순위 (초기 paint):
     1. URL hash (#cyberpunk, #paper ...) — 공유 링크의 SSOT
     2. localStorage["masc.bonsai.theme"] — 이전 세션 기억
     3. dark-fantasy (default)

   hashchange / chip 클릭으로 theme 바뀌면 localStorage에도 저장해서
   다음 방문에 URL 없이도 같은 테마로 복원. 단, URL이 존재하면 URL
   우선 — 공유 링크가 stored 값을 덮어쓴다.

   해시 예:
     http://127.0.0.1:8935/dashboard/b/#cyberpunk
     http://127.0.0.1:8935/dashboard/b/#terminal
*)

let storage_key = "masc.bonsai.theme"

let normalize_theme_token s =
  match String.lowercase s with
  | "cyber" | "cyberpunk" -> Some "cyberpunk"
  | "term" | "terminal" -> Some "terminal"
  | "parchment" -> Some "parchment"
  | "paper" -> Some "paper"
  | "dark" | "dark-fantasy" -> Some "dark-fantasy"
  | _ -> None
;;

let local_storage () =
  Js.Optdef.to_option Dom_html.window##.localStorage

let read_stored_theme () =
  match local_storage () with
  | None -> None
  | Some storage ->
    (match Js.Opt.to_option (storage##getItem (Js.string storage_key)) with
     | None -> None
     | Some v -> normalize_theme_token (Js.to_string v))
;;

let write_stored_theme theme =
  match local_storage () with
  | None -> ()
  | Some storage ->
    storage##setItem (Js.string storage_key) (Js.string theme)
;;

let current_hash_theme () =
  let hash = Js.to_string Dom_html.window##.location##.hash in
  match String.chop_prefix hash ~prefix:"#" with
  | None -> None
  | Some "" -> None
  | Some rest -> normalize_theme_token rest
;;

let apply_theme theme =
  Dom_html.document##.documentElement##setAttribute
    (Js.string "data-theme")
    (Js.string theme);
  write_stored_theme theme
;;

let resolve_initial_theme () =
  match current_hash_theme () with
  | Some t -> t
  | None ->
    (match read_stored_theme () with
     | Some t -> t
     | None -> "dark-fantasy")
;;

let install_theme_listener () =
  (* 초기 paint: URL hash > localStorage > dark-fantasy *)
  apply_theme (resolve_initial_theme ());
  let on_hashchange _ =
    (match current_hash_theme () with
     | Some t -> apply_theme t
     | None -> apply_theme "dark-fantasy");
    Js._true
  in
  Dom_html.window##.onhashchange := Dom_html.handler on_hashchange
;;

(* Moonrise clock — dashboard hero 아래 narrative strip의 "23:50 local"
   자리에 실제 브라우저 로컬 시각을 매초 투영. Bonsai state 경유
   안 함 — moonrise 한 element의 textContent 하나만 바꾸면 되니
   document.querySelectorAll("[data-moon-clock]") 직접 접근이 더 경제적. *)

let pad2 n =
  if n < 10 then Printf.sprintf "0%d" n else Printf.sprintf "%d" n
;;

let now_local_text () =
  let d = new%js Js.date_now in
  Printf.sprintf
    "%s:%s:%s local"
    (pad2 d##getHours)
    (pad2 d##getMinutes)
    (pad2 d##getSeconds)
;;

let tick_moon_clocks () =
  let nodes =
    Dom_html.document##querySelectorAll (Js.string "[data-moon-clock]")
  in
  let text = Js.string (now_local_text ()) in
  for i = 0 to nodes##.length - 1 do
    match Js.Opt.to_option (nodes##item i) with
    | None -> ()
    | Some el -> el##.textContent := Js.some text
  done
;;

let install_moon_clock () =
  tick_moon_clocks ();
  let _id =
    Dom_html.window##setInterval
      (Js.wrap_callback tick_moon_clocks)
      (Js.number_of_float 1000.0)
  in
  ()
;;

let () =
  install_theme_listener ();
  Start.start ~bind_to_element_with_id:"app" Dashboard_bonsai_lib.App.root;
  Dashboard_bonsai_lib.Logs_fetch.run ();
  Dashboard_bonsai_lib.Logs_fetch.start_polling ();
  Dashboard_bonsai_lib.Keepers_fetch.run ();
  Dashboard_bonsai_lib.Keepers_fetch.start_polling ();
  install_moon_clock ()
;;
