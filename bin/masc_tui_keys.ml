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

let keepers_jump =
  b Meta "2" "keepers"
    ~help:"jump to Keepers when the active field or panel does not use 2"

let global =
  [ b Meta "Tab / Shift-Tab" "next / previous surface"
  ; keepers_jump
  ; b Meta "r" "refresh the current surface"
  ; b Meta "i" "focus the composer (message the shown keeper)"
  ; b Meta ":" "command palette"
  ; b Meta ";" "agenda: what is coming, and who is waiting on you"
  ; b Meta "@" "answering: who is mid-turn or just finished; Enter opens their chat"
  ; b Meta "?" "this help"
  ; b Meta "Ctrl-B" "show or hide a visible keeper roster pane"
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
  ]

let for_surface = function
  | Overview ->
      [ b Navigate "j/k" "events" ~help:"scroll events"
      ; b Navigate "h/l" "pane" ~help:"move between events and tasks"
      ; b Act "t" "tasks" ~help:"hand j/k to the task list"
      ; b Act "Right / Enter" "open" ~help:"open the selected task"
      ; b Act "Left / Esc" "back" ~help:"close detail / back to events"
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
      ; b Navigate "[ / ]" "tabs" ~help:"detail tabs: Info / Settings / Secrets / GitHub"
      ; b Act "o" "logs" ~help:"open this Keeper's logs"
      ; b Act "Left / Esc" "back"
      ]
      @ List.filter (fun binding -> binding.key <> "l") keeper_actions
  | Keepers Keeper_logs ->
      (* The shared tail was missing here while the renderer's own footer
         string carried it, so the sheet and the footer disagreed about
         whether r/q worked on this screen. *)
      [ b Navigate "j/k" "scroll"; b Act "Left / Esc" "back" ] @ listing_meta
  | Keepers Keeper_calls ->
      [ b Navigate "j/k" "scroll"; b Act "Left / Esc" "back" ] @ listing_meta
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
      [ b Navigate "j/k" "move"
      ; b Act "Enter" "choose"
      ; b Act "d" "use the default"
          ~help:"drop this Keeper's own binding and follow [runtime].default"
      ; b Act "Esc" "back"
      ]
  | Lanes ->
      [ b Navigate "j/k" "move" ~help:"move the lane cursor"
      ; b Act "Right / Enter" "runs"
          ~help:"open the standalone lane's exact runs"
      ; b Act "Esc" "overview"
      ]
      @ listing_meta
  | Board ->
      [ b Navigate "j/k" "move"
      ; b Act "Right / Enter" "read" ~help:"read the post"
      ; b Act "Left / Esc" "back" ~help:"close the post"
      ; b Act "w" "write" ~help:"write a post"
      ; b Act "v / V" "vote up / down"
      ; b Act "c" "reply" ~help:"reply (while reading)"
      ; b Navigate "[ / ]" "previous / next post"
          ~help:"while reading, open the post before or after this one"
      ; b Navigate "s" "sort" ~help:"cycle hot / trending / recent / updated / discussed"
      ; b Search "f" "hearth"
          ~help:"narrow to one sub-board, busiest first; again for the next"
      ; b Navigate "z" "wide detail" ~help:"hide or show the post list while reading"
      ; b Act "Y" "copy link" ~help:"copy the selected post reference"
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
      ; b Navigate "[ / ]" "previous / next"
          ~help:"while a detail is open, step to the row before or after it"
      ; b Act "e" "external Gate lane"
          ~help:"cycle manual / auto_judge / always_allow for calls into \
                 attached outside services"
      ]
      @ listing_meta
  | Planning ->
      [ b Navigate "j/k" "move"
      ; b Navigate "v" "next Planning tab"
          ~help:"Goals \xe2\x86\x92 Task Review \xe2\x86\x92 Verdicts"
      ; b Act "Right / Enter" "detail"
      ; b Act "Left / Esc" "back"
      ; b Navigate "f" "filter" ~help:"cycle all / active / completed / dropped"
      ; b Navigate "s" "sort" ~help:"cycle phase / updated / due"
      ; b Navigate "[ / ]" "previous / next"
          ~help:"while a detail is open, step to the row before or after it"
      ; b Act "c" "complete" ~help:"complete goal"
      ; b Act "x" "drop"
      ; b Act "o" "reopen"
      ; b Act "Y" "copy link" ~help:"copy the selected goal reference"
      ]
      @ listing_meta
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
      ; b Act "a" "new wake"
          ~help:"open the create form; enter advances, esc abandons"
      ; b Act "Y" "copy link" ~help:"copy the selected schedule reference"
      ]
      @ listing_meta
  | Verification ->
      [ b Navigate "j/k" "move" ~help:"move; in details, scroll the evidence"
      ; b Navigate "v" "next Planning tab" ~help:"on to Verdicts, then Goals"
      ; b Act "Right / Enter" "details" ~help:"read the request and evidence"
      ; b Act "Left / Esc" "back" ~help:"back to the verification queue"
      ; b Navigate "[ / ]" "previous / next"
          ~help:"while a detail is open, step to the row before or after it"
      ; b Act "a" "approve" ~help:"approve the row under the cursor (press twice)"
      ; b Act "x" "reject" ~help:"reject with a reason ($EDITOR form)"
      ]
      @ listing_meta
  | Harness ->
      [ b Navigate "j/k" "move" ~help:"move; in a verdict, scroll"
      ; b Navigate "v" "next Planning tab" ~help:"back round to Goals"
      ; b Navigate "PgUp/PgDn" "page"
      ; b Act "Right / Enter" "verdict" ~help:"open the full harness verdict"
      ; b Act "Left / Esc" "back" ~help:"back to the verdict list"
      ; b Navigate "[ / ]" "previous / next"
          ~help:"while a detail is open, step to the row before or after it"
      ; b Act "y" "agree" ~help:"record the machine's verdict as yours"
      ; b Act "n" "overrule" ~help:"record the opposite verdict; $EDITOR takes the reason"
      ; b Act "Y" "copy task" ~help:"copy a link to the task on Overview"
      ]
      @ listing_meta
  | Fusion ->
      (* [fusion_mode] owns list/detail (masc_tui_types.ml); the detail
         footer is [footer_hints_fusion_detail], which also appends the live
         scroll position this static table cannot know. *)
      [ b Navigate "j/k" "move"
      ; b Navigate "PgUp/PgDn" "page"
      ; b Act "Enter" "detail" ~help:"Right or Enter opens detail"
      ; b Navigate "[ / ]" "previous / next"
          ~help:"while a detail is open, step to the row before or after it"
      ; b Act "Y" "copy" ~help:"copy the selected Fusion run reference"
      ; b Act "Esc" "back" ~help:"leave detail, or return to Overview"
      ]
      @ listing_meta
  | Memory ->
      [ b Navigate "j/k" "scroll"
      ; b Navigate "[ / ]" "keeper" ~help:"previous / next keeper row"
      ]
      @ listing_meta
  | Repositories ->
      [ b Navigate "j/k" "scroll"
      ; b Act "Enter" "browse"
          ~help:"open the repository tree, or the selected changed file"
      ; b Act "d" "Git changes"
          ~help:"show the selected repository's current working-tree changes"
      ; b Act "a" "add" ~help:"register a repository; opens $EDITOR"
      ; b Act "Left / Esc" "back"
          ~help:"leave Git changes, or return to Overview"
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
      [ b Navigate "j/k" "move / scroll"
      ; b Navigate "PgUp/PgDn" "detail page"
      ; b Act "Right / Enter" "detail"
          ~help:"show the full runtime, lane, dispatch, and probe fields"
      ; b Act "Left / Esc" "back"
      ]
      @ listing_meta
  | Config ->
      [ b Navigate "j/k" "select / scroll"
        (* Config combines persisted files, typed live params, and the local
           theme choice.  The pane strip says which meaning each key has. *)
      ; b Navigate "p" "runtime.toml / models / params / prompts / themes"
      ; b Act "e" "edit"
          ~help:"params use a type-aware field; runtime.toml previews; prompts save an override"
      ; b Act "E" "advanced JSON"
          ~help:"on params only: edit the exact JSON value"
      ; b Act "Enter" "edit / use"
          ~help:"edit the selected param; on themes, use that colour scheme"
      ; b Act "x" "default / clear"
          ~help:"params return to default; prompts clear override; themes follow terminal colours"
      ; b Act "Esc" "overview"
      ; b Meta "r" "reload"
      ; b Meta "Tab" "next"
      ]
  | Resources ->
      [ b Navigate "j/k" "move"
          ~help:"move the list; with the text focused, scroll it"
      ; b Navigate "h/l" "pane" ~help:"focus the resource list or text"
      ; b Navigate "Ctrl-W" "focus" ~help:"switch between resource list and text"
      ; b Navigate "J / K" "scroll text"
      ; b Navigate "[ / ]" "previous / next"
          ~help:"while the detail is focused, read the adjacent resource"
      ; b Act "Enter" "read" ~help:"read the selected resource"
      ; b Act "Esc" "list" ~help:"back to the list"
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
          ~help:"on the project tree, list every working-tree change; on an \
                 open file, show that file's diff against HEAD"
      ; b Act "Enter (history)" "open"
          ~help:"a commit answers with its pull request, from its (#N) and \
                 the repository's remote"
      ; b Act "H" "history"
          ~help:"the commits that touched the open file, newest first \
                 (H or Esc closes)"
      ]
      @ listing_meta
  | Tools ->
      [ b Navigate "j/k" "scroll"
      ; b Navigate "Home/End" "top/bottom"
      ; b Navigate "p" "section"
          ~help:"available / async runs / receipts / usage / all tools"
      ; b Navigate "J/K" "Skill" ~help:"select a published Skill"
      ; b Navigate "[/]" "Keeper" ~help:"change the effective Keeper surface"
      ; b Act "e" "edit Skill"
          ~help:"open the selected SKILL.md in $EDITOR, validate, CAS-save, and publish"
      ; b Act "Esc" "overview"
      ]
      @ listing_meta
  | System_logs ->
      (* j/k only: g, G, and f are Acting's keys. The old help table listed
         them here, documenting keys that did nothing. *)
      [ b Navigate "j/k" "scroll"
      ; b Act "l" "level floor"
          ~help:"raise the minimum level; after error, back to everything"
      ; b Act "c" "category"
          ~help:"cycle through the categories this page carries"
      ; b Act "Esc" "overview"
      ]
      @ listing_meta

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
  keepers_jump :: for_surface Overview
  |> List.filter (fun b -> not (List.mem b.key dead))
  |> List.map (fun b ->
         if b.key = "j/k" then
           { b with label = (if task_focus then "tasks" else "events") }
         else b)
  |> hints_of_bindings

let footer_hints_resources ~detail_focus =
  for_surface Resources
  |> List.map (fun binding ->
         if String.equal binding.key "j/k" then
           { binding with label = (if detail_focus then "scroll text" else "move") }
         else binding)
  |> hints_of_bindings

let opens_keepers ~message_mode key =
  (not message_mode) && String.equal key keepers_jump.key

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
        ; b Act "Y" "copy"
        ; b Act "Esc" "back" ~help:"Left or Esc returns to the run list"
        ]
        @ listing_meta))
    scroll max_scroll

