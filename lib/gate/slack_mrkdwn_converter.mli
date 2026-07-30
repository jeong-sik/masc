(** Slack_mrkdwn_converter — Converts standard markdown text to Slack mrkdwn format. *)

(** [to_slack_mrkdwn markdown_str] converts standard markdown constructs
    (such as [**bold**], [# Header], [[label](url)], and bullet lists)
    into Slack-compatible mrkdwn format. *)
val to_slack_mrkdwn : string -> string
