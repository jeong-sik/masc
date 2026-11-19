type t =
  | Ui
  | Io
  | Worker

(* Ui: every frame allocates the rows it draws, and at the runtime's size a
   held key meets a collection every few frames. On a live chat with
   PageUp/PageDown held, the 4M-word heap cut the median key-to-output time
   by about a quarter. Held Down/Up on Keepers and the Operations overview
   against the frozen replay (2026-11-19, 300 presses, three rounds per
   build) showed no difference either way within the host's load; that
   replay has no chat, so the chat measurement stands.

   Io and Worker: they allocate in bursts (a request, a decode, a local
   read) and wait in between. On the 4M-word heap the two of them kept
   43-45 MB more resident after 5 minutes idle: the heaps themselves and
   the runtime's minor tables sized from them. Their more frequent minor
   collections also stop the UI domain, so the same held keys ran while the
   overview re-read its local task files every 1.5 s: the median and p90
   key-to-output were no slower. *)
let minor_heap = function
  | Ui -> Minor_heap.Tuned
  | Io -> Minor_heap.Runtime_default
  | Worker -> Minor_heap.Runtime_default
;;

let use_ui_heap () = Minor_heap.apply (minor_heap Ui)

(* One worker keeps answer decoding and local reads off the UI domain; HTTP
   requests have their own domain. The server's core-sized default would add
   idle domains to every stop-the-world collection, and the client has no
   Keeper actors to spread over them. *)
let start_worker_pool ~sw domain_mgr =
  Domain_pool.create ~sw ~domain_count:1 (Minor_heap.domain_mgr (minor_heap Worker) domain_mgr)
;;
