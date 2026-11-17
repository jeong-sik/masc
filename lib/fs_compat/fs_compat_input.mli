(** Scoped ownership of one input channel across caller callbacks and chunked
    reads. Open/admission and final close use the existing canonical data-path
    mutex; the borrowed-channel body runs outside it on the calling context.

    The opener receives [path], must open that path synchronously without Eio
    effects or same-path mutex reentry, and must settle any rejected descriptor
    before returning an error or raising. The body must not close or retain the
    channel after returning. These scopes add no owned-file admission or tail
    policy and do not reopen the channel between chunks.

    A canonical pathname key is captured once during acquisition and reused for
    close. This coordinates cooperative writers of that pathname, not arbitrary
    hardlink/leaf-symlink aliases or writers following a moved inode elsewhere.
    Reading may overlap writes; this is not an atomic content snapshot.

    In Eio, acquisition/handoff and final close are cancellation-protected worker
    operations. Cleanup is installed before acquisition; caller cancellation is
    checked after ownership is secured and after normal-return cleanup. A body
    exception or cancellation retains its original exception/backtrace. *)

val with_open :
  path:string -> open_input:(string -> in_channel) ->
  (in_channel -> 'a) -> 'a

val with_open_result :
  path:string -> open_input:(string -> (in_channel, 'error) result) ->
  (in_channel -> ('a, 'error) result) -> ('a, 'error) result

module For_testing : sig
  val with_open :
    before_close:(in_channel -> unit) ->
    path:string -> open_input:(string -> in_channel) ->
    (in_channel -> 'a) -> 'a
  val with_open_result :
    before_close:(in_channel -> unit) ->
    path:string -> open_input:(string -> (in_channel, 'error) result) ->
    (in_channel -> ('a, 'error) result) -> ('a, 'error) result
  val path_mutex_available : string -> bool
  (** Nonblocking probe of the actual canonical path mutex. [before_close]
      runs inside that mutex; the real [close_in_noerr] follows even if the
      probe raises. It must not reenter that mutex. *)
end
