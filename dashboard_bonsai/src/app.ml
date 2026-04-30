(** Top-level router for the Bonsai island.

    Server serves the same HTML shell (see
    [lib/server/server_routes_http_pages.ml:bonsai_index_html]) at every
    [/dashboard/b/*] URL, so route selection happens client-side. Static
    read at mount time — no client-side history API yet.

    Route SSOT: [route.ml]. Add a tab = add a variant + extend helpers. *)

open! Core
open! Bonsai_web

let current_path () =
  Brr.Uri.path (Brr.Window.location Brr.G.window) |> Jstr.to_string
;;

let root (graph @ local) =
  match Route.of_path (current_path ()) with
  | Logs -> Logs_view.component graph
  | Hello -> Hello_view.component graph
  | Dead_keepers -> Dead_keepers_view.component graph
  | Keepers -> Keepers_view.component graph
  | Archive_runs -> Archive_runs_view.component graph
  | Overview -> Overview_view.component graph
  | Goals -> Goals_view.component graph
  | Multimodal -> Multimodal_view.component graph
  | other -> Placeholder_view.component ~route:other graph
;;
