type page =
  | Story
  | Schedule
  | Memory

let pages = [ Story; Schedule; Memory ]

let tab_label = function
  | Story -> "story"
  | Schedule -> "s schedules"
  | Memory -> "m memory"
;;

let next = function
  | Story -> Schedule
  | Schedule -> Memory
  | Memory -> Story
;;

type action =
  | Show of page
  | Close
  | Open_detail

(* Enter closes the window on the story page and returns to the story page from
   another. [s] and [m] belong to the window only while it is open: the list
   uses [s] to shut a Keeper down. The list reads their capitals the same way as
   the lowercase keys, so the window does too, and a capital [S] cannot arm a
   shutdown whose confirming [s] the window would take. Right stays the list's
   key for the detail.

   Where no Keeper is under the cursor -- a group heading, or a list with no
   Keeper -- Enter opens nothing and Right is the fold's key (RFC-0515 E12).
   Tab, [s], [m] and Esc only change the window, so they work there too. *)
let action_of_key ~on_keeper window key =
  match window, key with
  | None, ("\r" | "\n" | "enter") -> if on_keeper then Some (Show Story) else None
  | None, _ -> None
  | Some page, ("\t" | "tab") -> Some (Show (next page))
  | Some _, ("s" | "S") -> Some (Show Schedule)
  | Some _, ("m" | "M") -> Some (Show Memory)
  | Some _, ("\r" | "\n" | "enter" | "right") when not on_keeper -> None
  | Some Story, ("\r" | "\n" | "enter") -> Some Close
  | Some (Schedule | Memory), ("\r" | "\n" | "enter") -> Some (Show Story)
  | Some _, "esc" -> Some Close
  | Some _, "right" -> Some Open_detail
  | Some (Story | Schedule | Memory), _ -> None
;;
