/**
 * IDE shared signals — minimal state module.
 *
 * Extracted from `ide-shell.ts` to break a circular dependency:
 * `ide-shell` already imports `InspectorKeeperBDI` (and other heavy IDE
 * components), so importing `activeIdeFile` from `ide-shell` inside those
 * children re-enters the shell module at evaluation time and pulls
 * `router` (window-touching at module-eval) into every importer.
 *
 * Keep this module side-effect free: only signals/types live here.
 */

import { signal } from '@preact/signals'

export const activeIdeFile = signal<string>('package.json')
