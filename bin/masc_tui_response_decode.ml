let run ~name decode =
  Eio_guard.with_named_switch name (fun () ->
    Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ decode)
