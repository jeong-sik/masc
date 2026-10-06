type t =
  | Providers
  | Models
  | Model_sets
  | Runtime
  | Exec
  | Egress
  | Lsp
  | Typesafeai
  | Skills
  | Fusion
  | Board
  | Voice
  | Tui
  | Slack
  | Discord
  | Repositories
  | Browser
  | Machines
  | Memory_os
[@@deriving enumerate]

let key = function
  | Providers -> "providers"
  | Models -> "models"
  | Model_sets -> "model_sets"
  | Runtime -> "runtime"
  | Exec -> "exec"
  | Egress -> "egress"
  | Lsp -> "lsp"
  | Typesafeai -> "typesafeai"
  | Skills -> "skills"
  | Fusion -> "fusion"
  | Board -> "board"
  | Voice -> "voice"
  | Tui -> "tui"
  | Slack -> "slack"
  | Discord -> "discord"
  | Repositories -> "repositories"
  | Browser -> "browser"
  | Machines -> "machines"
  | Memory_os -> "memory_os"
;;

let path table rest = key table ^ "." ^ rest

(* Read back through [key], so the spelling above is the only one. *)
let of_key name = List.find_opt (fun table -> String.equal (key table) name) all
