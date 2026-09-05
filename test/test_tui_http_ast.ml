open Alcotest

(* A colour name is a violation wherever it is reached for, and the check is
   by name because it cannot be anything else: [module Raw = Ansi] followed
   by [Raw.red] resolves to the same colour, and no syntactic check sees
   through the alias. The guard's own fixtures pin that arrangement, so
   narrowing the rule to "only when the owner is spelled Ansi" would open it.

   One owner is exempt, by name. [Masc_tui_terminal_palette.red] does not
   choose a colour -- it asks an RGB value for its red channel -- and the
   guard reported it as a rule violation twice, both from the theme swatch
   added in #31212. A guard with false positives is worse than none: it
   teaches the reader that its output is noise, and the true ones go past
   with them. The exemption is one module and it is written down; anything
   wider would be the hole the fixtures exist to keep shut. *)
let is_reserved_status_color_segment = function
  | "red" | "yellow" | "green" | "Sgr" -> true
  | _ -> false
;;

let owns_colour_channels = function
  | "Masc_tui_terminal_palette" | "Terminal_palette" | "Palette" -> true
  | _ -> false
;;

let colour_path_violations ~reserved structure =
  let violations = ref [] in
  let inspect_path ({ txt; loc } : Longident.t Location.loc) =
    let path = Ast_grep.longident_to_string txt in
    let rec inspect = function
      (* Unqualified: the module was opened, so the colour is in scope by its
         bare name and this is the same reach for a raw token. *)
      | Longident.Lident segment ->
        if reserved segment then
          violations := (loc, path, segment) :: !violations
      | Longident.Ldot (prefix, segment) ->
        inspect prefix.txt;
        if
          reserved segment.txt
          && not (owns_colour_channels (Ast_grep.longident_leaf prefix.txt))
        then violations := (loc, path, segment.txt) :: !violations
      | Longident.Lapply (left, right) ->
        inspect left.txt;
        inspect right.txt
    in
    inspect txt
  in
  let iter =
    { Ast_iterator.default_iterator with
      expr =
        (fun self expression ->
          (match expression.Parsetree.pexp_desc with
           | Parsetree.Pexp_ident path
           | Parsetree.Pexp_construct (path, _)
           | Parsetree.Pexp_new path -> inspect_path path
           | Parsetree.Pexp_record (fields, _) ->
             List.iter (fun (path, _) -> inspect_path path) fields
           | Parsetree.Pexp_field (_, path)
           | Parsetree.Pexp_setfield (_, path, _) -> inspect_path path
           | _ -> ());
          Ast_iterator.default_iterator.expr self expression)
    ; pat =
        (fun self pattern ->
          (match pattern.Parsetree.ppat_desc with
           | Parsetree.Ppat_construct (path, _)
           | Parsetree.Ppat_type path
           | Parsetree.Ppat_open (path, _) -> inspect_path path
           | Parsetree.Ppat_record (fields, _) ->
             List.iter (fun (path, _) -> inspect_path path) fields
           | _ -> ());
          Ast_iterator.default_iterator.pat self pattern)
    ; module_expr =
        (fun self module_expr ->
          (match module_expr.Parsetree.pmod_desc with
           | Parsetree.Pmod_ident path -> inspect_path path
           | _ -> ());
          Ast_iterator.default_iterator.module_expr self module_expr)
    ; module_type =
        (fun self module_type ->
          (match module_type.Parsetree.pmty_desc with
           | Parsetree.Pmty_ident path | Parsetree.Pmty_alias path ->
             inspect_path path
           | _ -> ());
          Ast_iterator.default_iterator.module_type self module_type)
    ; typ =
        (fun self core_type ->
          (match core_type.Parsetree.ptyp_desc with
           | Parsetree.Ptyp_constr (path, _)
           | Parsetree.Ptyp_class (path, _)
           | Parsetree.Ptyp_open (path, _) -> inspect_path path
           | _ -> ());
          Ast_iterator.default_iterator.typ self core_type)
    ; package_type =
        (fun self package_type ->
          inspect_path package_type.Parsetree.ppt_path;
          List.iter
            (fun (path, _) -> inspect_path path)
            package_type.Parsetree.ppt_constraints;
          Ast_iterator.default_iterator.package_type self package_type)
    }
  in
  iter.structure iter structure;
  List.rev !violations
;;

let parse_status_color_fixture source =
  let lexbuf = Lexing.from_string source in
  Lexing.set_filename lexbuf "r8-status-color-fixture.ml";
  Parse.implementation lexbuf
;;

let status_color_violation_to_string (location, path, segment) =
  Printf.sprintf "%s:%d:%d: reserved %s in %s"
    location.Location.loc_start.pos_fname
    location.Location.loc_start.pos_lnum
    (location.Location.loc_start.pos_cnum
     - location.Location.loc_start.pos_bol
     + 1)
    segment path
;;

(* Four sites apply a theme, and each answers a different question: boot
   reads the name runtime.toml carries, the Config surface applies the one
   under the cursor, and the preview added by #31212 applies the scheme the
   cursor is passing over and then applies back whatever was in force when
   the reader walked in.

   The count is the point rather than the number. Anything past these is a
   further way to change the palette, which is how the surface came to apply
   on pageup/pagedown -- a key the footer never advertised, while it said
   "Enter: use theme" the whole time. When this fails, the question is not
   "what should the number be" but "what is the new site and does it belong".

   The number was 2 until the preview landed, and this test caught the change
   after the fact rather than before: #31212 merged red here. It is written
   down because a count that drifts silently stops being a gate.

   This counts; it does not prove Enter reaches the second one. The key press
   itself is not automated. *)
let reserved_status_color_path_violations structure =
  colour_path_violations ~reserved:is_reserved_status_color_segment structure
;;

(* The file list used to reach past the theme for all six of its type marks,
   and RFC-0427 moved them onto categorical slots. Zero is the count now, so
   it is the count from here: a surface that wants one of these hues asks the
   theme for a slot, which is the only form that moves when the terminal
   answers with its palette.

   Not folded into the status set above -- these are not status colours, and
   masc_tui_ansi.ml still names them where the slots are built. *)
let categorical_hue_segments =
  [ "blue"; "bright_blue"; "bright_cyan"; "bright_magenta"; "bright_yellow"
  ; "bright_green"; "bright_red"
  ]
;;

(* Deliberately open: [magenta] is still named at six sites in render.ml --
   a goal phase, a sandbox, a change badge and two context readings -- and
   each is an axis RFC-0427 has not moved yet. Closing the segment before
   moving them would fail the guard rather than the code. *)
let test_the_categorical_guard_rejects_a_raw_hue () =
  let violations source =
    source
    |> parse_status_color_fixture
    |> colour_path_violations ~reserved:(fun segment ->
         List.mem segment categorical_hue_segments)
  in
  if violations "let _ = Ansi.bright_blue" = [] then
    failf "the categorical guard let a raw hue through";
  if violations "let _ = Theme.category Theme.Slot_5" <> [] then
    failf "the categorical guard rejected a theme slot"
;;

let test_tui_render_asks_the_theme_for_a_categorical_hue () =
  let violations =
    Ast_grep.parse_implementation_or_fail "bin/masc_tui_render.ml"
    |> colour_path_violations ~reserved:(fun segment ->
         List.mem segment categorical_hue_segments)
  in
  match violations with
  | [] -> ()
  | _ ->
    failf
      "bin/masc_tui_render.ml names a categorical hue instead of a Theme slot:\n%s"
      (violations
       |> List.map status_color_violation_to_string
       |> String.concat "\n")
;;

let test_theme_apply_is_boot_and_the_surface () =
  check int "boot, the surface, and the preview's two" 4
    (Ast_grep.count_calls ~module_path:"bin/masc_tui.ml"
       ~callee:"Masc_tui_theme_choice.apply")
;;

let test_tui_status_colors_use_theme_tokens () =
  let violations =
    Ast_grep.parse_implementation_or_fail "bin/masc_tui_render.ml"
    |> reserved_status_color_path_violations
  in
  match violations with
  | [] -> ()
  | _ ->
    failf
      "bin/masc_tui_render.ml bypasses semantic Theme status tokens:\n%s"
      (violations
       |> List.map status_color_violation_to_string
      |> String.concat "\n")
;;

let test_tui_ansi_status_helpers_use_theme_tokens () =
  let module_path = "bin/masc_tui_ansi.ml" in
  let raw_status_identifiers =
    [ "red"
    ; "yellow"
    ; "green"
    ; "gray"
    ; "bright_red"
    ; "bright_yellow"
    ; "bright_green"
    ; "bright_black"
    ; "Ansi.red"
    ; "Ansi.yellow"
    ; "Ansi.green"
    ; "Ansi.gray"
    ; "Ansi.bright_red"
    ; "Ansi.bright_yellow"
    ; "Ansi.bright_green"
    ; "Masc_tui_theme.Sgr.red"
    ; "Masc_tui_theme.Sgr.yellow"
    ; "Masc_tui_theme.Sgr.green"
    ; "Masc_tui_theme.Sgr.gray"
    ; "Masc_tui_theme.Sgr.bright_red"
    ; "Masc_tui_theme.Sgr.bright_yellow"
    ; "Masc_tui_theme.Sgr.bright_green"
    ]
  in
  check int "the unused stringly status classifier is gone" 0
    (Ast_grep.count_value_bindings ~module_path ~name:"status_color");
  List.iter
    (fun binding_name ->
      check int (binding_name ^ " contains no direct raw status identifier") 0
        (Ast_grep.count_identifiers_outside_calls_in_value_binding ~module_path
           ~binding_name ~callees:[] ~identifiers:raw_status_identifiers))
    [ "priority_indicator"; "ctx_color"; "ctx_bar" ];
  check int "priority glyph has one owner" 1
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"priority_indicator"
       ~callee:"Masc_tui_theme.Glyph.priority");
  check int "the speaking priority uses the readable bad token" 1
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"priority_indicator" ~callee:"Theme.bad");
  (* Only the top priority speaks now; a warn-toned middle rank would mean
     the ladder grew back. *)
  check int "no warn-toned priority rank" 0
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"priority_indicator" ~callee:"Theme.warn");
  List.iter
    (fun (label, callee) ->
      check int ("context " ^ label ^ " tone has one owner") 1
        (Ast_grep.count_calls_in_value_binding ~module_path
           ~binding_name:"ctx_color" ~callee))
    [ "healthy", "Theme.muted"
    ; "pressure", "Theme.warn"
    ; "danger", "Theme.bad"
    ];
  check int "context tone reads the shared pressure projection" 1
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"ctx_color"
       ~callee:"Masc_tui_observation_layout.context_pressure");
  check int "the context bar consumes the shared tone once" 1
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"ctx_bar" ~callee:"ctx_color");
  check int "the context bar shares visible percentage rounding" 1
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"ctx_bar"
       ~callee:"Masc_tui_observation_layout.percentage_tenths");
  check int "the empty context bar recedes through the palette" 1
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"ctx_bar" ~callee:"Theme.recede");
  check int "the detail label shares visible percentage rounding" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render.ml"
       ~binding_name:"keeper_detail_pane"
       ~callee:"Observation_layout.percentage_tenths")
;;

(* The chat pane's role colours draw through the readable path, not out of the
   palette raw. Measured on twelve base16 schemes, the raw ones are where the
   pane loses rows: the Keeper's blue reads at 2.26:1 on default-light and the
   tool trail's bright black at 1.69:1 on Nord -- the row an operator scans to
   see what a keeper just did.

   The renderer guard cannot see this mapping because it lives in
   [masc_tui_ansi.ml], so this focused check requires every arm of [origin] to
   reach its resolved role token. *)
let test_chat_roles_draw_through_the_readable_path () =
  List.iter
    (fun callee ->
      check int
        (Printf.sprintf "chat origin resolves %s once" callee)
        1
        (Ast_grep.count_calls_in_value_binding
           ~module_path:"bin/masc_tui_ansi.ml" ~binding_name:"origin" ~callee))
    [ "Theme.user_origin"
    ; "Theme.keeper_origin"
    ; "Theme.quiet_origin"
    ; "Theme.warn"
    ; "Theme.bad"
    ]
;;

