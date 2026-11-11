(* The mechanism is [Fs_compat.Systhread_host], below this library so that
   [Fs_compat]'s own blocking calls use it. This module supplies what that
   layer cannot name: the log, the minor-heap tuning, and which fibers are
   pool work. *)
module Host = Fs_compat.Systhread_host

exception Host_failed = Host.Host_failed

let domain_count = Host.domain_count

let start () =
  Host.start
    ~on_domain_start:Minor_heap.tune
    ~on_failure:(fun exn ->
      Log.Misc.error
        "system-thread host failed; its callers now start threads on their own domain: %s"
        (Printexc.to_string exn))
    ~keeps_own_domain:Executor_pool_ref.in_worker_context
    ()
;;

let run = Host.run
