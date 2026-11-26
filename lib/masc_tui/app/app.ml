open Masc_tui_core
open Masc_tui_net
open Masc_tui_store
open Masc_tui_term
open Masc_tui_ui

type render_frame =
  model:Model.t -> cache:Card.Cache.t -> Cell_grid.t -> Presenter.cursor

let drain_budget_ns = 3_000_000L
let voice_tick_interval_ns = 100_000_000L
let progress_animation_interval_ns =
  Int64.div 1_000_000_000L (Int64.of_int Chat_transcript.animation_frames_per_second)
let progress_elapsed_interval_ns = 1_000_000_000L
let probe_timeout_s = 0.15
let probe_grace_s = 2.0

let palette_requested_of_env ~getenv =
  let term_usable =
    match getenv "TERM" with
    | Some term ->
        let trimmed = String.trim term in
        String.length trimmed > 0
        && not (String.equal (String.lowercase_ascii trimmed) "dumb")
    | None -> false
  in
  if not term_usable then false
  else
    match getenv "MASC_TUI_FORCE_COLOR" with
    | Some "1" -> true
    | Some _ | None -> (
        match getenv "NO_COLOR" with
        | Some value when String.length value > 0 -> false
        | Some _ | None -> true)

let rec fd_immediately_readable fd =
  match Unix.select [ fd ] [] [] 0.0 with
  | _ :: _, _, _ -> `Ready
  | [], _, _ -> `Not_ready
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> fd_immediately_readable fd
  | exception Unix.Unix_error _ -> `Error

let collect_startup_probe ?(timeout_s = probe_timeout_s)
    ?(max_bytes = Probe.max_bytes) ~clock ~fd ~palette_requested () =
  let decoder = Probe.create ~palette_requested in
  let timeout_s =
    if Float.is_finite timeout_s && timeout_s > 0.0 then timeout_s else 0.0
  in
  let deadline = Clock.Mono.after_s (Clock.Mono.now ()) timeout_s in
  let buf = Bytes.create 256 in
  let bytes_read = ref 0 in
  let read_once () =
    let room = Int.min (Bytes.length buf) (max_bytes - !bytes_read) in
    if room <= 0 then `Stop
    else
      match Unix.read fd buf 0 room with
      | 0 -> `Stop
      | n ->
          bytes_read := !bytes_read + n;
          for i = 0 to n - 1 do
            Probe.feed decoder (Bytes.get buf i)
          done;
          `Continue
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> `Continue
      | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) ->
          `Continue
      | exception Unix.Unix_error _ -> `Stop
  in
  let rec loop () =
    if !bytes_read >= max_bytes then ()
    else
      match Probe.startup_status decoder with
      | Probe.Input_ready | Probe.Replies_ready -> ()
      | Probe.Awaiting_replies ->
          (* Validate fd and drain already-buffered bytes before registering
             with Eio's poll loop (prevents Eio_posix POLLNVAL assertions on
             closed/invalid fds). *)
          (match fd_immediately_readable fd with
           | `Error -> ()
           | `Ready -> (
               match read_once () with
               | `Stop -> ()
               | `Continue -> loop ())
           | `Not_ready ->
               let remaining_s =
                 Clock.Mono.seconds_since deadline ~since:(Clock.Mono.now ())
               in
               if remaining_s <= 0.0 then ()
               else
                 let ready =
                   Eio.Fiber.first
                     (fun () ->
                       match Eio_unix.await_readable fd with
                       | () -> `Readable
                       | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
                       | exception Unix.Unix_error _ -> `Error)
                     (fun () ->
                       Eio.Time.sleep clock remaining_s;
                       `Timeout)
                 in
                 (match ready with
                  | `Timeout | `Error -> ()
                  | `Readable -> (
                      match fd_immediately_readable fd with
                      | `Error -> ()
                      | `Not_ready -> loop ()
                      | `Ready -> (
                          match read_once () with
                          | `Stop -> ()
                          | `Continue -> loop ()))))
  in
  loop ();
  decoder

let apply_probe_observation ~presenter (obs : Probe.observation) =
  Probe.set_current_observation obs;
  (match obs.palette with
   | Some _ as p -> Palette.set_current p
   | None -> ());
  let caps =
    Presenter.apply_probe_observation obs (Presenter.capabilities presenter)
  in
  Presenter.set_capabilities presenter caps

let apply_terminal_reply ~probe_decoder
    (reply : Input_decoder.terminal_reply) =
  let before = Probe.observation probe_decoder in
  (match reply with
   | Input_decoder.Palette_reply { slot; color } ->
       Probe.observe_palette probe_decoder slot color
   | Input_decoder.Cell_pixels_reply { width; height } ->
       Probe.observe_cell_pixels probe_decoder (width, height)
   | Input_decoder.Graphics_reply body -> (
       match Probe.parse_graphics_reply body with
       | Some r -> Probe.observe_graphics probe_decoder r
       | None -> ()));
  let after = Probe.observation probe_decoder in
  if Probe.equal_observation before after then None else Some after

type memory_graphic_state = {
  key : string;
  rect : Rect.t;
  protocol : Graphics.graphics_protocol;
}

let equal_memory_graphic_state a b =
  String.equal a.key b.key
  && Rect.equal a.rect b.rect
  && Graphics.equal_graphics_protocol a.protocol b.protocol

type memory_graphic_step = {
  pre_present_bytes : string;
  invalidate_presenter : bool;
  post_present_bytes : string;
  next_state : memory_graphic_state option;
}

let wrap_tmux ~in_tmux payload =
  if in_tmux then Graphics.tmux_wrapped payload else payload

let teardown_memory_graphic_bytes ~in_tmux = function
  | Some { protocol = Graphics.Kitty_protocol; _ } ->
      wrap_tmux ~in_tmux
        (Graphics.delete_image
           ~image_id:(Graphics.image_id Graphics.Memory_diagram))
  | Some { protocol = Graphics.ITerm2_protocol | Graphics.Unsupported_protocol; _ }
  | None ->
      ""

let composer_popup_open (model : Model.t) =
  match Update_nav.resolve_composer_popup model with
  | Update_nav.Composer_popup_none -> false
  | Update_nav.Composer_popup_slash _ | Update_nav.Composer_popup_mention _ ->
      true

let cached_png_digest_ref : (string * string) option ref = ref None

let cached_png_digest png =
  match !cached_png_digest_ref with
  | Some (prev_png, prev_hex) when prev_png == png -> prev_hex
  | Some _ | None ->
      let hex = Digest.to_hex (Digest.string png) in
      cached_png_digest_ref := Some (png, hex);
      hex

let desired_memory_graphic ~(probe : Probe.observation) ~term_program ~in_tmux
    ~(model : Model.t) =
  if composer_popup_open model || Model.sidebar_drawer_open model then None
  else
  let eff_term_program = if in_tmux then None else term_program in
  let protocol =
    Graphics.protocol_of_probe ~graphics:probe.graphics
      ~term_program:eff_term_program
  in
  match protocol with
  | Graphics.Unsupported_protocol -> None
  | Graphics.Kitty_protocol | Graphics.ITerm2_protocol -> (
      match
        Memory_diagram.active_memory_content_rect model,
        Memory_diagram.active_diagram model
      with
      | Some (keeper, content_rect), Some d
        when Memory_diagram.can_render_png_in_rect ~content_rect d -> (
          match Observed.to_option d.payload with
          | Some
              (Knowledge_store.Diagram_pele_png
                 { png; pixel_size; _ })
            when String.length png > 0 ->
              let rect, _ = Memory_diagram.diagram_body_rect ~content_rect d in
              if
                rect.w >= Memory_diagram.min_graphic_cols
                && rect.h >= Memory_diagram.min_graphic_rows
              then
                let kind_s =
                  match d.kind with
                  | Knowledge_store.Diagram_pele_card -> "card"
                  | Knowledge_store.Diagram_formation_tree -> "tree"
                in
                let fit_cols, fit_rows =
                  match protocol with
                  | Graphics.Kitty_protocol ->
                      Graphics.fit_cells ~cell_pixels:probe.cell_pixels
                        ~image_pixels:pixel_size ~columns:rect.w ~rows:rect.h
                  | Graphics.ITerm2_protocol | Graphics.Unsupported_protocol ->
                      (rect.w, rect.h)
                in
                let key =
                  Printf.sprintf "%s|%s|%s|%dx%d|%s" keeper d.event_identity
                    kind_s fit_cols fit_rows (cached_png_digest png)
                in
                Some ({ key; rect; protocol }, png, pixel_size)
              else None
          | Some (Knowledge_store.Diagram_pele_png _ | Knowledge_store.Diagram_text _)
          | None ->
              None)
      | (Some _ | None), (Some _ | None) -> None)

let plan_memory_graphic_clear ~active ~probe ~term_program ~in_tmux ~model =
  let desired = desired_memory_graphic ~probe ~term_program ~in_tmux ~model in
  match active, desired with
  | None, _ -> ("", false, None)
  | Some prev, Some (next, _, _) when equal_memory_graphic_state prev next ->
      ("", false, active)
  | Some prev, (None | Some _) ->
      let bytes = teardown_memory_graphic_bytes ~in_tmux (Some prev) in
      (bytes, true, None)

let plan_memory_graphic_place ~active ~probe ~term_program ~in_tmux ~model
    ~full_repaint =
  let desired = desired_memory_graphic ~probe ~term_program ~in_tmux ~model in
  match active, desired with
  | _, None -> ("", None)
  | Some prev, Some (next, _, _)
    when equal_memory_graphic_state prev next && not full_repaint ->
      ("", active)
  | (None | Some _), Some (next, png, pixel_size) ->
      let payload =
        match next.protocol with
        | Graphics.Kitty_protocol ->
            let cols, rows =
              Graphics.fit_cells ~cell_pixels:probe.cell_pixels
                ~image_pixels:pixel_size ~columns:next.rect.w ~rows:next.rect.h
            in
            wrap_tmux ~in_tmux
              (Graphics.replace_png
                 ~image_id:(Graphics.image_id Graphics.Memory_diagram)
                 ~placement_id:1 ~data:png ~rows ~cols ~crop:None)
        | Graphics.ITerm2_protocol ->
            wrap_tmux ~in_tmux
              (Graphics.iterm2_place ~data:png
                 { Graphics.columns = next.rect.w; rows = next.rect.h })
        | Graphics.Unsupported_protocol -> ""
      in
      if String.equal payload "" then ("", None)
      else
        let bytes =
          Printf.sprintf "\x1b7\x1b[%d;%dH%s\x1b8" (next.rect.y + 1)
            (next.rect.x + 1) payload
        in
        (bytes, Some next)

let step_memory_graphic ~active ~probe ~term_program ~in_tmux ~model
    ~full_repaint =
  let pre_present_bytes, invalidate_presenter, after_clear =
    plan_memory_graphic_clear ~active ~probe ~term_program ~in_tmux ~model
  in
  let post_present_bytes, next_state =
    plan_memory_graphic_place ~active:after_clear ~probe ~term_program ~in_tmux
      ~model ~full_repaint:(full_repaint || invalidate_presenter)
  in
  {
    pre_present_bytes;
    invalidate_presenter;
    post_present_bytes;
    next_state;
  }

let local_tz_offset_sec ?(at = Unix.time ()) () =
  let lt = Unix.localtime at in
  let gt = Unix.gmtime at in
  let day_diff =
    if lt.Unix.tm_year <> gt.Unix.tm_year then
      if lt.Unix.tm_year > gt.Unix.tm_year then 1 else -1
    else if lt.Unix.tm_yday <> gt.Unix.tm_yday then
      if lt.Unix.tm_yday > gt.Unix.tm_yday then 1 else -1
    else 0
  in
  let lt_sec = (lt.Unix.tm_hour * 3600) + (lt.Unix.tm_min * 60) + lt.Unix.tm_sec in
  let gt_sec = (gt.Unix.tm_hour * 3600) + (gt.Unix.tm_min * 60) + gt.Unix.tm_sec in
  (day_diff * 86400) + (lt_sec - gt_sec)

let with_sigpipe_ignored fn =
  let prev_sigpipe =
    match Sys.signal Sys.sigpipe Sys.Signal_ignore with
    | prev -> Some prev
    | exception Invalid_argument _ -> None
  in
  Fun.protect
    ~finally:(fun () ->
      match prev_sigpipe with
      | Some prev -> (
          match Sys.set_signal Sys.sigpipe prev with
          | () -> ()
          | exception Invalid_argument _ -> ())
      | None -> ())
    fn

let write_exit_line_fd fd reason =
  let payload = Exit_reason.wire_line reason ^ "\n" in
  with_sigpipe_ignored (fun () ->
      ignore
        (Terminal_out.write_all_fd ~stall_limit_s:0.5 fd payload
          : (unit, Unix.error) result))

let safe_close_fd fd =
  match Unix.close fd with
  | () -> ()
  | exception Unix.Unix_error _ -> ()

let redirect_stderr_off_terminal ~base_path =
  flush stderr;
  let orig_stderr =
    match Unix.dup ~cloexec:true Unix.stderr with
    | fd -> Some fd
    | exception Unix.Unix_error _ -> None
  in
  match
    let dir =
      Filename.concat (Common.masc_dir_from_base_path ~base_path) "logs"
    in
    let path =
      Filename.concat dir (Printf.sprintf "masc-tui-%d.log" (Unix.getpid ()))
    in
    Fs_compat.mkdir_p dir;
    let fd =
      Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND ] 0o644
    in
    Fun.protect
      ~finally:(fun () -> safe_close_fd fd)
      (fun () ->
        Unix.set_close_on_exec fd;
        Unix.dup2 fd Unix.stderr)
  with
  | () -> orig_stderr
  | exception (Unix.Unix_error _ | Sys_error _) ->
      (match orig_stderr with Some fd -> safe_close_fd fd | None -> ());
      output_string stderr
        "[masc-tui] could not redirect stderr off terminal; log lines may appear on screen\n";
      flush stderr;
      None

let measure_terminal_size ~fallback:(fb_cols, fb_rows) =
  match Terminal_size.get () with
  | Some (rows, cols) when rows > 0 && cols > 0 -> (cols, rows)
  | Some _ | None -> (fb_cols, fb_rows)

let detect_capabilities () : Presenter.capabilities =
  let level = Palette.stdout_color_level () in
  let color_depth = Palette.color_depth_of_level level in
  {
    Presenter.default_capabilities with
    synchronized_output = true;
    color_depth;
    kitty_keyboard = true;
    osc8_hyperlinks = true;
    osc52_clipboard = true;
  }

let msg_pace = function
  | Msg.Key_event _ | Msg.Paste_text _ | Msg.Mouse_event _ | Msg.Resize _
  | Msg.Chat_stream_chunk _ | Msg.Chat_stream_done _
  | Msg.Memory_diagram_rendered _ ->
      Frame_scheduler.Pace_interactive
  | Msg.Boot | Msg.Tick _ | Msg.Server_health_result _
  | Msg.Server_start_result _ | Msg.Http_reply _ | Msg.Sse_event _
  | Msg.Sse_freshness _ | Msg.Chat_stream_decode_warning _
  | Msg.Voice_event _ | Msg.Stream_gap _ | Msg.Github_login_chunk _
  | Msg.Github_login_done _ | Msg.Setup_login_output _
  | Msg.Setup_login_input_ready _ ->
      Frame_scheduler.Pace_animation

let earliest_opt a b =
  match a, b with
  | None, x | x, None -> x
  | Some x, Some y -> Some (if Int64.compare x y <= 0 then x else y)

let is_ctrl_c (ev : Input_decoder.key_event) =
  ev.mods.ctrl
  && (not ev.mods.alt)
  && (not ev.mods.shift)
  &&
  match ev.key with
  | Input_decoder.Char ("c" | "C") -> true
  | Input_decoder.Char _
  | Input_decoder.Enter
  | Input_decoder.Tab
  | Input_decoder.Backspace
  | Input_decoder.Escape
  | Input_decoder.Delete
  | Input_decoder.Insert
  | Input_decoder.Up
  | Input_decoder.Down
  | Input_decoder.Left
  | Input_decoder.Right
  | Input_decoder.Home
  | Input_decoder.End
  | Input_decoder.Page_up
  | Input_decoder.Page_down
  | Input_decoder.Function _ ->
      false

let default_mouse_capture = false

let mouse_capture_seq enabled =
  if enabled then "\x1b[?1000h\x1b[?1002h\x1b[?1006h"
  else "\x1b[?1000l\x1b[?1002l\x1b[?1006l"

let is_mouse_toggle_key (kev : Input_decoder.key_event) =
  (not kev.mods.ctrl) && (not kev.mods.alt) && (not kev.mods.shift)
  &&
  match kev.key with
  | Input_decoder.Char "m" -> true
  | Input_decoder.Char s when String.length s > 1 -> (
      match Input_decoder.Ime.single_latin_key s with
      | Some "m" -> true
      | Some _ | None -> false)
  | Input_decoder.Char _
  | Input_decoder.Enter
  | Input_decoder.Tab
  | Input_decoder.Backspace
  | Input_decoder.Escape
  | Input_decoder.Delete
  | Input_decoder.Insert
  | Input_decoder.Up
  | Input_decoder.Down
  | Input_decoder.Left
  | Input_decoder.Right
  | Input_decoder.Home
  | Input_decoder.End
  | Input_decoder.Page_up
  | Input_decoder.Page_down
  | Input_decoder.Function _ ->
      false

let is_korean_jamo_mouse_key (kev : Input_decoder.key_event) =
  match kev.key with
  | Input_decoder.Char s -> String.length s > 1
  | Input_decoder.Enter
  | Input_decoder.Tab
  | Input_decoder.Backspace
  | Input_decoder.Escape
  | Input_decoder.Delete
  | Input_decoder.Insert
  | Input_decoder.Up
  | Input_decoder.Down
  | Input_decoder.Left
  | Input_decoder.Right
  | Input_decoder.Home
  | Input_decoder.End
  | Input_decoder.Page_up
  | Input_decoder.Page_down
  | Input_decoder.Function _ ->
      false

let should_toggle_mouse_capture (m : Model.t) (kev : Input_decoder.key_event) =
  let on_knowledge_memory =
    Option.is_none (Model.active_inspector m)
    && Nav.equal_workspace m.nav.workspace Nav.Knowledge
    && Nav.equal_knowledge_tab m.knowledge.active_tab Nav.Knowledge_memory
  in
  let korean_in_keeper_chat =
    is_korean_jamo_mouse_key kev && Model.is_in_keeper_chat m
  in
  is_mouse_toggle_key kev
  && (not (Model.is_too_small_viewport m.viewport))
  && (not (Model.equal_breakpoint m.breakpoint Model.Micro))
  && Option.is_none m.nav.overlay
  && (not (Model.sidebar_has_focus m))
  && (not (Model.is_text_capture_active m))
  && (not on_knowledge_memory)
  && not korean_in_keeper_chat

let armed_expiry_deadline_ns (m : Model.t) : int64 option =
  let stop_dl =
    Option.map
      (fun (_, armed_at) ->
        Clock.Mono.to_ns
          (Clock.Mono.after_s armed_at Model.keeper_stop_arm_window_s))
      m.keeper_stop_armed
  in
  let quit_dl =
    Option.map
      (fun armed_at ->
        Clock.Mono.to_ns (Clock.Mono.after_s armed_at Model.quit_arm_window_s))
      m.quit_armed_at
  in
  earliest_opt stop_dl quit_dl

let should_emit_tick ~oauth_poll_deadline_ns ~now_ns ~last_voice_tick_ns
    ~toast_expires_ns ~arm_expires_ns ~voice_recording =
  let toast_expired =
    match toast_expires_ns with
    | Some exp -> Int64.compare now_ns exp >= 0
    | None -> false
  in
  let toast_deadline =
    match toast_expires_ns with
    | Some exp when Int64.compare now_ns exp < 0 -> Some exp
    | Some _ | None -> None
  in
  let arm_expired =
    match arm_expires_ns with
    | Some exp -> Int64.compare now_ns exp >= 0
    | None -> false
  in
  let arm_deadline =
    match arm_expires_ns with
    | Some exp when Int64.compare now_ns exp < 0 -> Some exp
    | Some _ | None -> None
  in
  let voice_due, voice_deadline =
    if not voice_recording then (false, None)
    else
      let next_due = Int64.add last_voice_tick_ns voice_tick_interval_ns in
      if Int64.compare now_ns next_due >= 0 then
        (true, Some (Int64.add now_ns voice_tick_interval_ns))
      else (false, Some next_due)
  in
  let oauth_due =
    match oauth_poll_deadline_ns with
    | Some due -> Int64.compare now_ns due >= 0
    | None -> false
  in
  let oauth_deadline =
    match oauth_poll_deadline_ns with
    | Some due when Int64.compare now_ns due < 0 -> Some due
    | Some _ | None -> None
  in
  ( toast_expired || arm_expired || voice_due || oauth_due
  , earliest_opt
      (earliest_opt (earliest_opt toast_deadline arm_deadline) voice_deadline)
      oauth_deadline )

let clock_minute_of_unix wall_unix =
  if (not (Float.is_finite wall_unix)) || wall_unix <= 0.0 then 0L
  else Int64.div (Int64.of_float (Float.floor wall_unix)) 60L

let next_minute_tick ~now_ns ~wall_unix ~last_minute =
  let cur_min = clock_minute_of_unix wall_unix in
  let minute_due = Int64.compare cur_min last_minute > 0 in
  let wait_s =
    if (not (Float.is_finite wall_unix)) || wall_unix <= 0.0 then 60.0
    else
      let min_start = Int64.to_float (Int64.mul cur_min 60L) in
      let elapsed_in_min = Float.max 0.0 (Float.min 60.0 (wall_unix -. min_start)) in
      (* Wake 50 ms after the exact :00 boundary so gettimeofday is cleanly in
         the new minute with zero sub-minute wakeups (0 Hz between minutes). *)
      Float.max 0.05 (60.05 -. elapsed_in_min)
  in
  let next_deadline_ns =
    Int64.add now_ns (Int64.of_float (wait_s *. 1_000_000_000.0))
  in
  (minute_due, cur_min, next_deadline_ns)

let progress_refresh_interval m =
  if Chat_transcript.reduce_motion m then progress_elapsed_interval_ns
  else progress_animation_interval_ns

let visible_harness_or_keeper_progress_interval (m : Model.t) =
  if Model.is_too_small_viewport m.viewport || Model.equal_breakpoint m.breakpoint Model.Micro
  then None
  else if
    (match m.nav.overlay, m.inline_modal with
    | Some (Nav.Inline_action (Nav.Keeper_operator_note_form _)), Some modal ->
        modal.submitting || Option.is_some modal.note_prefill_id
    | _ -> false) [@warning "-4"]
  then
    if Chat_transcript.reduce_motion m then None else Some progress_animation_interval_ns
  else
    let harness_reading =
      Option.is_none m.nav.overlay
      && Option.is_none (Model.active_inspector m)
      && Nav.equal_workspace m.nav.workspace Nav.Work
      && Nav.equal_work_tab m.work.active_tab Nav.Work_harness
      && Observed.is_loading m.work.harness_read
    in
    let keeper =
      if Option.equal Nav.equal_overlay m.nav.overlay
          (Some (Nav.Queue_context Nav.Drawer_queue)) then Model.target_keeper m
      else if Option.is_some m.nav.overlay then None
      else
        match Model.active_inspector m with
        | None ->
            if Nav.equal_workspace m.nav.workspace Nav.Keepers
               && Nav.equal_keeper_tab m.fleet.keeper_dive_tab Nav.Keeper_chat
               && (m.nav.zoomed || Model.uses_keeper_split ~width:m.viewport.cols m)
            then Model.selected_keeper_name m
            else None
        | Some _ -> None
    in
    (* Only a glyph with an animation frame needs a presentation clock. *)
    let keeper_working =
      (match Option.bind keeper (fun keeper ->
            Chat_transcript.live_chat_phase_badge ~model:m ~keeper) with
      | Some (Glyph.Live_working_frame _, _, _) -> true
      | Some _ | None -> false) [@warning "-4"]
    in
    if harness_reading || keeper_working then Some (progress_refresh_interval m)
    else None

let visible_progress_interval (m : Model.t) =
  if
    Nav.equal_workspace m.nav.workspace Nav.Infra
    && Option.is_none m.nav.overlay
    && Option.is_none (Model.active_inspector m)
    && (not (Model.is_too_small_viewport m.viewport))
    && (not (Model.equal_breakpoint m.breakpoint Model.Micro))
    && Nav.equal_infra_tab m.infra.active_tab Nav.Infra_code
    && Infra_store.equal_code_right_mode m.infra.code.right_mode Infra_store.Code_file
    && Observed.is_loading m.infra.code.open_file
  then Some (progress_refresh_interval m)
  else visible_harness_or_keeper_progress_interval m

let set_fd_nonblock fd enabled =
  match
    if enabled then Unix.set_nonblock fd
    else Unix.clear_nonblock fd
  with
  | () -> ()
  | exception Unix.Unix_error _ -> ()

type input_reader_handle = {
  stop_u : unit Eio.Promise.u;
  stopped : unit Eio.Promise.t;
}

let dispatch_decoded_events ~signals ~bell ~input_queue ?on_reply events =
  let pushed = ref false in
  List.iter
    (function
      | Input_decoder.Key kev when is_ctrl_c kev ->
          Signals.record_interrupt signals;
          Wake_bell.ring bell Wake_bell.Interrupt
      | Input_decoder.Key kev ->
          Signals.withdraw_interrupt signals;
          Eio.Stream.add input_queue (Msg.Key_event kev);
          pushed := true
      | Input_decoder.Paste { text; _ } ->
          Signals.withdraw_interrupt signals;
          Eio.Stream.add input_queue (Msg.Paste_text text);
          pushed := true
      | Input_decoder.Mouse mev ->
          Signals.withdraw_interrupt signals;
          Eio.Stream.add input_queue (Msg.Mouse_event mev);
          pushed := true
      | Input_decoder.Reply reply ->
          Option.iter (fun f -> f reply) on_reply
      | Input_decoder.Unknown_escape
      | Input_decoder.Invalid_utf8 ->
          ())
    events;
  if !pushed then Wake_bell.ring bell Wake_bell.Ui_bus

let start_input_reader ~sw ~clock ?(fd = Unix.stdin) ~signals ~bell ~input_queue
    ?probe_decoder ?(probe_grace_s = probe_grace_s) ?on_observation () =
  Eio.Switch.check sw;
  let stop_p, stop_u = Eio.Promise.create () in
  let stopped, mark_stopped = Eio.Promise.create () in
  let finish () = ignore (Eio.Promise.try_resolve mark_stopped () : bool) in
  let grace_s =
    if Float.is_finite probe_grace_s && probe_grace_s > 0.0 then probe_grace_s
    else 0.0
  in
  let grace_deadline = Clock.Mono.after_s (Clock.Mono.now ()) grace_s in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Fun.protect ~finally:finish (fun () ->
          let decoder = ref (Input_decoder.create ()) in
          let buf = Bytes.create 256 in
          let last_obs =
            ref
              (match probe_decoder with
               | Some pd -> Probe.observation pd
               | None -> Probe.empty_observation)
          in
          let publish_if_changed () =
            match probe_decoder with
            | None -> ()
            | Some pd ->
                let cur = Probe.observation pd in
                if not (Probe.equal_observation !last_obs cur) then begin
                  last_obs := cur;
                  Option.iter (fun f -> f cur) on_observation
                end
          in
          let on_reply reply =
            match probe_decoder with
            | None -> ()
            | Some pd -> (
                match apply_terminal_reply ~probe_decoder:pd reply with
                | Some obs ->
                    last_obs := obs;
                    Option.iter (fun f -> f obs) on_observation
                | None -> ())
          in
          let emit_events =
            dispatch_decoded_events ~signals ~bell ~input_queue ~on_reply
          in
          let drain_probe_replay () =
            match probe_decoder with
            | None -> ()
            | Some pd ->
                let rec drain () =
                  if Probe.has_replay pd then
                    match Probe.next pd ~next_raw:(fun () -> None) with
                    | Some ch ->
                        emit_events (Input_decoder.feed !decoder ch);
                        drain ()
                    | None -> ()
                in
                drain ()
          in
          let recover_step work =
            match work () with
            | () -> ()
            | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
            | exception ex ->
                ignore ex;
                decoder := Input_decoder.create ();
                (match probe_decoder with
                 | Some pd -> Probe.discard_incomplete_sequence pd
                 | None -> ())
          in
          let maybe_expire_probe () =
            match probe_decoder with
            | Some pd
              when (not (Probe.complete pd))
                   && Clock.Mono.compare (Clock.Mono.now ()) grace_deadline >= 0
              ->
                recover_step (fun () ->
                    ignore (Probe.finish pd : Probe.result);
                    drain_probe_replay ();
                    publish_if_changed ())
            | Some _ | None -> ()
          in
          let probe_active () =
            maybe_expire_probe ();
            match probe_decoder with
            | None -> false
            | Some pd ->
                (not (Probe.complete pd))
                || Probe.has_replay pd
                || Option.is_some (Probe.pending pd)
          in
          (* Replay any early user keystrokes buffered during startup probe
             immediately before sleeping on stdin. *)
          recover_step drain_probe_replay;
          let rec loop () =
            Eio.Switch.check sw;
            if Eio.Promise.is_resolved stop_p then `Stop_daemon
            else
              let active_probe = probe_active () in
              let pending_state =
                match probe_decoder with
                | Some pd when active_probe -> (
                    match Probe.pending pd with
                    | Some _ as p -> p
                    | None -> Input_decoder.pending !decoder)
                | Some _ | None -> Input_decoder.pending !decoder
              in
              let timer_opt =
                let pending_timeout =
                  Option.map Input_decoder.idle_timeout_s pending_state
                in
                let probe_timeout =
                  match probe_decoder with
                  | Some pd when active_probe && not (Probe.complete pd) ->
                      let rem =
                        Clock.Mono.seconds_since grace_deadline
                          ~since:(Clock.Mono.now ())
                      in
                      Some (Float.max 0.001 rem)
                  | Some _ | None -> None
                in
                match pending_timeout, probe_timeout with
                | None, None -> None
                | Some a, None -> Some (`Idle_flush, a)
                | None, Some b -> Some (`Probe_expire, b)
                | Some a, Some b ->
                    if b < a then Some (`Probe_expire, b)
                    else Some (`Idle_flush, a)
              in
              let wait_result =
                match timer_opt with
                | None ->
                    Eio.Fiber.first
                      (fun () ->
                        match Eio_unix.await_readable fd with
                        | () -> `Readable
                        | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
                        | exception Unix.Unix_error (Unix.EINTR, _, _) ->
                            `Retry
                        | exception Unix.Unix_error _ -> `Error)
                      (fun () ->
                        Eio.Promise.await stop_p;
                        `Stop)
                | Some (timer_tag, timeout_s) ->
                    Eio.Fiber.first
                      (fun () ->
                        match Eio_unix.await_readable fd with
                        | () -> `Readable
                        | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
                        | exception Unix.Unix_error (Unix.EINTR, _, _) ->
                            `Retry
                        | exception Unix.Unix_error _ -> `Error)
                      (fun () ->
                        Eio.Fiber.first
                          (fun () ->
                            Eio.Time.sleep clock timeout_s;
                            timer_tag)
                          (fun () ->
                            Eio.Promise.await stop_p;
                            `Stop))
              in
              match wait_result with
              | `Stop -> `Stop_daemon
              | `Retry -> loop ()
              | `Error ->
                  Signals.record_terminate signals ~signal:"STDIN_ERROR";
                  `Stop_daemon
              | `Probe_expire ->
                  maybe_expire_probe ();
                  loop ()
              | `Idle_flush ->
                  recover_step (fun () ->
                      let probe_was_pending =
                        match probe_decoder with
                        | Some pd -> Option.is_some (Probe.pending pd)
                        | None -> false
                      in
                      let decoder_was_pending =
                        Option.is_some (Input_decoder.pending !decoder)
                      in
                      let was_active = probe_active () in
                      (match probe_decoder with
                       | Some pd when was_active ->
                           if Probe.holds_incomplete_sequence pd then
                             Probe.discard_incomplete_sequence pd
                           else if Option.is_some (Probe.pending pd) then
                             (match Probe.next pd ~next_raw:(fun () -> None) with
                              | Some ch ->
                                  emit_events (Input_decoder.feed !decoder ch)
                              | None -> ());
                           drain_probe_replay ();
                           publish_if_changed ()
                       | Some _ | None -> ());
                      if probe_was_pending || decoder_was_pending then
                        emit_events (Input_decoder.idle !decoder));
                  loop ()
              | `Readable -> (
                  match Unix.read fd buf 0 256 with
                  | 0 ->
                      Signals.record_terminate signals ~signal:"EOF";
                      `Stop_daemon
                  | n ->
                      recover_step (fun () ->
                          match probe_decoder with
                          | Some pd when probe_active () ->
                              for i = 0 to n - 1 do
                                Probe.feed pd (Bytes.get buf i)
                              done;
                              drain_probe_replay ();
                              publish_if_changed ()
                          | Some _ | None ->
                              let chunk = Bytes.sub_string buf 0 n in
                              emit_events
                                (Input_decoder.feed_string !decoder chunk));
                      loop ()
                  | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
                  | exception
                      Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) ->
                      loop ()
                  | exception Unix.Unix_error _ ->
                      Signals.record_terminate signals ~signal:"STDIN_ERROR";
                      `Stop_daemon)
          in
          loop ()));
  { stop_u; stopped }

