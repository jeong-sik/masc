# Board attachment reading

Numbered stored File/Score attachments open a complete reading over the current
post. Escape returns to that post. The default is original source; `m` and `h`
choose Markdown and inert HTML interpretation, and `u` returns to source. These
are reader choices, not inferred media types. HTML uses the existing terminal
projection without scripts, navigation or external resource fetching.

The read captures the post ID, original name, digest and byte length. The actual
bounded binary GET carries expected workspace roots and requires the server's
admission receipt. Length and SHA-256 must match before content can be copied or
saved. A Board blob is not mapped to a published report or revision by digest.

Retrieval and width-specific display preparation run through the existing
workspace job and CPU boundaries. Opaque requests distinguish same-key reopens;
resize and interpretation changes supersede only their own preparation. Closing,
source removal, workspace withdrawal or read-epoch changes retire the reader.
Late responses cannot settle a replacement request.

`y` sends original UTF-8 bytes, including CRLF, through the existing terminal
clipboard path; sending is not clipboard acknowledgement. Binary content remains
available to explicit `s` save. `r` starts a fresh read. Scrolling and Home/End
cover the complete prepared reading. Other media retain their existing actions.

Protocol, original-byte and ownership tests do not establish visible UI behavior.
