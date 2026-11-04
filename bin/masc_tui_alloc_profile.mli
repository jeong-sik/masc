(** Where the UI domain allocates, sampled, off unless MASC_TUI_ALLOC_PROFILE
    names a file to append the report to.

    A held key on a busy surface allocated about 3 MB per frame on the UI
    domain (2026-11-04), and every minor collection that allocation causes
    stops every domain. The frame timer says a frame was slow; this says
    which code filled the minor heap.

    Samples come from [Gc.Memprof] on the domain that calls {!start}: each
    sampled word carries its call stack. The report ranks allocation sites by
    sampled words, as the innermost frame in masc's own sources and as the
    first frames of the recorded stack. Counts are samples scaled by the sampling rate,
    so they estimate words, not count them.

    A frame counts as masc's when its file is recorded under [bin/] or
    [lib/]. Some opam libraries record [lib/] paths too (Yojson's
    [lib/read.mll]), so a decoder's allocations can rank under the library's
    frame; the stack ranking still shows the masc caller.

    A variable of its own rather than a mode of MASC_TUI_FRAME_TIMING:
    sampling adds work at allocation points, so a run that measures frame
    time should not also sample. Like the frame timer it is a property of one
    process run, not of a workspace, so it is not a [runtime.toml] key. *)

val start : unit -> unit
(** Begin sampling on the calling domain when the environment asks for it.
    Does nothing otherwise. Call once, from the UI domain. *)

val report : unit -> unit
(** Stop sampling and append the ranked sites to the configured file. Silent
    when sampling is off, and on a file that cannot be opened. *)
