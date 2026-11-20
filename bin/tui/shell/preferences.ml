let store (state : Masc_tui_types.state) change =
  Masc_tui_types.note_session_pick state change;
  match state.connection_status with
  (* The account server of a multi-account installation keeps no [tui]
     table, and nothing is sent to it. No pick a person makes reaches here:
     its screen takes every key. What does is the first key retiring the help
     hint, which is not a choice to report. *)
  | Masc_tui_types.Account_server _ -> ()
  | Masc_tui_types.Disconnected | Masc_tui_types.Connecting | Masc_tui_types.Booting
  | Masc_tui_types.Degraded | Masc_tui_types.Connected ->
      ignore
        (Masc_tui_preference_writer.submit state.preference_writer
           ~sw:(Eio_context.get_switch_opt ()) change
         : Masc_tui_preference_writer.request)

let preference_name state = function
  | Masc.Tui_preference.Theme_chosen _ -> Masc_tui_types.ui_text state ~ko:"테마" ~en:"Theme"
  | Masc.Tui_preference.Language_chosen _ -> Masc_tui_types.ui_text state ~ko:"UI 언어" ~en:"UI language"
  | Masc.Tui_preference.Board_sort_chosen _ -> Masc_tui_types.ui_text state ~ko:"Board 정렬" ~en:"Board sort"
  | Masc.Tui_preference.Candle_chosen _ -> Masc_tui_types.ui_text state ~ko:"Candle" ~en:"Candle"
  | Masc.Tui_preference.Help_hint_retired -> Masc_tui_types.ui_text state ~ko:"도움말 안내" ~en:"The help hint"
  | Masc.Tui_preference.Chat_visited keeper ->
      let target = Keeper_id.Keeper_name.to_string keeper in
      Masc_tui_types.ui_text state ~ko:("대화 " ^ target) ~en:("Conversation " ^ target)

(* A pick the screen already shows: only what did not go as shown is said. A
   credential that may not write runtime.toml is said once for the session. *)
let report_outcome (state : Masc_tui_types.state) change outcome =
  let name = preference_name state change in
  match outcome with
  | Ok Masc_tui_preference_writer.Unchanged -> false
  | Ok (Masc_tui_preference_writer.Committed { durability; ignored_legacy_keys }) ->
      let legacy_said =
        match ignored_legacy_keys with
        | [] -> false
        | keys ->
            Masc_tui_loader.report_action state "warn"
              (Masc_tui_types.ui_text state
                 ~ko:(name ^ ": 저장했어요. 다만 이후 릴리스에서 읽지 않는 옛 키가 파일에 남아 있어 무시돼요: " ^ String.concat ", " keys)
                 ~en:(name ^ " saved. Legacy keys left in the file are ignored from this release on: " ^ String.concat ", " keys));
            true
      in
      let durability_said =
        match durability with
        | Runtime.Durable -> false
        | Runtime.Durability_unconfirmed { detail } ->
            Masc_tui_loader.report_action state "warn"
              (Masc_tui_types.ui_text state ~ko:(name ^ ": 저장했지만 디스크에 반영됐는지 확인하지 못했어요: " ^ detail)
                 ~en:(name ^ " saved; durability unconfirmed: " ^ detail));
            true
      in
      legacy_said || durability_said
  | Error (Masc_tui_preference_writer.Not_permitted reason) ->
      if state.preference_refusal_said then false
      else begin
        state.preference_refusal_said <- true;
        Masc_tui_loader.report_action state "error"
          (Masc_tui_types.ui_text state
             ~ko:("이 터미널의 credential 로는 화면 설정을 저장할 수 없어요. 이번 세션에만 적용돼요: " ^ reason)
             ~en:("This terminal's credential may not store screen settings. They last this session only: " ^ reason));
        true
      end
  | Error (Masc_tui_preference_writer.Refused reason | Masc_tui_preference_writer.Not_started reason) ->
      Masc_tui_loader.report_action state "error"
        (Masc_tui_types.ui_text state ~ko:(name ^ ": 저장하지 못했어요. 이번 세션에만 적용돼요: " ^ reason)
           ~en:(name ^ " not saved. This session only: " ^ reason));
      true
  | Error (Masc_tui_preference_writer.Unobserved reason) ->
      Masc_tui_loader.report_action state "error"
        (Masc_tui_types.ui_text state ~ko:(name ^ ": 저장됐는지 알 수 없어요: " ^ reason)
           ~en:(name ^ " save outcome unknown: " ^ reason));
      true

