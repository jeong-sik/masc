(** Top-level router for the Bonsai island.

    Server serves the same HTML shell (see
    [lib/server/server_routes_http_pages.ml:bonsai_index_html]) at every
    [/dashboard/b/*] URL, so route selection happens client-side. Static
    read at mount time — no client-side history API yet. *)

open! Core
open! Bonsai_web

let current_path () =
  Brr.Uri.path (Brr.Window.location Brr.G.window) |> Jstr.to_string
;;

let root (graph @ local) =
  let path = current_path () in
  if String.is_prefix path ~prefix:"/dashboard/b/logs"
  then Logs_view.component graph
  else Hello_view.component graph
;;
