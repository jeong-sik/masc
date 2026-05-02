import { runningUnderVitest } from '../../lib/test-env'

export const COCKPIT_FRAME_SRC = '/cockpit/MASC Cockpit (Full).html'

export function shouldLoadCockpitFrame(): boolean {
  return !runningUnderVitest()
}
