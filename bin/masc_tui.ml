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

let render_body ~(model : Model.t) ~cache ~history_rows rect grid =
  match Model.active_inspector model with
  | Some (Nav.Verification_inspector req_id) ->
      Screen_work.render_verification ~req_id ~model ~cache ~rect grid
  | Some (Nav.Tool_inspector tool_name) ->
      Screen_runtime.render_inspector ~target:(`Tool tool_name) ~model ~cache
        ~rect grid
  | Some (Nav.Skill_inspector ref_s) ->
      Screen_runtime.render_inspector ~target:(`Skill ref_s) ~model ~cache
        ~rect grid
  | Some (Nav.Exact_run_inspector run_id) ->
      Screen_runtime.render_inspector ~target:(`Exact_run run_id) ~model ~cache
        ~rect grid
  | Some (Nav.File_inspector peek) ->
      Screen_file_peek.render ~peek ~model ~cache ~rect grid
  | None -> (
      match model.nav.workspace with
      | Nav.Pulse -> Screen_pulse.render ~model ~cache ~rect grid
      | Nav.Work -> Screen_work.render ~model ~cache ~rect grid
      | Nav.Knowledge -> Screen_knowledge.render ~model ~cache ~rect grid
      | Nav.Keepers ->
          Screen_keepers.render_with_history_rows ~model ~cache
            ~history_rows:(Some history_rows) ~rect grid
      | Nav.Runtime -> Screen_runtime.render ~model ~cache ~rect grid
      | Nav.Infra -> Screen_infra.render ~model ~cache ~rect grid)

let render_overlay ~model ~cache rect grid =
  Overlays.render ~model ~cache ~rect grid

let render_frame ~model ~cache ~history_rows grid =
  Chrome.render_frame ~model ~cache
    ~render_body:(render_body ~model ~cache ~history_rows)
    ~render_overlay:(render_overlay ~model ~cache)
    grid

let () =
  (* One place keeps the chat history rows of the keepers whose chat was
     drawn last. Nothing clears it: an entry is used only while the layout
     and the messages it was built from are still equal. *)
  let history_rows = Keeper_dive.History_rows.create () in
  let exit_code =
    match Cli_args.parse_and_dispatch () with
    | Cli_args.Exit code -> code
    | Cli_args.Start cli ->
        App.run ~cli ~render_frame:(render_frame ~history_rows) ()
  in
  exit exit_code
