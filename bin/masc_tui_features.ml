(* The feature sheet's rows: what this TUI can do, one sentence each, with
   the door spelled the way you type it. [/features] draws this list; [?]
   answers "what does this key do here", and this answers "what is there to
   do at all" -- the question a fresh operator or a fresh Keeper has before
   any footer can help them.

   Every opener is checked against the machine that would answer it
   (test_tui_features): commands against the parser's spellings, keys against
   the key table's global row and its exported key constants, surfaces
   against the help sheet's own section list. A row without a real door is a
   build failure, and so is a door renamed under a sheet still advertising
   the old spelling. *)

type opener =
  | Command of string  (** the word after the slash; checked against the parser *)
  | Key of string  (** a key as the table spells it *)
  | Surface of string  (** a route, named the way the help sheet names it *)
  | Token of string  (** a wire name or a code-block fence, proven outside the TUI *)

type row = {
  opener : opener;
  description : string;  (** one sentence; long enough rows wrap, never cut *)
}

let opener_text = function
  | Command word -> "/" ^ word
  | Key key -> key
  | Surface route -> route
  | Token token -> token

(* Widest opener spelled above: "masc_tool_help" and "System / Tools" are 14
   cells. A longer opener pads by the minimum and its row simply starts its
   sentence further right, the way the help sheet's long usages do. *)
let opener_cells = 14

let sections =
  [ ( "Get anywhere"
    , [ { opener = Key ":"; description = "command palette: jump anywhere by name" }
      ; { opener = Key ";"
        ; description = "agenda: what is coming, who is waiting on you" }
      ; { opener = Key "@"
        ; description = "answering: who is mid-turn or just finished" }
      ; { opener = Key "Ctrl-L"
        ; description = "Activity pane: what every keeper is doing now" }
      ; { opener = Command "keeper"
        ; description = "switch this pane to another keeper: /keeper <name>" }
      ; { opener = Key "&"
        ; description = "Collab: watch MSX/DOS, manage play links" }
      ; { opener = Surface "Dashboard"
        ; description = "decisions and remembered conversations; Enter opens the selected destination" }
      ; { opener = Surface "Work"
        ; description = "Goals, Tasks and evidence; t switches lists, Enter reads details" }
      ; { opener = Surface "Keepers"
        ; description = "conversations, settings and history; c opens chat, l opens logs" }
      ; { opener = Surface "Usage"
        ; description = "f selects an account, v cycles Plan/Trend/Keepers, a restores all accounts" }
      ; { opener = Surface "Board"
        ; description = "Enter reads a discussion; S follows its recorded successor, Esc returns" }
      ; { opener = Surface "Workspace"
        ; description = "Enter browses files; Ctrl-P in Code finds checkout files; v reads selected repository context" }
      ; { opener = Surface "System"
        ; description = "p cycles settings panes; on Models, v reads complete account/model details" }
      ] )
  ; ( "Steer a turn"
    , [ { opener = Command "steer"
        ; description = "type over a running turn: /steer <message>" }
      ; { opener = Command "interrupt"
        ; description = "stop a streaming turn: /interrupt [keeper]" }
      ; { opener = Command "run-next"
        ; description = "promote your queued message and resume" }
      ; { opener = Command "priority"
        ; description = "auto-promote typed input: /priority on|off" }
      ; { opener = Command "queue"
        ; description = "inspect and manage waiting messages" }
      ; { opener = Command "find"
        ; description = "jump to the newest message holding text" }
      ; { opener = Command "copy"
        ; description = "latest completed reply to the clipboard" }
      ] )
  ; ( "See what happened"
    , [ { opener = Command "artifacts"
        ; description = "Markdown/HTML reports: f selects format, t filters today, Enter reads full width; {/} selects revisions" }
      ; { opener = Command "context"
        ; description = "inspect the last observed provider input" }
      ; { opener = Key "Ctrl-X"
        ; description = "context inspector over this chat's last turn" }
      ; { opener = Command "measurement"
        ; description = "read a published measurement: /measurement <sha256>" }
      ; { opener = Command "errors"
        ; description = "this chat's loading failures, in a scrollable log" }
      ; { opener = Command "diff"; description = "Git working-tree changes and diff" }
      ; { opener = Command "patch"
        ; description = "patch review for pending changes (alias /review)" }
      ] )
  ; ( "Bring media in"
    , [ { opener = Command "image"
        ; description = "draw an image file on the terminal: /image <path>" }
      ; { opener = Command "attach"
        ; description = "stage an image for the next message: /attach <path>" }
      ; { opener = Command "ref"
        ; description = "stage an image reference: /ref <url|file_id>" }
      ; { opener = Command "listen"
        ; description = "play the newest audio or MIDI attachment" }
      ; { opener = Command "embeds"
        ; description = "inline rich embed cards: /embeds on|compact|off" }
      ] )
  ; ( "Draw and call"
    , [ (* Both fences draw in the chat's code-block reader
           (bin/masc_tui_mermaid_grammar.ml, bin/masc_tui_alphatex.ml; the
           alphatex drawing and highlighting shipped as #42777 and #42779,
           both marked Experimental in CHANGELOG.md). *)
        { opener = Token "```mermaid"
        ; description = "this code block draws as a diagram" }
      ; { opener = Token "```alphatex"
        ; description = "guitar tablature from a code block (Experimental)" }
      ; { opener = Command "score"
        ; description = "full alphaTex notation and playback in this terminal: /score [N]" }
      ; { opener = Command "music"
        ; description = "phrases, arrangements and takes: /music or Dashboard s; plain terminal supported" }
      ; (* The in-tool help surface the tool schema descriptions point at:
           lib/tool_surface/tool_help_registry.ml registers it by this name. *)
        { opener = Token "masc_tool_help"
        ; description = "ask how and when to use any tool" }
      ; (* config/tools/masc_wiki_lint.toml names the tool; its description's
           first word is the Experimental mark. *)
        { opener = Token "masc_wiki_lint"
        ; description = "check the wiki, write nothing (Experimental)" }
      ; { opener = Surface "System / Tools"
        ; description = "the tool catalog, receipts and usage" }
      ; { opener = Command "addons"
        ; description = "cross-lane observations and packaging: /addons" }
      ; { opener = Command "play"
        ; description = "shared DOS play links and QR invites: /play invites" }
      ] )
  ]

let all_rows = List.concat_map snd sections

let lines ~width =
  (* The rows draw plain, deliberately: [/features] answers as a chat notice,
     and a notice passes through [Keeper_chat.terminal_safe_text], which turns
     every control byte -- ESC with them -- into text the operator reads. A
     dimmed heading shipped as a visible "[2m"; the hierarchy lives in the
     diamond and the column instead of in colour, the way the [/help]
     catalog's plain rows do. *)
  (* The item marker also keeps a fence name at the start of a row from
     opening a Markdown block when this sheet is placed in a chat notice. *)
  let prefix = "  \xe2\x80\xa2 " in
  let column = Masc_tui_message_layout.display_width prefix + opener_cells + 2 in
  let row_lines row =
    let opener = opener_text row.opener in
    let pad =
      max 2 (opener_cells - Masc_tui_message_layout.display_width opener)
    in
    match
      Masc_tui_message_layout.wrap_words
        ~max_cells:(max 1 (width - column))
        row.description
    with
    | [] -> []
    | first :: rest ->
      let lead = prefix ^ opener ^ String.make pad ' ' in
      (lead ^ first)
      :: List.map (fun piece -> String.make column ' ' ^ piece) rest
  in
  let section_lines (title, rows) =
    ("\xe2\x97\x86 " ^ title)
    :: List.concat_map row_lines rows
    @ [ "" ]
  in
  List.concat_map section_lines sections
