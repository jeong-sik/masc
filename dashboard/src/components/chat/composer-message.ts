import type { ChatBlock, ChatAttachBlock, KeeperConversationAttachment } from '../../types'
import type { ChatComposerSendPayload } from './primitives'
import { stableAttachmentId } from './attachments'

function blocksToAttachments(blocks: ChatBlock[]): KeeperConversationAttachment[] {
  const generatedCounts = new Map<string, number>()
  return blocks
    .filter((b): b is ChatAttachBlock => b.t === 'attach')
    .map((b) => {
      const baseId = stableAttachmentId({
        name: b.name,
        type: b.kind === 'image' || b.src?.startsWith('data:image/') ? 'image' : 'file',
        kind: b.kind,
        mimeType: b.mimeType,
        size: b.sizeBytes,
        dims: b.dims,
        data: b.data ?? b.svg ?? b.ph,
        src: b.src,
      })
      const count = generatedCounts.get(baseId) ?? 0
      generatedCounts.set(baseId, count + 1)
      // A reference chip rebuilds as its carrier form (#33728); only the
      // byte-backed chips go through the data-URL reconstruction.
      if (b.ref) {
        const attachment: KeeperConversationAttachment =
          b.ref.kind === 'url'
            ? { kind: 'url', id: b.id ?? baseId, name: b.name, url: b.ref.url, mimeType: b.mimeType }
            : { kind: 'file_id', id: b.id ?? baseId, name: b.name, fileId: b.ref.fileId, mimeType: b.mimeType }
        return attachment
      }
      return {
        id: b.id ?? (count === 0 ? baseId : `${baseId}-${count + 1}`),
        type: b.kind === 'image' || b.src?.startsWith('data:image/') ? 'image' : 'file',
        name: b.name,
        size: b.sizeBytes ?? 0,
        mimeType: b.mimeType ?? 'application/octet-stream',
        data: b.data ?? b.src ?? '',
        dims: b.dims,
      } satisfies KeeperConversationAttachment
    })
}

function blocksToDisplayBlocks(blocks: ChatBlock[]): ChatBlock[] | undefined {
  const displayBlocks = blocks.filter((block) => block.t !== 'attach')
  return displayBlocks.length > 0 ? displayBlocks : undefined
}

export function composerMessageOptions({ blocks, userBlocks, clientActionId }: ChatComposerSendPayload) {
  return {
    attachments: blocksToAttachments(blocks),
    blocks: blocksToDisplayBlocks(blocks),
    userBlocks,
    clientActionId,
  }
}