let test_tui_status_color_ast_guard_fixtures () =
  let expect_violation source =
    let violations =
      source
      |> parse_status_color_fixture
      |> reserved_status_color_path_violations
    in
    if violations = [] then
      failf "R8 AST guard did not reject fixture:\n%s" source
  in
  let expect_no_violation source =
    let violations =
      source
      |> parse_status_color_fixture
      |> reserved_status_color_path_violations
    in
    if violations <> [] then
      failf
        "R8 AST guard rejected semantic or literal fixture:\n%s\n%s"
        source
        (violations
         |> List.map status_color_violation_to_string
         |> String.concat "\n")
  in
  List.iter expect_violation
    [ "let _ = Ansi.red"
    ; "let _ = Ansi.yellow"
    ; "let _ = Ansi.green"
    ; "let _ = Masc_tui_theme.Sgr.red"
    ; "let _ = Ansi.(if failed then red else green)"
    ; "let _ = Ansi.((red))"
    ; "let _ = Theme.(* raw *)Sgr.(* raw *)red"
    ; "module Raw = (* raw *) Theme.Sgr"
    ; "module type Raw = Theme.Sgr"
    ; "open (* raw *) Theme.Sgr"
    ; "include (* raw *) Theme.Sgr"
    ; "module Raw = Ansi\nlet _ = Raw.red"
    ; "open Ansi\nlet _ = red"
    ; "let _ = value.Theme.red"
    ; "let _ = { Theme.red = value }"
    ; "let read = function { Theme.red = value } -> value"
    ; "let read = function Sgr.Constructor -> ()"
    ; "type raw = Theme.Sgr.t"
    ; "type raw = Theme.Sgr.(t)"
    ; "type raw = #Theme.Sgr.c"
    ; "type packed = (module Theme.Sgr)"
    ; "type packed = (module S with type Theme.Sgr.t = int)"
    ];
  List.iter expect_no_violation
    [ "let _ = Theme.ok"
    ; "let _ = Theme.warn"
    ; "let _ = Theme.bad"
    ; "let _ = Theme.Syntax.keyword"
    ; "let _ = Theme.Syntax.string"
    ; "let _ = Theme.Syntax.diff_added_bg"
    ; "let _ = Ansi.bold ^ Ansi.blue ^ Ansi.reset"
    ; "module Raw = Ansi"
    ; "open Ansi"
    ; "include Ansi"
    ; "let greenish = redacted + yellow_status"
    ; "type 'red marker = Marker"
    ; "type 'green marker = Marker"
    ; "type 'yellow marker = Marker"
    ; "let _ = \"Theme.Sgr.red; open Ansi\""
    ; "let _ = 'r'"
    ; "let _ = {| Theme.Sgr.green; include Ansi |}"
    ; "let _ = {tag_name| Ansi.yellow |tag_name}"
    ; "let _ = {%foo| Theme.Sgr.red |}"
    ; "let _ = {%foo.bar tag_name| Ansi.yellow |tag_name}"
    ; "{%%foo| Theme.Sgr.red |}"
    ; "{%%foo.bar tag_name| Ansi.green |tag_name}"
    ; "(* Theme.Sgr.red (* nested open Ansi *) *) let _ = Theme.ok"
    ; "(* \"(*\" *) let _ = Theme.ok"
    ; "(* {| *) |} *) let _ = Theme.ok"
    ; "let éred = 1\nlet _ = éred"
    ; "type 'éred marker = Marker"
    ; "let _ = {é| Theme.Sgr.red |é}"
    ]
;;

let test_is_success_http_status_called () =
  let n =
    Ast_grep.count_calls
      ~module_path:"bin/masc_tui_http.ml"
      ~callee:"Masc.Tui_decode.is_success_http_status"
  in
  if n < 1 then
    failf
      "bin/masc_tui_http.ml must call Masc.Tui_decode.is_success_http_status for raw body responses; got %d"
      n
;;

let test_http_get_uses_auth_headers () =
  let n =
    Ast_grep.count_calls
      ~module_path:"bin/masc_tui_http.ml"
      ~callee:"auth_headers"
  in
  if n < 3 then
    failf
      "bin/masc_tui_http.ml must call auth_headers >= 3; got %d"
      n
;;

let test_http_client_does_not_own_tui_env_contract () =
  let module_path = "bin/masc_tui_http.ml" in
  check int "no local TUI env literals" 0
    (Ast_grep.count_string_literals ~module_path ~needle:"MASC_TUI_");
  check int "no ambient agent env fallback" 0
    (Ast_grep.count_string_literals ~module_path ~needle:"MASC_AGENT");
  check int "no local timeout env accessor" 0
    (Ast_grep.count_calls ~module_path ~callee:"Env_config_core.get_float_nonneg");
  check int "no local timeout env binding" 0
    (Ast_grep.count_value_bindings ~module_path ~name:"timeout_env")
;;

let test_keeper_chat_uses_current_async_contract () =
  let module_path = "bin/masc_tui.ml" in
  check int "TUI keeper chat has no removed models field" 0
    (Ast_grep.count_string_literals ~module_path ~needle:"models");
  check int "TUI targets the keeper chat stream once" 1
    (Ast_grep.count_string_literals
       ~module_path:"bin/masc_tui_http.ml"
       ~needle:"/api/v1/keepers/chat/stream");
  check int "request projection owns the required request id field" 1
    (Ast_grep.count_string_literals
       ~module_path:"bin/masc_tui_keeper_chat_projection.ml"
       ~needle:"request_id");
  check int "blocking send helper is gone" 0
    (Ast_grep.count_value_bindings ~module_path ~name:"send_keeper_message");
  check int "permissive whole-body decoder is not used by the TUI" 0
    (Ast_grep.count_calls_across_files
       ~module_paths:[ "bin/masc_tui.ml"; "bin/masc_tui_http.ml" ]
       ~callee:"Tui_decode.parse_keeper_chat_response");
  check bool "chat POST has a finite request deadline" true
    (Ast_grep.count_calls_with_label
       ~module_path:"bin/masc_tui_http.ml"
       ~callee:"Masc_http_client.post_sync" ~label:"timeout_sec"
     >= 1);
  (* The streaming send deliberately has no wall-clock cap -- one would cancel
     a turn that is still emitting. Its bound is silence, so that is the one to
     pin: without it a quiet turn parks the dispatch fiber for good. *)
  check bool "chat stream has a finite silence bound" true
    (Ast_grep.count_calls_with_label
       ~module_path:"bin/masc_tui_http.ml"
       ~callee:"Masc_http_client.post_stream" ~label:"idle_timeout_sec"
     >= 1);
  check int "chat send does not keep the root switch alive on exit" 0
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"launch_keeper_request" ~callee:"Eio.Fiber.fork");
  check bool "chat send runs in a cancellable daemon fiber" true
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"launch_keeper_request" ~callee:"Eio.Fiber.fork_daemon"
     >= 1);
  check bool "async completion checks request identity" true
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"apply_keeper_chat_result"
       ~callee:"Keeper_chat.same_request_identity"
     >= 1);
  (* The pane draws the durable transcript merged with this session's rows.
     Reading state.msg_history directly is what it did when the scrollback was
     session-only, and going back to that would silently drop the saved
     conversation while everything still compiled. *)
  (* A held tool call expires. Its prompt lives in the chat pane, so an
     operator on any other surface would lose the call without ever seeing it
     was waiting. The composer line is the one row every surface draws, which
     is why the notice goes there -- drawing it only in the chat pane is the
     bug this pins. *)
  check bool "every surface says when a keeper is holding a call" true
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render.ml" ~binding_name:"composer_line"
       ~callee:"awaiting_approval_notice"
     >= 1);
  check bool "the chat pane draws the merged transcript" true
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render.ml" ~binding_name:"render_keeper_message"
       ~callee:"chat_rows_for"
     >= 1);
  check int "the chat pane draws exactly one shared status footer" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render.ml"
       ~binding_name:"render_keeper_message" ~callee:"footer_line");
  check bool "draft cleanup checks Keeper and message identity" true
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"consume_dispatched_message_draft" ~callee:"String.equal"
     >= 3);
  check bool "dispatch lock waits for main-state acknowledgement" true
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"enqueue_dispatch_ack" ~callee:"Eio.Promise.await"
     >= 1);
  check bool "HTTP projection preserves stream acceptance provenance" true
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_http.ml"
       ~binding_name:"post_keeper_chat"
       ~callee:"Masc_tui_keeper_chat_projection.decode_response_with_provenance"
     >= 1);
  let render_path = "bin/masc_tui_render.ml" in
  List.iter
    (fun callee ->
      check bool ("message renderer wires " ^ callee) true
        (Ast_grep.count_calls_in_value_binding ~module_path:render_path
           ~binding_name:"render_keeper_message" ~callee
         >= 1))
    (* [Ansi.move_to] is gone from this binding on purpose: the renderer no
       longer writes a cursor escape inline. It hands the position to
       [finish_frame_with_strip ~cursor:...], and the frame presenter emits the
       move when it paints. Asserting the old escape here
       would pin the pre-differential-frame renderer.

       [Message_layout.input_cursor_row] is gone for a related reason: it
       predicted the caret's row by repeating the pane's layout arithmetic,
       which only stayed true while every row the pane drew was also counted
       in the row budget. The renderer now reads the rows it has already put
       in the frame, so [frame_lines] is what this list pins instead. *)
    [ "Message_layout.input_viewport"
    ; "frame_lines"
    ; "Message_layout.input_cursor_column"
    ; "Message_layout.message_viewport_supported"
      (* Renamed by #30141, which put a surface strip above every frame.  The
         assertion is that the renderer still hands its rows to the frame
         presenter rather than painting them itself, and that is what the new
         name does. *)
    ; "finish_frame_with_strip"
    ];
  check bool "message input uses the same viewport gate as rendering" true
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"keeper_message_input_supported"
       ~callee:"Masc_tui_message_layout.message_viewport_supported"
     >= 1);
  check bool "main loop suppresses unsupported message input" true
    (Ast_grep.count_calls_in_value_binding ~module_path ~binding_name:"main"
       ~callee:"keeper_message_input_supported"
     >= 1);
  check bool "compact viewport still recognizes recovery control input" true
    (Ast_grep.count_calls_in_value_binding ~module_path ~binding_name:"main"
       ~callee:"Char.code"
     >= 1)
;;

