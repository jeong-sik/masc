# Unicode blank conclusions and the complete schema consumer

Baseline #41056: `fe6964a5f55bd65db3bc2cdd96463fa2ee0e4f12`.
Child #41065 at `a4c34a31e24ed7140286e96fc31ed20c57e4e92b` is included in this
parent's history, preserving its source/evidence and both review responses.
The parent's registered consumer test now understands synthesis branches; it
no longer requires absent root-level required/properties members.

The decoder and schema now share Uucp.White.is_white_space. At module
initialization, the schema's character class is generated from that property;
there is no separate handwritten production whitespace list. The decoder folds
UTF-8 input through the same property, preserving meaningful content unchanged.
Malformed UTF-8 is an explicit error. uutf/uucp are direct fusion_core dependencies.

Actual isolated native decoder processes evaluated 135 blank cases: empty,
each Unicode White_Space code point and their concatenation, at all five
conclusion positions. The baseline rejected 30 and incorrectly accepted 105;
the candidate rejects all 135. Five supported multilingual/emoji answers plus
Insufficient retain their original content. Eleven source-sliced Judge parser
tests and the unchanged source-sliced Keeper Fusion schema consumer pass.

Node's actual ECMAScript RegExp engine checks all five patterns exported by
the compiled decoder against the 25 Unicode White_Space code points, empty
strings and meaningful content. All pass. The independent test alphabet comes
from Unicode 17 PropList, not the generated pattern:
https://www.unicode.org/Public/17.0.0/ucd/PropList.txt

The native runner accepts candidate-checkout and shared-checkout-cache paths.
It compiles the actual decoder with OCaml 5.5.1 and a cached Fusion_types object.
These are focused decoder/consumer slices and actual schema regex checks,
not the full Fusion/consumer suites, provider fallback, server, installation or
production evidence. The earlier full-consumer-file typecheck encountered
inconsistent cached Masc/Operator_tool interfaces; that limit remains.
Earlier evidence retains its historical source hashes; manifest.json here
identifies the current sources.
