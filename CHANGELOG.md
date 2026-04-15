# Changelog

## 0.1.0 — unreleased

Initial release.

- `NNQ::Zstd.wrap(socket, level: -3, dict: nil)` — transparent Zstd
  compression decorator around an `NNQ::Socket`.
- Sender-side dictionary training: first ~1000 messages < 1 KiB each,
  or up to 100 KiB cumulative sample bytes. Training failure disables
  training for the session.
- In-band dict shipping via a 4-byte preamble discriminator
  (`00 00 00 00` = plaintext, Zstd frame magic = compressed, Zstd
  dict magic = dictionary).
- Bounded decompression: `Frame_Content_Size` required; effective
  cap is `min(16 MiB, socket.recv_maxsz)`.
- Per-wrapper caps: 32 dicts, 128 KiB cumulative. Violations raise
  `NNQ::Zstd::ProtocolError`.
- Auto-generated dict IDs restricted to the user range
  `32_768..(2**31 - 1)`.