let test_user_message_background_has_one_render_snapshot () =
  let main_path = "bin/masc_tui.ml" in
  let render_path = "bin/masc_tui_render.ml" in
  let ansi_path = "bin/masc_tui_ansi.ml" in
  check int "late palette publication clears its callback before use" 1
    (Ast_grep.count_field_clears_to_none ~module_path:main_path
       ~binding_name:"take_late_palette_publisher"
       ~field_name:"late_palette_publisher");
  check int "late palette helper gates on its one-shot publisher" 1
    (Ast_grep.count_field_accesses_outside_calls_in_value_binding
       ~module_path:main_path ~binding_name:"publish_late_terminal_palette"
       ~callees:[] ~fields:[ "late_palette_publisher" ]);
  check int "late palette helper reads the O(1) decoder palette" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"publish_late_terminal_palette"
       ~callee:"Masc_tui_terminal_probe.palette");
  check int "late palette helper consumes the one-shot publisher" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"publish_late_terminal_palette"
       ~callee:"take_late_palette_publisher");
  check int "input checks publication after next and before probe removal" 3
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"take_input_byte"
       ~callee:"publish_late_terminal_palette");
  check int "late publication updates the palette authority" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"install_late_palette_publisher"
       ~callee:"Masc_tui_terminal_palette.set_current");
  check int "late publication requests one full repaint" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"install_late_palette_publisher"
       ~callee:"request_full_repaint");
  check int "startup has one conditional late publisher installation" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"main" ~callee:"install_late_palette_publisher");
  check int "Chat theme reads one atomic palette snapshot" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:ansi_path
       ~binding_name:"snapshot" ~callee:"Masc_tui_terminal_palette.snapshot");
  check int "Chat theme publishes one generation-keyed cache update" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:ansi_path
       ~binding_name:"snapshot" ~callee:"Atomic.compare_and_set");
  check int "Chat theme projects the semantic background only on a cache miss"
    1
    (Ast_grep.count_calls_in_value_binding ~module_path:ansi_path
       ~binding_name:"snapshot"
       ~callee:"Masc_tui_theme.user_message_background");
  check int "only the two User contexts read the palette generation" 2
    (Ast_grep.count_field_accesses_outside_calls_in_value_binding
       ~module_path:ansi_path ~binding_name:"body_context" ~callees:[]
       ~fields:[ "palette_generation" ]);
  check int "one palette snapshot spans layout and draw" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:render_path
       ~binding_name:"render_keeper_message" ~callee:"Chat_theme.snapshot");
  check int "layout receives the captured Chat theme" 1
    (Ast_grep.count_applications_with_exact_labelled_identifiers_in_value_binding
       ~module_path:render_path ~binding_name:"render_keeper_message"
       ~callee:"cached_chat_markdown" ~arguments:[ "theme", "chat_theme" ]);
  check int "visible drawing receives the captured Chat theme" 1
    (Ast_grep.count_applications_with_exact_labelled_identifiers_in_value_binding
       ~module_path:render_path ~binding_name:"render_keeper_message"
       ~callee:"render_chat_row" ~arguments:[ "theme", "chat_theme" ]);
  check int "layout derives one body context per entry" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:render_path
       ~binding_name:"cached_chat_markdown"
       ~callee:"Chat_theme.body_context");
  check int "draw derives one body context per row" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:render_path
       ~binding_name:"render_chat_row" ~callee:"Chat_theme.body_context");
  check int "cache key reads the role-aware palette generation" 1
    (Ast_grep.count_field_accesses_outside_calls_in_value_binding
       ~module_path:render_path ~binding_name:"cached_chat_markdown" ~callees:[]
       ~fields:[ "palette_generation" ]);
  (* The folded-origin margin changes several attributes, so it still closes
     by fully restoring the captured row. A bare link has a narrower typed
     closer below: resetting it would cut an enclosing diff background. *)
  check int "the margin fully restores the captured row" 1
    (Ast_grep.count_field_accesses_outside_calls_in_value_binding
       ~module_path:render_path ~binding_name:"render_chat_row" ~callees:[]
       ~fields:[ "inline_restore" ]);
  check int "the link uses its selective row restore" 1
    (Ast_grep.count_field_accesses_outside_calls_in_value_binding
       ~module_path:render_path ~binding_name:"render_chat_row" ~callees:[]
       ~fields:[ "link_restore" ]);
  check int "the selective closer turns off underline" 1
    (Ast_grep.count_identifiers_outside_calls_in_value_binding
       ~module_path:ansi_path ~binding_name:"link_style_restore" ~callees:[]
       ~identifiers:[ "Ansi.no_underline" ]);
  check int "the selective closer restores the row foreground" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:ansi_path
       ~binding_name:"link_style_restore" ~callee:"link_foreground");
  check int "Status links restore the warning foreground" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:ansi_path
       ~binding_name:"link_foreground" ~callee:"Theme.warn");
  check int "Error links restore the error foreground" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:ansi_path
       ~binding_name:"link_foreground" ~callee:"Theme.bad");
  check int "neutral links restore only the default foreground" 1
    (Ast_grep.count_identifiers_outside_calls_in_value_binding
       ~module_path:ansi_path ~binding_name:"link_foreground" ~callees:[]
       ~identifiers:[ "Ansi.default_fg" ]);
  check int "the selective closer never resets the enclosing row" 0
    (Ast_grep.count_identifiers_outside_calls_in_value_binding
       ~module_path:ansi_path ~binding_name:"link_style_restore" ~callees:[]
       ~identifiers:[ "Ansi.reset" ]);
  check int "both chat diff rows use the paired foreground" 2
    (Ast_grep.count_identifiers_outside_calls_in_value_binding
       ~module_path:render_path ~binding_name:"chat_markdown_palette"
       ~callees:[] ~identifiers:[ "Theme.Syntax.diff_row_foreground" ]);
  check int "chat diff rows do not borrow the terminal default foreground" 0
    (Ast_grep.count_identifiers_outside_calls_in_value_binding
       ~module_path:render_path ~binding_name:"chat_markdown_palette"
       ~callees:[] ~identifiers:[ "Ansi.default_fg" ]);
  check int "Markdown palette has no hard-coded reset closer" 0
    (Ast_grep.count_identifiers_outside_calls_in_value_binding
       ~module_path:render_path ~binding_name:"chat_markdown_palette"
       ~callees:[] ~identifiers:[ "Ansi.reset" ]);
  List.iter
    (fun binding_name ->
      check int (binding_name ^ " restores the captured Markdown context") 1
        (Ast_grep.count_field_accesses_outside_calls_in_value_binding
           ~module_path:render_path ~binding_name ~callees:[]
           ~fields:[ "markdown_close" ]))
    [ "chat_markdown"; "chat_markdown_streaming" ]
;;

let test_operator_approvals_use_current_contract () =
  check int "operator summary endpoint is exact" 1
    (Ast_grep.count_string_literals
       ~module_path:"bin/masc_tui_http.ml"
       ~needle:
         "/api/v1/operator?view=summary&include_messages=0&include_keepers=0");
  check bool "loader uses exact operator projection" true
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui_loader.ml"
       ~callee:"Masc_tui_operator_projection.decode_snapshot"
     >= 1);
  check bool "semantic action status is checked" true
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui_http.ml"
       ~callee:"Masc_tui_operator_projection.decode_confirm_response"
     >= 1);
  check bool "submitted token is bound into response validation" true
    (Ast_grep.count_calls_with_label
       ~module_path:"bin/masc_tui_http.ml"
       ~callee:"Masc_tui_operator_projection.decode_confirm_response"
       ~label:"expected_token"
     >= 1);
  check bool "submitted decision is bound into response validation" true
    (Ast_grep.count_calls_with_label
       ~module_path:"bin/masc_tui_http.ml"
       ~callee:"Masc_tui_operator_projection.decode_confirm_response"
       ~label:"expected_decision"
     >= 1);
  check bool "HTTP refresh and action reconciliation reload approvals" true
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui.ml"
       ~callee:"load_approvals"
     >= 2);
  check bool "refreshes reserve an approval generation" true
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui.ml"
       ~callee:"Approval.Flow.reserve_refresh"
     >= 1);
  check bool "actions invalidate older approval generations" true
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui.ml"
       ~callee:"Approval.Flow.begin_action"
     >= 1);
  check bool "only the owning action completion clears inflight state" true
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui.ml"
       ~callee:"Approval.Flow.finish_action"
     >= 1);
  check bool "approval input uses the behavior-tested two-key gate" true
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui.ml"
       ~callee:"Approval.approval_gate_transition"
     >= 1);
  check int "approval receipt reads one typed presentation result" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui.ml"
       ~binding_name:"present_frame"
       ~callee:"Frame_presenter.present");
  check int "approval receipt has one post-presentation commit" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui.ml"
       ~binding_name:"present_frame"
       ~callee:"commit_presented_approval");
  check int "presentation compares typed approval authority" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui.ml"
       ~binding_name:"present_frame"
       ~callee:"Approval_authority.authority_changed");
  check int "approval effects reconcile against the current typed list" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui.ml"
       ~binding_name:"answer_presented_approval"
       ~callee:"approval_items");
  check int "approval effects never reselect by mutable cursor" 0
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui.ml"
       ~binding_name:"answer_presented_approval"
       ~callee:"List.nth_opt");
  check int "approval effects require the presented typed identity" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui.ml"
       ~binding_name:"answer_presented_approval"
       ~callee:"Approval_authority.resolve");
  check int "presented operator rows keep the confirmation gate" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui.ml"
       ~binding_name:"answer_presented_approval"
       ~callee:"handle_approval_decision");
  check int "presented Keeper rows keep their exact call identity" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui.ml"
       ~binding_name:"answer_presented_approval"
       ~callee:"launch_surface_tool_approval");
  check int "Gate rejection collects its required reason in the editor" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui.ml"
       ~binding_name:"reject_gate_approval"
       ~callee:"Masc_tui_editor.roundtrip");
  check int "Gate rejection resolves the presented approval after collecting a reason" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui.ml"
       ~binding_name:"reject_gate_approval"
       ~callee:"launch_gate_resolve");
  check int "normal approval rendering emits one typed receipt" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render.ml"
       ~binding_name:"render"
       ~callee:"approval_items");
  check int "approval refresh preserves selected token identity" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui.ml"
       ~binding_name:"apply_approvals_load"
       ~callee:"Approval.reconcile_cursor");
  check int "deferred confirmation has truthful operator copy" 1
    (Ast_grep.count_string_literals
       ~module_path:"bin/masc_tui.ml"
       ~needle:"Confirmation accepted; action deferred: %s");
  check int "execution failure preserves accepted confirmation" 1
    (Ast_grep.count_string_literals
       ~module_path:"bin/masc_tui.ml"
       ~needle:"Confirmation accepted; action failed: %s");
  check int "transport failure remains unverified" 1
    (Ast_grep.count_string_literals
       ~module_path:"bin/masc_tui.ml"
       ~needle:"Confirmation outcome unverified");
  check int "payload has its own visible row" 1
    (Ast_grep.count_string_literals
       ~module_path:"bin/masc_tui_render.ml"
       ~needle:"  %spayload=%s%s");
  check bool "approval renderer sanitizes direct external text" true
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render.ml"
       ~binding_name:"render_approvals"
       ~callee:"Terminal_text.single_line"
     >= 7);
  (* A floor, like the [single_line] check above it, not an exact count. What
     this protects is that optional external text reaches the terminal
     sanitised; sanitising one more field is the behaviour it wants, and an
     exact count failed on it -- #30518 added two and took main red. Dropping
     below the floor is the real risk, and a floor still catches that. *)
  check bool "approval renderer sanitizes optional text with defaults" true
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render.ml"
       ~binding_name:"render_approvals"
       ~callee:"Terminal_text.single_line_or"
     >= 3);
  (* A floor for the same reason as its two neighbours, and it is the last of
     the three to become one. The surface now sanitises two optional errors
     rather than one -- [gate_error] when the Gate lanes will not read, and
     [approvals_error] when the list will not -- and both are external text
     reaching a terminal, so both belong. An exact count called the second one
     a regression.

     The distinction worth keeping: an exact count is right where a new call
     site is a new way to do something, which is why the theme-apply check
     above stays exact -- a fourth [apply] is a fourth way to change the
     palette and the reader should be made to say why. Here more is the
     behaviour the rule wants, and only fewer is the failure. *)
  (* The name column is measured, not chosen. Sixteen cells cut
     "rw-e0-r9-20260820-review" to "rw-e0-r9-202608~", and two keepers whose
     names share a long prefix then read alike -- which is the column's whole
     job. The pre-pass that measures them is the [display_width] call; a
     return to a fixed width takes it with it. *)
  (* The Tools header names its skills instead of serialising them. It used
     [Skill_reference.list_to_yojson] and then let the line's width cut the
     result, so the header read [{"identity":{"source_id":"project-masc"~] --
     sixty characters answering nothing, where a reader looks first, about
     skills the same screen lists by name a few rows below.

     A return to the wire form brings the call back with it. *)
  check int "the tools header does not serialise its skills" 0
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render.ml"
       ~binding_name:"tools_display_lines"
       ~callee:"Skill_reference.list_to_yojson");
  check bool "approval renderer measures its name column" true
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render.ml"
       ~binding_name:"render_approvals"
       ~callee:"Message_layout.display_width"
     >= 1);
  check bool "approval renderer sanitizes optional error text" true
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render.ml"
       ~binding_name:"render_approvals"
       ~callee:"Terminal_text.optional_single_line"
     >= 1);
  check int "terminal text boundary delegates to the typed sanitizer" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_ansi.ml"
       ~binding_name:"single_line"
       ~callee:"Masc.Tui_decode.sanitize_terminal_text");
  check int "approval payload uses its terminal projection" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render.ml"
       ~binding_name:"render_approvals"
       ~callee:
         "Masc_tui_operator_projection.approval_payload_for_terminal");
  check int "approval payload projection serializes once" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_operator_projection.ml"
       ~binding_name:"approval_payload_for_terminal"
       ~callee:"Yojson.Safe.to_string");
  check int "approval payload projection sanitizes once" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_operator_projection.ml"
       ~binding_name:"approval_payload_for_terminal"
       ~callee:"Masc.Tui_decode.sanitize_terminal_text");
  check int "approval renderer never serializes a raw payload" 0
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render.ml"
       ~binding_name:"render_approvals"
       ~callee:"Yojson.Safe.to_string");
  (* Seven: [state.workspace], each row's [ov_cluster] / [ov_project], the
     agent [ai_summary], the event content, and the transport tail's
     [th_primary_path] / [th_queue_pressure]. Every one arrives from outside
     the renderer. A failed transport read needs no projection of its own; it
     reaches the operator through the Recent Events row the surface error
     already writes. *)
  check int "overview event text crosses the terminal boundary" 5
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render.ml"
       ~binding_name:"render_overview"
       ~callee:"Terminal_text.single_line");
  check int "briefing is not an approval source" 0
    (Ast_grep.count_string_literals
       ~module_path:"bin/masc_tui_loader.ml"
       ~needle:"pending_confirms")
;;

