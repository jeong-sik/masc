export {
  AttachmentComposer,
  hasFailedAttachments,
  hasUploadingAttachments,
  readyAttachmentsOf,
  revokeComposerPreviews,
  type AttachmentComposerProps,
  type ComposerAttachmentItem,
} from './attachment-composer'
export { AttachmentGallery, type AttachmentGalleryProps } from './attachment-gallery'
export {
  ALLOWED_AUDIO_TYPES,
  ALLOWED_DOCUMENT_TYPES,
  ALLOWED_IMAGE_TYPES,
  ATTACHMENT_INPUT_ACCEPT,
  DEFAULT_MAX_ATTACHMENT_BYTES,
  MAX_COMPOSER_ATTACHMENTS,
  classifyAttachmentKind,
  createLocalPreviewUrl,
  extractTransferFiles,
  formatAttachmentBytes,
  formatAttachmentOrigin,
  readImageDimensions,
  resolveAttachmentMimeType,
  revokeLocalPreviewUrl,
  validateAttachmentFile,
} from './validation'
