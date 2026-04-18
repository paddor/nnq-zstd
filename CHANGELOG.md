# Changelog

## 0.2.0 — 2026-04-18

- **`zstd+tcp://` is now a transport-layer plugin.** The old
  `NNQ::Zstd.wrap(socket)` / `NNQ::Zstd::Wrapper` above-socket
  wrapper is removed. Compression registers itself as
  `NNQ::Engine.transports["zstd+tcp"]` at `require "nnq/zstd"`
  time. Usage:

  ```ruby
  push = NNQ::PUSH0.new
  push.connect("zstd+tcp://127.0.0.1:5555", level: -3)

  pull = NNQ::PULL0.new
  pull.bind("zstd+tcp://127.0.0.1:5555")
  ```

  Per-engine `Codec` instances are cached in a `WeakKeyMap` so all
  connections on one socket share codec state (critical for dict
  training across fan-in / fan-out). Wrapping happens post-handshake
  via `Transport::ZstdTcp.wrap_connection(conn, engine)`, which
  NNQ's `ConnectionLifecycle` now calls on any transport that
  implements the hook.

  Migration: replace `sock = NNQ::Zstd.wrap(NNQ::PUSH0.new.connect("tcp://…"))`
  with `NNQ::PUSH0.new.connect("zstd+tcp://…")`.

- **Codec: single active dict per direction.** The multi-dict
  registry (`@send_dicts`, `@shipped_peers`, rotating slot, up to
  `MAX_DICTS = 32`) collapses to a single active send dict and a
  single recv dict. Each `Codec` now lives on exactly one engine,
  so there's no peer fan-out for the codec to track — shipping is
  gated by a simple `@dict_shipped` flag. `encode` returns
  `[wire, dict_frame]` (single frame, not array). `initialize` takes
  `dict:` (one dict) rather than `dicts:`. Removes
  `MAX_DICTS`/`MAX_DICTS_TOTAL_BYTES`; adds `MAX_DICT_SIZE = 32 KiB`
  guard on incoming dict frames.

## 0.1.1 — 2026-04-16

- **`Wrapper#send_request` decodes the reply.** Cooked REQ's
  `send_request` returns the matching reply body, but the wrapper
  used to return it untouched, so a caller doing `nnq req -z`
  against a compressing REP saw the raw wire (a NUL preamble plus
  the uppercase echo, rendered as `....HELLO`) instead of the
  plaintext. `send_request` now runs the reply through
  `Codec#decode` before returning, matching `#receive`.
- **Regression test** for the above in
  `test/nnq/zstd/wrapper_test.rb` — binds a REP, wraps both ends,
  calls `req.send_request("hello")`, and asserts the returned
  string equals `"HELLO"` and does not start with the NUL
  preamble.
- **`Gemfile`**: declare `protocol-sp` as a path dep under
  `NNQ_DEV=1` so the local nnq path dep resolves.

## 0.1.0 — 2026-04-15

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