let test_planning_constructors_do_not_collide () =
  let module_path = "bin/masc_tui_types.ml" in
  let planning_mode_constructors =
    Ast_grep.constructor_names_of_type ~module_path ~type_name:"planning_mode"
  in
  let surface_constructors =
    Ast_grep.constructor_names_of_type ~module_path ~type_name:"surface"
  in
  check bool "planning sub-mode does not reuse top-level Planning" false
    (List.mem "Planning" planning_mode_constructors);
  check bool "planning list sub-mode explicit" true
    (List.mem "Planning_list" planning_mode_constructors);
  check bool "planning detail sub-mode explicit" true
    (List.mem "Planning_detail" planning_mode_constructors);
  check bool "top-level Planning surface remains" true
    (List.mem "Planning" surface_constructors)
;;

let test_planning_phase_uses_goal_ssot () =
  check bool "projection parses the canonical goal phase" true
    (Ast_grep.count_calls
       ~module_path:"lib/tui_decode.ml"
       ~callee:"Goal_phase.parse"
     >= 1);
  check bool "loader uses the behavioral planning decoder" true
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui_loader.ml"
       ~callee:"Tui_decode.decode_planning_snapshot"
     >= 1);
  check bool "renderer labels the canonical goal phase" true
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui_render.ml"
       ~callee:"Goal_phase.to_string"
     >= 1);
  check int "renderer does not lowercase planning status strings" 0
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui_render.ml"
       ~callee:"String.lowercase_ascii");
  check int "projection rejects an unknown canonical phase" 1
    (Ast_grep.count_string_literals
       ~module_path:"lib/tui_decode.ml"
       ~needle:"unknown planning goal phase")
;;

let test_tui_current_projection_wiring () =
  check int "task loader is a named canonical-backlog projection" 1
    (Ast_grep.count_value_bindings
       ~module_path:"bin/masc_tui_loader.ml"
       ~name:"load_active_tasks");
  check bool "task loader uses the canonical backlog observation" true
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui_loader.ml"
       ~callee:"Workspace_backlog.read_backlog_observation_with_source_r"
     >= 1);
  check bool "loader uses the behavior-tested active task projection" true
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui_loader.ml"
       ~callee:"Tui_decode.active_tasks_of_domain"
     >= 1);
  check int "task row projection has one domain boundary" 1
    (Ast_grep.count_value_bindings
       ~module_path:"lib/tui_decode.ml"
       ~name:"task_of_domain");
  check bool "keeper loader uses canonical persisted-name classification" true
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui_loader.ml"
       ~callee:"Keeper_meta_store.persisted_keeper_names_result"
     >= 1);
  check bool "keeper loader uses the typed current-schema store" true
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui_loader.ml"
       ~callee:"Keeper_meta_store.read_meta"
     >= 1);
  check bool "keeper loader projects typed metadata" true
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui_loader.ml"
       ~callee:"Tui_decode.keeper_of_meta"
     >= 1);
  check bool "keeper metrics use the cluster-aware canonical path" true
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_loader.ml"
       ~binding_name:"load_selected_keeper_logs"
       ~callee:"Keeper_types_support.keeper_metrics_store"
     = 1);
  check bool "keeper metrics use the strict bounded physical tail" true
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_metrics_tail.ml" ~binding_name:"load"
       ~callee:"Dated_jsonl.read_recent_result"
     = 1);
  check int "selected Keeper identity reaches the metrics decoder" 1
    (Ast_grep.count_calls_with_label
       ~module_path:"bin/masc_tui_loader.ml"
       ~callee:"Metrics_tail.load" ~label:"expected_keeper");
  (* #30658 put every call site behind a workspace-identity gate, so the
     invariant moved with it. Counting the raw loader name now passes on the
     single call inside that wrapper while the gate itself goes unguarded, so
     the count follows the name the sites actually reach for, and a second
     check pins the wrapper as the only way through. *)
  check bool "all log interactions use the identity-gated Keeper loader" true
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui.ml"
       ~callee:"load_keeper_logs_if_safe"
     >= 3);
  check int "the gate is the only caller of the raw Keeper log loader" 1
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui.ml"
       ~callee:"load_selected_keeper_logs");
  (* Where that one call sits, not just that there is one. Emptying the gate's
     body and calling the loader from anywhere else keeps the count at one and
     reads every workspace's logs. (From #30681, which reached the pair above
     independently and saw the gap this closes.) *)
  check int "and the gate is where that call sits" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui.ml"
       ~binding_name:"load_keeper_logs_if_safe"
       ~callee:"load_selected_keeper_logs");
  check int "Board list success uses shared post replacement" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui.ml" ~binding_name:"apply_board_list_load"
       ~callee:"replace_board_posts");
  (* Detail success deliberately does *not* go through the shared replacement.
     That helper reranks the list, and reranking on a detail response made rapid
     j/k navigation snap back to row zero as answers arrived (#30409). A detail
     response enriches one row; it does not decide the order. Pinned at zero so
     that putting the call back has to come with a new answer for that. *)
  check int "Board detail success does not rerank the list" 0
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui.ml" ~binding_name:"apply_board_post_load"
       ~callee:"replace_board_posts");
  check int "Board post replacement reconciles selection once" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui.ml" ~binding_name:"replace_board_posts"
       ~callee:"Board_selection.reconcile_cursor");
  check int "Board detail starts through the generation-aware projection" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui.ml"
       ~binding_name:"start_board_post_refresh"
       ~callee:"Board_detail.start");
  (* Two identity comparisons, and both have to stay. The guard refuses a
     response carrying a different post than the one asked for; the in-place
     map then picks the row to enrich (#30409 replaced a reranking call with
     it). Counting them together is what this can see, so the count moves when
     either one goes. *)
  check int "Board detail success compares the post identity twice" 2
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui.ml" ~binding_name:"apply_board_post_load"
       ~callee:"String.equal");
  check int "Board detail completion remains valid away from the Board tab" 0
    (Ast_grep.count_field_accesses_outside_calls_in_value_binding
       ~module_path:"bin/masc_tui.ml"
       ~binding_name:"board_detail_request_still_current" ~callees:[]
       ~fields:[ "view" ]);
  (* [board_read_pane], not [render_board_read]: #30255 split the surface the
     way #30146 split keeper detail, so the frame picks the layout and the
     pane draws the content. Everything these guards watch -- the detail
     selection, the shared row allocation, the single scroll projection, the
     sanitised post fields -- went with the content. Nothing is left in the
     frame, so pointing them at the old name read one move as six
     regressions. *)
  check int "Board renderer selects detail by post identity" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render.ml"
       ~binding_name:"board_read_pane"
       ~callee:"Board_detail.view_for");
  check bool "metadata refresh reconciles the selected log identity" true
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_loader.ml"
       ~binding_name:"load_from_masc_dir"
       ~callee:"Metrics_tail.reconcile_selection"
     = 1);
  check bool "metrics diagnostics are terminal-safe before rendering" true
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render.ml"
       ~binding_name:"render_keeper_logs"
       ~callee:"Keeper_chat.terminal_safe_text"
     >= 1);
  check bool "log input uses viewport-bounded scrolling" true
    (Ast_grep.count_calls_across_files
       ~module_paths:[ "bin/masc_tui.ml" ]
       ~callee:"Metrics_tail.scroll_up"
     = 1
     && Ast_grep.count_calls_across_files
          ~module_paths:[ "bin/masc_tui.ml" ]
          ~callee:"Metrics_tail.scroll_down"
        = 1);
  List.iter
    (fun retired ->
      check int ("retired raw metrics helper absent: " ^ retired) 0
        (Ast_grep.count_value_bindings
           ~module_path:"bin/masc_tui_loader.ml" ~name:retired))
    [ "read_last_lines"; "parse_log_entry"; "find_metrics_files"; "load_keeper_logs" ];
  check bool "Keeper log rows use the current typed discriminator" true
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"lib/tui_decode.ml" ~binding_name:"decode_log_entry"
       ~callee:"Keeper_metrics_record.kind_of_json"
     = 1);
  check bool "live context uses the trace-scoped TurnRecord projection" true
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_context_state.ml" ~binding_name:"load"
       ~callee:"Projection.context_fields"
     = 1);
  check bool "loader applies the behavior-tested selection transition" true
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_loader.ml"
       ~binding_name:"load_selected_live_context"
       ~callee:"Context_state.for_selection"
     = 1);
  check int "keeper detail reads context through the Keeper stamp" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render.ml"
       ~binding_name:"keeper_detail_pane"
       ~callee:"Context_state.reading_for_keeper");
  check int "chat header reads context through the Keeper stamp" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render.ml"
       ~binding_name:"render_keeper_message"
       ~callee:"Context_state.reading_for_keeper");
  check int "chat header uses one measured context item projection" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render.ml"
       ~binding_name:"render_keeper_message"
       ~callee:"Observation_layout.context_header_item");
  (* The budget handed to the context item must come from measured cells, or
     a CJK title (two cells per character) overflows the box and [box_line]
     cuts a reading into a different statement. Counting every
     [display_width] in this binding froze the header's shape instead: the
     identity budget measures here too, so adding a header segment moved the
     total and failed a contract it never touched. Bind the measurement to
     the argument that needs it. *)
  check int "chat context item measures the actual header budget" 1
    (Ast_grep.count_applications_with_label_containing_call_in_value_binding
       ~module_path:"bin/masc_tui_render.ml"
       ~binding_name:"render_keeper_message"
       ~callee:"Observation_layout.context_header_item" ~label:"max_cells"
       ~nested_callee:"Message_layout.display_width");
  check bool "log diagnostics remain operator-visible" true
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render.ml"
       ~binding_name:"render_keeper_logs"
       ~callee:"Metrics_tail.error_to_string"
     = 1);
  check bool "log empty copy distinguishes typed outcomes" true
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render.ml"
       ~binding_name:"render_keeper_logs"
       ~callee:"Metrics_tail.empty_message"
     = 1);
  (* Exact, not substring: the retired alias is the whole key "running", and
     the fleet reading legitimately holds "running_keeper_fiber_count".
     Scoped to the planning decoders, not the file: the alias was theirs, and
     other readers in this module spell the same word for their own reasons --
     [Fusion_running] serialises to it (#30079). A file-wide count read those
     as the retired alias returning. *)
  List.iter
    (fun binding_name ->
      check int
        (Printf.sprintf "retired planning running alias absent from %s" binding_name)
        0
        (Ast_grep.count_exact_string_literals_in_value_binding
           ~module_path:"lib/tui_decode.ml"
           ~binding_name
           ~needle:"running"))
    [ "decode_planning_goal"
    ; "decode_planning_rollup"
    ; "decode_planning_backlog"
    ; "decode_planning_snapshot"
    ];
  (* [proactive_enabled] left the keeper detail row in #29311, and that row is
     now built from [Keeper_meta_contract] rather than raw keys, so it cannot
     come back through it. The one literal left is [decode_keeper_runtime],
     which reads GET /api/v1/gate/keepers -- a live route, not the durable
     metadata the retirement was about. Counted, so a second reader still
     fails. *)
  check int "proactive_enabled is read only by decode_keeper_runtime" 1
    (Ast_grep.count_string_literals
       ~module_path:"lib/tui_decode.ml"
       ~needle:"proactive_enabled");
  check int "verify appears only inside verifying_count" 1
    (Ast_grep.count_string_literals
       ~module_path:"lib/tui_decode.ml"
       ~needle:"verify");
  List.iter
    (fun retired ->
       check int ("retired keeper field absent: " ^ retired) 0
         (Ast_grep.count_string_literals
            ~module_path:"lib/tui_decode.ml"
            ~needle:retired))
    [ "active_goal_ids"
    ; "active_model"
    ; "models"
    ; "initiative_enabled"
    ; "trigger_mode"
    ; "context_budget"
    ; "drift_enabled"
    ]
;;

let test_overview_state_domains_are_closed_sum () =
  let workspace_health_constructors =
    Ast_grep.constructor_names_of_type
      ~module_path:"bin/masc_tui_types.ml"
      ~type_name:"workspace_health"
  in
  let attention_severity_constructors =
    Ast_grep.constructor_names_of_type
      ~module_path:"bin/masc_tui_types.ml"
      ~type_name:"attention_severity"
  in
  check (list string) "workspace health constructors"
    [
      "Workspace_health_critical";
      "Workspace_health_bad";
      "Workspace_health_risk";
      "Workspace_health_warning";
      "Workspace_health_degraded";
      "Workspace_health_initializing";
      "Workspace_health_ok";
      "Workspace_health_unknown";
    ]
    workspace_health_constructors;
  check (list string) "attention severity constructors"
    [
      "Attention_critical";
      "Attention_bad";
      "Attention_warning";
      "Attention_info";
    ]
    attention_severity_constructors;
  check int "loader has an explicit unknown health decode error" 1
    (Ast_grep.count_string_literals
       ~module_path:"bin/masc_tui_loader.ml"
       ~needle:"unknown workspace health");
  check int "loader has an explicit unknown severity decode error" 1
    (Ast_grep.count_string_literals
       ~module_path:"bin/masc_tui_loader.ml"
       ~needle:"unknown attention severity")
;;

let test_planning_cursor_uses_visible_goal_order () =
  check int "visible planning helper lives in shared types" 1
    (Ast_grep.count_value_bindings
       ~module_path:"bin/masc_tui_types.ml"
       ~name:"planning_visible_goals");
  check int "visible planning helper avoids duplicate-prone insertion helper" 0
    (Ast_grep.count_value_bindings
       ~module_path:"bin/masc_tui_types.ml"
       ~name:"insert_sorted");
  check bool "visible planning helper uses stable depth sort" true
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui_types.ml"
       ~callee:"List.stable_sort"
     >= 1);
  check int "render no longer owns a private tree sorter" 0
    (Ast_grep.count_value_bindings
       ~module_path:"bin/masc_tui_render.ml"
       ~name:"sort_goals_for_tree");
  check bool "render uses shared visible-goal order" true
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui_render.ml"
       ~callee:"planning_visible_goals"
     >= 1);
  check bool "key handling uses shared visible-goal order" true
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui.ml"
       ~callee:"planning_visible_goals"
     >= 2)
