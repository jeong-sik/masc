open! Core
open! Bonsai_web
open Js_of_ocaml

(* URL hash로 data-theme 선택. colors_and_type.css가 이미 SPA head에
   :root palette 5종을 공급하므로 <html data-theme="..."> 한 줄로 전체
   팔레트가 즉시 전환된다.

   해시 예:
     http://127.0.0.1:8935/dashboard/b/#cyberpunk
     http://127.0.0.1:8935/dashboard/b/#terminal
     http://127.0.0.1:8935/dashboard/b/#dark (또는 해시 없음)

   hashchange 이벤트도 listen해 전환을 즉시 반영한다. 세션 간 persistence는
   아직 없음 (localStorage 미사용) — URL이 SSOT. *)

let normalize_theme_token s =
  match String.lowercase s with
  | "cyber" | "cyberpunk" -> Some "cyberpunk"
  | "term" | "terminal" -> Some "terminal"
  | "parchment" -> Some "parchment"
  | "paper" -> Some "paper"
  | "dark" | "dark-fantasy" -> Some "dark-fantasy"
  | _ -> None
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
    (Js.string theme)
;;

let install_theme_listener () =
  (match current_hash_theme () with
   | Some t -> apply_theme t
   | None -> ());
  let on_hashchange _ =
    (match current_hash_theme () with
     | Some t -> apply_theme t
     | None -> apply_theme "dark-fantasy");
    Js._true
  in
  Dom_html.window##.onhashchange := Dom_html.handler on_hashchange
;;

let () =
  install_theme_listener ();
  Start.start ~bind_to_element_with_id:"app" Dashboard_bonsai_lib.App.root;
  Dashboard_bonsai_lib.Logs_fetch.run ();
  Dashboard_bonsai_lib.Logs_fetch.start_polling ()
;;
