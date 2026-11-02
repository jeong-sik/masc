val read : base_path:string -> goal_id:string -> Candle_goal_observation.t
(** Observe current configuration and the ledger independently. Never repairs,
    appends, truncates, appraises, or pays. The ledger lock infrastructure may
    create a lock file and parent directory. *)
