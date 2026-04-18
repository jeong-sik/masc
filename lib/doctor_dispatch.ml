let known_sidecars = [ "discord"; "slack"; "telegram"; "imessage"; "cli" ]

let sidecar_dir = function
  | "discord" -> Some "sidecars/discord-bot"
  | "slack" -> Some "sidecars/slack-bot"
  | "telegram" -> Some "sidecars/telegram-bot"
  | "imessage" -> Some "sidecars/imessage-bot"
  | "cli" -> Some "sidecars/cli-connector"
  | _ -> None

let known_summary = String.concat "|" known_sidecars

let aggregate_exit_code rcs =
  let normalise rc = if rc < 0 || rc > 2 then 2 else rc in
  List.fold_left (fun acc rc -> max acc (normalise rc)) 0 rcs