let stop_input_reader handle =
  ignore (Eio.Promise.try_resolve handle.stop_u () : bool);
  Eio.Promise.await handle.stopped

let can_launch_pending_wiki_editor (m : Model.t) =
  (not (Model.is_too_small_viewport m.viewport))
  && (not (Model.equal_breakpoint m.breakpoint Model.Micro))
  && Option.is_none m.nav.overlay
  && (not (Model.is_text_capture_active m))
  &&
  match Model.active_inspector m with
  | Some _ -> false
  | None ->
      Nav.equal_workspace m.nav.workspace Nav.Knowledge
      && (match m.knowledge.active_tab with
          | Nav.Knowledge_wiki -> true
          | Nav.Knowledge_board
          | Nav.Knowledge_artifacts
          | Nav.Knowledge_memory ->
              false)

let run ~(cli : Cli_args.config) ~(render_frame : render_frame) () =
  match Cli_args.check_tty () with
  | Cli_args.Non_tty { reason; exit_code } ->
      output_string stderr (reason ^ "\n");
      flush stderr;
      exit_code
  | Cli_args.Tty_ok ->
      Domains.use_ui_heap ();
      let orig_stderr = ref (redirect_stderr_off_terminal ~base_path:cli.base_path) in
      let close_orig_stderr () =
        match !orig_stderr with
        | None -> ()
        | Some fd ->
            orig_stderr := None;
            safe_close_fd fd
      in
      let exit_reason = ref Exit_reason.Unrecorded in
      let restart_requested = ref false in
      let exit_code =
        Fun.protect ~finally:close_orig_stderr (fun () ->
        Eio_main.run @@ fun env ->
        Eio.Switch.run @@ fun sw ->
        Eio_guard.enable ();
        Eio.Switch.on_release sw Eio_guard.disable;
        Fs_compat.set_fs (Eio.Stdenv.fs env);

        (* LIFO release registration order:
           1. Exit-line writer (runs LAST after terminal & signal teardown)
           2. Wake_bell signal pipe & Signals handlers
           3. Termios raw mode restoration
           4. Terminal_out alt-screen / Kitty CSI u leave & stdout drain
           5. Cmd_executor / Sse_hub / Voice_runner / Io_domain / Worker_pool *)
        Eio.Switch.on_release sw (fun () ->
            with_sigpipe_ignored (fun () ->
                let reason = !exit_reason in
                let line = Exit_reason.wire_line reason in
                (match
                   output_string stderr (line ^ "\n");
                   flush stderr
                 with
                 | () -> ()
                 | exception Sys_error _ -> ());
                match !orig_stderr with
                | None -> ()
                | Some fd ->
                    write_exit_line_fd fd reason;
                    if !restart_requested then (
                      match Unix.dup2 fd Unix.stderr with
                      | () -> ()
                      | exception Unix.Unix_error _ -> ());
                    orig_stderr := None;
                    safe_close_fd fd));

        let bell = Wake_bell.create () in
        Wake_bell.attach_signal_pipe ~sw bell;
        let signals = Signals.create ~bell in
        Signals.install ~sw signals;

        let raw_session : Termios.raw_session option ref = ref None in
        let enter_raw () =
          (match Termios.enter_raw_mode Unix.stdin with
          | Ok s -> raw_session := Some s
          | Error _ -> ());
          set_fd_nonblock Unix.stdin true;
          set_fd_nonblock Unix.stdout true
        in
        let restore_raw () =
          set_fd_nonblock Unix.stdin false;
          set_fd_nonblock Unix.stdout false;
          match !raw_session with
          | None -> ()
          | Some s ->
              raw_session := None;
              ignore (Termios.restore_raw_mode s : Termios.restore_outcome)
        in
        enter_raw ();
        Eio.Switch.on_release sw restore_raw;

        let caps = detect_capabilities () in
        let in_tmux =
          match Sys.getenv_opt "TMUX" with
          | Some s -> not (String.equal (String.trim s) "")
          | None -> false
        in
        let keyboard =
          if in_tmux then Terminal_out.Xterm
          else if caps.kitty_keyboard then Terminal_out.Kitty
          else Terminal_out.Legacy
        in
        (* Keep mouse tracking OFF by default so native terminal drag-select and
           copy ALWAYS work cleanly; operator may opt in/out at runtime via [m]. *)
        let mouse_capture = ref default_mouse_capture in
        let set_mouse_capture enabled =
          mouse_capture := enabled;
          Terminal_out.write (mouse_capture_seq enabled);
          Terminal_out.flush ()
        in
        let write_enter_screen () =
          Terminal_out.write
            (Terminal_out.enter_screen_seq ~keyboard ~mouse:false
               ~bracketed_paste:true);
          if !mouse_capture then
            Terminal_out.write (mouse_capture_seq true);
          Terminal_out.flush ()
        in
        Terminal_out.set_on_write_lost (fun () ->
            Wake_bell.ring bell Wake_bell.Ui_bus);
        Eio.Switch.on_release sw (fun () ->
            Terminal_out.set_on_write_lost (fun () -> ()));
        write_enter_screen ();
        Terminal_out.install_switch_teardown ~sw ~keyboard ();

        let term_program =
          Graphics.effective_term_program ~getenv:Sys.getenv_opt
        in
        let active_memory_graphic : memory_graphic_state option ref = ref None in
        let clear_active_memory_graphic () =
          let bytes =
            teardown_memory_graphic_bytes ~in_tmux !active_memory_graphic
          in
          active_memory_graphic := None;
          if not (String.equal bytes "") then begin
            Terminal_out.write bytes;
            Terminal_out.flush ()
          end
        in
        Eio.Switch.on_release sw clear_active_memory_graphic;
        let document_graphics = Document_graphics.create () in
        let clear_document_graphic () =
          Document_graphics.cancel_pending document_graphics;
          let bytes = Document_graphics.clear document_graphics ~in_tmux in
          if not (String.equal bytes "") then begin
            Terminal_out.write bytes;
            Terminal_out.flush ()
          end
        in
        Eio.Switch.on_release sw clear_document_graphic;

        let clock = Eio.Stdenv.clock env in
        (* Bounded startup terminal probe (CSI 16t cell pixels, optional
           OSC 10/11/4 palette, Kitty APC G graphics). Early user keystrokes
           stay in [probe_decoder]'s replay buffer and are drained immediately
           by [start_input_reader]. *)
        let palette_requested =
          palette_requested_of_env ~getenv:Sys.getenv_opt
        in
        Terminal_out.write (Probe.query ~palette:palette_requested);
        Terminal_out.flush ();
        let probe_decoder =
          collect_startup_probe ~clock ~fd:Unix.stdin ~palette_requested ()
        in
        let initial_obs = Probe.observation probe_decoder in
        let pending_probe_obs = Atomic.make initial_obs in
        let applied_probe_obs = ref initial_obs in
        let on_probe_observation (obs : Probe.observation) =
          Probe.set_current_observation obs;
          (match obs.palette with
           | Some _ as p -> Palette.set_current p
           | None -> ());
          Atomic.set pending_probe_obs obs;
          Wake_bell.ring bell Wake_bell.Ui_bus
        in

        (* Inner cancellable work switch: keeps terminal/raw-mode teardown on
           the outer [sw] strictly isolated from non-daemon HTTP/stream/voice
           fibers. On normal exit, restart, or ANY uncaught UI-loop exception,
           failing [work_sw] cancels in-flight fibers immediately instead of
           blocking root [Switch.run] in [await_idle] while raw mode stays on. *)
        let module Work_exit = struct
          exception Shutdown
        end in
        let exit_code_ref = ref 1 in
        (try
           Eio.Switch.run @@ fun work_sw ->
           let io = Io_domain.start ~sw:work_sw ~env in
           let worker = Worker_pool.create ~sw:work_sw (Eio.Stdenv.domain_mgr env) in

           let init_cols, init_rows = measure_terminal_size ~fallback:(80, 24) in
           let init_wall_unix = Unix.gettimeofday () in
           let tz_offset_sec = local_tz_offset_sec ~at:init_wall_unix () in
           let theme_warnings =
             Theme_file.load_overrides ~base_path:cli.base_path ~themes_dir:cli.themes_dir
           in
           List.iter
             (fun warning ->
               output_string stderr ("[masc-tui] theme: " ^ warning ^ "\n"))
             theme_warnings;
           flush stderr;
           let model =
             let initial =
               Model.initial ~cols:init_cols ~rows:init_rows ~lang:cli.lang
                 ~theme_preset:cli.theme ~cli_lang_override:cli.lang_explicit
                 ~cli_theme_override:cli.theme_explicit ~tz_offset_sec
                 ~wall_unix:init_wall_unix ~tui_version:Build_version.current
                 ~tui_commit:Build_commit_generated.commit ()
             in
             let initial =
               match theme_warnings with
               | [] -> initial
               | _ :: _ ->
                   let notice =
                     Say.make
                       ~ko:
                         (Printf.sprintf
                            "테마 파일 %d개를 확인하세요. 잘못된 파일은 내장 색으로 표시됩니다 (로그 확인)"
                            (List.length theme_warnings))
                       ~en:
                         (Printf.sprintf
                            "Check %d theme file(s); invalid files fall back to built-in colors (see log)"
                            (List.length theme_warnings))
                   in
                   Model.with_toast ~now:(Clock.Mono.now ())
                     ~level:Model.Toast_warning notice initial
             in
             ref initial
           in
           let presenter =
             Presenter.create ~cols:init_cols ~rows:init_rows ~capabilities:caps
           in
           apply_probe_observation ~presenter initial_obs;
           let card_cache = Card.Cache.create () in
           let scheduler = ref (Frame_scheduler.create ()) in

           let input_queue : Msg.t Eio.Stream.t = Eio.Stream.create max_int in
           let input_handle : input_reader_handle option ref =
             ref
               (Some
                  (start_input_reader ~sw:work_sw ~clock ~signals ~bell ~input_queue
                     ~probe_decoder ~on_observation:on_probe_observation ()))
           in

           let should_quit = ref false in
           let on_quit reason =
             exit_reason := reason;
             should_quit := true;
             Wake_bell.ring bell Wake_bell.Terminate
           in
           let on_restart () =
             restart_requested := true;
             exit_reason := Exit_reason.Quit_key;
             should_quit := true;
             Wake_bell.ring bell Wake_bell.Terminate
           in

           let editor_handoff : Cmd_executor.editor_handoff =
             {
               pause_terminal =
                 (fun () ->
                   clear_active_memory_graphic ();
                   clear_document_graphic ();
                   (match !input_handle with
                   | Some h ->
                       input_handle := None;
                       stop_input_reader h
                   | None -> ());
                   Terminal_out.write (Terminal_out.leave_screen_seq ~keyboard);
                   ignore
                     (Terminal_out.drain ~within_s:Terminal_out.handoff_limit_s
                       : Terminal_out.drained);
                   restore_raw ();
                   Signals.suspend_sigtstp_guard signals);
               resume_terminal =
                 (fun () ->
                   Signals.clear_interrupts signals;
                   Signals.resume_sigtstp_guard signals;
                   enter_raw ();
                   write_enter_screen ();
                   Presenter.invalidate presenter;
                   Card.Cache.clear card_cache;
                   input_handle :=
                     Some
                       (start_input_reader ~sw:work_sw ~clock ~signals ~bell ~input_queue
                          ~probe_decoder ~on_observation:on_probe_observation ());
                   scheduler :=
                     Frame_scheduler.mark_dirty
                       ~pace:Frame_scheduler.Pace_interactive !scheduler;
                   (* Trigger the main loop's resize path so any terminal geometry
                      change during $EDITOR runs through Update.step and executes
                      all resulting commands without dropping them. *)
                   Signals.record_resize signals;
                   Wake_bell.ring bell Wake_bell.Resize);
             }
           in

           let bus =
             Cmd_executor.create_bus
               ~on_wake:(fun () -> Wake_bell.ring bell Wake_bell.Ui_bus)
               ()
           in
           let executor =
             Cmd_executor.create ~sw:work_sw ~io ~worker ~clock ~cli ~bus ~editor_handoff
               ~on_editor_ready:(fun () -> Wake_bell.ring bell Wake_bell.Ui_bus)
               ~on_quit ~on_restart ()
           in
           Eio.Switch.on_release work_sw (fun () ->
               Cmd_executor.shutdown ~preserve_owned_server:!restart_requested
                 executor);

        let presented_run_next = ref None in
        let pending_run_next = ref [] in
        let same_queue_action (a : Update_nav.queue_run_next) (b : Update_nav.queue_run_next) =
          String.equal a.keeper b.keeper
          && String.equal a.request_id b.request_id
          && String.equal a.body b.body
          && Option.equal String.equal a.interrupt_token b.interrupt_token
        in
        let is_pending epoch keeper request_id (pending_epoch, pending_keeper, pending_id) =
          Epoch.equal epoch pending_epoch && String.equal keeper pending_keeper
          && String.equal request_id pending_id
        in
        let apply_msg ~now msg =
          (* This receipt releases only the request that reserved the key. *)
          ((match msg with
            | Msg.Http_reply { epoch; reply = Msg.Reply_keeper_run_next { keeper; request_id; _ } } ->
                pending_run_next :=
                  List.filter (fun pending -> not (is_pending epoch keeper request_id pending))
                    !pending_run_next
            | _ -> ()) [@warning "-4"]);
          let toggle_mouse =
            match msg with
            | Msg.Key_event kev -> should_toggle_mouse_capture !model kev
            | Msg.Boot
            | Msg.Paste_text _
            | Msg.Mouse_event _
            | Msg.Resize _
            | Msg.Tick _
            | Msg.Server_health_result _
            | Msg.Server_start_result _
            | Msg.Http_reply _
            | Msg.Sse_event _
            | Msg.Sse_freshness _
            | Msg.Chat_stream_chunk _
            | Msg.Chat_stream_done _
            | Msg.Chat_stream_decode_warning _
            | Msg.Memory_diagram_rendered _
            | Msg.Voice_event _
            | Msg.Stream_gap _
            | Msg.Github_login_chunk _
            | Msg.Github_login_done _
            | Msg.Setup_login_output _
            | Msg.Setup_login_input_ready _ ->
                false
          in
          if toggle_mouse then begin
            let next_enabled = not !mouse_capture in
            set_mouse_capture next_enabled;
            let notice =
              if next_enabled then
                Say.make
                  ~ko:"마우스 모드 켜짐 (드래그해 선택하면 복사, [m]으로 네이티브 선택 복귀)"
                  ~en:"Mouse mode ON (drag to select and copy, [m] for native drag-select)"
              else
                Say.make
                  ~ko:"네이티브 드래그 선택 모드 (마우스 캡처 꺼짐)"
                  ~en:"Native terminal drag-select ON (mouse capture OFF)"
            in
            model :=
              !model |> Model.disarm_quit |> Model.disarm_keeper_stop
              |> Model.with_toast ~now ~level:Model.Toast_info notice;
            scheduler :=
              Frame_scheduler.mark_dirty
                ~pace:Frame_scheduler.Pace_interactive !scheduler
          end
          else begin
            let next_model, cmds = Update.step ~now !model msg in
            let drawer_run_next =
              Option.equal Nav.equal_overlay !model.nav.overlay
                (Some (Nav.Queue_context Nav.Drawer_queue))
              && List.exists
                   (* Other drawer commands do not use the painted run-next action. *)
                   ((function
                     | Cmd.Http_post { req = Cmd.Post_keeper_run_next _; _ } -> true
                     | _ -> false) [@warning "-4"])
                   cmds
            in
            let next_model, cmds =
              if drawer_run_next then begin
                let painted = !presented_run_next in
                presented_run_next := None;
                let lost = Terminal_out.take_lost () in
                if lost then Presenter.invalidate presenter;
                match painted, Update_nav.queue_run_next_target !model with
                | Some (epoch, shown), Some current
                  when not lost && not (Terminal_out.behind ())
                       && Epoch.equal epoch !model.epoch
                       && same_queue_action shown current
                       && not (List.exists
                                 (is_pending epoch current.keeper current.request_id)
                                 !pending_run_next) ->
                    pending_run_next :=
                      (epoch, current.keeper, current.request_id) :: !pending_run_next;
                    next_model, cmds
                | _ ->
                    ( Model.with_toast ~now ~level:Model.Toast_warning
                        (Say.make ~ko:"대기 메시지가 바뀌었습니다. 표시된 항목을 다시 확인하세요"
                           ~en:"The queued message changed. Check the displayed item first")
                        !model
                    , [] )
              end
              else next_model, cmds
            in
            model := next_model;
            scheduler :=
              Frame_scheduler.mark_dirty ~pace:(msg_pace msg) !scheduler;
            if cmds <> [] then Cmd_executor.execute_all executor cmds
          end
        in

        let last_resize_gen = ref (Signals.resize_generation signals) in
        let last_voice_tick_ns = ref 0L in
        let last_clock_minute = ref (clock_minute_of_unix init_wall_unix) in
        let progress_deadline = ref None in

        (* Boot sequence: GET /health + Voice probe; healthy reply triggers
           workspace guard, declarative Sync_streams, and bootstrap fetches. *)
        apply_msg ~now:(Clock.Mono.now ()) Msg.Boot;

        let drain_inputs ~now ~deadline_ns =
          let rec loop () =
            if !should_quit then ()
            else if
              Int64.compare (Clock.Mono.to_ns (Clock.Mono.now ())) deadline_ns
              >= 0
            then begin
              if not (Eio.Stream.is_empty input_queue) then
                Wake_bell.ring bell Wake_bell.Ui_bus
            end
            else
              match Eio.Stream.take_nonblocking input_queue with
              | None -> ()
              | Some msg ->
                  apply_msg ~now msg;
                  loop ()
          in
          loop ()
        in

        let drain_bus ~now ~deadline_ns =
          let rec loop () =
            if !should_quit then ()
            else if Int64.compare (Clock.Mono.to_ns (Clock.Mono.now ())) deadline_ns >= 0
            then begin
              if not (Ui_bus.is_empty bus) then
                Wake_bell.ring bell Wake_bell.Ui_bus
            end
            else
              match Ui_bus.drain_up_to ~max_items:32 bus with
              | [] -> ()
              | items ->
                  List.iter
                    (fun item ->
                      if not !should_quit then
                        match item with
                        | Ui_bus.Snapshot (_, msg) | Ui_bus.Stream_event msg ->
                            apply_msg ~now msg
                        | Ui_bus.Stream_gap dropped ->
                            apply_msg ~now (Msg.Stream_gap dropped))
                    items;
                  loop ()
          in
          loop ()
        in

        let run_loop () =
          while not !should_quit do
            ignore (Wake_bell.drain_mask bell : int);
            let now = Clock.Mono.now () in
            let now_ns = Clock.Mono.to_ns now in

            (* 1. Process POSIX exit signals. *)
            (match Signals.poll_exit ~now signals with
            | Signals.Continue -> ()
            | Signals.Interrupt_armed ->
                model :=
                  Model.with_toast ~now ~duration_s:Signals.interrupt_arm_window_s
                    ~level:Model.Toast_warning
                    (Say.make
                       ~ko:"종료하려면 Ctrl+C 를 한 번 더 누르세요"
                       ~en:"Press Ctrl+C again to quit")
                    !model;
                scheduler :=
                  Frame_scheduler.mark_dirty
                    ~pace:Frame_scheduler.Pace_interactive !scheduler
            | (Signals.Interrupt_confirmed | Signals.Terminate _) as verdict -> (
                match Signals.exit_reason_of_verdict verdict with
                | Some reason ->
                    exit_reason := reason;
                    should_quit := true
                | None -> ()));

            (* 2. Dynamic SIGWINCH / SIGCONT resize handling. *)
            if not !should_quit then begin
              let cur_gen = Signals.resize_generation signals in
              if cur_gen <> !last_resize_gen then begin
                presented_run_next := None;
                last_resize_gen := cur_gen;
                let cols, rows =
                  measure_terminal_size
                    ~fallback:(!model.viewport.cols, !model.viewport.rows)
                in
                if cols <> !model.viewport.cols || rows <> !model.viewport.rows
                then begin
                  Presenter.resize presenter ~cols ~rows;
                  Card.Cache.clear card_cache;
                  apply_msg ~now (Msg.Resize { cols; rows })
                end
                else begin
                  Presenter.invalidate presenter;
                  scheduler :=
                    Frame_scheduler.mark_dirty
                      ~pace:Frame_scheduler.Pace_interactive !scheduler
                end
              end;

              (* Sync any late terminal probe observation into Presenter capabilities. *)
              let latest_obs = Atomic.get pending_probe_obs in
              if not (Probe.equal_observation latest_obs !applied_probe_obs) then begin
                applied_probe_obs := latest_obs;
                Presenter.set_capabilities presenter
                  (Presenter.apply_probe_observation latest_obs
                     (Presenter.capabilities presenter));
                scheduler :=
                  Frame_scheduler.mark_dirty
                    ~pace:Frame_scheduler.Pace_interactive !scheduler
              end;

              if Document_graphics.take_dirty document_graphics ~now then
                scheduler :=
                  Frame_scheduler.mark_dirty
                    ~pace:Frame_scheduler.Pace_interactive !scheduler;

              (* Recover from lost terminal writes by forcing full repaint. *)
              if Terminal_out.take_lost () then begin
                presented_run_next := None;
                Presenter.invalidate presenter;
                scheduler :=
                  Frame_scheduler.mark_dirty
                    ~pace:Frame_scheduler.Pace_interactive !scheduler
              end;

              (* 3. Drain input events first, then bounded 3 ms Ui_bus batch,
                    then any async-fetched $EDITOR handoff ready for the UI loop. *)
              let drain_deadline_ns = Int64.add now_ns drain_budget_ns in
              drain_inputs ~now ~deadline_ns:drain_deadline_ns;
              drain_bus ~now ~deadline_ns:drain_deadline_ns;
              if not !should_quit then
                Cmd_executor.run_pending_editor
                  ~can_launch:(fun () ->
                    (not !should_quit)
                    && can_launch_pending_wiki_editor !model)
                  executor;

              (* 4. Service active timers (toast expiration / 10 Hz voice timer)
                    without introducing idle polling. *)
              if not !should_quit then begin
                let now_after = Clock.Mono.now () in
                let now_after_ns = Clock.Mono.to_ns now_after in
                let toast_expires_ns =
                  Option.map
                    (fun (toast : Model.toast) -> Clock.Mono.to_ns toast.expires_at)
                    !model.toast
                in
                let voice_recording =
                  match !model.drafts.voice with
                  | Drafts.Voice_recording _ -> true
                  | Drafts.Voice_off
                  | Drafts.Voice_transcribing
                  | Drafts.Voice_error _ ->
                      last_voice_tick_ns := 0L;
                      false
                in
                let wall_now = Unix.gettimeofday () in
                let oauth_poll_deadline_ns =
                  Keeper_context_store.next_oauth_poll_deadline_ns
                    ~now_ns:now_after_ns ~wall_unix:wall_now
                    !model.keeper_context
                in
                let arm_expires_ns = armed_expiry_deadline_ns !model in
                let emit_tick, extra =
                  should_emit_tick ~oauth_poll_deadline_ns ~now_ns:now_after_ns
                    ~last_voice_tick_ns:!last_voice_tick_ns ~toast_expires_ns
                    ~arm_expires_ns ~voice_recording
                in
                let minute_due, cur_minute, minute_deadline =
                  next_minute_tick ~now_ns:now_after_ns ~wall_unix:wall_now
                    ~last_minute:!last_clock_minute
                in
                let should_tick_now = emit_tick || minute_due in
                if should_tick_now then begin
                  if voice_recording then last_voice_tick_ns := now_after_ns;
                  if minute_due then last_clock_minute := cur_minute;
                  apply_msg ~now:now_after (Msg.Tick { wall_unix = wall_now })
                end;
                ignore (Signals.expire_interrupt ~now:now_after signals : bool);
                let interrupt_deadline =
                  Option.map Clock.Mono.to_ns
                    (Signals.interrupt_armed_deadline signals)
                in
                let extra_after =
                  if should_tick_now then
                    let post_toast_expires =
                      Option.map
                        (fun (toast : Model.toast) ->
                          Clock.Mono.to_ns toast.expires_at)
                        !model.toast
                    in
                    let post_oauth_deadline =
                      Keeper_context_store.next_oauth_poll_deadline_ns
                        ~now_ns:now_after_ns ~wall_unix:wall_now
                        !model.keeper_context
                    in
                    let post_arm_expires = armed_expiry_deadline_ns !model in
                    let _, next_extra =
                      should_emit_tick
                        ~oauth_poll_deadline_ns:post_oauth_deadline
                        ~now_ns:now_after_ns
                        ~last_voice_tick_ns:!last_voice_tick_ns
                        ~toast_expires_ns:post_toast_expires
                        ~arm_expires_ns:post_arm_expires ~voice_recording
                    in
                    earliest_opt
                      (earliest_opt next_extra (Some minute_deadline))
                      interrupt_deadline
                  else
                    earliest_opt
                      (earliest_opt extra (Some minute_deadline))
                      interrupt_deadline
                in
                (* Visible progress needs a presentation clock. It does
                   not emit a model tick or request more server observations. *)
                let progress_interval = visible_progress_interval !model in
                (match progress_interval, !progress_deadline with
                 | None, _ -> progress_deadline := None
                 | Some _, Some due when Int64.compare now_after_ns due < 0 -> ()
                 | Some interval, _ ->
                     progress_deadline := Some (Int64.add now_after_ns interval);
                     scheduler :=
                       Frame_scheduler.mark_dirty
                         ~pace:Frame_scheduler.Pace_animation !scheduler);
                scheduler :=
                  Frame_scheduler.set_extra_deadline
                    (earliest_opt extra_after !progress_deadline)
                    !scheduler;

                (* 5. Frame pacing & differential CSI 2026 presentation. *)
                let output_behind = Terminal_out.behind () in
                (match
                   Frame_scheduler.decide ~now_ns:now_after_ns ~output_behind
                     !scheduler
                 with
                | Frame_scheduler.Render_now ->
                    let render_start = Clock.Mono.now () in
                    let grid = Presenter.back_grid presenter in
                    Cell_grid.clear grid;
                    let frame_model =
                      match progress_interval with
                      | None -> !model
                      | Some _ ->
                          let m = !model in
                          let freshness =
                            {
                              m.freshness with
                              last_wall_unix = wall_now;
                              last_mono =
                                Clock.Mono.max m.freshness.last_mono now_after;
                            }
                          in
                          { m with freshness }
                    in
                    let cursor = render_frame ~model:frame_model ~cache:card_cache grid in
                    let render_us =
                      Clock.Mono.us_since (Clock.Mono.now ()) ~since:render_start
                    in
                    let probe_obs = Probe.current_observation () in
                    let theme = Theme.of_preset !model.theme_preset in
                    let desired_document =
                      Document_graphics.prepare document_graphics ~sw ~now:now_after
                        ~base_path:cli.base_path
                        ~endpoint:(Cmd_executor.current_endpoint executor)
                        ~fetch_retained:(fun endpoint ~path ~max_body_bytes ->
                          Http_client.get_raw_limited ~io ~clock ~max_body_bytes endpoint ~path)
                        ~on_ready:(fun () -> Wake_bell.ring bell Wake_bell.Ui_bus)
                        ~probe:probe_obs ~theme grid
                    in
                    List.iter
                      (Document_graphics.mask_fallback grid
                         ~style:(Typography.primary ~bg:(Color.of_rgb theme.surface_0) theme))
                      desired_document;
                    let document_pre =
                      Document_graphics.before_present document_graphics
                        ~in_tmux desired_document
                    in
                    let pre_bytes, invalidate_for_graphic, remaining_graphic =
                      plan_memory_graphic_clear ~active:!active_memory_graphic
                        ~probe:probe_obs ~term_program ~in_tmux ~model:!model
                    in
                    active_memory_graphic := remaining_graphic;
                    let pre_bytes = pre_bytes ^ document_pre in
                    if not (String.equal pre_bytes "") then begin
                      Terminal_out.write pre_bytes;
                      Terminal_out.flush ()
                    end;
                    if invalidate_for_graphic then Presenter.invalidate presenter;
                    let diff_stats =
                      Presenter.present_back presenter ~cursor
                        ~write:Terminal_out.write
                    in
                    if diff_stats.bytes_emitted > 0 then Terminal_out.flush ();
                    (* Settled drag-select text is copied once via the async
                       clipboard path; the executor publishes the outcome
                       toast. The highlight stays until the next key/wheel. *)
                    if Model.mouse_selection_is_pending_copy !model then begin
                      (match Model.mouse_selection_rect !model with
                      | Some rect ->
                          let text =
                            Selection.extract_text (Presenter.front_grid presenter)
                              ~rect
                          in
                          if not (String.equal text "") then
                            Cmd_executor.execute executor
                              (Cmd.Copy_clipboard text)
                      | None -> ());
                      model := Model.mark_mouse_selection_copied !model
                    end;
                    presented_run_next :=
                      Option.map (fun target -> frame_model.epoch, target)
                        (Update_nav.queue_run_next_target frame_model);
                    let post_bytes, next_graphic =
                      plan_memory_graphic_place ~active:!active_memory_graphic
                        ~probe:probe_obs ~term_program ~in_tmux ~model:!model
                        ~full_repaint:
                          (diff_stats.full_repaint || invalidate_for_graphic)
                    in
                    active_memory_graphic := next_graphic;
                    let document_post =
                      Document_graphics.after_present document_graphics ~in_tmux
                        ~full_repaint:(diff_stats.full_repaint || invalidate_for_graphic)
                        desired_document
                    in
                    let post_bytes = post_bytes ^ document_post in
                    if not (String.equal post_bytes "") then begin
                      Terminal_out.write post_bytes;
                      Terminal_out.flush ()
                    end;
                    let finished_ns = Clock.Mono.to_ns (Clock.Mono.now ()) in
                    scheduler :=
                      Frame_scheduler.record_rendered ~now_ns:finished_ns
                        ~render_us ~diff_us:diff_stats.diff_us
                        ~dirty_cells:diff_stats.dirty_cells
                        ~bytes_emitted:diff_stats.bytes_emitted !scheduler
                | Frame_scheduler.Skip_backpressure _ ->
                    scheduler :=
                      Frame_scheduler.record_skipped_backpressure
                        ~now_ns:now_after_ns !scheduler
                | Frame_scheduler.Wait_until _ | Frame_scheduler.Sleep_idle -> ());

                (* 6. Sleep until next monotonic deadline or Wake_bell ring.
                      When idle (Next_deadline_ns None), performs pure 0 Hz sleep. *)
                if not !should_quit then
                  if
                    Wake_bell.is_rung bell
                    || (not (Ui_bus.is_empty bus))
                    || not (Eio.Stream.is_empty input_queue)
                    || Cmd_executor.has_pending_editor executor
                  then Eio.Fiber.yield ()
                  else
                    let sleep_now_ns = Clock.Mono.to_ns (Clock.Mono.now ()) in
                    let (Frame_scheduler.Next_deadline_ns deadline_ns) =
                      Frame_scheduler.next_deadline ~now_ns:sleep_now_ns
                        ~output_behind:(Terminal_out.behind ()) !scheduler
                    in
                    let deadline_ns =
                      earliest_opt deadline_ns
                        (Option.map Clock.Mono.to_ns
                           (Document_graphics.next_retry_deadline document_graphics))
                    in
                    ignore
                      (Wake_bell.await_until_ns ~clock ~now_ns:sleep_now_ns
                         ~deadline_ns bell
                        : [ `Woken | `Timeout ])
              end
            end
          done
        in
        let code =
          match run_loop () with
          | () ->
              if Exit_reason.is_normal !exit_reason then 0 else 1
          | exception (Eio.Cancel.Cancelled _ as ex) ->
              if Exit_reason.equal !exit_reason Exit_reason.Unrecorded then
                exit_reason := Exit_reason.Exception "cancelled";
              raise ex
          | exception ex ->
              exit_reason := Exit_reason.Exception (Printexc.to_string ex);
              1
        in
        exit_code_ref := code;
        (* Fail [work_sw] first so in-flight HTTP/stream/input fibers cancel
           immediately; [work_sw]'s [on_release] hook runs [Cmd_executor.shutdown]. *)
        Eio.Switch.fail work_sw Work_exit.Shutdown
        with
        | Work_exit.Shutdown -> ()
        | Eio.Exn.Multiple exns
          when List.exists (fun (ex, _) -> ex == Work_exit.Shutdown) exns ->
            let unexpected =
              List.filter
                (fun (ex, _) ->
                  not
                    (ex == Work_exit.Shutdown
                    || match ex with
                       | Eio.Cancel.Cancelled _ -> true
                       | _ -> false))
                exns
            in
            (match unexpected with
             | [] -> ()
             | (ex, _) :: _ ->
                 if
                   Exit_reason.is_normal !exit_reason
                   || Exit_reason.equal !exit_reason Exit_reason.Unrecorded
                 then
                   exit_reason :=
                     Exit_reason.Exception
                       ("shutdown teardown: " ^ Printexc.to_string ex);
                 exit_code_ref := 1));
        !exit_code_ref)
      in
      if !restart_requested then begin
        match Unix.execv Sys.executable_name Sys.argv with
        | _ -> 0
        | exception Unix.Unix_error (err, fn, _) ->
            output_string stderr
              (Printf.sprintf "[masc-tui] restart failed (%s): %s\n" fn
                 (Unix.error_message err));
            flush stderr;
            1
      end
      else exit_code

let run_argv ?argv ~render_frame () =
  match Cli_args.parse_and_dispatch ?argv () with
  | Cli_args.Exit code -> code
  | Cli_args.Start cli -> run ~cli ~render_frame ()
