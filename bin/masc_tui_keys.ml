(* The key table — data first, two projections after. Dispatch does not read
   this; the displays do. When a key is added to the match in masc_tui.ml,
   its row here is the discoverability contract (#30356 taught the cost of
   the two drifting apart). *)

open Masc_tui_types

type group = Navigate | Act | Search | Meta

type binding = {
  key : string;
  label : string;
  help : string option;
  group : group;
}

let b ?help group key label = { key; label; help; group }

let global =
  [ b Meta "Tab / Shift-Tab" "next / previous surface"
  ; b Meta "r" "refresh the current surface"
  ; b Meta "i" "focus the composer (message the shown keeper)"
  ; b Meta ":" "command palette"
  ; b Meta ";" "agenda: what is coming, and who is waiting on you"
  ; b Meta "?" "this help"
  ; b Meta "Ctrl-B" "show or hide the keeper roster beside a surface"
  ; b Meta "Ctrl-T" "release the mouse so you can drag-select and copy"
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
  ; b Act "a" "new" ~help:"new keeper"
  ]

let for_surface = function
  | Overview ->
      [ b Navigate "j/k" "events" ~help:"scroll events"
      ; b Navigate "h/l" "pane" ~help:"move between events and tasks"
      ; b Act "t" "tasks" ~help:"hand j/k to the task list"
      ; b Act "Right / Enter" "open" ~help:"open the selected task"
      ; b Act "Left / Esc" "back" ~help:"close detail / back to events"
      ; b Meta "2" "keepers"
      ]
      @ listing_meta
  | Acting ->
      [ b Navigate "j/k" "scroll"
      ; b Navigate "g / G" "newest / oldest"
      ; b Act "f" "filter" ~help:"cycle the filter"
      ; b Act "Esc" "overview"
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
      @ listing_meta
  | Keepers Keeper_detail ->
      [ b Navigate "h/l" "pane" ~help:"move between roster and detail"
      ; b Navigate "[ / ]" "tabs" ~help:"detail tabs: Info / Settings / GitHub"
      ; b Act "L" "gh login" ~help:"on the GitHub tab: start the gh device-flow login"
      ; b Act "o" "logs" ~help:"open this Keeper's logs"
      ; b Act "Left / Esc" "back"
      ]
      @ List.filter (fun binding -> binding.key <> "l") keeper_actions
  | Keepers Keeper_logs ->
      [ b Navigate "j/k" "scroll"; b Act "Left / Esc" "back" ]
  | Keepers Keeper_calls ->
      [ b Navigate "j/k" "scroll"; b Act "Left / Esc" "back" ]
  | Keepers Keeper_message ->
      [ b Navigate "h / Left" "roster"
          ~help:"focus the visible Keeper roster (h when the draft is empty)"
      ; b Navigate "Right / Esc" "chat" ~help:"return focus to the chat composer"
      ; b Navigate "j/k" "roster move" ~help:"move while the roster has focus"
      ; b Act "Enter" "send / open"
          ~help:"send from chat, or open the selected Keeper from the roster"
      ; b Act "Ctrl-J" "newline" ~help:"newline in the draft"
      ; b Act "Ctrl-G" "next keeper" ~help:"next keeper with a chat open"
      ; b Act "Ctrl-U" "clear" ~help:"clear the draft"
      ; b Act "Ctrl-K / Ctrl-P" "queued line"
          ~help:"cancel / edit the last queued line"
      ; b Navigate "PgUp / PgDn" "history" ~help:"scroll history by a page"
      ; b Navigate "Up / Down" "adjust"
          ~help:"when scrolled back, adjust by one line"
      ; b Act "Ctrl-R" "reasoning" ~help:"cycle reasoning hidden / folded / full"
      ; b Act "Ctrl-D" "tool detail" ~help:"toggle compact / full tool-call detail"
      ; b Act "Ctrl-F" "clock"
          ~help:"cycle origin row / inline clock / no clock"
      ; b Act "y / n" "approval" ~help:"answer a tool approval"
      ; b Act "Esc" "back" ~help:"back; during a turn, interrupt it"
      ]
  | Keepers Keeper_runtime_pick ->
      [ b Navigate "j/k" "move"; b Act "Enter" "choose"; b Act "Esc" "back" ]
  | Lanes ->
      [ b Navigate "j/k" "scroll"; b Act "Esc" "overview" ] @ listing_meta
  | Board ->
      [ b Navigate "j/k" "move"
      ; b Act "Right / Enter" "read" ~help:"read the post"
      ; b Act "Left / Esc" "back" ~help:"close the post"
      ; b Act "w" "write" ~help:"write a post"
      ; b Act "v / V" "vote up / down"
      ; b Act "c" "reply" ~help:"reply (while reading)"
      ; b Navigate "Ctrl-W" "pane" ~help:"switch between the post list and detail pane"
      ; b Navigate "h/l" "pane" ~help:"focus the post list or detail pane"
      ]
      @ listing_meta
  | Approvals ->
      [ b Navigate "j/k" "move"
        (* The list draws each ask on one row. Enter is where a multi-line
           argument is readable before y answers it. *)
      ; b Act "Enter" "read the whole ask" ~help:"j/k scrolls it; Esc goes back"
      ; b Act "y" "confirm"
      ; b Act "n" "deny"
      ]
      @ listing_meta
  | Planning ->
      [ b Navigate "j/k" "move"
      ; b Act "Right / Enter" "detail"
      ; b Act "Left / Esc" "back"
      ; b Act "c" "complete" ~help:"complete goal"
      ; b Act "x" "drop"
      ; b Act "o" "reopen"
      ]
      @ listing_meta
  | Schedules ->
      [ b Navigate "j/k" "move" ~help:"move; in details, scroll the payload"
      ; b Act "Right / Enter" "details" ~help:"open schedule details"
      ; b Act "Left / Esc" "back" ~help:"back to the schedule list"
      ; b Act "x" "cancel" ~help:"arm / confirm cancellation"
      ]
      @ listing_meta
  | Verification ->
      [ b Navigate "j/k" "move" ~help:"move; in details, scroll the evidence"
      ; b Act "Right / Enter" "details" ~help:"read the request and evidence"
      ; b Act "Left / Esc" "back" ~help:"back to the verification queue"
      ; b Act "a" "approve" ~help:"approve the row under the cursor (press twice)"
      ; b Act "x" "reject" ~help:"reject with a reason ($EDITOR form)"
      ]
      @ listing_meta
  | Harness ->
      [ b Navigate "j/k" "scroll"; b Act "Esc" "overview" ] @ listing_meta
  | Fusion ->
      (* [fusion_mode] owns list/detail (masc_tui_types.ml); the detail
         footer is [footer_hints_fusion_detail], which also appends the live
         scroll position this static table cannot know. *)
      [ b Navigate "j/k" "move"
      ; b Act "Right / Enter" "detail"
      ; b Act "Left / Esc" "back"
      ]
      @ listing_meta
  | Repositories ->
      [ b Navigate "j/k" "scroll"
      ; b Act "Enter" "browse"
          ~help:"open this repository's tree on the Code surface"
      ; b Act "Esc" "overview"
      ]
      @ listing_meta
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
      ; b Act "o" "editor" ~help:"open in $EDITOR / $NVIM"
      ]
      @ listing_meta
  | Connectors ->
      [ b Navigate "j/k" "scroll"
      ; b Act "b / u" "bind / unbind" ~help:"bind / unbind a channel (editor form)"
      ; b Act "Esc" "overview"
      ]
      @ listing_meta
  | Runtime ->
      [ b Navigate "j/k" "scroll"; b Act "Esc" "overview" ] @ listing_meta
  | Config ->
      [ b Navigate "j/k" "scroll"
        (* The surface owns the two files the server reads. Which one [e]
           opens depends on which list is showing, so the row says both. *)
      ; b Navigate "p" "runtime.toml / prompts"
      ; b Act "e" "edit"
          ~help:"runtime.toml previews before it writes; a prompt saves as an override"
      ; b Act "x" "clear override" ~help:"on a prompt: back to the file's words"
      ; b Act "Esc" "overview"
      ; b Meta "r" "reload"
      ; b Meta "Tab" "next"
      ]
  | Resources ->
      [ b Navigate "j/k" "move" ~help:"move the list; with the text focused, scroll it"
      ; b Navigate "h/l" "pane" ~help:"focus the resource list or text"
      ; b Navigate "Ctrl-W" "focus" ~help:"switch between resource list and text"
      ; b Navigate "J / K" "scroll text"
      ; b Act "Enter" "read" ~help:"read the selected resource"
      ; b Act "Esc" "list" ~help:"back to the list"
      ; b Meta "r" "reload"
      ; b Meta "Tab" "next"
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
           first, and only climbs a directory once no file is open
           (masc_tui.ml:6001). A key that works and is not listed is the same
           drift as a listed key that does nothing, pointing the other way. *)
      ; b Act "Left / Esc" "back"
          ~help:"close the history, then the file, then climb one directory"
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
      ; b Act "D" "definition"
          ~help:"jump to where a name on the cursor line is defined (one \
                 name jumps at once; several open the palette as choices)"
      ; b Act "B" "back"
          ~help:"walk back through the definition jumps, newest first"
      ; b Act "m" "notes"
          ~help:"the notes anchored to the open file (repository scope)"
      ; b Act "w" "add note"
          ~help:"in the notes view: add one through the $EDITOR form \
                 (kind: Comment / Decision / Question / Bookmark)"
      ; b Act "d" "diff"
          ~help:"the open file's working tree against HEAD (d or Esc closes)"
      ; b Act "Enter (history)" "open"
          ~help:"a commit answers with its pull request, from its (#N) and \
                 the repository's remote; a keeper edit jumps the cursor \
                 to the lines it wrote (B walks back)"
      ; b Act "H" "history"
          ~help:"the work over the open file: its commits and the recorded \
                 keeper edits, newest first (H or Esc closes)"
      ]
      @ listing_meta
  | Tools ->
      [ b Navigate "j/k" "scroll"
      ; b Navigate "[/]" "Keeper" ~help:"change the effective Keeper surface"
      ; b Act "Esc" "overview"
      ]
      @ listing_meta
  | System_logs ->
      (* j/k only: g, G, and f are Acting's keys. The old help table listed
         them here, documenting keys that did nothing. *)
      [ b Navigate "j/k" "scroll"; b Act "Esc" "overview" ] @ listing_meta

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
  for_surface Overview
  |> List.filter (fun b -> not (List.mem b.key dead))
  |> List.map (fun b ->
         if b.key = "j/k" then
           { b with label = (if task_focus then "tasks" else "events") }
         else b)
  |> hints_of_bindings

