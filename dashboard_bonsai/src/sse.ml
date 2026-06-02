(** SSE (Server-Sent Events) helper — Phase 0.4 spike.

    This file currently stubs out the EventSource wrapper. Two implementations
    will be benchmarked before Phase 1:

    1. [brr] — [Brr_io.Ev.listen] on a [Brr_io.Sse.source]. Clean, modern.
    2. [js_of_ocaml] raw — [Dom_html.eventSource]. Minimal dependency surface.

    The winner stays, the loser gets deleted. The comparison goes into
    [docs/bonsai-migration/phase-0-report.md]. *)

type t = { url : string }

let connect url = { url }
let url t = t.url