;;

(* The screen dials one address and it is not a setting.

   MASC_HOST is the *server's* bind address -- [main_eio.ml] spells it
   "Host/IP to bind" and [Server_auth] calls it [configured_bind_host]. Its
   documented non-default values are the wildcards 0.0.0.0 and ::, which
   [Masc_network_defaults.is_unspecified_host] exists to name as "every
   interface" rather than a reachable peer. Reading it here pointed the screen
   at an address that is not a destination, and made a second setting: the
   roster, the backlog, the metrics and the context occupancy come off local
   disk under [base_path], and nothing checked the two named one machine.

   Pinned at zero rather than described, because the way back is one
   plausible-looking line. *)
let test_the_screen_does_not_read_the_servers_bind_address () =
  let main_path = "bin/masc_tui.ml" in
  check int "no bind-address reader" 0
    (Ast_grep.count_calls ~module_path:main_path
       ~callee:"Env_config_core.masc_host");
  check int "the peer is named once" 1
    (Ast_grep.count_value_bindings ~module_path:main_path
       ~name:"server_peer_host")
;;

let test_server_identity_is_revalidated_on_every_refresh () =
  let main_path = "bin/masc_tui.ml" in
  check int "each full refresh asks the compact identity probe once" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"load_http_surfaces" ~callee:"load_server_identity");
  check int "identity-known cache gating is absent" 0
    (Ast_grep.count_identifiers_outside_calls_in_value_binding
       ~module_path:main_path ~binding_name:"load_http_surfaces" ~callees:[]
       ~identifiers:[ "identity_known" ]);
  check int "HTTP apply uses the tested A-to-B transition" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"apply_http_surfaces"
       ~callee:"Masc_tui_types.server_identity_of_refresh");
  (* The clearing is [state.server_identity <- None], a write. Counting
     reads of the field found none and called a working path broken. *)
  check int "a failed refresh clears current identity" 1
    (Ast_grep.count_field_clears_to_none ~module_path:main_path
       ~binding_name:"apply_async_message" ~field_name:"server_identity")
;;

let test_scoped_surface_refresh_does_not_own_connection_status () =
  let main_path = "bin/masc_tui.ml" in
  check int "scoped launch preserves the last full connection reading" 0
    (Ast_grep.count_field_accesses_outside_calls_in_value_binding
       ~module_path:main_path ~binding_name:"start_http_scoped_refresh"
       ~callees:[] ~fields:[ "connection_status" ]);
  check int "scoped completion preserves the last full connection reading" 0
    (Ast_grep.count_field_accesses_outside_calls_in_value_binding
       ~module_path:main_path ~binding_name:"apply_http_scoped_surfaces"
       ~callees:[] ~fields:[ "connection_status" ])
;;

let test_gate_stance_listing_rides_the_flow_generation () =
  let main_path = "bin/masc_tui.ml" in
  (* The stance listing replaces the whole yolo set. Two daemon fibers reach
     it -- a periodic GET and the operator's own POST -- and the network
     decides which lands first, so a GET that started before the press can
     put the pre-press answer back and the armed gate reads as auto again.
     The next press then computes yolo a second time instead of toggling
     back, which is what makes it visible rather than a flicker. The held
     call listing already rides [Approval.Flow]; these four pin the stance
     listing onto the same guard. *)
  check int "the stance fetch takes a generation" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"launch_keeper_tool_modes_load"
       ~callee:"Approval.Flow.reserve_refresh");
  check int "arming a gate opens an action" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"launch_keeper_tool_mode_set"
       ~callee:"Approval.Flow.begin_action");
  check int "a stale stance listing is dropped" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"apply_async_message"
       ~callee:"Approval.Flow.is_current");
  check int "the press closes its own action" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"apply_async_message"
       ~callee:"Approval.Flow.finish_action")
;;

let test_the_scroll_counts_back_from_a_pinned_row () =
  let main_path = "bin/masc_tui.ml" in
  let render_path = "bin/masc_tui_render.ml" in
  (* [msg_scroll] used to count back from whatever row was newest at the
     moment it was read, so a reply landing moved what the same count meant
     and the operator reading back was carried toward it. Three things hold
     the fix: every key that scrolls goes through the one setter that keeps
     the pin, the pane adds back what arrived since, and nothing writes the
     field around the setter. *)
  check int "no key writes the scroll behind the setter's back" 0
    (Ast_grep.count_field_writes_in_module ~module_path:main_path
       ~field:"msg_scroll");
  check int "returning to the bottom releases the pin" 1
    (Ast_grep.count_field_clears_to_none
       ~module_path:"bin/masc_tui_types.ml" ~binding_name:"set_msg_scroll"
       ~field_name:"msg_scroll_pin");
  check int "the pane reads the pin but never moves it" 0
    (Ast_grep.count_field_writes_in_module ~module_path:render_path
       ~field:"msg_scroll_pin");
  check int "and the count it asks for carries what arrived" 1
    (Ast_grep.count_identifiers_outside_calls_in_value_binding
       ~module_path:render_path ~binding_name:"render_keeper_message"
       ~callees:[] ~identifiers:[ "rows_since_pin" ])
;;

let test_planning_refresh_reconciles_navigation_identity () =
  let main_path = "bin/masc_tui.ml" in
  check int "planning apply owns one identity reconciliation" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"apply_planning_load"
       ~callee:"Planning_selection.reconcile");
  check int "planning reconciliation has one application owner" 1
    (Ast_grep.count_calls ~module_path:main_path
       ~callee:"Planning_selection.reconcile");
  check int "planning apply is independent of the visible surface" 0
    (Ast_grep.count_field_accesses_outside_calls_in_value_binding
       ~module_path:main_path ~binding_name:"apply_planning_load" ~callees:[]
       ~fields:[ "view" ]);
  check int "scoped HTTP application owns one planning apply" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"apply_http_scoped_surfaces"
       ~callee:"apply_planning_load");
  (* #29443 removed two [List.find_opt (fun g -> g.pg_id = goal_id) p.pl_goals]
     lookups from the key loop: the loop re-derived the Planning selection from
     whichever snapshot it happened to hold, and a reorder between refreshes
     moved the cursor onto a different goal. Reconciliation belongs to
     [Planning_selection.reconcile], pinned above.

     That absence was guarded by counting [List.find_opt] in [main], which is a
     2,700-line key dispatcher: #30603 added a repository lookup for the PR-URL
     jump and turned this red on a call with nothing to do with Planning. What
     the loop must not do is reach into the snapshot's goal list itself; the two
     reads it legitimately makes both go through [planning_visible_goals], so
     that projection is the permitted path and anything else is the bug coming
     back. *)
  check int "refresh loop reads planning goals only through the visible projection" 0
    (Ast_grep.count_field_accesses_outside_calls_in_value_binding
       ~module_path:main_path ~binding_name:"main"
       ~callees:[ "planning_visible_goals" ] ~fields:[ "pl_goals" ])
;;

let test_overview_events_use_scroll_projection () =
  check int "overview renders one bounded event window" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render.ml"
       ~binding_name:"render_overview"
       ~callee:"Render_schedule.project_overview_event_window");
  check int "event prepend preserves one manual anchor" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_loader.ml"
       ~binding_name:"add_event"
       ~callee:"Render_schedule.overview_event_offset_after_prepend");
  check int "overview older input is bounded once" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui.ml"
       ~binding_name:"main"
       ~callee:"Render_schedule.scroll_overview_events_older");
  check int "overview newer input is bounded once" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui.ml"
       ~binding_name:"main"
       ~callee:"Render_schedule.scroll_overview_events_newer");
  check int "both overview input directions use current layout" 2
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui.ml"
       ~binding_name:"main" ~callee:"overview_layout")
;;

