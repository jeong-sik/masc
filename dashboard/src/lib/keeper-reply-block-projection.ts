import type { KeeperConversationEntry, ChatBlock } from '../types'
import { parseTextToChatBlocks } from './chat-blocks'

/** Remove only the range explicitly owned by the text projection writer. */
export function producerReplyBlocks(entry: Pick<KeeperConversationEntry, 'blocks' | 'replyTextProjection'>): ChatBlock[] {
  const blocks = entry.blocks ?? []
  const projection = entry.replyTextProjection
  if (!projection) return blocks
  if (!Number.isSafeInteger(projection.offset) || !Number.isSafeInteger(projection.length)
    || projection.offset < 0 || projection.length < 0 || projection.offset + projection.length > blocks.length) {
    throw new Error('Invalid reply text block projection')
  }
  return [...blocks.slice(0, projection.offset), ...blocks.slice(projection.offset + projection.length)]
}

export function projectFinalReplyBlocks(entry: Pick<KeeperConversationEntry, 'blocks' | 'replyTextProjection'>, text: string) {
  const retained = producerReplyBlocks(entry).filter(block => block.t !== 'status')
  const projected = parseTextToChatBlocks(text)
  return { blocks: [...retained, ...projected],
    replyTextProjection: Object.freeze({ offset: retained.length, length: projected.length }) }
}
