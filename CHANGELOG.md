# Changelog

## 0.1.0 — unreleased

Initial release.

- **`Wrapper#send_request` decodes the reply.** Cooked REQ's
  `send_request` returns the matching reply body, but the wrapper
  used to return it untouched, so a caller doing `nnq req -z`
  against a compressing REP saw the raw wire (a NUL preamble plus
  the uppercase echo, rendered as `....HELLO`) instead of the
  plaintext. `send_request` now runs the reply through
  `Codec#decode` before returning, matching `#receive`.
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
