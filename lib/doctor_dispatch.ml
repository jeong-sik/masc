let known_sidecars = [ "discord"; "slack"; "telegram"; "imessage"; "cli" ]

let sidecar_dir = function
  | "discord" -> Some "sidecars/discord-bot"
  | "slack" -> Some "sidecars/slack-bot"
  | "telegram" -> Some "sidecars/telegram-bot"
  | "imessage" -> Some "sidecars/imessage-bot"
  | "cli" -> Some "sidecars/cli-connector"
  | _ -> None

let known_summary = String.concat "|" known_sidecars
