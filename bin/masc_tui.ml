(** Thin entrypoint for the MASC interactive terminal UI ([masc-tui]).

    Wires the pure screen and overlay renderers from [masc_tui_screens_core],
    [masc_tui_screens_ops], and [masc_tui_screens_domain] into
    {!Masc_tui_screens_core.Chrome.render_frame} and delegates CLI dispatch,
    TTY guarding, and the 3-domain Eio runtime loop to {!Masc_tui_app}. *)

open Masc_tui_core
open Masc_tui_store
open Masc_tui_screens_core
open Masc_tui_screens_ops
open Masc_tui_screens_domain
open Masc_tui_app

let render_body ~(model : Model.t) ~cache rect grid =
  match Model.active_dive model with
  | Some (Nav.Dive_keeper { name; tab }) ->
      Screen_keepers.render_dive ~name ~tab ~model ~cache ~rect grid
  | Some (Nav.Dive_work target) ->
      Screen_work.render_dive ~target ~model ~cache ~rect grid
  | Some (Nav.Dive_knowledge target) ->
      Screen_knowledge.render_dive ~target ~model ~cache ~rect grid
  | Some (Nav.Dive_runtime target) ->
      Screen_runtime.render_dive ~target ~model ~cache ~rect grid
  | Some (Nav.Dive_infra target) ->
      Screen_infra.render_dive ~target ~model ~cache ~rect grid
  | None -> (
      match model.nav.workspace with
      | Nav.Pulse -> Screen_pulse.render ~model ~cache ~rect grid
      | Nav.Work -> Screen_work.render ~model ~cache ~rect grid
      | Nav.Knowledge -> Screen_knowledge.render ~model ~cache ~rect grid
      | Nav.Keepers -> Screen_keepers.render ~model ~cache ~rect grid
      | Nav.Runtime -> Screen_runtime.render ~model ~cache ~rect grid
      | Nav.Infra -> Screen_infra.render ~model ~cache ~rect grid)

let render_overlay ~model ~cache rect grid =
  Overlays.render ~model ~cache ~rect grid

let render_frame ~model ~cache grid =
  Chrome.render_frame ~model ~cache
    ~render_body:(render_body ~model ~cache)
    ~render_overlay:(render_overlay ~model ~cache)
    grid

let () =
  let exit_code =
    match Cli_args.parse_and_dispatch () with
    | Cli_args.Exit code -> code
    | Cli_args.Start cli -> App.run ~cli ~render_frame ()
  in
  exit exit_code