let test_render_loop_uses_monotonic_dirty_schedule () =
  let main_path = "bin/masc_tui.ml" in
  check bool "main loop reads a monotonic clock" true
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"main" ~callee:"Mtime_clock.elapsed_ns"
     >= 3);
  check int "main loop has no wall-clock refresh deadline" 0
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"main" ~callee:"Unix.gettimeofday");
  check bool "context bar width is total" true
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_ansi.ml"
       ~binding_name:"ctx_bar"
       ~callee:"Masc_tui_render_schedule.nonnegative_width"
     = 1);
  (* [keeper_detail_pane], not [render_keeper_detail]: #30146 split the surface
     so the frame picks a narrow or a side-by-side layout and the pane draws the
     content. Everything these four guards watch -- the clamped bar width, the
     scroll normalization, the sanitized fields, the timestamp projections --
     went with the content. Nothing is left in the frame, so pointing them at
     the old name read a move as four regressions. *)
  check bool "keeper detail clamps its derived bar width" true
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render.ml"
       ~binding_name:"keeper_detail_pane"
       ~callee:"Masc_tui_render_schedule.keeper_context_bar_width"
     = 1);
  check int "keeper detail persists one viewport-normalized scroll" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render.ml"
       ~binding_name:"keeper_detail_pane"
       ~callee:"Render_schedule.normalize_keeper_detail_scroll");
  (* #30210 replaced the byte-at-a-time read with a buffered refill, so the
     wait moved with it. The contract did not: whichever binding blocks for
     input owns the deadline, and EINTR has to come back as a retry rather
     than as end of input. *)
  check bool "interrupted input uses the deadline-aware retry contract" true
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"refill_input_reader"
       ~callee:"Render_schedule.Input_wait.await"
     = 1);
  check int "surface renderers perform no direct stdout writes" 0
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui_render.ml" ~callee:"print_string");
  check int "surface renderers perform no direct flushes" 0
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui_render.ml" ~callee:"flush");
  check int "main has one frame presentation boundary" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"main" ~callee:"Frame_presenter.present");
  check int "main reads the compact gate from the presented frame" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"main"
       ~callee:"Frame_presenter.last_frame_is_compact");
  check int "main does not recompute compact state from newer mutable state" 0
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"main"
       ~callee:"Render_schedule.Viewport.requires_compact_frame");
  check int "run loop polls pending resize twice per pass" 2
    (Ast_grep.count_calls_inside_while_in_value_binding
       ~module_path:main_path ~binding_name:"run_loop"
       ~callee:"consume_resize_request");
  check int "resize polling consumes one pending signal" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"consume_resize_request" ~callee:"Atomic.exchange");
  check int "render owns one compact viewport gate" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render.ml" ~binding_name:"render"
       ~callee:"Render_schedule.Viewport.requires_compact_frame");
  check int "compact render has one fallback branch" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render.ml" ~binding_name:"render"
       ~callee:"render_terminal_too_small");
  check int "compact render has one normal-surface branch" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render.ml" ~binding_name:"render"
       ~callee:"render_surface");
  let render_path = "bin/masc_tui_render.ml" in
  check int "overview layout owns one shared row allocation" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:render_path
       ~binding_name:"overview_layout"
       ~callee:"Render_schedule.allocate_overview");
  check int "overview renderer consumes one shared layout" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:render_path
       ~binding_name:"render_overview" ~callee:"overview_layout");
  (* 6 = the five allocation-sourced bounds plus the task-panel window, which
     follows the cursor through the same [task_rows] value (#29684). Every
     bound still comes from the one shared allocation above. *)
  check int "overview bounds each variable section from that allocation" 6
    (Ast_grep.count_field_accesses_outside_calls_in_value_binding
       ~module_path:render_path ~binding_name:"render_overview" ~callees:[]
       ~fields:[ "attention_rows"; "task_error_rows"; "task_rows" ]);
  check int "board read consumes one shared row allocation" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:render_path
       ~binding_name:"board_read_pane"
       ~callee:"Render_schedule.allocate_board_read");
  check int "board body and comments share the allocation" 2
    (Ast_grep.count_field_accesses_outside_calls_in_value_binding
       ~module_path:render_path ~binding_name:"board_read_pane" ~callees:[]
       ~fields:[ "body_rows"; "comment_rows" ]);
  check int "board read projects one scroll across body and comments" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:render_path
       ~binding_name:"board_read_pane"
       ~callee:"Render_schedule.project_board_read_scroll");
  check int "board renderer consumes normalized body and comment offsets" 3
    (Ast_grep.count_field_accesses_outside_calls_in_value_binding
       ~module_path:render_path ~binding_name:"board_read_pane" ~callees:[]
       ~fields:[ "normalized_scroll"; "body_offset"; "comment_offset" ]);
  check int "resize invalidation and Force request share one boundary" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"invalidate_frame_for_resize"
       ~callee:"Frame_presenter.invalidate");
  check int "resize boundary owns terminal-size cache invalidation" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"invalidate_frame_for_resize"
       ~callee:"invalidate_terminal_size");
  check int "resize boundary requests one forced frame" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"invalidate_frame_for_resize"
       ~callee:"Render_schedule.request");
  check int "resize request's reason is exactly Force" 1
    (Ast_grep
     .count_applications_with_exact_positional_constructor_in_value_binding
       ~module_path:main_path ~binding_name:"invalidate_frame_for_resize"
       ~callee:"Render_schedule.request" ~position:1
       ~constructor:"Render_schedule.Force");
  (* The contract is that this boundary is the only door, not that main walks
     through it once. #30255 gave the loop a second reason to distrust the
     presenter's cached screen -- an image overlay covered the frame and was
     dismissed -- and a count read that as a regression. What must stay true
     is that main never reaches past the boundary: the three assertions above
     pin what happens inside it, and this one pins that nothing else does it.

     [Frame_presenter.invalidate] appears once in the whole file, inside the
     boundary, so a caller that invalidated on its own would raise this to 2
     and fail here. *)
  check bool "main reaches the presenter only through the resize boundary" true
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"main" ~callee:"invalidate_frame_for_resize"
     >= 1);
  check int "nothing invalidates the presenter outside that boundary" 1
    (Ast_grep.count_calls ~module_path:main_path
       ~callee:"Frame_presenter.invalidate");
  let terminal_repair_path = "bin/masc_tui_terminal_write_repair.ml" in
  check int "console repair boundary delegates to the repair state" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"request_console_write_repair"
       ~callee:"Terminal_write_repair.request_repaint");
  check int "damaged terminal state requests one forced frame" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:terminal_repair_path
       ~binding_name:"request_repaint"
       ~callee:"Render_schedule.request");
  check int "console repair request's reason is exactly Force" 1
    (Ast_grep
     .count_applications_with_exact_positional_constructor_in_value_binding
       ~module_path:terminal_repair_path ~binding_name:"request_repaint"
       ~callee:"Render_schedule.request" ~position:1
       ~constructor:"Render_schedule.Force");
  check int "terminal write publishes one durable damage marker" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:terminal_repair_path
       ~binding_name:"note" ~callee:"Atomic.set");
  check int "repaint inspection does not consume the damage marker" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:terminal_repair_path
       ~binding_name:"request_repaint" ~callee:"Atomic.get");
  check int "run loop polls the console repair boundary inside its while" 1
    (Ast_grep.count_calls_inside_while_in_value_binding ~module_path:main_path
       ~binding_name:"run_loop" ~callee:"request_console_write_repair");
  check int "main enters the run loop" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"main" ~callee:"run_loop");
  check int "presentation consumes the external-write marker once" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:main_path ~binding_name:"present_frame"
       ~callee:"Terminal_write_repair.consume_damage");
  check int "TTY gate validates stdin and stdout" 2
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"require_interactive_terminal" ~callee:"Unix.isatty");
  check int "console observer gate requires stderr to target a TTY" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:terminal_repair_path
       ~binding_name:"console_sink_writes_to_terminal" ~callee:"Unix.isatty");
  check int "main gates the observer on a terminal-backed console sink" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"main"
       ~callee:"Terminal_write_repair.console_sink_writes_to_terminal");
  check int "TUI installs and removes one Console_sink observer" 2
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"main" ~callee:"Console_sink.set_after_write_observer");
  check int "TUI installs the Console_sink observer with Some" 1
    (Ast_grep
     .count_applications_with_exact_positional_constructor_in_value_binding
       ~module_path:main_path ~binding_name:"main"
       ~callee:"Console_sink.set_after_write_observer" ~position:0
       ~constructor:"Some");
  check int "cleanup removes the Console_sink observer" 1
    (Ast_grep
     .count_applications_with_exact_positional_constructor_in_value_binding
       ~module_path:main_path ~binding_name:"cleanup"
       ~callee:"Console_sink.set_after_write_observer" ~position:0
       ~constructor:"None");
  check int "Console_sink observer marks the terminal write" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"main" ~callee:"Terminal_write_repair.note");
  check int "loader routes its diagnostic through Console_sink" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_loader.ml" ~binding_name:"report"
       ~callee:"Console_sink.write");
  check int "loader no longer writes directly to stderr" 0
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_loader.ml" ~binding_name:"report"
       ~callee:"Printf.eprintf");
  let console_sink_path = "lib/masc_log/console_sink.ml" in
  check int "synchronous console writes use the observed writer boundary" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:console_sink_path
       ~binding_name:"write" ~callee:"write_line");
  check int "queued lines and the drop marker use the observed boundary" 2
    (Ast_grep.count_identifiers_outside_calls_in_value_binding
       ~module_path:console_sink_path ~binding_name:"write_batch" ~callees:[]
       ~identifiers:[ "write_line" ]);
  check int "observed writer boundary attempts the configured writer once" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:console_sink_path
       ~binding_name:"write_line" ~callee:"current_writer");
  let signal_handler signal handler =
    Ast_grep.count_applications_with_exact_signal_handler_in_value_binding
      ~module_path:main_path ~binding_name:"enter_terminal_session" ~signal
      ~handler
  in
  check bool "startup registers cleanup and handlers before raw mode" true
    (Ast_grep.direct_call_sequence_matches_in_value_binding
       ~module_path:main_path ~binding_name:"enter_terminal_session"
       ~callees:
         [ "at_exit"
         ; "Sys.set_signal"
         ; "Sys.set_signal"
         ; "Sys.set_signal"
         ; "Sys.set_signal"
         ; "Sys.set_signal"
         ; "Sys.set_signal"
         ; "Sys.set_signal"
           (* [apply_raw_mode], not [Unix.tcsetattr]: raw mode is the pair of
              setting the record and turning off the literal-next key the
              record cannot carry, and the two are named once so the three
              places that take raw mode back cannot take it without the key.
              What this pins is unchanged -- the cleanup and the handlers are
              registered before the terminal is taken. *)
         ; "apply_raw_mode"
         ]);
  check int "startup registers the real cleanup callback" 1
    (Ast_grep
     .count_applications_with_exact_positional_identifier_in_value_binding
       ~module_path:main_path ~binding_name:"enter_terminal_session"
       ~callee:"at_exit" ~position:0 ~identifier:"cleanup");
  check int "main enters the guarded terminal session once" 1
    (Ast_grep
     .count_applications_with_exact_labelled_identifiers_in_value_binding
       ~module_path:main_path ~binding_name:"main"
       ~callee:"enter_terminal_session"
       ~arguments:
         [ "cleanup", "cleanup"
         ; "terminate", "terminate"
           (* SIGINT stopped meaning "the session is over". It is the only one
              of these a person sends by hand mid-sentence, so it asks the loop
              to interrupt the turn instead, and the handler that does it is
              handed in here with the rest. The guard lists every argument by
              name, so a new one has to be named or the whole call stops
              matching -- which is what it is for: this is the boundary where
              a signal becomes a decision, and an argument that arrived
              unlisted would be a decision nobody pinned. *)
         ; "request_interrupt", "request_interrupt"
         ; "request_full_repaint", "request_full_repaint"
         ; "suspend", "suspend"
         ; "new_term", "new_term"
         ]);
  (* SIGINT no longer ends the session. It is the one signal a person sends by
     hand mid-sentence, so it asks the loop to interrupt the turn and the
     surface stays up; the two below still mean the session is over. Pinned as
     the handler it now has rather than dropped, because "Ctrl-C does not kill
     this" is the property, and an unpinned SIGINT could quietly go back to
     terminating. *)
  check int "SIGINT interrupts the turn rather than the session" 1
    (signal_handler "Sys.sigint" "request_interrupt");
  check int "SIGINT does not terminate" 0
    (signal_handler "Sys.sigint" "terminate");
  check int "SIGTERM terminates through cleanup" 1
    (signal_handler "Sys.sigterm" "terminate");
  check int "SIGHUP terminates through cleanup" 1
    (signal_handler "Sys.sighup" "terminate");
  check int "SIGQUIT terminates through cleanup" 1
    (signal_handler "Sys.sigquit" "terminate");
  check int "SIGWINCH requests a full repaint" 1
    (signal_handler "Sys.sigwinch" "request_full_repaint");
  check int "SIGCONT requests a full repaint" 1
    (signal_handler "Sys.sigcont" "request_full_repaint");
  check int "SIGTSTP initially installs the suspend handler" 1
    (signal_handler "Sys.sigtstp" "suspend");
  check int "resume reinstalls the suspend handler" 1
    (Ast_grep.count_applications_with_exact_signal_handler_in_value_binding
       ~module_path:main_path ~binding_name:"suspend" ~signal:"Sys.sigtstp"
       ~handler:"suspend");
  check int "startup raw mode uses new termios" 1
    (Ast_grep
     .count_applications_with_exact_positional_identifier_in_value_binding
       ~module_path:main_path ~binding_name:"enter_terminal_session"
       ~callee:"apply_raw_mode" ~position:0 ~identifier:"new_term");
  (* And [apply_raw_mode] is where the record and the key are set together.
     Asserted here so the pair cannot come apart under a name this guard
     already accepts. *)
  check int "raw mode sets the termios record" 1
    (Ast_grep
     .count_applications_with_exact_positional_identifier_in_value_binding
       ~module_path:main_path ~binding_name:"apply_raw_mode"
       ~callee:"Unix.tcsetattr" ~position:2 ~identifier:"new_term");
  check int "raw mode reclaims the key the record cannot carry" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"apply_raw_mode"
       ~callee:"Masc_tui_termios.disable_literal_next");
  check int "terminal restoration cleans presenter state" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"restore_terminal" ~callee:"Frame_presenter.cleanup");
  check int "terminal restoration reapplies old termios" 1
    (Ast_grep
     .count_applications_with_exact_positional_identifier_in_value_binding
       ~module_path:main_path ~binding_name:"restore_terminal"
       ~callee:"Unix.tcsetattr" ~position:2 ~identifier:"old_term");
  check int "suspend restores the shell terminal first" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"suspend" ~callee:"restore_terminal");
  check int "suspend temporarily installs the default action" 1
    (Ast_grep
     .count_applications_with_exact_identifier_and_constructor_in_value_binding
       ~module_path:main_path ~binding_name:"suspend"
       ~callee:"Sys.set_signal" ~identifier_position:0
       ~identifier:"Sys.sigtstp" ~constructor_position:1
       ~constructor:"Sys.Signal_default");
  check int "suspend self-signals SIGTSTP" 1
    (Ast_grep
     .count_applications_with_exact_positional_identifier_in_value_binding
       ~module_path:main_path ~binding_name:"suspend" ~callee:"Unix.kill"
       ~position:1 ~identifier:"Sys.sigtstp");
  (* Through [apply_raw_mode], like every other place that takes raw mode back.
     OCaml's tcsetattr restores c_cc from the snapshot its last tcgetattr took,
     so a resume that set the record alone would hand the terminal back the
     literal-next key and Ctrl-V would stop arriving after the first Ctrl-Z. *)
  check int "resume reapplies raw termios" 1
    (Ast_grep
     .count_applications_with_exact_positional_identifier_in_value_binding
       ~module_path:main_path ~binding_name:"suspend"
       ~callee:"apply_raw_mode" ~position:0 ~identifier:"new_term");
  check int "resume requests a repaint" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"suspend" ~callee:"request_full_repaint");
  check bool "suspend reaches self-stop only after terminal restoration" true
    (Ast_grep.direct_call_sequence_matches_in_value_binding
       ~module_path:main_path ~binding_name:"suspend"
       ~callees:[ "restore_terminal"; "Sys.set_signal"; "Fun.protect" ]);
  check bool "resume lifecycle is confined to Fun.protect finally" true
    (Ast_grep.fun_protect_sequences_match_in_value_binding
       ~module_path:main_path ~binding_name:"suspend"
       ~body_callees:[ "Unix.kill" ]
       ~finally_callees:
         [ "Sys.set_signal"
         ; "apply_raw_mode"
         ; "Frame_presenter.setup"
         ; "request_full_repaint"
         ]);
  check int "the local input loop propagates one Break" 1
    (Ast_grep.count_applications_with_exact_positional_constructor_in_value_binding
       ~module_path:main_path ~binding_name:"run_loop" ~callee:"raise"
       ~position:0 ~constructor:"Break");
  check bool "Break is converted to success outside the root Eio switch" true
    (Ast_grep.try_handler_wraps_nested_callback_in_value_binding
       ~module_path:main_path ~binding_name:"run_with_eio_context"
       ~exception_constructor:"Break" ~outer_callee:"Eio_main.run"
       ~inner_callee:"Eio.Switch.run" ~callback_callee:"f");
  check int "main passes its message mode to q classification" 1
    (Ast_grep.count_applications_with_exact_labelled_identifiers_in_value_binding
       ~module_path:main_path ~binding_name:"run_loop"
       ~callee:"Render_schedule.Input_shortcut.is_quit"
       ~arguments:[ "message_mode", "message_mode" ]);
  check int "main passes its message mode to Keeper classification" 1
    (Ast_grep.count_applications_with_exact_labelled_identifiers_in_value_binding
       ~module_path:main_path ~binding_name:"run_loop"
       ~callee:"Masc_tui_keys.opens_keepers"
       ~arguments:[ "message_mode", "message_mode" ])
