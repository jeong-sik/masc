(** Post_turn_wirein_failure_site — closed sum for [site] label on
    [metric_keeper_post_turn_wirein_failures]. *)

type t = Post_commit_transient

val to_label : t -> string
