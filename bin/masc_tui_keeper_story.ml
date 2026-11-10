type page =
  | Story
  | Schedule
  | Memory
  | World

let pages = [ Story; Schedule; Memory ]

let tab_label = function
  | Story -> "story"
  | Schedule -> "s schedules"
  | Memory -> "m memory"
  | World -> "world"
;;

let next = function
  | Story -> Schedule
  | Schedule -> Memory
  | Memory -> Story
  | World -> World
;;

type selection = Keeper_selected | World_selected | No_selection

type memory_view = Memory_summary | Memory_recent | Memory_frequent | Memory_changes | Memory_storage

type action =
  | Show of page
  | Close
  | Open_detail
  | Open_world
  | Show_memory of memory_view
  | Scroll_memory of int

(* Enter closes the window on the story page and returns to the story page from
   another. [s] and [m] belong to the window only while it is open: the list
   uses [s] to shut a Keeper down. The list reads their capitals the same way as
   the lowercase keys, so the window does too, and a capital [S] cannot arm a
   shutdown whose confirming [s] the window would take. Right stays the list's
   key for the detail.

   Where no Keeper is under the cursor -- a group heading, or a list with no
   Keeper -- Enter opens nothing and Right is the fold's key (RFC-0515 E12).
   Tab, [s], [m] and Esc only change the window, so they work there too. *)
let action_of_key ~selection window key =
  let on_keeper = match selection with Keeper_selected -> true | World_selected | No_selection -> false in
  match window, key with
  | (None | Some (Story | Schedule | Memory | World)), "W" -> Some Open_world
  | (None | Some (Story | Schedule | Memory)), ("\r" | "\n" | "enter")
      when selection = World_selected -> Some (Show World)
  | Some World, ("\r" | "\n" | "enter" | "esc") -> Some Close
  | Some World, ("\t" | "tab" | "s" | "S" | "m" | "M" | "right") -> Some (Show World)
  | Some (Story | Schedule | Memory), ("\t" | "tab" | "s" | "S" | "m" | "M" | "right")
      when selection = World_selected -> Some (Show World)
  | None, ("\r" | "\n" | "enter") -> if on_keeper then Some (Show Story) else None
  | None, _ -> None
  | Some ((Story | Schedule | Memory) as page), ("\t" | "tab") -> Some (Show (next page))
  | Some (Story | Schedule | Memory), ("s" | "S") -> Some (Show Schedule)
  | Some (Story | Schedule | Memory), ("m" | "M") -> Some (Show Memory)
  | Some Memory, "0" when on_keeper -> Some (Show_memory Memory_summary)
  | Some Memory, "1" when on_keeper -> Some (Show_memory Memory_recent)
  | Some Memory, "2" when on_keeper -> Some (Show_memory Memory_frequent)
  | Some Memory, "3" when on_keeper -> Some (Show_memory Memory_changes)
  | Some Memory, "4" when on_keeper -> Some (Show_memory Memory_storage)
  | Some Memory, "[" when on_keeper -> Some (Scroll_memory (-1))
  | Some Memory, "]" when on_keeper -> Some (Scroll_memory 1)
  | Some (Story | Schedule | Memory), ("\r" | "\n" | "enter" | "right") when not on_keeper -> None
  | Some Story, ("\r" | "\n" | "enter") -> Some Close
  | Some (Schedule | Memory), ("\r" | "\n" | "enter") -> Some (Show Story)
  | Some (Story | Schedule | Memory), "esc" -> Some Close
  | Some (Story | Schedule | Memory), "right" -> Some Open_detail
  | Some (Story | Schedule | Memory | World), _ -> None
;;