(* The Fusion detail view: the keys table owns the key list; the renderer
   owns the live scroll numbers it appends after them. ([view] stays
   [Fusion]; [fusion_mode] decides list vs detail — masc_tui_types.ml.)
   [scroll] is the clamped position the renderer computed, so the footer
   agrees with what is on screen. *)
let footer_hints_fusion_detail ~scroll ~max_scroll =
  Printf.sprintf "%s  (%d/%d)"
    (hints_of_bindings
       ([ b Navigate "j/k" "scroll"
        ; b Navigate "PgUp/PgDn" "page"
        ; b Act "Left / Esc" "back"
        ]
        @ listing_meta))
    scroll max_scroll

(* One section per surface family; the strip's spelling names it. Keepers
   sub-modes collapse into the two sections an operator thinks in. *)
let help_surfaces : (string * surface) list =
  [ "Overview", Overview
  ; "Acting", Acting
  ; "Keepers", Keepers Keeper_list
  ; "Keeper detail", Keepers Keeper_detail
  ; "Chat", Keepers Keeper_message
  ; "Lanes", Lanes
  ; "Board", Board
  ; "Approvals", Approvals
  ; "Planning", Planning
  ; "Schedules", Schedules
  ; "Verify", Verification
  ; "Harness", Harness
  ; "Fusion", Fusion
  ; "Repos", Repositories
  ; "Changes", Changes
  ; "Connectors", Connectors
  ; "Runtime", Runtime
  ; "Config", Config
  ; "Resources", Resources
  ; "Tools", Tools
  ; "Logs", System_logs
  ]

let entries bindings =
  List.map
    (fun { key; label; help; _ } -> (key, Option.value help ~default:label))
    bindings

let help_sections () =
  ("Global", entries global)
  :: List.map
       (fun (title, surface) -> (title, entries (for_surface surface)))
       help_surfaces
