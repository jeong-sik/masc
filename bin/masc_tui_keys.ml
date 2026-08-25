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
  ; b Act "g" "yolo" ~help:"toggle yolo tool approval"
  ; b Act "p / w" "pause / wake"
  ; b Act "s" "shutdown"
  ; b Act "e" "settings"
  ; b Act "a" "new" ~help:"new keeper"
  ]

let for_surface = function
  | Overview ->
      [ b Navigate "j/k" "events" ~help:"scroll events"
      ; b Act "t" "tasks" ~help:"hand j/k to the task list"
      ; b Act "Enter" "open" ~help:"open the selected task"
      ; b Act "Esc" "back" ~help:"close detail / back to events"
      ; b Meta "2" "keepers"
      ]
      @ listing_meta
  | Acting ->
      [ b Navigate "j/k" "scroll"
      ; b Navigate "g / G" "newest / oldest"
      ; b Act "f" "filter" ~help:"cycle the filter"
      ; b Meta "Tab" "next"
      ; b Meta "q" "quit"
      ]
  | Keepers Keeper_list ->
      (b Navigate "j/k" "move" ~help:"move the roster cursor")
      :: (b Act "Enter" "detail" ~help:"keeper detail")
      :: keeper_actions
      @ [ b Search "/" "search" ~help:"search names; Enter keeps the query"
        ; b Search "n / N" "next / previous match"
        ]
      @ listing_meta
  | Keepers Keeper_detail ->
      [ b Navigate "[ / ]" "tabs" ~help:"detail tabs: Info / Instructions / GitHub"
      ; b Act "L" "gh login" ~help:"on the GitHub tab: start the gh device-flow login"
      ; b Act "Esc" "back"
      ]
      @ keeper_actions
  | Keepers Keeper_logs -> [ b Navigate "j/k" "scroll"; b Act "Esc" "back" ]
  | Keepers Keeper_calls -> [ b Navigate "j/k" "scroll"; b Act "Esc" "back" ]
  | Keepers Keeper_message ->
      [ b Act "Enter" "send" ~help:"send, or queue while a turn runs"
      ; b Act "Ctrl-J" "newline" ~help:"newline in the draft"
      ; b Act "Ctrl-G" "next keeper" ~help:"next keeper with a chat open"
      ; b Act "Ctrl-U" "clear" ~help:"clear the draft"
      ; b Act "Ctrl-K / Ctrl-P" "queued line"
          ~help:"cancel / edit the last queued line"
      ; b Navigate "PgUp / PgDn" "history" ~help:"scroll history by a page"
      ; b Navigate "Up / Down" "adjust"
          ~help:"when scrolled back, adjust by one line"
      ; b Act "y / n" "approval" ~help:"answer a tool approval"
      ; b Act "Esc" "back" ~help:"back; during a turn, interrupt it"
      ]
  | Keepers Keeper_runtime_pick ->
      [ b Navigate "j/k" "move"; b Act "Enter" "choose"; b Act "Esc" "back" ]
  | Lanes -> b Navigate "j/k" "scroll" :: listing_meta
  | Board ->
      [ b Navigate "j/k" "move"
      ; b Act "Enter" "read" ~help:"read the post"
      ; b Act "w" "write" ~help:"write a post"
      ; b Act "v / V" "vote up / down"
      ; b Act "c" "reply" ~help:"reply (while reading)"
      ; b Navigate "Ctrl-W" "pane" ~help:"switch between the post list and detail pane"
      ]
      @ listing_meta
  | Approvals ->
      [ b Navigate "j/k" "move"; b Act "y" "confirm"; b Act "n" "deny" ]
      @ listing_meta
  | Planning ->
      [ b Navigate "j/k" "move"
      ; b Act "Enter" "detail"
      ; b Act "c" "complete" ~help:"complete goal"
      ; b Act "x" "drop"
      ; b Act "o" "reopen"
      ]
      @ listing_meta
  | Schedules ->
      [ b Navigate "j/k" "move" ~help:"move; in details, scroll the payload"
      ; b Act "Enter" "details" ~help:"open schedule details"
      ; b Act "Esc" "back" ~help:"back to the schedule list"
      ; b Act "x" "cancel" ~help:"arm / confirm cancellation"
      ]
      @ listing_meta
  | Verification -> b Navigate "j/k" "scroll" :: listing_meta
  | Harness -> b Navigate "j/k" "scroll" :: listing_meta
  | Fusion ->
      (* [fusion_mode] owns list/detail (masc_tui_types.ml); the detail
         footer is [footer_hints_fusion_detail], which also appends the live
         scroll position this static table cannot know. *)
      [ b Navigate "j/k" "move"; b Act "Enter" "detail" ] @ listing_meta
  | Repositories -> b Navigate "j/k" "scroll" :: listing_meta
  | Changes ->
      [ b Navigate "j/k" "scroll"
      ; b Act "Enter" "written diff" ~help:"what the call wrote, as a diff"
      ; b Act "d" "tree diff" ~help:"what the tree holds now"
      ; b Act "o" "editor" ~help:"open in $EDITOR / $NVIM"
      ]
      @ listing_meta
  | Connectors ->
      [ b Navigate "j/k" "scroll"
      ; b Act "b / u" "bind / unbind" ~help:"bind / unbind a channel (editor form)"
      ]
      @ listing_meta
  | Runtime -> b Navigate "j/k" "scroll" :: listing_meta
  | Config ->
      [ b Navigate "j/k" "scroll"
      ; b Act "e" "edit" ~help:"edit runtime.toml; the server previews before it writes"
      ; b Meta "r" "reload"
      ; b Meta "Tab" "next"
      ]
  | Resources ->
      [ b Navigate "j/k" "move" ~help:"move the list; with the text focused, scroll it"
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
      ; b Act "Enter" "open" ~help:"drill in, or open the file"
        (* Esc walks back out the way Enter came in: it closes an open file
           first, and only climbs a directory once no file is open
           (masc_tui.ml:6001). A key that works and is not listed is the same
           drift as a listed key that does nothing, pointing the other way. *)
      ; b Act "Esc" "back" ~help:"close the file, then climb one directory"
      ]
      @ listing_meta
  | Tools -> b Navigate "j/k" "scroll" :: listing_meta
  | System_logs ->
      (* j/k only: g, G, and f are Acting's keys. The old help table listed
         them here, documenting keys that did nothing. *)
      b Navigate "j/k" "scroll" :: listing_meta

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
        ; b Act "Esc" "back"
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
