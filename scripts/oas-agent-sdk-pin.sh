#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.216.3"
# Pinned to the v0.216.3 release (tracks main). On top of 0.216.0:
# - Opaque provider Tool IDs, including blank IDs, survive OAS codecs while
#   MASC keeps Tool.Invocation.t as the occurrence authority (oas#2648).
# - Tool.schedule accepts declared serial order without a synthetic
#   batch_index < batch_size constraint (oas#2652).
# - Provider-native prepared-request measurement exists as an OAS primitive
#   (oas#2647). MASC intentionally does not reconstruct completion requests;
#   fit admission must measure and dispatch the same opaque OAS request.
# - Typed empty-completion overflow maps to InvalidRequest /
#   Retry.ContextOverflow without MASC string matching (oas#2659).
# - Stacked OAS PRs run the full CI matrix (oas#2656). This is CI-only and adds
#   no runtime/API contract for MASC to adapt or duplicate.
# The reachability guard in check-oas-pin.sh tracks main; oas-drift-check.sh
# reports the public-surface delta at pin-bump time.
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="2102d4de5cdce118cfd6100a8c88e1ed52b0678b"
readonly OAS_AGENT_SDK_MIN_VERSION="0.216.3"
