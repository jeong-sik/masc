type t =
  | Providers
  | Models
  | Runtime
  | Exec
  | Egress
  | Lsp
  | Typesafeai
  | Skills
  | Fusion
  | Voice
  | Tui
  | Slack
  | Discord
  | Repositories
  | Browser
  | Memory_os

let all =
  [ Providers
  ; Models
  ; Runtime
  ; Exec
  ; Egress
  ; Lsp
  ; Typesafeai
  ; Skills
  ; Fusion
  ; Voice
  ; Tui
  ; Slack
  ; Discord
  ; Repositories
  ; Browser
  ; Memory_os
  ]
;;

let key = function
  | Providers -> "providers"
  | Models -> "models"
  | Runtime -> "runtime"
  | Exec -> "exec"
  | Egress -> "egress"
  | Lsp -> "lsp"
  | Typesafeai -> "typesafeai"
  | Skills -> "skills"
  | Fusion -> "fusion"
  | Voice -> "voice"
  | Tui -> "tui"
  | Slack -> "slack"
  | Discord -> "discord"
  | Repositories -> "repositories"
  | Browser -> "browser"
  | Memory_os -> "memory_os"
;;

(* Read back through [key], so the spelling above is the only one. *)
let of_key name = List.find_opt (fun table -> String.equal (key table) name) all
