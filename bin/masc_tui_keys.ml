(* The key table — data first, then the display projections. Most dispatch
   remains the ordered match in masc_tui.ml; cross-surface shortcuts whose
   spelling is shared with the displays classify through this module too.
   That keeps one binding record authoritative for both behaviour and
   discoverability (#30356 taught the cost of the two drifting apart). *)

open Masc_tui_types

type group = Navigate | Act | Search | Meta

type binding = {
  key : string;
  label : string;
  help : string option;
  group : group;
}

let b ?help group key label = { key; label; help; group }

(* [None] is shared by all Config panes; [Some panes] belongs only to those
   input handlers. Keep availability beside the binding, not in a second key
   list inferred from the rendered label. *)
let config_bindings =
  [ b Navigate "j/k" "select / scroll", Some
      [ Config_runtime; Config_models; Config_params; Config_prompts
      ; Config_presets; Config_themes; Config_voice ]
  ; b Navigate "p" "next pane"
      ~help:"runtime.toml / models / params / prompts / presets / themes / voice", None
  ; b Navigate "PgUp/PgDn" "page"
      ~help:"pages runtime.toml, the voice reading and the detail of prompts \
             and presets, and moves the selection a page on models and themes",
      Some [ Config_runtime; Config_models; Config_prompts; Config_presets
           ; Config_themes; Config_voice ]
  ; b Navigate "v" "read status"
      ~help:"runtime.toml: source revision, validation issues, and application/restart details",
      Some [ Config_runtime ]
  ; b Navigate "9" "Runtime"
      ~help:"runtime status, lane routing, probes and connected clients", None
  ; b Navigate "s" "resources"
      ~help:"the MCP resource catalog, off the ring under Config", None
  ; b Navigate "t" "tools"
      ~help:"the tool catalog, receipts, and usage, off the ring under Config", None
  ; b Act "e" "edit"
      ~help:"params use a type-aware field; runtime.toml previews; models open source; prompts save an override; voice opens the setup wizard",
      Some [ Config_runtime; Config_models; Config_params; Config_prompts; Config_voice ]
  ; b Act "E" "advanced JSON"
      ~help:"on params only: edit the exact JSON value", Some [ Config_params ]
  ; b Act "Enter" "edit / use"
      ~help:"edit the selected param; on themes, use that colour scheme",
      Some [ Config_params; Config_themes ]
  ; b Act "x" "default / clear"
      ~help:"params return to default; prompts clear override; themes follow terminal colours",
      Some [ Config_params; Config_prompts; Config_themes ]
  ; b Act "f" "filter"
      ~help:"on themes, cycle All / Dark / Light schemes", Some [ Config_themes ]
    (* Pane-scoped writes. Each of these is the only key that does what it
       does, and none of them were listed: presets could be made and put
       back, and the prompt list could be switched between three readings,
       with nothing on screen saying so. Short labels: the pane each belongs
       to and what it does are in the help, which the ? overlay draws in
       full. *)
  ; b Act "n" "new"
      ~help:"on presets, name a preset holding the configuration as it stands",
      Some [ Config_presets ]
  ; b Act "u" "restore"
      ~help:"on presets, put the selected one back; press twice to confirm",
      Some [ Config_presets ]
  ; b Act "i" "input"
      ~help:"on prompts, the input this prompt was last given", Some [ Config_prompts ]
  ; b Act "a" "fragments / keeper voice"
      ~help:"on prompts, show or hide the internal pieces the main prompts \
             are built from, though not on the runtime assets reading; on \
             voice, give the selected keeper its own voice",
      Some [ Config_prompts; Config_voice ]
  ; b Act "o" "assets"
      ~help:"on prompts, switch between the read-only runtime assets and \
             the registry you can override",
      Some [ Config_prompts ]
  ; b Act "Esc" "overview", None
  ; b Meta "r" "reload", None
  ; b Meta "Tab" "next", None
  ; b Meta "q" "quit", None
  ]

(* The Runtime keys, by the reading they act on. [p] goes somewhere different
   from each reading, so the footer names where it goes from here while the
   cheat sheet names the whole walk. The lane edits -- [e], [a], [x], [J]/[K],
   [D] -- act on the keeper lane under the cursor, and the all-runtimes reading
   has no lane row to act on. *)
type runtime_key =
  | Every_reading of binding
  | Keeper_lanes_only of binding
  | Reading_walk

let runtime_reading_walk_help =
  "walk the three substrate readings; the third is the standalone Lanes surface"

let runtime_keys =
  [ Every_reading (b Navigate "j/k" "move / scroll")
  ; Every_reading (b Navigate "PgUp/PgDn" "detail page")
  ; Every_reading
      (b Act "Right / Enter" "detail"
         ~help:"show the full runtime, lane, dispatch, and probe fields")
  ; Reading_walk
  ; Every_reading
      (b Navigate "c" "clients"
         ~help:"everyone attached to this workspace, off the ring under Runtime")
  ; Keeper_lanes_only
      (b Act "e" "add failover"
         ~help:"append a failover candidate to the lane under the cursor (keeper lanes only)")
  ; Keeper_lanes_only
      (b Act "a" "new lane"
         ~help:"name a new lane, then pick its first runtime; e adds the rest")
  ; Keeper_lanes_only
      (b Act "x" "drop candidate"
         ~help:"take the candidate under the cursor out of its lane; the last one \
                cannot go, remove the lane instead")
  ; Keeper_lanes_only
      (b Act "J/K" "move candidate" ~help:"move the candidate under the cursor down or up its lane")
  ; Keeper_lanes_only
      (b Act "f" "default runtime"
         ~help:"replace [runtime].default, what a keeper with no assignment walks")
  ; Keeper_lanes_only
      (b Act "m" "vision fleet"
         ~help:"edit [runtime].media_failover in the slot editor; refused while \
                boot dropped one of its entries")
  ; Keeper_lanes_only
      (b Act "R" "rename lane"
         ~help:"give the lane under the cursor another name; the assignments \
                that route to it and [runtime].default, when it names it, are \
                rewritten in the same write. The field opens on the name it \
                has now")
  ; Keeper_lanes_only
      (b Act "D" "remove lane"
         ~help:"remove the lane under the cursor; press twice. Refused while a keeper is \
                assigned to it")
  ; Every_reading (b Act "Left / Esc" "back")
  ; Every_reading
      (b Search "/" "find" ~help:"jump the cursor to a matching lane id or runtime id")
  ; Every_reading (b Search "n / N" "next / previous match")
  ]

let runtime_sheet_binding = function
  | Every_reading binding | Keeper_lanes_only binding -> binding
  | Reading_walk ->
    b Navigate "p" "keeper lanes / all runtimes / service lanes"
      ~help:runtime_reading_walk_help

let runtime_footer_binding ~(mode : runtime_mode) = function
  | Every_reading binding -> Some binding
  | Keeper_lanes_only binding ->
    (match mode with
     | Runtime_lanes -> Some binding
     | Runtime_all -> None)
  | Reading_walk ->
    Some
      (b Navigate "p"
         (match mode with
          | Runtime_lanes -> "all runtimes"
          | Runtime_all -> "service lanes")
         ~help:runtime_reading_walk_help)

(* Ctrl-S folds the turn dashboard back to its progress line, and unfolds it.
   The terminal used to take this byte for flow control -- raw mode clears
   IXON now, which is what makes it bindable at all. A letter would not do:
   in the composer every letter is text.

   The byte and the printed name sit together because the chat pane prints
   the name on the folded line while masc_tui.ml matches the byte. Apart,
   one of them drifts and the line names a key that does nothing. *)
let expand_turn_key = "\019"
let expand_turn_label = "Ctrl-S"

(* The control keys a body row names beside a figure or a draft. They are
   here, beside the bindings that list them, so a row and the footer cannot
   spell one key two ways: the composer said "^Y" under a footer saying
   "Ctrl-Y", and the context header "^X" for a key the table did not list. *)
let voice_speak_key = "Ctrl-Y"
let voice_listen_key = "Ctrl-A"
let roster_toggle_key = "Ctrl-B"

(* Ctrl-X opens the context inspector from the chat. It is named on the
   context header, beside the figure it explains, and nowhere else: the
   footer has no room for a key whose home is that row. *)
let context_inspector_key = "\024"
let context_inspector_label = "Ctrl-X"

(* The two voice keys, named for a reader looking at an empty draft. One
   spelling for every row that takes a draft, so the composer row and the chat
   pane cannot come to describe the same keys two ways. *)
let voice_keys_hint =
  Printf.sprintf "(%s to speak, %s to keep listening)" voice_speak_key
    voice_listen_key


let keepers_jump =
  b Meta "2" "keepers"
    ~help:"jump to Keepers when the active field or panel does not use 2"

let global =
  [ b Meta "Tab / Shift-Tab" "next / previous surface"
  ; keepers_jump
  ; b Meta "r" "refresh the current surface"
  ; b Meta "i" "focus the composer (message the shown keeper)"
  ; b Meta ":" "command palette"
  ; b Meta ";"
      "agenda: what is coming, and who is waiting on you; Enter opens a row"
  ; b Meta "@" "answering: who is mid-turn or just finished; Enter opens their chat"
  ; b Meta "?" "this help"
  ; b Meta "&"
      "the MSX screen: the emulator core over the whole terminal (esc: back; \
       also `:` go MSX)"
  ; b Meta roster_toggle_key "keeper roster beside the chat — put away until you ask"
      ~help:"the Activity pane (Ctrl-L) answers the same question for every \
             keeper, so the column starts hidden; this brings it back on a \
             terminal wide enough to hold it"
  ; b Meta "Ctrl-L"
      "show or hide the Activity pane: what every keeper is doing right now, and \
       on its Changes tab the selected keeper's files (press the header to switch)"
      ~help:"the wheel over it scrolls the full list; a press picks a keeper, a second press opens its chat"
  ; b Meta "Ctrl-^" "show or hide Browser Lane; retain tab and scroll"
  ; b Meta "Ctrl-T" "release the mouse so you can drag-select and copy"
  ; b Navigate "Ctrl-]" "follow the reference under the cursor"
      ~help:"and Esc on the surface it opens comes back here"
  ; b Meta "q" "quit"
  ]

(* The plain-listing tail every converted footer shares. *)
let listing_meta = [ b Meta "r" "refresh"; b Meta "Tab" "next"; b Meta "q" "quit" ]

let keeper_actions =
  [ b Act "c" "chat" ~help:"chat with the keeper"
  ; b Act "l" "logs"
  ; b Act "t" "calls" ~help:"tool calls"
  ; b Act "u" "runtime" ~help:"pick a runtime lane"
  ; b Act "g" "yolo / auto" ~help:"toggle yolo / auto tool approval"
  ; b Act "p / w" "pause / wake"
  ; b Act "s" "shutdown"
  ; b Act "e" "settings"
  ; b Act "f" "files" ~help:"file changes this keeper wrote"
  ; b Act "a" "new" ~help:"new keeper"
  ; b Act "x" "delete" ~help:"stop and permanently remove the confirmed keeper"
  ; b Navigate "D" "deletions" ~help:"durable deletion records, failures and cleanup retry"

  ]

(* The keys that move a row list by more than a step. Shared rather than
   retyped per surface: they answer wherever [row_list] in masc_tui.ml finds a
   list, and that is one decision, so the table should not be able to claim
   them for one listing and forget them on the next. *)
let row_list_jumps =
  [ b Navigate "PgUp/PgDn" "page"
  ; b Navigate "Home/End" "top/bottom"
  ]

(* The same two, minus the page key, for the surfaces whose own entry already
   spells one because a detail pane under them pages too. *)
let row_list_edges = [ b Navigate "Home/End" "top/bottom" ]

(* The two keys the whole surface exists for, as one binding. Spelled apart
   ("y" and "n") they were two items a fitted row could drop one at a time,
   and the row that cannot lose the way to answer keeps its keys by that
   spelling: [Masc_tui_footer.never_dropped_keys] pins "y / n", which the open
   approval's own footer never said. *)
let approval_decide =
  b Act "y / n" "decide" ~help:"y confirms, n denies the approval under the cursor"

let approval_retry =
  b Act "R" "retry Auto Judge"
    ~help:"only when the blocked row is safely rearmable"

(* Where a Fusion run's caller and its Board evidence are, on the list and
   in the detail alike: one binding each, so the two footers cannot name the
   key two ways. *)
(* The keys a post answers to, in the Board's surface list and in the read
   footer alike. The read pane spelled them a second time in its own row --
   "[c] Reply   [v/V] Vote (+/-)   [Y] Copy Link   [Esc] Back" -- above a
   footer that spelled c, Y and Esc again and had no vote key at all, so that
   row was the only place on the screen that said v votes. *)
let board_vote_key = b Act "v / V" "vote" ~help:"vote the post up or down"
let board_reply_key = b Act "c" "reply" ~help:"reply (while reading)"
let board_copy_key = b Act "Y" "copy link" ~help:"copy the selected post reference"

let fusion_caller_key = b Navigate "K" "calling Keeper"
let fusion_board_key = b Navigate "B" "Board evidence"

let for_surface = function
  | Overview ->
      [ b Navigate "j/k" "events" ~help:"scroll events"
      ; b Navigate "h/l" "pane" ~help:"move between events and tasks"
      ; b Navigate "m" "telemetry"
          ~help:"system metrics and multicore engine telemetry"
      ; b Act "t" "tasks" ~help:"hand j/k to the task list"
      ; b Act "Right / Enter" "open" ~help:"open the selected task"
      ; b Act "Left / Esc" "back" ~help:"close detail / back to events"
      ; b Navigate "Home/End" "top/bottom"
          ~help:"the ends of the events column, or of an open task's detail"
      ]
      @ listing_meta
  | Acting ->
      [ b Navigate "1 / 2" "Events / Logs"
          ~help:"Events, or the server's own log lines; l opens Logs as well"
      ; b Navigate "j/k" "move" ~help:"select an event / scroll its evidence"
      (* [Navigate], not [Act]: the group is documented as "doing something to
         the thing under the cursor", and this key does nothing to the event
         the cursor is on -- it chooses which events the list holds at all,
         the way Planning spells its own filter. The group is also the
         retention order, so in [Act] this key was given up before
         [Home/End]. *)
      ; b Navigate "f" "filter" ~help:"cycle Turns / Actions / Everything; Turns has no individual event evidence"
      (* "evidence", not "event evidence": every row on this surface is an
         event, so the label was saying the surface's own subject back to the
         reader. The six cells it gives back are what lets [f] stay on the row
         beside it -- see the footer case in test_tui_keys. *)
      ; b Act "Enter" "evidence" ~help:"Actions/Everything: exact selected event; Turns are aggregates"
      (* One key, one row. Esc closes the evidence pane when one is open
         (masc_tui.ml guards the close on acting_detail) and otherwise
         leaves the surface, so two rows read as two bindings. *)
      ; b Act "Esc" "back"
          ~help:"close event evidence; from the list, back to Overview"
      (* One row per action. g and G reach the ends Home and End reach, and
         l the tab 2 opens; a row for each spent two of the footer's places
         on actions it already showed, and at 120 columns the fitter dropped
         Enter -- the key that opens an event -- to keep them. The rows are
         the spellings every other reader shares; the extras are in help. *)
      ; b Navigate "Home/End" "newest / oldest"
          ~help:"g and G as well; the ring counts back from the newest, so \
                 its top is now"
      ; b Meta "Tab" "next"
      ; b Meta "q" "quit"
      ]
  | Metrics ->
      [ b Navigate "j/k" "scroll"
      ; b Navigate "1-3" "section"
          ~help:"1: Engine & Scheduler · 2: Work & Outcomes · 3: Memory & Gate Safety"
      ; b Navigate "s" "cycle" ~help:"cycle telemetry section"
      ; b Act "Esc" "overview"
      ; b Meta "r" "refresh"
      ; b Meta "Tab" "next"
      ; b Meta "q" "quit"
      ]
  | Keepers Keeper_list ->
      (b Navigate "j/k" "move" ~help:"move the roster cursor")
      :: (b Act "Right / Enter" "detail" ~help:"keeper detail")
      :: keeper_actions
      @ [ b Search "/" "search" ~help:"search names; Enter keeps the query"
        ; b Search "n / N" "next / previous match"
        ; b Act "Esc" "overview"
        ]
      @ row_list_jumps @ listing_meta
  | Keepers Keeper_detail ->
      [ b Navigate "h/l" "pane" ~help:"move between roster and detail"
        (* The tabs come from the list the strip draws. Named by hand this row
           said "Info / Settings / Secrets / GitHub" while the strip drew
           nine, so a reader who trusted the sheet did not know Sandbox,
           Identity, Channels, Automation or Runs existed -- and Sandbox is
           the second tab. Config's [p] had the same drift and a test to
           catch it; this row cannot drift at all now. *)
      ; b Navigate "[ / ]" "tabs"
          ~help:
            ("detail tabs: "
             ^ String.concat " / "
                 (List.map Masc_tui_types.keeper_detail_tab_label
                    Masc_tui_types.keeper_detail_tabs))
      ; b Act "o" "logs"
          ~help:"open container logs in Sandbox; Keeper activity elsewhere"
      ; b Act "U" "runtime" ~help:"pick a runtime lane"
      ; b Act "Left / Esc" "back"
      ; b Navigate "Home/End" "top/bottom" ~help:"the ends of this tab"
      ]
      @ List.filter
          (fun binding -> binding.key <> "l" && binding.key <> "u")
          keeper_actions
  | Keepers Keeper_logs ->
      (* The shared tail was missing here while the renderer's own footer
         string carried it, so the sheet and the footer disagreed about
         whether r/q worked on this screen. *)
      [ b Navigate "j/k" "scroll"; b Act "Left / Esc" "back" ] @ listing_meta
  | Keepers Keeper_calls ->
      [ b Navigate "j/k" "scroll"
      ; b Navigate "Home/End" "top/bottom"
      ; b Act "Left / Esc" "back"
      ]
      @ listing_meta
  | Keepers Keeper_message ->
      [ b Navigate "Left" "roster" ~help:"focus the visible Keeper roster"
      ; b Navigate "Right / Esc" "chat" ~help:"return focus to the chat composer"
      ; (* One key, two focuses: the roster when it holds focus, the history
           when the chat is scrolled back. Listed once so the table keeps the
           one-key-one-row contract (#33236). *)
        b Navigate "Up / Down" "roster move / scroll"
          ~help:"roster focused: move; chat scrolled back: adjust by one line"
      ; b Act "Enter" "send / open"
          ~help:"send from chat, or open the selected Keeper from the roster"
      ; b Act "Ctrl-J" "newline" ~help:"newline in the draft"
      ; b Act voice_speak_key "speak"
          ~help:"record into the draft; again to stop and keep what was said"
      ; b Act voice_listen_key "keep listening"
          ~help:"continuous capture on/off: each sentence starts the next capture"
      ; b Act "Ctrl-G" "next keeper" ~help:"next keeper with a chat open"
      ; b Act "Ctrl-U" "clear" ~help:"clear the draft"
      ; b Act "Ctrl-K / Ctrl-P" "queued line"
          ~help:"cancel / edit the last queued line"
      ; b Act "Ctrl-T" "queue"
          ~help:"inspect and manage waiting turns"
      ; b Navigate "PgUp/PgDn" "history" ~help:"scroll history by a page"
      ; b Act "Ctrl-R" "reasoning" ~help:"cycle reasoning hidden / folded / full"
      ; b Act "Ctrl-D" "tool detail" ~help:"toggle compact / full tool-call detail"
      ; b Act expand_turn_label "turn detail"
          ~help:
            "unfold the running turn's status rows, or fold them back to the \
             progress line"
      ; b Act "Ctrl-N" "journal detail"
          (* The three words are the states' own, the way Ctrl-R above spells
             its own. Pressing this answers "Librarian/Memory timeline: full",
             so a help promising "full detail" sends a reader looking for a
             state the pane never names. *)
          ~help:"cycle Memory journal summary / full / hidden"
      ; b Act "Ctrl-F" "message metadata"
          ~help:"cycle no clock / inline clock / full timestamp and request id"
      ; b Act "/approve /deny" "approval" ~help:"type a command and Enter to answer a tool approval"
      ; b Act "Ctrl-Q" "leave"
          ~help:"leave with a turn running, without interrupting it"
      ; b Act "Esc" "back" ~help:"back; during a turn, interrupt it"
      ]
  | Keepers Keeper_runtime_pick ->
      [ b Navigate "j/k" "move"
      ; b Act "Enter" "choose"
      ; b Act "d" "use the default"
          ~help:"drop this Keeper's own binding and follow [runtime].default"
      ; b Act "Esc" "back"
      ]
  | Lanes ->
      [ b Navigate "j/k" "move" ~help:"move the lane cursor"
      (* One destination, two keys. [o] came from #35915 and [A] from #35761,
         and each arrived with its own binding and its own wording -- the
         footer then spent two of its items saying "Lane Add-ons" and
         "add-ons", the heading named [o], and the guide named [A]. The
         dispatch was one arm the whole time ([Some "o" | Some "O" | Some "A"]
         on Lanes), so the table says so too. Both keys stay: a PTY walk
         presses [A] and the guide's first line names it. *)
      ; b Navigate "o / A" "Lane Add-ons"
          ~help:"inspect Lane Add-on declarations, instances and observations"
      ; b Act "Right / Enter" "runs"
          ~help:"open the standalone lane's exact runs"
      ; b Act "a" "append slot"
          ~help:"add a failover candidate to this lane's walk order"
      ; b Act "s" "slots"
          ~help:"edit the lane's declared slots in walk order: x drops, J/K \
                 reorders, Esc closes"
        (* The lane detail spent four rows on the file's shape and on this
           key, the same two sentences under every lane. They are here, where
           the key is. *)
      ; b Navigate "e" "lane config"
          ~help:
            "open this lane's runtime.exact_output_lanes section in the \
             preview-checked runtime.toml editor; slots is a required \
             non-empty catalog-ref array and cli_slots an optional \
             official-client runtime-id array"
      ; b Navigate "p" "runtime"
          ~help:"open the Runtime surface"
      ; b Act "Esc" "overview" ~help:"back to Overview"
      ; b Search "/" "find"
          ~help:"jump the cursor to a matching standalone lane; the run list \
                 and a run's detail carry no searchable rows"
      ; b Search "n / N" "next / previous match"
      ]
      @ row_list_jumps @ listing_meta
  | Clients ->
      [ b Navigate "j/k" "move" ~help:"move the roster cursor"
        (* Two doors, one action: both call [goto_surface Runtime]. As two
           bindings the sheet printed the answer twice, one row under the
           other, and the second row's help differed from the first by a
           pronoun. The compound spelling is the one the table already uses
           for [Left / Esc] and [o / A], and [key_atoms] splits the slash, so
           the footer keeps its Esc pin and both keys stay counted. *)
      ; b Act "p / Esc" "runtime"
          ~help:"back to the Runtime surface this hangs off"
      ; b Search "/" "find"
          ~help:"jump the cursor to a matching attached name"
      ; b Search "n / N" "next / previous match"
      ]
      @ row_list_jumps @ listing_meta
  | Board ->
      [ b Navigate "j/k" "move"
      ; b Act "Right / Enter" "read" ~help:"read the post"
      ; b Act "Left / Esc" "back" ~help:"close the post"
      ; b Act "w" "write" ~help:"write a post"
      ; board_vote_key
      ; board_reply_key
      ; b Navigate "[ / ]" "previous / next post"
          ~help:"while reading, open the post before or after this one"
      ; b Navigate "s" "sort" ~help:"cycle hot / trending / recent / updated / discussed"
      ; b Search "f / F" "next / previous hearth"
          ~help:"move forward or backward through all hearths"
      ; b Search "H" "choose hearth" ~help:"search hearth names and choose directly"
      ; b Navigate "z" "wide detail" ~help:"hide or show the post list while reading"
      ; board_copy_key
      ; b Navigate "Ctrl-W" "pane" ~help:"switch between the post list and detail pane"
      ; b Navigate "h/l" "pane" ~help:"focus the post list or detail pane"
        (* Beside [f], not instead of it: [f] narrows the list to one hearth,
           this jumps the cursor to a post without changing what is listed. *)
      ; b Navigate "PgUp/PgDn" "detail page"
        (* The global page dispatcher already scrolls the open post body and
           its comment thread by a window; it answers in the detail pane, so
           the help owed it a line. *)
      ; b Search "/" "find" ~help:"jump the cursor to a matching post id, author or title"
      ; b Search "n / N" "next / previous match"
      ]
      @ row_list_edges @ listing_meta
  | Approvals ->
      [ b Navigate "j/k" "move"
        (* The list draws each ask on one row. Enter is where a multi-line
           argument is readable before y answers it. *)
      ; b Act "Enter" "read the whole ask"
          ~help:"the reader takes its own keys: j/k and the page keys scroll it, \
                 Home/End reach its ends, [ / ] step asks, Esc goes back"
      ; approval_decide
      ; approval_retry
        (* The footer names this key and the sheet did not, so an operator who
           pressed [?] to find out how to answer a Keeper's question found
           every other key on the surface and not that one. The approval queue
           owns this surface's arrows and its y/n, which is why answering
           opens as its own mode rather than as a key on the row. *)
      ; b Act "a" "answer a question"
          ~help:"open the selected Keeper question in its own mode; Esc leaves it"
      ; b Navigate "[ / ]" "previous / next"
          ~help:"while a detail is open, step to the row before or after it"
      ; b Act "w" "Workspace Gate mode"
          ~help:"choose manual, Auto Judge or allow-all; Enter applies, Esc cancels"
      ; b Act "e" "external Gate lane"
          ~help:"choose how calls into outside services are reviewed; Enter applies"
      ]
      @ row_list_jumps @ listing_meta
  | Planning ->
      [ b Navigate "j/k" "move"
      ; b Navigate "v" "next Planning tab"
          ~help:"Goals, then the two task surfaces: Task Review and \
                 Task Verdicts. Not stages of one flow"
      ; b Act "Right / Enter" "detail"
      ; b Act "Left / Esc" "back"
      ; b Navigate "f" "filter" ~help:"cycle all / active / completed / dropped"
      ; b Navigate "s" "sort" ~help:"cycle phase / updated / due"
      ; b Navigate "[ / ]" "previous / next"
          ~help:"while a detail is open, step to the row before or after it"
      ; b Act "c" "request completion"
          ~help:"send the goal to the completion judge; press again to submit"
      ; b Act "a" "confirm proof"
          ~help:"read the proven Goal evidence; press again to confirm that exact proof"
      ; b Act "x" "drop"
      ; b Act "o" "reopen"
      ; b Act "Y" "copy link" ~help:"copy the selected goal reference"
        (* Over the goals [f] and [s] left on screen, in the order they are
           drawn: the search walks what the list shows, not the snapshot. *)
      ; b Search "/" "find" ~help:"jump the cursor to a matching goal id or title"
      ; b Search "n / N" "next / previous match"
      ]
      @ row_list_jumps @ listing_meta
  | Schedules ->
      [ b Navigate "j/k" "move" ~help:"move; in details, scroll the payload"
      ; b Navigate "PgUp/PgDn" "page"
      ; b Act "Right / Enter" "details" ~help:"open schedule details"
      ; b Act "Left / Esc" "back" ~help:"back to the schedule list"
      ; b Navigate "[ / ]" "previous / next"
          ~help:"while a detail is open, step to the row before or after it"
      ; b Act "n" "new" ~help:"create a schedule through a $EDITOR JSON form"
      ; b Act "e" "modify"
          ~help:"edit the selected active schedule; running/finished rows refuse"
      ; b Act "x" "cancel" ~help:"arm / confirm cancellation"
      ; b Act "Y" "copy link" ~help:"copy the selected schedule reference"
      ]
      @ row_list_edges @ listing_meta
  | Verification ->
      [ b Navigate "j/k" "move" ~help:"move; in details, scroll the evidence"
      ; b Navigate "v" "next Planning tab"
          ~help:"on to Task Verdicts, then back to Goals"
      ; b Navigate "h" "queue / history"
          ~help:"the queue is what a task is still waiting on; the history is \
                 every request ever submitted, which nothing removes"
      ; b Act "Right / Enter" "details" ~help:"read the request and evidence"
      ; b Act "Left / Esc" "back" ~help:"back to the list"
      ; b Navigate "[ / ]" "previous / next"
          ~help:"while a detail is open, step to the row before or after it"
      ; b Navigate "< / >" "newer / older"
          ~help:"step either list a page at a time; one page holds two \
                 hundred rows, so a shorter queue arrives whole"
      (* One item, spelled the way Approvals spells its own pair. Apart, the
         fitter gave up [x] and then [a], and what was left was a queue of
         work with no visible way to act on it -- which is the one thing this
         surface exists for. [Masc_tui_footer.never_dropped_keys] pins the
         pair whole; pinning [a] or [x] alone would pin the [a] that creates
         a keeper and the [x] that deletes one. *)
      ; b Act "a / x" "approve / reject"
          ~help:"a approves the row under the cursor (press twice); x rejects \
                 with a reason ($EDITOR form)"
      ; b Search "/" "find"
          ~help:"jump the cursor to a matching task id, title, or submitter; \
                 the queue answers this, an open detail does not"
      ; b Search "n / N" "next / previous match"
      ]
      @ row_list_jumps @ listing_meta
  | Harness ->
      [ b Navigate "j/k" "move" ~help:"move; in a verdict, scroll"
      ; b Navigate "v" "next Planning tab" ~help:"back round to Goals"
      ; b Navigate "PgUp/PgDn" "page"
      ; b Act "Right / Enter" "verdict" ~help:"open the full evaluator verdict"
      ; b Act "Left / Esc" "back" ~help:"back to the verdict list"
      ; b Navigate "[ / ]" "previous / next"
          ~help:"while a detail is open, step to the row before or after it"
      ; b Act "y" "agree" ~help:"record the machine's verdict as yours"
        (* [x], not [n]: this surface answers the row search, and [n] / [N]
           step it. Spelled the way Verification spells its own rejection. *)
      ; b Act "x" "overrule" ~help:"record the opposite verdict; $EDITOR takes the reason"
      ; b Act "Y" "copy task" ~help:"copy a link to the task on Overview"
      ; b Search "/" "find" ~help:"jump the cursor to a matching task id or title"
      ; b Search "n / N" "next / previous match"
      ]
      @ row_list_edges @ listing_meta
  | Fusion ->
      (* [fusion_mode] owns list/detail (masc_tui_types.ml); the detail
         footer is [footer_hints_fusion_detail], which also appends the live
         scroll position this static table cannot know. *)
      [ b Navigate "j/k" "move"
      ; b Navigate "PgUp/PgDn" "page"
      ; b Act "Enter" "open" ~help:"open a retained run or its historical Board evidence"
      ; b Navigate "[ / ]" "previous / next"
          ~help:"while a detail is open, step to the row before or after it"
      ; fusion_caller_key
      ; fusion_board_key
      ; b Act "Y" "copy" ~help:"copy the selected Fusion run reference"
      ; b Search "/" "find"
          ~help:"jump the cursor to a matching run id, Keeper or preset; an \
                 open run's detail carries no searchable rows"
      ; b Search "n / N" "next / previous match"
      ; b Act "Esc" "back" ~help:"leave detail, or return to Overview"
      ]
      @ row_list_edges @ listing_meta
  | Memory ->
      [ b Navigate "j/k" "move" ~help:"move the keeper row"
      ; b Act "Enter" "facts"
          ~help:"browse what the selected keeper actually remembers"
      ; b Act "a / A" "all fleet"
          ~help:"browse and search consolidated memory across the entire fleet"
      ; b Act "s" "sort"
          ~help:"cycle sort keepers (facts, size, delta, state, name)"
      ; b Act "Esc" "clear / back"
          ~help:"clear the filter, or return to Overview"
      ; b Search "/" "filter"
          ~help:"show only keepers whose id or state matches"
      ; b Search "n / N" "next / previous match"
      ]
      @ row_list_jumps @ listing_meta
  | Repositories ->
      [ b Navigate "j/k" "scroll"
      ; b Act "Enter" "browse"
          ~help:"open the repository tree, or the selected changed file"
      ; b Navigate "H" "recent activity" ~help:"recorded clone writes by Keeper and Task in the last day"
      ; b Act "d" "Git changes"
          ~help:"show the selected repository's current working-tree changes"
      ; b Act "a" "add" ~help:"register a repository; opens $EDITOR"
      ; b Act "Left / Esc" "back"
          ~help:"leave Git changes, or return to Overview"
      ; b Search "/" "find"
          ~help:"jump the cursor to a matching repository, or to a changed \
                 path while Git changes is open"
      ; b Search "n / N" "next / previous match"
      ]
      @ row_list_jumps @ listing_meta
  | Changes ->
      (* "move", not "scroll": the keys move the marked row and the window
         follows it, which is also what the surface's own footer says. *)
      [ b Navigate "j/k" "move"
      ; b Navigate "[ / ]" "keeper" ~help:"previous / next keeper"
      ; b Act "Right / Enter" "written diff"
          ~help:"what the call wrote, as a diff"
      ; b Act "Left / Esc" "back" ~help:"close the diff"
      ; b Act "d" "tree diff" ~help:"what the tree holds now"
      ; b Act "v" "view code"
          ~help:"the file on the Code surface, read from the keeper's own \
                 workspace"
      ; b Search "/" "find"
          ~help:"jump the cursor to a matching written path"
      ; b Search "n / N" "next / previous match"
      ; b Act "o" "editor" ~help:"open in $EDITOR / $NVIM"
      ]
      @ row_list_jumps @ listing_meta
  | Connectors ->
      [ b Navigate "B" "Browser Lane"
          ~help:"read browser tabs and page text; select live / automation inside Browser"
      ; b Act "Ctrl-O" "Browser screenshot"
          ~help:"inside Browser Lane: preview the selected tab; any key returns"
      ; b Navigate "j/k" "scroll"
      ; b Act "b / u" "bind / unbind" ~help:"bind / unbind a channel"
      ; b Act "Esc" "keeper" ~help:"back to the selected Keeper"
      ; b Search "/" "find" ~help:"jump the cursor to a matching transport"
      ; b Search "n / N" "next / previous match"
      ]
      @ row_list_jumps @ listing_meta
  | Runtime ->
      List.map runtime_sheet_binding runtime_keys @ row_list_edges @ listing_meta
  | Config ->
      List.map fst config_bindings
  | Resources ->
      (* Two panes with two meanings, and the keys below say so once rather
         than per row: with the list focused the cursor moves and [/] lands
         it on a match; with the text focused the same keys move the reading.
         Both ends answer to Home and End. *)
      [ b Navigate "j/k" "move"
          ~help:"move the list; with the text focused, scroll it"
      ; b Navigate "h/l" "pane" ~help:"focus the resource list or text"
      ; b Navigate "Ctrl-W" "focus" ~help:"switch between resource list and text"
      ; b Navigate "J/K" "scroll text"
      ; b Navigate "[ / ]" "previous / next"
          ~help:"while the detail is focused, read the adjacent resource"
      ; b Navigate "PgUp/PgDn" "page"
          ~help:"a page of the list, or of the text when it is focused"
      ; b Navigate "Home/End" "top/bottom"
          ~help:"the first or last resource, or the ends of the text when it                  is focused"
      ; b Act "Enter" "read" ~help:"read the selected resource"
      ; b Act "Esc" "back"
          ~help:"the text hands back to the list; the list leaves for Config"
      ; b Search "/" "find"
          ~help:"jump the cursor to a matching resource name; the list has to                  be focused for there to be a cursor to land"
      ; b Search "n / N" "next / previous match"
      ; b Meta "r" "reload"
      ; b Meta "Tab" "next"
      ; b Meta "q" "quit"
      ]
  | Code ->
      (* A row surface: masc_tui_types gives it a searchable row list
         (code_entries), so the cursor and "/" are real here, and Enter drills
         one directory level (the /workspace/children route is lazy). Claimed
         from those two facts rather than from the render, so the footer does
         not advertise a key nothing handles. *)
      [ b Navigate "j/k" "move"
      ; b Navigate "h/l" "pane" ~help:"focus the tree or open file"
      ; b Act "Right / Enter" "open" ~help:"drill in, or open the file"
        (* Esc walks back out the way Enter came in: it closes an open file
           first, and only climbs a directory once no file is open. From the
           project root, Esc alone leaves for Workspace, the ring parent --
           Left stays on the surface, the same convention as every other
           off-ring child. A key that works and is not listed is the same
           drift as a listed key that does nothing, pointing the other way. *)
      ; b Act "Left / Esc" "back"
          ~help:"close the history, then the file, then climb one \
                 directory; Esc at the project root leaves for Workspace"
      ; b Navigate "Shift-Left / Shift-Right" "pan"
          ~help:"with a file open, scroll it sideways one cell at a time"
      ; b Search "/" "find"
          ~help:"jump the cursor to a match: the tree, or the open file's \
                 lines"
      ; b Search "n / N" "next / previous match"
      ; b Act "K" "hover"
          ~help:"ask the language server what a name on the cursor line is \
                 (one name asks at once; several open the palette as \
                 choices)"
      ; b Act "R" "references"
          ~help:"ask the language server where a name on the cursor line is \
                 used; needs the project's reference index, and says which \
                 command builds it when there is none"
      ; b Act "D" "definition"
          ~help:"jump to where a name on the cursor line is defined (one \
                 name jumps at once; several open the palette as choices)"
      ; b Act "B" "back"
          ~help:"walk back through the definition jumps, newest first"
      ; b Act "b" "blame"
          ~help:"who last touched each run of lines, in the margin; b again \
                 drops it"
      ; b Act "m" "notes"
          ~help:"the memos in the open file: comments on their own row \
                 reading masc(name): text, or masc(name) question: text; m \
                 again closes the list"
      ; b Act "d" "diff"
          ~help:"on the project tree, list every working-tree change; on an \
                 open file, show that file's diff against HEAD"
      ; b Act "Enter (history)" "open"
          ~help:"a commit answers with its pull request, from its (#N) and \
                 the repository's remote"
      ; b Act "H" "history"
          ~help:"the commits that touched the open file, newest first \
                 (H or Esc closes)"
      ]
      @ row_list_jumps @ listing_meta
  | Tools ->
      [ b Navigate "j/k" "scroll"
      ; b Navigate "Home/End" "top/bottom"
      ; b Navigate "p" "section"
          ~help:"available / async runs / receipts / usage / all tools"
      ; b Navigate "J/K" "Skill" ~help:"select a published Skill"
      ; b Navigate "[ / ]" "Keeper" ~help:"change the effective Keeper surface"
      ; b Act "c / C" "new Skill"
          ~help:"open $EDITOR on a template for a new Skill; c starts an \
                 instruction Skill, C starts a composition Skill"
      ; b Act "e" "edit Skill"
          ~help:"open the selected SKILL.md in $EDITOR, validate, CAS-save, and publish"
      ; b Act "Esc" "config" ~help:"back to the Config surface it hangs off"
      ]
      @ listing_meta
  | System_logs ->
      [ b Navigate "1 / 2" "Events / Logs"
      ; b Navigate "j/k" "move / scroll"
      ; b Navigate "PgUp/PgDn" "detail page"
      ; b Navigate "[ / ]" "previous / next"
          ~help:"while detail is open, inspect the adjacent visible log entry"
      ; b Act "l" "level floor"
          ~help:"raise the minimum level; after error, back to everything"
      ; b Act "v" "verbose"
          ~help:"toggle DEBUG rows directly; off uses the INFO floor"
      ; b Act "c" "category"
          ~help:"cycle through the categories this page carries"
      ; b Act "Right / Enter" "detail"
          ~help:"show the full message, source, category, turn, and JSON details"
      ; b Act "Left / Esc" "back"
      ; b Search "/" "find"
          ~help:"jump the cursor to a matching module, keeper, or message, \
                 over the rows the level and category filters leave"
      ; b Search "n / N" "next / previous match"
      ]
      @ row_list_edges @ listing_meta

let group_rank = function Navigate -> 0 | Act -> 1 | Search -> 2 | Meta -> 3

(* Sort by group, then flatten to the footer's "key:label  key:label" form.
   Both the static per-surface footer and the Fusion detail footer (which
   appends a live scroll position) render through this one projection. *)
let hints_of_bindings bindings =
  bindings
  |> List.stable_sort (fun a b -> compare (group_rank a.group) (group_rank b.group))
  |> List.map (fun { key; label; _ } -> key ^ ":" ^ label)
  |> String.concat "  "

let footer_hints surface = hints_of_bindings (for_surface surface)

(* The keys an open approval answers to. Its footer was written out in the
   renderer, which is how it came to spell the decision keys apart from the
   queue behind it and to call [R] something the key table does not. *)
let footer_hints_approval_detail =
  hints_of_bindings
    [ b Navigate "j/k" "scroll"
    ; approval_decide
    ; approval_retry
    ; b Act "Esc" "back"
    ]

(* The Board draft's two footers were written out in the renderer, and the
   pane above them then spelled the same key a second way: "Ctrl-E: $EDITOR"
   over a footer saying "Ctrl-E:$EDITOR", with "Enter: newline" beside it
   that the footer never named. Both rows project from here, and the pane
   keeps to what the draft is and where it goes. *)
let board_compose_writing_bindings =
  [ b Act "Enter" "newline" ~help:"newline in the draft; Esc opens the send menu"
  ; b Act "Ctrl-E" "$EDITOR" ~help:"hand the draft to $EDITOR and take it back"
  ; b Meta "Esc" "menu" ~help:"send, discard, or keep writing"
  ; b Meta "Tab" "surfaces"
  ]

(* No [q] here: while the draft has the keys, [q] is a printable scalar and
   goes into the draft like any other letter. Leaving is Esc and then d. *)
let footer_hints_board_compose_writing =
  "type to write  " ^ hints_of_bindings board_compose_writing_bindings

let board_compose_armed_bindings ~reply =
  [ b Act "s" "send" ]
  @ [ b Act "e" "edit in $EDITOR" ]
  @ (if reply then [] else [ b Act "h" "cycle hearth" ~help:"a new post's sub-board" ])
  @ [ b Act "d" "discard"; b Meta "Esc" "keep writing" ]

let footer_hints_board_compose_armed ~reply =
  hints_of_bindings (board_compose_armed_bindings ~reply)

(* A pane's own keys, then the keys all seven panes share. *)
let config_pane_bindings pane =
  let own =
    List.filter_map
      (fun (binding, panes) ->
        match panes with
        | Some panes when List.mem pane panes -> Some binding
        | Some _ | None -> None)
      config_bindings
  in
  let shared =
    List.filter_map
      (fun (binding, panes) ->
        match panes with None -> Some binding | Some _ -> None)
      config_bindings
  in
  (own, shared)

(* The pane's own keys lead the row and the shared ones follow. A cut row
   gives up its back first, and the shared keys are the ones a reader already
   met on the pane before -- the reason r, Tab and q close every row. Sorted
   as one list, the hops to Runtime, Resources and Tools outlived every key a
   pane answers itself: at 120 columns presets lost n and u, and the runtime
   assets lost o, their only way back to the registry. *)
let config_row ~own ~shared =
  String.concat "  "
    (List.filter
       (fun row -> not (String.equal row ""))
       [ hints_of_bindings own; hints_of_bindings shared ])

let footer_hints_config ~pane =
  let own, shared = config_pane_bindings pane in
  config_row ~own ~shared

(* The keeper-voice screen: two lists and one write. The keys are its own --
   the keeper walks under [j]/[k] and the voice under the arrows, so an
   assignment cannot be made by moving one axis and hoping the other
   followed -- and the row is built here rather than written as a string, so
   the spellings are the table's. *)
let voice_agent_bindings =
  [ b Navigate "j/k" "keeper"
  ; b Navigate "\xe2\x86\x90/\xe2\x86\x92" "voice"
  ; b Act "Enter" "assign" ~help:"write this keeper's voice into voice.tts.agent_voices"
  ; b Act "Esc" "back" ~help:"leave the screen; nothing is written"
  ]

let footer_hints_voice_agent () = hints_of_bindings voice_agent_bindings

(* The prompts pane's read-only half. [o] swaps the registry for the assets
   shipped with the binary, and there [a], [i], [e] and [x] answer with a
   notice rather than acting (masc_tui.ml), so the row leaves them out and
   names where [o] goes back to. *)
let footer_hints_prompt_assets =
  let registry_only = [ "a"; "i"; "e"; "x" ] in
  let own, shared = config_pane_bindings Config_prompts in
  let own =
    own
    |> List.filter (fun binding -> not (List.mem binding.key registry_only))
    |> List.map (fun binding ->
           if String.equal binding.key "o" then { binding with label = "registry" }
           else binding)
  in
  config_row ~own ~shared

(* The Overview footer is the same table plus one runtime fact the renderer
   owns: whether j/k currently drives the task list (task_focus) or the
   event list. The table stays the SSOT — this projection only relabels
   j/k and drops the keys that are dead in the current mode (t enters the
   task list, Enter/Esc act on the focused task), exactly like the old
   hand-assembled literal did, but without a second key list. *)
let footer_hints_overview ~task_focus =
  let dead =
    if task_focus then [ "t" ] else [ "Right / Enter"; "Left / Esc" ]
  in
  keepers_jump :: for_surface Overview
  |> List.filter (fun b -> not (List.mem b.key dead))
  |> List.map (fun b ->
         if b.key = "j/k" then
           { b with label = (if task_focus then "tasks" else "events") }
         else b)
  |> hints_of_bindings

(* The Code surface's footer, which the renderer used to spell by hand. It
   named d, H, m and w and nothing else, so the three language-server keys
   never appeared on the screen they work on -- and neither did blame or the
   row search when those arrived. Projected here, from the table the help
   sheet already reads, and narrowed to what the current mode answers: an
   overlay owns the pane, so the keys that act on the code underneath are
   dead while it is up, and the tree pane answers none of the file keys. *)
type code_pane =
  | Code_tree  (** the file list has focus *)
  | Code_file  (** a file is open and nothing covers it *)
  | Code_overlay  (** history, diff or notes is drawn over the file *)

let footer_hints_code ~pane =
  let file_keys =
    [ "Shift-Left / Shift-Right"; "K"; "D"; "R"; "B"; "b"; "d"; "H"; "m" ]
  in
  (* One key belongs to one pane and was showing on all three: [Enter
     (history)] opens a commit's pull request and only the history view has
     commits. Named apart from [file_keys] because it is the overlay's own,
     not the file's. *)
  let overlay_keys = [ "Enter (history)" ] in
  let dead =
    match pane with
    | Code_tree -> overlay_keys @ file_keys
    | Code_file -> overlay_keys
    | Code_overlay -> file_keys
  in
  for_surface Code
  |> List.filter (fun b -> not (List.mem b.key dead))
  |> List.map (fun b ->
       if String.equal b.key "j/k" then
         { b with label = (match pane with Code_tree -> "move" | _ -> "scroll") }
       else b)
  |> hints_of_bindings

(* The Runtime footer is the table's, with the two keys that depend on the
   reading on screen: [p] names where it goes from here, and [e] exists only on
   the keeper-lane reading, where a row names a lane to append to. The renderer
   used to spell its own line -- "j/k:scroll  Enter:detail  p:%s  Tab:next
   q:quit  r:live refresh" -- which never named [c], the one key to Clients,
   or [Esc], the way back to Config, and called the global refresh a live
   one. *)
let footer_hints_runtime ~(mode : runtime_mode) =
  List.filter_map (runtime_footer_binding ~mode) runtime_keys
  @ row_list_edges @ listing_meta
  |> hints_of_bindings

let footer_hints_resources ~detail_focus =
  for_surface Resources
  (* The row search needs a cursor to land on, and with the text focused
     there is none -- [surface_row_texts] says so too. Dropped here rather
     than listed and silent. *)
  |> List.filter (fun binding ->
         (not detail_focus)
         || not (String.equal binding.key "/" || String.equal binding.key "n / N"))
  |> List.map (fun binding ->
         if String.equal binding.key "j/k" then
           { binding with label = (if detail_focus then "scroll text" else "move") }
         else binding)
  |> hints_of_bindings

let opens_keepers ~message_mode key =
  (not message_mode) && String.equal key keepers_jump.key

(* An armed two-press action expires on the next unrelated input: otherwise
   it waits indefinitely and a later press of the same key -- after the
   cursor has moved, after a refresh -- submits work the operator armed
   minutes ago for something else.

   Two facts, not one. [input_seen] says the loop actually read something:
   the loop turns on a timeout as well, and a turn that read nothing is not
   an unrelated input. [key] says what it read, and it is [None] for a
   mouse report, a paste, and a graphics reply -- deliberate input that is
   not the second press, so it cancels.

   The rule lives here because the dispatch loop restated it once per armed
   field and the connector unbind's restatement read the timeout turn as an
   unrelated key. Its arm therefore survived one iteration: the two [u]
   presses removed a binding only when both bytes arrived in the same
   read. *)
let cancels_two_press ~input_seen ~key ~second_press =
  input_seen
  &&
  match key with
  | None -> true
  | Some pressed -> not (List.exists (String.equal pressed) second_press)

(* The Fusion detail view: the keys table owns the key list; the renderer
   owns the live scroll numbers it appends after them. ([view] stays
   [Fusion]; [fusion_mode] decides list vs detail — masc_tui_types.ml.)
   [position] is the window the renderer drew ({!Masc_tui_scroll.window_text}),
   so the footer agrees with what is on screen.

   [K] and [B] answer in the detail as they do on the list (masc_tui.ml
   matches them under [Fusion_detail]); the footer left them out, and a body
   row said "K Keeper · B Board" in its own notation instead. *)
let footer_hints_board_read ~focus_posts ~split =
  hints_of_bindings
    ([ b Navigate "j/k" (if focus_posts then "posts" else "scroll")
     ; b Navigate "[/]" "post"
     ; b Navigate "PgUp/PgDn" "page"
     ]
     @ (if split then [ b Navigate "h/l" "pane"; b Navigate "Ctrl-W" "switch" ]
        else [])
     @ [ b Navigate "z" "wide"
       ; board_vote_key
       ; board_reply_key
       ; board_copy_key
       ; b Act "Left / Esc" "back"
       ; b Meta "r" "refresh"
       ; b Meta "Tab" "next"
       ])

let footer_hints_fusion_detail ~position =
  Printf.sprintf "%s  %s"
    (hints_of_bindings
       ([ b Navigate "j/k" "scroll"
        ; b Navigate "PgUp/PgDn" "page"
        ; fusion_caller_key
        ; fusion_board_key
        ; b Act "Y" "copy"
        ; b Act "Esc" "back" ~help:"Left or Esc returns to the run list"
        ]
        @ listing_meta))
    position

(* Lanes sub-modes ([lanes_mode] owns overview/list/detail/notice —
   masc_tui_types.ml). The overview footer stays [for_surface Lanes]; these
   name the drill-downs the same way the Fusion detail footer does. *)
let footer_hints_lanes_run_list =
  hints_of_bindings
    ([ b Navigate "j/k" "move" ~help:"move the run cursor"
     ; b Act "Right / Enter" "prompt" ~help:"open the run's prompt and output"
     ; b Act "]" "older" ~help:"load the next retained-run page from the server"
     ; b Act "Left / Esc" "back" ~help:"back to the lane overview"
     ]
     @ listing_meta)

let footer_hints_lanes_run_detail ~position =
  let hints =
    hints_of_bindings
      ([ b Navigate "j/k" "compare" ~help:"scroll Input and Output together"
       ; b Navigate "PgUp/PgDn" "page" ~help:"page both evidence panes"
       ; b Act "Left / Esc" "back" ~help:"back to the run list"
       ]
       @ listing_meta)
  in
  match position with
  | None -> hints
  | Some position -> hints ^ "  " ^ position

let footer_hints_git_changes =
  hints_of_bindings
    ([ b Navigate "j/k" "move"
     ; b Act "Right / d / Enter" "diff"
     ; b Act "v" "open in code"
     ; b Act "p" "open PR"
     ; b Act "t/g" "task / goal"
     ; b Act "Left / Esc" "back"
     ]
     @ listing_meta)

let footer_hints_git_diff =
  hints_of_bindings
    ([ b Navigate "j/k" "scroll"
     ; b Act "v" "open in code"
     ; b Act "p" "open PR"
     ; b Act "t/g" "task / goal"
     ; b Act "Left / Esc" "back to files"
     ]
     @ listing_meta)

(* The Memory fact browser drawn over the health table. Its own row because
   the keys change with it: the cursor moves rows instead of scrolling the
   table, [c] narrows by the categories the loaded store holds, and Esc
   closes the browser rather than leaving the surface.

   The footer row and the sheet read this one list. The keys are not the
   health row's under these names -- Enter opens the reading, s reorders
   instead of pausing a keeper -- so a reader who has not pressed them learns
   them only from [?], which is what [?] answers. *)
let bindings_memory_facts =
  [ b Navigate "j/k" "move"
  ; b Act "Enter" "detail"
      ~help:"read the whole fact in a wide overlay that owns the terminal"
  ; b Act "c / C" "category" ~help:"cycle category filter (forward / backward)"
  ; b Act "s" "sort" ~help:"cycle sort (recency, last retrieved, retrieved count, category, claim)"
  ; b Act "a / A" "all fleet" ~help:"switch to consolidated memory across entire fleet"
  ; b Search "/" "filter" ~help:"live text filter / search"
  ; b Search "n / N" "next / previous match"
  ; b Act "Esc" "close / clear" ~help:"clear filter or exit to health table"
  ]
  @ row_list_edges @ listing_meta

let footer_hints_memory_facts = hints_of_bindings bindings_memory_facts

(* The reading the browser's Enter opens. One fact scrolls under the cursor
   instead of the cursor moving rows, so it owns page and edge keys the
   browser row has none of. The window marker it leads with is not a key, and
   the renderer adds it. *)
let bindings_memory_fact_detail =
  [ b Navigate "j/k" "scroll"
  ; b Navigate "PgUp/PgDn" "page"
  ; b Navigate "g / G" "top/bottom"
      ~help:"jump to the first or last line of the fact"
  ; b Act "Esc" "close" ~help:"return to the fact list"
  ]

let memory_fact_detail_hints = hints_of_bindings bindings_memory_fact_detail

(* One section per surface family; the strip's spelling names it. Keepers
   sub-modes collapse into the two sections an operator thinks in. *)
let help_surfaces : (string * surface) list =
  [ "Overview", Overview
  ; "Activity", Acting
  ; "Metrics", Metrics
  ; "Keepers", Keepers Keeper_list
  ; "Keeper detail", Keepers Keeper_detail
  ; "Chat", Keepers Keeper_message
  ; "Lanes", Lanes
  ; "Config / Runtime / Clients", Clients
  ; "Board", Board
  ; "Approvals", Approvals
  ; "Planning / Goals", Planning
  ; "Planning / Task Review", Verification
  ; "Planning / Task Verdicts", Harness
  ; "Fusion", Fusion
  (* "Schedules", the name the title bar and the palette both use. It read
     "Keeper detail / Automation" -- a Keeper detail tab that has no keys of
     its own and no route to this screen -- so a reader who typed "go
     Schedules" and pressed [?] found this screen's keys under the name of a
     screen they were not on. The family is Keepers, which is where the strip
     puts the highlight while this surface is open. *)
  ; "Keepers / Schedules", Schedules
  ; "Memory", Memory
  ; "Workspace", Repositories
  ; "Workspace / Code", Code
  ; "Changes", Changes
  ; "Config / Runtime", Runtime
  ; "Config", Config
  ; "Config / Resources", Resources
  ; "Config / Tools", Tools
  ; "Activity / Logs", System_logs
  ]

let entries bindings =
  List.map
    (fun { key; label; help; _ } -> (key, Option.value help ~default:label))
    bindings

(* The reader's own surface first, then the keys that work everywhere, then
   the rest as reference. A sheet that opens on Planning while the reader is
   on Overview is a list to search rather than an answer: the question [?]
   asks is "what can I do here", and twenty other surfaces are what sits
   underneath that answer.

   [current] is matched exactly rather than by ring position. The Keepers
   sub-modes are three sections here and one entry on the strip, and a reader
   in the chat is asking for the chat's keys, not the roster's. A surface with
   no section of its own simply matches nothing and the sheet reads as it did
   before this argument existed. *)
let here_marker = " \xc2\xb7 you are here"

(* The Keeper detail tabs. Until 2026-08-30 the renderer drew these as
   hand-written strings in its own [tab_hint] match, so the detail tabs were
   a second key list this module did not own -- the exact split the header
   above says cannot happen. [T] was missing from that string as well as
   from here, so toggling a provider was undocumented on every screen.

   The tabs' keys are conditional on the tab rather than the surface, which
   is why they are not in [for_surface]: listing them there would advertise
   them on the five tabs where they do nothing. *)
let keeper_detail_tab_bindings (tab : Masc_tui_types.keeper_detail_tab) =
  match tab with
  | Detail_github ->
      [ b Act "L" "login" ~help:"start the gh device-flow login"
      ; b Act "P" "token" ~help:"set fine-grained PAT / token"
      ]
  | Detail_sandbox ->
      [ b Act "o" "actual logs"
      ; b Act "d/m/s" "backend"
          ~help:"set the sandbox backend in place: docker / microvm / remote_ssh"
      ; b Navigate "PgUp/PgDn" "detail page"
      ; b Meta "R" "refresh"
      ]
  | Detail_instructions ->
      [ b Act "e" "edit JSON in $EDITOR"
          ~help:"the settings form; only changed fields are sent"
      ]
  | Detail_identity ->
      [ (* Arrows first: the digits only reach the first nine rows and the
           list is a declaration directory that can hold more. *)
        b Navigate "arrows+enter" "connect"
      ; b Act "T" "toggle" ~help:"turn the provider under the cursor on or off"
      ; b Act "A" "app"
          ~help:"open the app-registration form for it -- it asks for a Client ID"
      ; b Search "/" "filter"
      ; b Meta "R" "refresh"
      ]
  | Detail_channels ->
      [ b Navigate "j/k" "transport"
      ; b Navigate "J/K" "binding"
      ; b Navigate "PgUp/PgDn" "detail page"
      ; b Act "b / e / u u" "bind / reassign / remove"
          ~help:"bind a channel, reassign the selected row, or remove it twice-confirmed"
      ]
  | Detail_info | Detail_secrets | Detail_automation | Detail_runs -> []

(* The single keys a binding's key names, in this table's own notation:
   alternatives apart with "/" ("d/m/s", "Left / Esc"), a key pressed twice
   apart with a space ("u u"), and a chord with "+" ("arrows+enter"). *)
let key_atoms key =
  String.split_on_char '/' key
  |> List.concat_map (String.split_on_char ' ')
  |> List.concat_map (String.split_on_char '+')
  |> List.filter (fun atom -> not (String.equal atom ""))
  |> List.sort_uniq String.compare

(* The keys a detail tab's own arms answer before the Keeper controls do.
   Sandbox takes [s] for the remote_ssh backend and [o] for its container
   logs; Channels takes [j/k] and [e]; Settings takes [e]. *)
let keeper_detail_tab_taken_keys tab =
  List.concat_map
    (fun binding -> key_atoms binding.key)
    (keeper_detail_tab_bindings tab)

(* The keys the detail footer leads with. Same [key:label] spelling as the
   rest of the row, and the tab switch leads because it is on every tab. *)
let keeper_detail_tab_hint tab =
  String.concat "  "
    ("[ ]:tab"
     :: List.map
          (fun binding -> binding.key ^ ":" ^ binding.label)
          (keeper_detail_tab_bindings tab))

(* A surface's rows on the sheet. The shared tail -- r, Tab and q exactly as
   [listing_meta] spells them -- is said once, under Global. Repeated under
   every surface it took three of the dozen rows an 80x24 sheet shows of the
   reader's own section. A surface that names one of those keys its own way
   ([r] reload on Config) keeps that row: it says something Global does not.
   Footers keep the tail, since a footer is all a surface shows. *)
let sheet_bindings surface =
  List.filter
    (fun binding -> not (List.mem binding listing_meta))
    (for_surface surface)

let help_sections ?current () =
  let sections =
    List.map
      (fun (title, surface) ->
         (* The Keeper detail tabs each own keys the surface list cannot
            hold, and the sheet is where a reader looks for them. Append
            them under the surface with the tab named, so [?] answers
            "what does T do" -- which nothing did before 2026-08-30. *)
         let tab_entries =
           match surface with
           | Keepers Keeper_detail ->
               List.concat_map
                 (fun tab ->
                    List.map
                      (fun (key, help) ->
                         ( key
                         , Printf.sprintf "on the %s tab: %s"
                             (Masc_tui_types.keeper_detail_tab_label tab)
                             help ))
                      (entries (keeper_detail_tab_bindings tab)))
                 Masc_tui_types.keeper_detail_tabs
           (* The fact browser and the reading its Enter opens have the same
              problem the tabs above have: keys the surface list cannot hold,
              on screens the reader is standing on. The Memory section is
              where they look, so both rows go there with the screen named. *)
           | Memory ->
               List.map
                 (fun (key, help) -> (key, "in the facts browser: " ^ help))
                 (entries bindings_memory_facts)
               @ List.map
                   (fun (key, help) -> (key, "in the fact detail: " ^ help))
                   (entries bindings_memory_fact_detail)
           | _ -> []
         in
         (surface, (title, entries (sheet_bindings surface) @ tab_entries)))
      help_surfaces
  in
  let here, rest =
    match current with
    | None -> ([], sections)
    | Some current ->
        List.partition (fun (surface, _) -> surface = current) sections
  in
  List.map (fun (_, (title, keys)) -> (title ^ here_marker, keys)) here
  @ ("Global", entries global)
    :: (List.map (fun (_, section) -> section) rest
        (* The marks last, as reference, the way the slash commands read as
           reference. One reader of them has no words beside it: the Keepers
           rows draw each glyph with its status word and so does the chat
           header, but the roster pane beside the chat is 34 cells wide and
           draws the glyph alone (masc_tui_render_prim.ml: "Without it the pane
           says a keeper exists and nothing else"). Selecting keepers until
           every state has been seen was the only way that reader could learn
           the marks, and a rare one such as failing may never be selected.

           Masc_tui_keeper_mark carried this list for exactly this and nothing
           read it. Its shape is already the sheet's: a mark, and what it
           means. Last rather than beside Global because the section order up
           to there is asserted. *)
        @ [ ("Keeper marks", Masc_tui_keeper_mark.legend)
          (* The Keepers header words and the Mode S letters. They were two
             rows above every roster: an empty roster spent them on columns
             it had nothing in, a narrow one on columns it did not draw, and
             beside the Activity pane both rows were cut. *)
          ; ("Keeper columns", Masc_tui_keeper_mark.column_legend)
          (* The Board's first column is the only place these three appear, and
             the column has no room for a legend of its own: its header already
             spends three rows and the hearth row is cut at 150 columns. *)
          (* The Memory roster's ST column. The words were a literal row the
             surface drew above every roster -- including a roster that had
             failed to read, where the column it explained was not on screen.
             Same move as the Keeper columns above: the row goes, the sheet
             keeps the words, and the glyphs now come from the function the
             column draws with. *)
          ; ("Memory marks", Masc_tui_memory_mark.legend)
          ; ("Board marks", Masc_tui_board_kind_mark.legend)
          (* The Code tree's file marks. A folder takes the arrow and a file
             takes its kind's mark, and neither carries a word -- the name
             beside it says the extension the mark was read from, not what the
             mark means. Seven marks drew with nothing anywhere saying so. *)
          ; ("File marks", Masc_tui_file_icon.legend)
          (* Planning's own legend says the marks its list is drawing, which
             is what keeps that line inside a narrow frame -- so a mark no
             goal carries right now has nowhere else to be explained. Here. *)
          ; ("Judge marks", Masc_tui_planning_proof_mark.legend)
          (* The marks and phrases on a chat's tool and skill rows. Six
             outcome marks, eight skill phrases and two words of proof sat on
             every transcript with nothing anywhere saying what one meant;
             an operator reading them asked what "받아서 씀" received and
             wrote (2026-09-14). *)
          ; ("Chat marks", Masc_tui_keeper_chat_transcript.legend)
          (* The first column of Config's two list panes. The prompt registry
             draws three marks and the params list two, and the words for
             them were only in the detail pane below the list -- for the one
             row the cursor was on. A reader scanning twenty rows could tell
             a marked row from an unmarked one and not what the mark said. *)
          ; ("Prompt marks", Masc_tui_config_mark.prompt_legend)
          ; ("Param marks", Masc_tui_config_mark.param_legend)
          ])

let footer_hints_browser_lane =
  hints_of_bindings
    [ b Navigate "b" "browser"
    ; b Navigate "l / a" "live / automation"
    ; b Navigate "[ / ]" "tab"
    ; b Navigate "j/k" "text"
    ; b Act "Ctrl-O" "screenshot"
    ; b Act "g" "URL"
    ; b Act "o / x" "open / close session"
    ; b Act "r" "refresh"
    ; b Navigate "Ctrl-^ / Esc" "hide lane"
    ]