;;

(* The startup notice and the reconciliation detail are the only two places
   that tell an operator this process has no bearer. Neither runs under a unit
   test -- one is startup straight-line code in a binary, the other reaches the
   chat surface -- so their wiring is pinned here. Without the startup line the
   first symptom is a recovered dispatch that can never settle. *)
let test_missing_operator_token_is_reported () =
  check int "startup binds the bearer to the workspace it opened" 1
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui.ml"
       ~callee:"Masc_tui_http.install_operator_token");
  (* Not a call count on [operator_token_present]: every surface that reports a
     refusal now reads it, so counting occurrences says nothing about startup.
     What must not disappear is that startup says out loud what came of binding
     a bearer -- a silent mint reads to the operator as a broken credential
     when the server's index has not caught up yet. *)
  check int "startup reports what came of binding a bearer" 1
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui.ml"
       ~callee:"Masc_tui_credential.outcome_notice");
  (* The mint's window is a policy, and the three the type offers mean different
     things. [Long_lived] leaves an admin secret on disk that nothing retires;
     [With_expiry] takes the workspace's operator-session day, which is the very
     window that refuses a session left running overnight. Only a named window
     is this client's own answer. *)
  check int "the self-mint does not ask for a bearer that never expires" 0
    (Ast_grep.count_constructors
       ~module_path:"bin/masc_tui_http.ml"
       ~constructor:"Auth_login.Long_lived");
  check int "the self-mint names its own window" 1
    (Ast_grep.count_constructors
       ~module_path:"bin/masc_tui_http.ml"
       ~constructor:"Auth_login.Expires_in_hours");
  (* And the number is read off the client's own constant. A literal here would
     compile, mint, and quietly disagree with what the startup notice tells the
     operator the credential is good for. *)
  check int "the window comes from the one place that states it" 1
    (Ast_grep.count_identifiers_outside_calls_in_value_binding
       ~module_path:"bin/masc_tui_http.ml"
       ~binding_name:"install_operator_token"
       ~callees:[]
       ~identifiers:[ "Masc_tui_credential.self_mint_expiry_hours" ]);
  (* Both refusal surfaces must ask what this process actually holds. Passing a
     constant would compile and read plausibly while asserting something the
     401 never established -- which is the failure these lines exist to end. *)
  check int "the chat surface asks whether a bearer was presented" 1
    (Ast_grep.count_applications_with_exact_labelled_unit_call_in_value_binding
       ~module_path:"bin/masc_tui.ml"
       ~binding_name:"apply_keeper_chat_result"
       ~callee:"Keeper_chat.reconciliation_failure_detail"
       ~label:"credential_sent"
       ~nested_callee:"Masc_tui_http.operator_token_present");
  check int "the roster surface asks the same question" 1
    (Ast_grep.count_applications_with_exact_labelled_unit_call_in_value_binding
       ~module_path:"bin/masc_tui.ml"
       ~binding_name:"apply_keeper_roster_load"
       ~callee:"Keeper_control.roster_failure_message"
       ~label:"credential_sent"
       ~nested_callee:"Masc_tui_http.operator_token_present");
  (* Every surface reads JSON through these two. Answering a refusal inside them
     is what keeps the server's auth body out of six different panes; a surface
     that decoded the status itself would print it again. *)
  check int "the JSON reads share one refusal answer" 2
    (Ast_grep.count_calls ~module_path:"bin/masc_tui_http.ml" ~callee:"decode_json");
  check int "no surface decodes a status on its own" 1
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui_http.ml"
       ~callee:"Masc.Tui_decode.decode_json_response_body");
  (* Needled on the sentence rather than on "operator token": doc comments reach
     the parsetree as string constants, so the looser needle counts prose that
     is not a message. *)
  check int "the refusal sentence has one owner" 0
    (Ast_grep.count_string_literals_across_files
       ~module_paths:[ "bin/masc_tui_http.ml"; "bin/masc_tui.ml" ]
       ~needle:"holds no operator token");
  (* Zero, not one: the name reaches a lookup, the argument that tells
     masc login which name to print, and the command handed to the operator.
     Three copies of one fact is how the header, the file, and the advice end
     up naming different things. *)
  check int "the bearer env name has one owner" 0
    (Ast_grep.count_string_literals
       ~module_path:"bin/masc_tui_http.ml"
       ~needle:"MASC_TOKEN")
;;

let test_renderers_sanitize_untrusted_terminal_fields () =
  let render_path = "bin/masc_tui_render.ml" in
  let sanitizer_calls =
    [ "Terminal_text.single_line"
    ; "Terminal_text.optional_single_line"
    ; "Terminal_text.single_line_or"
    ; "Terminal_text.single_lines"
    ; "Terminal_text.short_timestamp"
    ; "Terminal_text.clock_timestamp"
      (* Not a [Terminal_text] name, but it is a boundary crossing all the
         same: it serializes the approval payload and hands the result to
         [Masc.Tui_decode.sanitize_terminal_text] before returning
         (masc_tui_operator_projection.ml). This list matches on the call
         site's spelling, so a wrapper that sanitizes internally has to be
         named here or the guard reads it as a raw access. *)
    ; "Masc_tui_operator_projection.approval_payload_for_terminal"
      (* Also not a [Terminal_text] name, and also a boundary: it sanitises the
         text it is handed one line at a time, through the sanitiser its caller
         passes. A body cannot be sanitised whole -- a newline is a control
         byte, so the escape lands at every break and the document arrives as
         one unbroken run with "\x0A" printed through it, which is what a board
         post looked like. Per line the escape still covers what it is for. *)
    ; "Message_layout.wrap_body"
    ]
  in
  let fixture_path = "test/fixtures/tui_terminal_text_ast_fixture.ml" in
  check int "field boundary helper catches the unwrapped fixture field" 1
    (Ast_grep.count_field_accesses_outside_calls_in_value_binding
       ~module_path:fixture_path ~binding_name:"render"
       ~callees:sanitizer_calls ~fields:[ "safe"; "raw" ]);
  check int "identifier boundary helper catches the unwrapped fixture value" 1
    (Ast_grep.count_identifiers_outside_calls_in_value_binding
       ~module_path:fixture_path ~binding_name:"report"
       ~callees:[ "Terminal_text.single_line" ]
       ~identifiers:[ "path"; "err" ]);
  let check_binding module_path binding =
    check int (binding ^ " exists exactly once") 1
      (Ast_grep.count_value_bindings ~module_path ~name:binding)
  in
  let check_fields ?(non_rendering_calls = []) binding fields =
    check_binding render_path binding;
    let allowed_calls = sanitizer_calls @ non_rendering_calls in
    List.iter
      (fun field ->
        let total =
          Ast_grep.count_field_accesses_outside_calls_in_value_binding
            ~module_path:render_path ~binding_name:binding ~callees:[]
            ~fields:[ field ]
        in
        if total = 0 then
          failf "%s no longer accesses expected untrusted field %s" binding field;
        let outside =
          Ast_grep.count_field_accesses_outside_calls_in_value_binding
            ~module_path:render_path ~binding_name:binding
            ~callees:allowed_calls ~fields:[ field ]
        in
        if outside <> 0 then
          failf
            "%s has %d %s access(es) outside Terminal_text"
            binding outside field)
      fields
  in
  let check_identifiers ~module_path ~binding ~callees identifiers =
    check_binding module_path binding;
    List.iter
      (fun identifier ->
        let total =
          Ast_grep.count_identifiers_outside_calls_in_value_binding
            ~module_path ~binding_name:binding ~callees:[]
            ~identifiers:[ identifier ]
        in
        if total = 0 then
          failf "%s no longer references expected untrusted value %s" binding
            identifier;
        let outside =
          Ast_grep.count_identifiers_outside_calls_in_value_binding
            ~module_path ~binding_name:binding ~callees
            ~identifiers:[ identifier ]
        in
        if outside <> 0 then
          failf "%s has %d raw %s reference(s) outside Terminal_text" binding
            outside identifier)
      identifiers
  in
  check_fields "task_line" [ "id"; "title" ];
  check_identifiers ~module_path:render_path ~binding:"task_line"
    ~callees:sanitizer_calls [ "name" ];
  check_fields "render_overview"
    [ "workspace"
    ; "overview_error"
    ; "ov_cluster"
    ; "ov_project"
    ; "ai_summary"
    ; "content"
      (* [th_primary_path] and [th_queue_pressure] left this list because they
         left the category. Both are closed variants now, rendered through
         [Transport_metrics.*_kind_to_string], so the renderer has no arbitrary
         text to sanitize -- the type removed what the sanitizer was for. Asking
         for the call here would ask the renderer to sanitize a constructor. *)
    ];
  check_fields "overview_layout" [ "tasks_error" ];
  check_fields "render_approvals"
    [ "aps_actor_filter"
    ; "approvals_error"
    ; "ap_target_id"
    ; "ap_actor"
    ; "ap_action_type"
    ; "ap_target_type"
    ; "ap_summary"
    ; "ap_expires_at"
    ; "ap_payload"
    ; "ap_trace_id"
    ; "ap_created_at"
    ];
  check_fields "render_board_list"
    [ "board_list_error"; "bp_id"; "bp_author"; "bp_title" ];
  (* [String.equal] keeps a post out of its own related list. Comparison never
     reaches the terminal, and sanitizing first would be wrong besides: two
     different ids can fold to one line, and identity must read the raw id. *)
  check_fields
    ~non_rendering_calls:
      [ "Board_detail.view_for"; "String.equal"; "Link.scan" ]
    "board_read_pane"
    [ "bp_id"
    ; "bp_author"
    ; "bp_title"
    ; "bp_created_at"
    ; "bp_body"
    ; "bc_author"
    ; "bc_content"
    ];
  (* [Link.scan] reads the body without drawing it, but what it returns is
     drawn -- and [Link.parse] percent-decodes, so an id can carry the escape
     bytes the body could not. Sanitize where it lands. *)
  check_identifiers ~module_path:render_path ~binding:"board_read_pane"
    ~callees:sanitizer_calls [ "id" ];
  (* Every split surface hands its list through one sidebar, so this is the
     single place a row label can reach the terminal unsanitized. Seven
     callers now pass titles that came off the wire. *)
  check_identifiers ~module_path:render_path ~binding:"write_list_sidebar"
    ~callees:sanitizer_calls [ "label" ];
  check_fields "render_planning_list"
    [ "planning_error"; "pg_due_date"; "pg_title" ];
  (* The drawing moved into [planning_detail_pane] when the goal list came to
     sit beside the goal; [render_planning_detail] is now the split, and
     guarding it would guard a function that renders nothing. Same move as
     #29626 made for [keeper_row_content].

     [String.equal] finds the open goal's row in the sidebar and [List.mem]
     asks which tasks name this goal. Neither reaches the terminal, and the
     labels the sidebar draws are sanitized where they are drawn. *)
  check_fields ~non_rendering_calls:[ "List.mem" ] "planning_detail_pane"
    [ "pg_id"; "pg_title"; "pg_due_date"; "pg_metric"; "pg_target_value" ];
  check_fields ~non_rendering_calls:[ "String.equal" ] "render_planning_detail"
    [ "pg_id" ];
  check_fields "render_keeper_list" [ "keepers_error" ];
  (* #29626 moved the row itself into [keeper_row_content] so the list could
     carry action affordances. The fields the row shows did not change, and
     neither did their sanitizers -- only the binding that holds them. *)
  check_fields "keeper_row_content" [ "k_current_task_id"; "k_name" ];
  (* These calls compare or look up the raw Keeper identity before anything is
     rendered: [String.equal] checks the cached detail stamp, the typed context
     lookup checks its own snapshot stamp, and the Gate section asks two
     (keeper, value) lists what was set for this one. None reaches the
     terminal -- what the Gate rows draw is the value, sanitized where it is
     drawn -- so those raw [k_name] accesses do not belong inside a text
     sanitizer.

     The lookups in particular must stay raw: the stored key is the Keeper's
     own name, and a sanitized copy would simply stop matching, which reads on
     screen as "follows the workspace" for a Keeper somebody moved. *)
  check_fields
    ~non_rendering_calls:
      [ "String.equal"
      ; "Context_state.reading_for_keeper"
      ; "List.mem"
      ; "List.assoc_opt"
      ]
    "keeper_detail_pane"
    [ "k_name"
    ; "k_current_task_id"
    ; "error"
    ; "observed_at"
    ; "turn_ref"
    ; "k_last_turn_ts"
    ; "k_created_at"
    ; "k_updated_at"
    ];
  check_fields "render_keeper_logs"
    [ "k_name"; "le_ts"; "le_tools_used"; "le_work_kind" ];
  check_fields "footer_line" [ "sid_base_path" ];
  check int "footer path has no workspace fallback" 0
    (Ast_grep.count_field_accesses_outside_calls_in_value_binding
       ~module_path:render_path ~binding_name:"footer_line" ~callees:[]
       ~fields:[ "workspace" ]);
  let ansi_path = "bin/masc_tui_ansi.ml" in
  [ "single_line"
  ; "optional_single_line"
  ; "single_line_or"
  ; "single_lines"
  ; "short_timestamp"
  ; "clock_timestamp"
  ]
  |> List.iter (check_binding ansi_path);
  let check_direct_result binding callee =
    check bool (binding ^ " returns its trusted projection directly") true
      (Ast_grep.direct_call_sequence_matches_in_value_binding
         ~module_path:ansi_path ~binding_name:binding ~callees:[ callee ])
  in
  check_direct_result "single_line"
    "Masc.Tui_decode.sanitize_terminal_text";
  check_direct_result "optional_single_line" "Option.map";
  check_direct_result "single_line_or" "Option.value";
  check_direct_result "single_lines" "List.map";
  check_direct_result "short_timestamp"
    "Masc.Tui_decode.short_timestamp_for_terminal";
  check_direct_result "clock_timestamp"
    "Masc.Tui_decode.clock_timestamp_for_terminal";
  check int "shared terminal boundary delegates to the typed sanitizer" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:ansi_path ~binding_name:"single_line"
       ~callee:"Masc.Tui_decode.sanitize_terminal_text");
  check int "optional boundary maps the sanitizer" 1
    (Ast_grep
     .count_applications_with_exact_positional_identifier_in_value_binding
       ~module_path:ansi_path ~binding_name:"optional_single_line"
       ~callee:"Option.map" ~position:0 ~identifier:"single_line");
  check int "defaulted boundary uses the optional sanitizer" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:ansi_path
       ~binding_name:"single_line_or" ~callee:"optional_single_line");
  check int "list boundary maps the sanitizer" 1
    (Ast_grep
     .count_applications_with_exact_positional_identifier_in_value_binding
       ~module_path:ansi_path ~binding_name:"single_lines" ~callee:"List.map"
       ~position:0 ~identifier:"single_line");
  check int "short timestamp delegates to slice-then-sanitize helper" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:ansi_path
       ~binding_name:"short_timestamp"
       ~callee:"Masc.Tui_decode.short_timestamp_for_terminal");
  check int "clock timestamp delegates to slice-then-sanitize helper" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:ansi_path
       ~binding_name:"clock_timestamp"
       ~callee:"Masc.Tui_decode.clock_timestamp_for_terminal");
  let decode_path = "lib/tui_decode.ml" in
  [ "short_timestamp_for_terminal"; "clock_timestamp_for_terminal" ]
  |> List.iter (fun binding ->
       check_binding decode_path binding;
       check bool (binding ^ " returns the final sanitizer result") true
         (Ast_grep.direct_call_sequence_matches_in_value_binding
            ~module_path:decode_path ~binding_name:binding
            ~callees:[ "sanitize_terminal_text" ]);
       check int (binding ^ " has one final sanitizer") 1
         (Ast_grep.count_calls_in_value_binding ~module_path:decode_path
            ~binding_name:binding ~callee:"sanitize_terminal_text");
       check int (binding ^ " never uses raw text after sanitizing") 0
         (Ast_grep.count_identifiers_outside_calls_in_value_binding
            ~module_path:decode_path ~binding_name:binding
            ~callees:[ "sanitize_terminal_text" ] ~identifiers:[ "text" ]));
  check int "log renderer does not slice sanitized timestamp bytes" 0
    (Ast_grep.count_calls_in_value_binding ~module_path:render_path
       ~binding_name:"render_keeper_logs" ~callee:"String.sub");
  check int "log renderer uses the safe clock projection once" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:render_path
       ~binding_name:"render_keeper_logs"
       ~callee:"Terminal_text.clock_timestamp");
  (* Six: two observation timestamps in Live Context, the last turn, the oldest
     row a partial Last 24h window reached, and the created / updated pair. Each
     one arrives from a keeper file or a metrics row, so none may reach the
     frame unprojected. *)
  check int "keeper detail uses safe short projections for every timestamp" 6
    (Ast_grep.count_calls_in_value_binding ~module_path:render_path
       ~binding_name:"keeper_detail_pane"
       ~callee:"Terminal_text.short_timestamp");
  check_identifiers ~module_path:"bin/masc_tui_loader.ml" ~binding:"report"
    ~callees:[ "Masc_tui_ansi.Terminal_text.single_line" ] [ "path"; "err" ]
