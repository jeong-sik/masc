### Performance

- Read the frame buffer length directly when sizing output buffers, avoiding
  a full content copy and a second copy when the Activity pane is open.
