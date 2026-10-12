# Codex native stream block lifecycle

Base: `08442304c801e684de07b5ad67ca86deea0bfc06`.

Codex producer emits a native observation for repeated item/started and
item/completed. The Keeper adapter previously emitted another block start at the
same live index, forgot closed identities, and could reopen a completed call.

The adapter now retains typed Open index / Closed ownership by provider identity.
Repeated starts do not reopen blocks; unknown finish also fences later start.
Progress reaches only Open ownership. Completion retires ownership before its
observer and finally closes content under cancellation protection, preserving
normal completion-before-stop. Terminal closure retires and closes unfinished
native blocks without synthesizing successful completion. Unnamed observations
remain in raw trace without opening unpairable blocks.

The opt-in process fixture repeats native start and completion, restarts the
completed identity, and leaves another native item unfinished. It expects two
unique native starts and one stop per block. Syntax-only parsing and whitespace
checks passed; fixture was not executed. No Dune build, CI, formal approval,
installed runtime or screenshot proof is claimed.

Raw observations and the native-action observer still follow original producer
events. Their duplicate semantic action attribution is not corrected by this
stream-block unit and remains a follow-up. Explicit cancellation raised by a stop
callback can replace an earlier completion observer exception through Fun.protect.
Overall native async/provider/UI correctness remains incomplete.
