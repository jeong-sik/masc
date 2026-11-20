(** One 60 Hz frame window: bursts are coalesced without delaying an idle
    terminal's first changed frame. *)
let frame_interval_ns = 16_000_000L

(* One enable/disable pair for SGR mouse reports. Without tracking the
   terminal keeps the wheel for its own scrollback -- which scrolls past the
   TUI's frame on a non-alternate screen -- or turns it into arrow keys only
   if configured to. With it, wheel reports arrive here and read_input maps
   them to the same keys the arrows make.

   1002 is button-event tracking: motion reports while a button is held, the
   drag a selection is read from. It follows 1000 so a terminal that knows
   both ends on 1002, and one that knows only 1000 still reports the wheel
   and the press. *)
let mouse_tracking_enable = "\x1b[?1006;1000;1002h"
let mouse_tracking_disable = "\x1b[?1006;1002;1000l"

(* One enable/disable pair for bracketed paste. Without it the terminal
   delivers a paste as the keys it looks like, so every newline in it is
   Return: a three-line paste is three messages, a pasted Markdown block
   arrives as three sends, and the operator gets a queue full of fragments
   instead of the thing they copied. With it the payload comes wrapped in
   ESC[200~ and ESC[201~ and the text arrives as text.

   Written and cleared beside the mouse mode, for the reasons its comment
   gives about when a byte may be put on this stream. *)
let bracketed_paste_enable = "\x1b[?2004h"
let bracketed_paste_disable = "\x1b[?2004l"

let toggle_mouse_tracking_key = Masc_tui_keys.mouse_toggle_key

(* Ctrl-B, as an editor toggles its side bar. The roster beside a keeper chat
   costs 30 of the terminal's columns, and a reader who knows which keeper
   they are talking to wants them back. A letter would not do -- in the
   composer every letter is text. *)
let toggle_roster_pane_key = "\002"

(* Ctrl-L, beside Ctrl-B: the Activity pane is the side bar on the other
   edge. It costs the surface [Masc_tui_acting_pane.pane_cols] columns for
   the fleet's live feed, or [wide_pane_cols] for whole names and each
   call's age, and a reader who wants the width back, or the feed beside a
   chat, walks it narrow, wide, hidden. One key for the three: every other
   Ctrl letter is taken, and in the composer every plain letter is text. *)
let toggle_acting_pane_key = "\012"

(* Ctrl-^ keeps a reader one key away without consuming a typed letter. *)
let toggle_browser_lane_key = "\030"

type t = {
  old_term : Unix.terminal_io;
  old_reclaimed_keys : Masc_tui_termios.snapshot;
  new_term : Unix.terminal_io;
  profile : Masc_tui_terminal_profile.t;
  presenter : Masc_tui_frame_presenter.t;
  title : Masc_tui_terminal_title.t;
  resize_requested : bool Atomic.t;
  resize_generation : int Atomic.t;
  exit_signals : Masc_tui_exit_signals.t;
  mouse_tracking_on : bool Atomic.t;
  cleanup_started : bool Atomic.t;
  mutable keeper_preference_exit_warnings : string list;
}

let create () =
  let old_term = Unix.tcgetattr Unix.stdin in
  (* Read beside [old_term] because the record carries only one of them,
     Ctrl-backslash. The reclaimed keys are turned off for as long as this
     program owns the terminal ([apply_raw_mode]) and handed back whenever the
     terminal is -- at exit and around Ctrl-Z. Restoring [old_term] alone
     leaves the shell without the other keys, which the PTY harness catches as
     a terminal this program did not put back the way it found it. *)
  let old_reclaimed_keys = Masc_tui_termios.snapshot Unix.stdin in
  (* c_icrnl off so Return and Ctrl-J arrive as themselves. With the terminal's
     default translation on, Return is delivered as LF -- the same byte Ctrl-J
     sends -- and the composer cannot tell "send this" from "start a new line".
     LF still submits below if some terminal sends it for Return, so this only
     ever adds a key. *)
  (* Flow control off. IXON lives in c_iflag and ICANON in c_lflag, so raw
     mode did not touch it: the tty was still answering Ctrl-S by stopping
     output and Ctrl-Q by resuming it, and neither byte ever reached the
     key layer. Measured on a pty with the TUI running: ixon=True.

     What an operator saw was small, because IXANY is on too -- the next key
     they pressed released it, so the screen stalled rather than froze. What
     it cost was a key: Ctrl-S could not be bound to anything, which is the
     key a reader reaches for to hold a moving surface still. *)
  let new_term =
    { old_term with
      Unix.c_icanon = false
    ; c_echo = false
    ; c_icrnl = false
    ; c_ixon = false
    }
  in
  let profile = Masc_tui_terminal_profile.detect ~getenv:Sys.getenv_opt in
  Masc_tui_msx.set_synchronized_output
    (Masc_tui_terminal_profile.synchronized_output profile);
  let presenter =
    Masc_tui_frame_presenter.create
      ~synchronized_output:(Masc_tui_terminal_profile.synchronized_output profile)
      ()
  in
  { old_term
  ; old_reclaimed_keys
  ; new_term
  ; profile
  ; presenter
  ; title = Masc_tui_terminal_title.create ()
  ; resize_requested = Atomic.make false
  ; resize_generation = Atomic.make 0
  ; exit_signals = Masc_tui_exit_signals.create ()
  ; mouse_tracking_on = Atomic.make true
  ; cleanup_started = Atomic.make false
  ; keeper_preference_exit_warnings = []
  }

let presenter t = t.presenter
let exit_signals t = t.exit_signals
let resize_requested t = Atomic.get t.resize_requested
let take_resize_request t = Atomic.exchange t.resize_requested false
let resize_generation t = Atomic.get t.resize_generation
let bump_resize_generation t = ignore (Atomic.fetch_and_add t.resize_generation 1)

let set_keeper_preference_exit_warnings t warnings =
  t.keeper_preference_exit_warnings <- warnings

let create_render_schedule () =
  Masc_tui_render_schedule.create ~min_interval_ns:frame_interval_ns ()

let enable_bracketed_paste () =
  Masc_tui_terminal_out.write bracketed_paste_enable;
  Masc_tui_terminal_out.flush ()

let toggle_mouse_tracking t =
  let on = not (Atomic.get t.mouse_tracking_on) in
  Atomic.set t.mouse_tracking_on on;
  Masc_tui_terminal_out.write
    (if on then mouse_tracking_enable else mouse_tracking_disable);
  Masc_tui_terminal_out.flush ()

(* Raw mode, and the keys the record cannot turn off.

   The tty layer takes some keys for itself: Ctrl-V (paste), Ctrl-backslash
   (SIGQUIT, which ends the session unconfirmed), and on BSD terminals Ctrl-O
   (Browser screenshot) and Ctrl-Y (speak) -- see
   [Masc_tui_termios.reclaimed_key]. Every hand-off gives them back, and
   [Unix.tcsetattr] writes [new_term]'s [c_vquit], the quit character it was
   read with. Reclaiming them after it keeps the three places that take raw
   mode back (session start, the return from Ctrl-Z, the return from $EDITOR)
   from taking it back without the keys.

   The result is not checked because there is nothing left for it to report:
   the [tcsetattr] on the line above just succeeded on this descriptor, so it
   is a terminal this process can set. What remains is a hangup between the two
   calls, and that ends the session either way. *)
let apply_raw_mode new_term =
  Unix.tcsetattr Unix.stdin Unix.TCSANOW new_term;
  Masc_tui_termios.reclaim Unix.stdin

(* The terminal changes hands: its queued bytes go first, but a terminal
   that stopped reading does not hold the handoff or the exit for good. *)
let drain_before_handoff () =
  match Masc_tui_terminal_out.(drain ~within_s:handoff_limit_s) with
  | Masc_tui_terminal_out.Drained -> ()
  | Masc_tui_terminal_out.Abandoned ->
      Log.Transport.warn
        "tui_terminal_not_reading: dropped the queued output after %.1fs and handed the terminal over"
        Masc_tui_terminal_out.handoff_limit_s

let restore_outcome t =
  (* No tracking-off here. [cleanup] writes the off byte once, at real
     process exit, after the farewell. [hand_off] writes it before the stop
     and [take_back] takes the mode again when the process continues. *)
  Masc_tui_frame_presenter.cleanup t.presenter
    ~write:Masc_tui_terminal_out.write
    ~flush:Masc_tui_terminal_out.flush;
  if Masc_tui_terminal_profile.dynamic_title t.profile then
    Masc_tui_terminal_title.clear t.title
      ~write:Masc_tui_terminal_out.write
      ~flush:Masc_tui_terminal_out.flush;
  (* Raw mode and the alternate screen are given back only after every
     queued byte reached the terminal: a frame still queued would otherwise
     land on the shell's screen, or in a child process's input. *)
  drain_before_handoff ();
  (* Keep the known-loss result so exit cleanup does not write a farewell
     or tracking controls to a terminal that already rejected restoration. *)
  let outcome =
    Masc_tui_terminal_restore.put_back ~set:(fun () ->
      Unix.tcsetattr Unix.stdin Unix.TCSANOW t.old_term)
  in
  (* After the record, not before: [tcsetattr] is what puts the rest of the
     terminal back, and these characters, Ctrl-backslash aside, are the part
     it cannot reach. A refusal here is the terminal already gone. *)
  Masc_tui_termios.restore Unix.stdin t.old_reclaimed_keys;
  outcome

let restore t =
  match restore_outcome t with
  | Masc_tui_terminal_restore.Restored
  | Masc_tui_terminal_restore.Terminal_gone _ -> ()

let request_full_repaint t =
  ignore (Atomic.fetch_and_add t.resize_generation 1);
  Atomic.set t.resize_requested true;
  Masc_tui_wake.(ring loop Resize_signal)

let hand_off t =
  Masc_tui_terminal_out.write mouse_tracking_disable;
  Masc_tui_terminal_out.flush ();
  restore t

let take_back t =
  apply_raw_mode t.new_term;
  Masc_tui_frame_presenter.setup t.presenter
    ~write:Masc_tui_terminal_out.write
    ~flush:Masc_tui_terminal_out.flush;
  if Atomic.get t.mouse_tracking_on then
    Masc_tui_terminal_out.write mouse_tracking_enable;
  enable_bracketed_paste ();
  request_full_repaint t

let restore_for_music t =
  Masc_tui_terminal_out.write bracketed_paste_disable;
  if Masc_tui_terminal_profile.kitty_keyboard t.profile then
    Masc_tui_terminal_out.write Masc_tui_csi.disable_kitty_keyboard;
  hand_off t

let reenter_from_music t =
  take_back t;
  if Masc_tui_terminal_profile.kitty_keyboard t.profile then
    Masc_tui_terminal_out.write Masc_tui_csi.enable_kitty_keyboard;
  Masc_tui_terminal_out.flush ()

let cleanup t () =
  if Atomic.compare_and_set t.cleanup_started false true then begin
    (* The terminal is being given back for good. A Ctrl-Z now would run
       [suspend], whose resume takes raw mode and the alternate screen
       again after this restore, and the shell would inherit them. *)
    Sys.set_signal Sys.sigtstp Sys.Signal_ignore;
    Console_sink.set_after_write_observer None;
    (* Bound by name: the AST guard pins this call by listing every
       labelled argument as an identifier, so the exit writer is a named
       function rather than an inline closure. *)
    let finish () =
      List.iter
        (fun warning ->
          Masc_tui_terminal_out.write
            ("[masc-tui] " ^ Masc_tui_ansi.Terminal_text.single_line warning ^ "\n"))
        t.keeper_preference_exit_warnings;
      Masc_tui_terminal_out.write "Goodbye!\n";
      (* Tracking off after Goodbye: a terminal left in report mode keeps
         swallowing the wheel after this process is gone, and the farewell
         line is the last thing a reader matches on -- a byte after it cannot
         disturb that read. *)
      Masc_tui_terminal_out.write mouse_tracking_disable;
      Masc_tui_terminal_out.write bracketed_paste_disable;
      (* The mode belongs to this program's screen. A shell that inherited it
         would see its own keys reported in a form it does not read. *)
      if Masc_tui_terminal_profile.kitty_keyboard t.profile then
        Masc_tui_terminal_out.write Masc_tui_csi.disable_kitty_keyboard;
      drain_before_handoff ()
    in
    let restore () = restore_outcome t in
    Masc_tui_terminal_restore.finish_after_restore ~restore ~finish
  end

let enter t =
  let terminate signal =
    Masc_tui_exit_signals.request_terminate t.exit_signals
      ~signal:(Exit_journal.signal_name signal);
    Masc_tui_wake.(ring loop Terminate_signal)
  in
  let request_interrupt _ =
    Masc_tui_exit_signals.request_interrupt t.exit_signals;
    Masc_tui_wake.(ring loop Interrupt_signal)
  in
  let request_repaint _ = request_full_repaint t in
  let rec suspend _ =
    hand_off t;
    Sys.set_signal Sys.sigtstp Sys.Signal_default;
    Fun.protect
      ~finally:(fun () ->
        Sys.set_signal Sys.sigtstp (Sys.Signal_handle suspend);
        take_back t)
      (fun () -> Unix.kill (Unix.getpid ()) Sys.sigtstp)
  in
  (* [at_exit] runs its callbacks in the reverse of this order. Restore first
     so an error writing the frame summary cannot prevent the first restore
     attempt. An exception interrupts that cleanup pass; OCaml may retry
     remaining callbacks while reporting an uncaught exception. The exit
     reason is registered first so it is written last, after the terminal is
     back. *)
  at_exit Exit_journal.write_once;
  at_exit Masc_tui_frame_timing.report;
  at_exit Masc_tui_alloc_profile.report;
  at_exit (cleanup t);
  Masc_tui_alloc_profile.start ();
  (* SIGINT asks the loop what a Ctrl-C means this time; the rest tell it the
     session is over. Neither ends the process from the handler: the loop
     leaves through [Exit_journal.Break], so the switch release that stops a
     server this TUI started runs whichever signal ended the session. *)
  Sys.set_signal Sys.sigint (Sys.Signal_handle request_interrupt);
  Sys.set_signal Sys.sigterm (Sys.Signal_handle terminate);
  Sys.set_signal Sys.sighup (Sys.Signal_handle terminate);
  Sys.set_signal Sys.sigquit (Sys.Signal_handle terminate);
  Sys.set_signal Sys.sigwinch (Sys.Signal_handle request_repaint);
  Sys.set_signal Sys.sigcont (Sys.Signal_handle request_repaint);
  Sys.set_signal Sys.sigtstp (Sys.Signal_handle suspend);
  apply_raw_mode t.new_term

let setup_screen t =
  if Masc_tui_terminal_write_repair.console_sink_writes_to_terminal () then
    Console_sink.set_after_write_observer
      (Some (fun () -> Masc_tui_terminal_write_repair.note ()));
  (* Before the first frame and after session entry, so the at_exit cleanup
     that gives this back is already installed. *)
  Masc_tui_frame_presenter.setup t.presenter
    ~write:Masc_tui_terminal_out.write
    ~flush:Masc_tui_terminal_out.flush;
  Masc_tui_terminal_out.write mouse_tracking_enable;
  enable_bracketed_paste ();
  (* Only terminals with an extended profile receive this opt-in. Apple
     Terminal does not implement the protocol; keeping an unsupported control
     sequence off its parser also keeps its crash-sensitive render path small. *)
  if Masc_tui_terminal_profile.kitty_keyboard t.profile then
    Masc_tui_terminal_out.write Masc_tui_csi.enable_kitty_keyboard;
  Masc_tui_terminal_out.flush ()

(* What a size change costs, wherever it was noticed: the presenter's cached
   screen describes the old geometry, and the next frame has to be drawn
   rather than skipped as unchanged. Both doors below end here so the two
   cannot come to disagree about what a resize costs. *)
let discard_frame_for_new_size presenter render_schedule =
  Masc_tui_msx.invalidate ();
  Masc_tui_frame_presenter.invalidate presenter;
  Masc_tui_render_schedule.request render_schedule Masc_tui_render_schedule.Force

(* SIGWINCH says the size changed without saying to what, so the cached size
   is dropped and the next reader re-probes. The loop's own ioctl snapshot
   takes the other door: it already holds the new size and has to keep it, or
   the frame it is about to draw would read a different one. *)
let invalidate_frame_for_resize presenter render_schedule =
  Masc_tui_ansi.invalidate_terminal_size ();
  discard_frame_for_new_size presenter render_schedule

let request_console_write_repair render_schedule =
  Masc_tui_terminal_write_repair.request_repaint render_schedule

let terminal_title_visible_keeper (state : Masc_tui_types.state) =
  match state.view with
  | Masc_tui_types.Code -> None
  | Masc_tui_types.Keepers Masc_tui_types.Keeper_message -> state.msg_target_keeper_name
  | Masc_tui_types.Keepers
      Masc_tui_types.(Keeper_list | Keeper_detail | Keeper_logs | Keeper_calls
      | Keeper_runtime_pick) ->
      Option.map
        (fun (keeper : Masc_tui_types.keeper) -> keeper.Masc.Tui_decode.k_name)
        (Masc_tui_types.selected_keeper state)
  | Masc_tui_types.Overview | Masc_tui_types.Acting | Masc_tui_types.Metrics
  | Masc_tui_types.Memory | Masc_tui_types.Lanes | Masc_tui_types.Clients
  | Masc_tui_types.Board | Masc_tui_types.Approvals | Masc_tui_types.Planning
  | Masc_tui_types.Schedules | Masc_tui_types.Verification
  | Masc_tui_types.Harness | Masc_tui_types.Fusion
  | Masc_tui_types.Repositories | Masc_tui_types.Changes
  | Masc_tui_types.Connectors | Masc_tui_types.Runtime
  | Masc_tui_types.Config | Masc_tui_types.Resources
  | Masc_tui_types.Tools | Masc_tui_types.System_logs -> None

let terminal_title_runtime (state : Masc_tui_types.state) keeper_name =
  Option.bind keeper_name (fun name ->
    Option.bind
      (List.find_opt
         (fun (keeper : Masc_tui_types.keeper) ->
           String.equal keeper.Masc.Tui_decode.k_name name)
         state.keepers)
      (fun keeper ->
        match (Masc_tui_types.keeper_reading state keeper).Masc_tui_keeper_control.liveness with
        | Masc_tui_keeper_control.Present runtime -> Some runtime.Masc.Tui_decode.kr_runtime_id
        | Masc_tui_keeper_control.Absent
        | Masc_tui_keeper_control.Unobserved
        | Masc_tui_keeper_control.Invalid _ -> None))

let terminal_title_attention state =
  Option.map List.length (Masc_tui_types.operator_actions state)

let title_snapshot (state : Masc_tui_types.state) =
  let live = Option.map Masc_tui_types.turn_log_keeper_name state.msg_live in
  let inflight =
    List.map
      (fun (entry : Masc_tui_types.inflight) ->
        entry.Masc_tui_types.sent_request.Masc_tui_keeper_chat_projection.keeper_name)
      state.msg_inflight
  in
  let keeper_name =
    Masc_tui_terminal_title.select_keeper
      ~live
      ~inflight
      ~visible:(terminal_title_visible_keeper state)
  in
  let activity =
    match live, inflight with
    | Some _, _ | None, _ :: _ -> Masc_tui_terminal_title.Working
    | None, [] -> Masc_tui_terminal_title.Connection state.connection_status
  in
  Masc_tui_terminal_title.make
    ~activity
    ~attention:(terminal_title_attention state)
    ~keeper_name
    ~runtime_id:(terminal_title_runtime state keeper_name)
    ~workspace:state.workspace

let present_title t state =
  if Masc_tui_terminal_profile.dynamic_title t.profile then
    Masc_tui_terminal_title.present t.title
      ~write:Masc_tui_terminal_out.write
      ~flush:Masc_tui_terminal_out.flush
      (title_snapshot state)
