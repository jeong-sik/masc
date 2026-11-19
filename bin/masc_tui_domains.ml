type t =
  | Ui
  | Io
  | Worker

(* A minor collection stops every domain, so the process collects each time
   any one domain fills its own heap. On a loaded host each stop also waits
   until every domain is back on a core.

   Ui: every frame allocates the rows it draws. On a live chat with
   PageUp/PageDown held, the 4M-word heap cut the median key-to-output time
   by about a quarter.

   Worker: it decodes answers and reads the local task files. A refresh
   used to parse those files whole, several MB of JSON, and on a small heap
   that lengthened the key-latency tail after r to about twice main's. Since
   #53335 a refresh decodes a file only when its version moves, and the
   worker's heap no longer shows in that tail. Measured 2026-11-19 against
   the frozen replay with #53335 in: overview at 120x40, Down/Up every
   33 ms, r every 45 presses, key-to-output of the presses within 600 ms of
   an r, 14 rounds with the builds interleaved, load 227-582, ms:

     worker heap               p90    p95    p99
     256k (runtime)            40.1   78.1   137.0
     1M                        40.6   71.6   132.6
     4M                        41.5   69.7   129.6
     every domain 4M           37.4   63.8   124.5

   The last row is every domain on 4M words, Io included; the other rows
   keep Io on the runtime's heap. Paired by round, 256k minus the last row
   is p95 +14 ms [-12, +33] and p99 +13 ms [-24, +41] at 90%, while 256k
   without #53335 was p99 +159 ms [+56, +283] over 8 rounds: the method
   sees a refresh tail, and with #53335 there is none to see.

   A smaller worker heap is the memory the TUI saves. Physical footprint
   after 5 minutes idle at 200x60, eight TUIs at once, two runs per build:
   256k 138-150 MB on the overview and 153-157 MB on Keepers, 4M 175-177 MB
   and 179-194 MB. The worker takes the runtime's heap. If a refresh ever
   decodes whole files again, measure the tail again.

   Io: it sends requests and reads answers, and leaves decoding to the
   worker. Its heap changed neither figure beyond the spread between
   rounds: compare the 4M row with the last. *)
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