let drain_completions (state : Masc_tui_types.state) ~can_take =
  let changed = ref false in
  Masc_tui_preference_writer.drain_completed state.preference_writer ~can_take
    ~apply:(fun (completion : Masc_tui_preference_writer.completion) ->
      let change = completion.request.change in
      let accepted =
        match change with
        | Masc.Tui_preference.Chat_visited keeper ->
            Masc_tui_types.accept_chat_visit state completion keeper
        | Masc.Tui_preference.Theme_chosen _ | Masc.Tui_preference.Language_chosen _
        | Masc.Tui_preference.Board_sort_chosen _ | Masc.Tui_preference.Candle_chosen _
        | Masc.Tui_preference.Help_hint_retired -> false
      in
      let said = report_outcome state change completion.outcome in
      changed := !changed || accepted || said);
  !changed

let drain_keeper_completions (state : Masc_tui_types.state) ~can_take =
  let changed = ref false in
  Masc_tui_config.drain_keeper_preferences state.keeper_preference_writer ~can_take
    ~apply:(fun completion ->
      changed := true;
      Option.iter (Masc_tui_loader.report_action state "error")
        (Masc_tui_types.apply_keeper_preference_completion state completion));
  !changed

(* The stored picks in [settings], except the ones this session has changed
   itself: a value read later never replaces a choice made meanwhile. The
   opening screen is not among them; it is the start-up read's alone. *)
let apply_stored_picks ~on_midi_soundfont ~on_audio_input_device ~set_table_frame
    (state : Masc_tui_types.state) (settings : Masc.Tui_preference.settings) =
  let unpicked key = not (List.mem key state.session_picks) in
  let module Key = Masc.Tui_preference.Key in
  if unpicked Key.Midi_soundfont then on_midi_soundfont settings.midi_soundfont;
  if unpicked Key.Audio_input_device then on_audio_input_device settings.audio_input_device;
  if unpicked Key.Last_chat_keeper then
    (match settings.last_chat_keeper with
     | Ok None -> state.home_last_chat <- Masc_tui_types.No_chat_receipt
     | Ok (Some keeper) -> state.home_last_chat <- Masc_tui_types.Recorded_chat keeper
     | Error reason ->
         state.home_last_chat <- Masc_tui_types.Unreadable_chat_receipt reason;
         Masc_tui_loader.add_event state "error" reason);
  if unpicked Key.Board_sort then
    (match settings.board_sort with
     | None -> ()
     | Some value ->
         (match Masc_tui_types.board_sort_of_string value with
          | Some sort -> state.board_sort <- sort
          | None -> Masc_tui_loader.add_event state "error" ("Unknown saved Board sort: " ^ value)));
  (* A theme named in runtime.toml's [tui] section is applied, so the reader's
     pick survives a restart instead of being re-chosen each session. When no
     preference is stored on a Truecolor terminal, activate the curated
     Truecolor default theme; storing [terminal] opts back into following the
     terminal's own palette. *)
  if unpicked Key.Theme then
    let apply_default_if_truecolor () =
      if state.theme_choice = None
         && Masc_tui_theme.color_depth () = Masc_tui_theme.Truecolor
         && Masc_tui_theme_choice.apply Masc_tui_theme_choice.default_truecolor_theme
      then state.theme_choice <- Some Masc_tui_theme_choice.default_truecolor_theme
    in
    (match settings.theme, state.theme_before_preview with
     | None, None -> apply_default_if_truecolor ()
     | None, Some _ -> ()
     | Some name, None when String.equal name Masc_tui_theme_choice.terminal_choice_name ->
         Masc_tui_theme_choice.follow_terminal ();
         state.theme_choice <- None
     | Some name, Some _ when String.equal name Masc_tui_theme_choice.terminal_choice_name ->
         state.theme_before_preview <- Some None
     (* A preview is on screen. The stored theme becomes what Esc puts back,
        and the preview stays where the reader is looking. *)
     | Some name, Some _ ->
         if List.exists
              (fun (entry : Masc_tui_theme_choice.entry) ->
                String.equal entry.Masc_tui_theme_choice.name name)
              (Masc_tui_theme_choice.entries ())
         then state.theme_before_preview <- Some (Some name)
     | Some name, None ->
         if Masc_tui_theme_choice.apply name then state.theme_choice <- Some name);
  if unpicked Key.Language then
    (match settings.language with
     | None -> ()
     | Some value ->
         (match Masc_tui_types.ui_language_of_string value with
          | Some lang -> state.ui_language <- lang
          | None -> Masc_tui_loader.add_event state "error" ("Unknown saved UI language: " ^ value)));
  if unpicked Key.Candle then
    (match settings.candle with
     | None -> ()
     | Some value ->
         (match Masc_tui_emblem_screen.style_of_string value with
          | Some style -> Masc_tui_emblem_screen.set_style style
          | None -> Masc_tui_loader.add_event state "error" ("Unknown saved candle: " ^ value)));
  if unpicked Key.Reduce_motion then
    state.about_reduce_motion <-
      (match settings.reduce_motion with Some enabled -> enabled | None -> false);
  (* Absent reads as on, which is what masc drew before the key existed -- a
     reader who never set it sees no change. *)
  if unpicked Key.Lift_colours then
    Masc_tui_theme.set_lift_enabled (Option.value settings.lift_colours ~default:true);
  (* The box a table draws is a look, and a look that survives a restart is
     the point of storing it. *)
  if unpicked Key.Table_frame then
    set_table_frame (Option.value settings.table_frame ~default:false);
  (* Absent reads as on -- the hints predate the key, and a reader who never
     set it sees no change. *)
  if unpicked Key.Hints_visible then
    state.hints_visible <- Option.value settings.hints_visible ~default:true;
  (* Absent reads as not shown: the door line exists for a first-time
     reader, and a long-running operator still meets it once. *)
  if unpicked Key.Help_hint_shown then
    state.help_hint_shown <- Option.value settings.help_hint_shown ~default:false;
  if unpicked Key.Coalesce_queued_input then
    state.coalesce_queued_input <- Option.value settings.coalesce_queued_input ~default:false;
  if unpicked Key.User_input_priority_next then
    state.user_input_priority_next <-
      Option.value settings.user_input_priority_next ~default:false;
  (* Default false, unlike its neighbours: this one sends without the operator
     confirming, so absence is not consent. *)
  state.voice_send_on_stop <- Option.value settings.send_on_stop ~default:false

let apply_startup_settings ~on_midi_soundfont ~on_audio_input_device ~set_table_frame
    (state : Masc_tui_types.state) (tui_settings : Masc_tui_config.t) =
  (* The server could not answer this terminal's settings: it opens on the
     defaults, says so once, and reads them again when a server is first
     reached. *)
  Option.iter
    (fun reason ->
       state.settings_reread <- Masc_tui_types.Reread_due;
       Masc_tui_loader.report_action state "error"
         (Masc_tui_types.ui_text state
            ~ko:("서버에서 화면 설정을 읽지 못해 기본값으로 열었어요: " ^ reason)
            ~en:("Screen settings could not be read from the server; opened on the defaults: " ^ reason)))
    tui_settings.settings_unread;
  apply_stored_picks ~on_midi_soundfont ~on_audio_input_device ~set_table_frame
    state tui_settings.stored;
  (match tui_settings.stored.opening with
   | Ok Masc_tui_config.Overview -> ()
   | Ok (Masc_tui_config.Last None as opening) ->
       state.opening_mode <- opening;
       state.opening_notice <-
         Some "Could not open last chat (no saved Keeper). Showing Dashboard."
   | Ok ((Masc_tui_config.Last (Some _) | Masc_tui_config.Keeper _) as opening) ->
       state.opening_mode <- opening;
       state.opening_pending <- true
   | Error reason ->
       state.opening_notice <- Some (reason ^ ". Showing Dashboard."));
  let note_keeper_preference_error message =
    Masc_tui_types.note_keeper_preference_startup_error state message;
    Masc_tui_loader.add_event state "error" message
  in
  (match tui_settings.keeper_list_sort with
   | None -> ()
   | Some value ->
       (match Masc_tui_keeper_list_model.sort_of_string value with
        | Some sort -> state.keeper_list_sort <- sort
        | None -> note_keeper_preference_error ("Unknown saved Keeper order: " ^ value)));
  (match tui_settings.keeper_list_view with
   | None -> ()
   | Some value ->
       (match Masc_tui_keeper_list_model.view_of_string value with
        | Some view -> state.keeper_list_view <- view
        | None -> note_keeper_preference_error ("Unknown saved Keeper view: " ^ value)));
  (match tui_settings.keeper_list_density with
   | None -> ()
   | Some value ->
       (match Masc_tui_keeper_list_model.density_of_string value with
        | Some density -> state.keeper_list_density <- density
        | None -> note_keeper_preference_error ("Unknown saved Keeper density: " ^ value)));
  Option.iter
    (fun reason -> note_keeper_preference_error ("Keeper view preferences unavailable: " ^ reason))
    tui_settings.keeper_list_error
