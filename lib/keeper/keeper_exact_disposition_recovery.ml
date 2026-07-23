let prepare_registration_result
      ~base_path
      ~keeper_name
      ~settled_at
  =
  Keeper_event_queue_persistence.prepare_registration_after_exact_recovery_result
    ~base_path
    ~keeper_name
    ~settled_at
    ()
;;