;;

(* A failed turn used to be drawn twice: the server records it in the
   transcript, the pane records it in the session, and the filter that drops
   session rows the transcript holds could only see the role. Every error row
   was kept, because most of them are notices the server has no row for and
   dropping those loses the only record.

   The transcript now says which is which -- a persisted failure carries the
   operation it ran under, which is the id the session dispatched with -- so
   the filter reads the rows rather than the role alone. A body that stopped
   gathering ids from the transcript would be back to keeping every error row
   and drawing the failure twice. *)
let test_the_session_filter_reads_the_transcript () =
  check bool "the row filter gathers failure ids from the transcript" true
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui.ml"
       ~binding_name:"forget_session_rows_the_transcript_holds"
       ~callee:"List.filter_map"
     >= 1)
;;


(* The Board header and its rows are laid out by one function.

   They were not: the rows sized their title to [cols - 68] and the header
   claimed a fixed 20, so at eighty columns the header ran long, SCORE was
   cut to "SC~" and REPLIES fell off the frame entirely -- two columns still
   drawn on every row with nothing saying what they were. The mark ahead of
   the id is one cell and the header reserved two, which put every label one
   cell off its data.

   A header that disagrees with its rows is worse than no header: it labels
   the wrong column and the reader has no way to notice.

   The shared arithmetic became a shared column description. This pins that
   the surface draws its header and its rows from it rather than either one
   spelling widths again: one title width, asked once, and the two rows built
   from the description that width was measured against. *)
let test_the_board_header_and_rows_share_one_layout () =
  let module_path = "bin/masc_tui_render.ml" in
  let in_board callee =
    Ast_grep.count_calls_in_value_binding ~module_path
      ~binding_name:"render_board_list" ~callee
  in
  check int "the title is sized once for the whole surface" 1
    (in_board "board_title_width");
  check int "the header is drawn from the column description" 1
    (in_board "Render_schedule.board_header_row");
  check int "and so is every row" 1 (in_board "Render_schedule.board_row")
;;

(* Exact lane payloads used to pretty-print JSON and hand its plain lines
   straight to the frame. A long scalar then ended at the right edge and no
   token carried syntax colour. Pin the shared document renderer at the
   payload boundary: it owns both fenced JSON lexing and cell-safe wrapping. *)
let test_lane_run_payload_uses_the_json_document_renderer () =
  let module_path = "bin/masc_tui_render.ml" in
  check int "payload is fenced as JSON" 1
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"lane_run_payload_lines" ~callee:"fenced_document_text");
  check int "payload uses the shared highlighted document renderer" 1
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"lane_run_payload_lines" ~callee:"document_markdown")
;;


let () =
  run "masc-tui-http-regression" [
    ( "tui-http",
      [
        test_case "theme apply is boot and the surface" `Quick
          test_theme_apply_is_boot_and_the_surface;
        test_case
          "TUI status colors use semantic Theme tokens"
          `Quick
          test_tui_status_colors_use_theme_tokens;
        test_case
          "TUI render asks the theme for a categorical hue"
          `Quick
          test_tui_render_asks_the_theme_for_a_categorical_hue;
        test_case
          "the categorical guard rejects a raw hue"
          `Quick
          test_the_categorical_guard_rejects_a_raw_hue;
        test_case
          "TUI ANSI status helpers use semantic Theme tokens"
          `Quick
          test_tui_ansi_status_helpers_use_theme_tokens;
        test_case
          "TUI status color AST guard fixtures"
          `Quick
          test_tui_status_color_ast_guard_fixtures;
        test_case
          "chat roles draw through the readable path"
          `Quick
          test_chat_roles_draw_through_the_readable_path;
        test_case "check success status" `Quick test_is_success_http_status_called;
        test_case "missing operator token is reported" `Quick
          test_missing_operator_token_is_reported;
        test_case "auth headers used" `Quick test_http_get_uses_auth_headers;
        test_case
          "http client does not own TUI env contract"
          `Quick
          test_http_client_does_not_own_tui_env_contract;
        test_case
          "keeper chat uses current async contract"
          `Quick
          test_keeper_chat_uses_current_async_contract;
        test_case
          "user message background has one render snapshot"
          `Quick
          test_user_message_background_has_one_render_snapshot;
        test_case
          "operator approvals use current contract"
          `Quick
          test_operator_approvals_use_current_contract;
        test_case
          "planning constructors do not collide"
          `Quick
          test_planning_constructors_do_not_collide;
        test_case "planning phase uses goal SSOT" `Quick
          test_planning_phase_uses_goal_ssot;
        test_case "current projection wiring" `Quick
          test_tui_current_projection_wiring;
        test_case
          "overview state domains are closed-sum"
          `Quick
          test_overview_state_domains_are_closed_sum;
        test_case
          "planning cursor uses visible goal order"
          `Quick
          test_planning_cursor_uses_visible_goal_order;
        test_case
          "planning refresh reconciles navigation identity"
          `Quick
          test_planning_refresh_reconciles_navigation_identity;
        test_case
          "the scroll counts back from a pinned row"
          `Quick
          test_the_scroll_counts_back_from_a_pinned_row;
        test_case
          "gate stance listing rides the flow generation"
          `Quick
          test_gate_stance_listing_rides_the_flow_generation;
        test_case
          "the screen does not read the server's bind address"
          `Quick
          test_the_screen_does_not_read_the_servers_bind_address;
        test_case
          "server identity is revalidated on every refresh"
          `Quick
          test_server_identity_is_revalidated_on_every_refresh;
        test_case
          "scoped surface refresh preserves connection status"
          `Quick
          test_scoped_surface_refresh_does_not_own_connection_status;
        test_case
          "overview events use bounded scroll projection"
          `Quick
          test_overview_events_use_scroll_projection;
        test_case
          "render loop uses monotonic dirty scheduling"
          `Quick
          test_render_loop_uses_monotonic_dirty_schedule;
        test_case
          "renderers sanitize untrusted terminal fields"
          `Quick
          test_renderers_sanitize_untrusted_terminal_fields;
        test_case
          "the session row filter reads the transcript"
          `Quick
          test_the_session_filter_reads_the_transcript;
        test_case
          "the board header and rows share one layout"
          `Quick
          test_the_board_header_and_rows_share_one_layout;
        test_case
          "lane run payload uses the JSON document renderer"
          `Quick
          test_lane_run_payload_uses_the_json_document_renderer;
      ]
    )
  ]
