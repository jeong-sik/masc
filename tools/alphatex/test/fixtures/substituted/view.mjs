import { real, replaced as renamed } from './dependency.mjs'
import { join } from 'node:path'

export const read = () => ({ real, renamed, joined: join('a', 'b') })