(* Lanes sub-modes ([lanes_mode] owns overview/list/detail/notice —
   masc_tui_types.ml). The overview footer stays [for_surface Lanes]; these
   name the drill-downs the same way the Fusion detail footer does. *)
let footer_hints_lanes_run_list =
  hints_of_bindings
    ([ b Navigate "j/k" "move" ~help:"move the run cursor"
     ; b Act "Right / Enter" "prompt" ~help:"open the run's prompt and output"
     ; b Act "Left / Esc" "back" ~help:"back to the lane overview"
     ]
     @ listing_meta)

let footer_hints_lanes_run_detail ~scroll ~max_scroll =
  Printf.sprintf "%s  (%d/%d)"
    (hints_of_bindings
       ([ b Navigate "j/k" "scroll"
        ; b Navigate "PgUp/PgDn" "page"
        ; b Act "Left / Esc" "back" ~help:"back to the run list"
        ]
        @ listing_meta))
    scroll max_scroll

(* The lane notice is static — there is nothing to move through, so it keeps
   only the way back plus the shared tail. *)
let footer_hints_lane_notice =
  hints_of_bindings
    ([ b Act "Left / Esc" "back" ~help:"back to the lane overview" ]
     @ listing_meta)

let footer_hints_git_changes =
  hints_of_bindings
    ([ b Navigate "j/k" "move"
     ; b Act "Enter" "open file"
     ; b Act "Left / Esc" "back"
     ]
     @ listing_meta)

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
  ; "Planning / Goals", Planning
  ; "Planning / Task Review", Verification
  ; "Planning / Verdicts", Harness
  ; "Schedules", Schedules
  ; "Fusion", Fusion
  ; "Memory", Memory
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
  | Detail_github -> [ b Act "L" "login" ~help:"start the gh device-flow login" ]
  | Detail_sandbox -> [ b Meta "R" "refresh" ]
  | Detail_instructions ->
      [ b Act "e" "edit JSON in $EDITOR"
          ~help:"the settings form; only changed fields are sent"
      ]
  | Detail_identity ->
      [ (* Arrows first: the digits only reach the first nine rows and the
           list is a declaration directory that can hold more. *)
        b Navigate "arrows+enter" "connect"
      ; b Act "T" "toggle" ~help:"turn the provider under the cursor on or off"
      ; b Act "A" "app" ~help:"open the app-registration form for it"
      ; b Search "/" "filter"
      ; b Meta "R" "refresh"
      ]
  | Detail_info | Detail_secrets -> []

(* The compact strip beside the tab row. Same [key:label] spelling the
   footer uses, and the tab switch leads because it is on every tab. *)
let keeper_detail_tab_hint tab =
  String.concat "  "
    ("[ ]:tab"
     :: List.map
          (fun binding -> binding.key ^ ":" ^ binding.label)
          (keeper_detail_tab_bindings tab))

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
           | _ -> []
         in
         (surface, (title, entries (for_surface surface) @ tab_entries)))
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
    :: List.map (fun (_, section) -> section) rest
