import { fileURLToPath } from 'node:url'

// The VST host ships inside this viewer's own runtime: install-alphatex.sh
// writes vst/host and vst/host.py beside these modules, so a viewer never
// speaks to a host from another revision.
export const vstHostPath = fileURLToPath(new URL('./vst/host', import.meta.url))
