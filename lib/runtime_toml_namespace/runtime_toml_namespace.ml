type t =
  | Providers
  | Models
  | Media_readers
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
  | Keeper_settings
  | Reactive
  | Autonomous
  | Heartbeat
  | Wire_capture
  | Debug
  | Turn
  | Supervisor
  | Metrics
  | Memory
  | Wiki_contents
  | Vision
  | Maintenance
  | Transport
  | Sandbox
  | Web_search
  | Otel
[@@deriving enumerate]

let key = function
  | Providers -> "providers"
  | Models -> "models"
  | Media_readers -> "media_readers"
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
  | Keeper_settings -> "keeper_settings"
  | Reactive -> "reactive"
  | Autonomous -> "autonomous"
  | Heartbeat -> "heartbeat"
  | Wire_capture -> "wire_capture"
  | Debug -> "debug"
  | Turn -> "turn"
  | Supervisor -> "supervisor"
  | Metrics -> "metrics"
  | Memory -> "memory"
  | Wiki_contents -> "wiki_contents"
  | Vision -> "vision"
  | Maintenance -> "maintenance"
  | Transport -> "transport"
  | Sandbox -> "sandbox"
  | Web_search -> "web_search"
  | Otel -> "otel"
;;

let path table rest = key table ^ "." ^ rest

(* Read back through [key], so the spelling above is the only one. *)
let of_key name = List.find_opt (fun table -> String.equal (key table) name) all
