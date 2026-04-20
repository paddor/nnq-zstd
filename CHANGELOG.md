# Changelog

## 0.2.3 — 2026-04-20

- **RFC rewritten** around the `zstd+tcp://` transport-plugin
  architecture (the 0.1.x "wrapper" vocabulary is gone). Structured
  and worded closely after omq-zstd's RFC, adapted for SP's single-
  frame messages (no multipart, no MORE flag, no ZMTP command
  frames).
- **`MAX_DICT_SIZE` raised from 32 KiB to 64 KiB.** Matches omq-zstd
  and leaves room for larger user-supplied dictionaries. Both the
  codec check and the RFC §6.2 / §8.3 / §9 cap updated.

## 0.2.2 — 2026-04-20

- **Decompression is bounded by `socket.options.max_message_size`
  alone.** The old `min(16 MiB, recv_maxsz)` hybrid cap meant
  `--recv-maxsz 0` (explicit opt-out) still silently imposed a
  16 MiB ceiling on the compressed path, inconsistent with the
  plaintext path. The `MAX_DECOMPRESSED_SIZE` constant is removed;
  `Codec#@recv_max_size` is stored and passed through to
  `RZstd.decompress` / `Dictionary#decompress` as-is (`nil` →
  unbounded). The FCS pre-check is now gated on `@recv_max_size`
  being set. RFC §5.2 updated to match.

## 0.2.1 — 2026-04-20

- **`ZstdConnection#last_wire_size_in`.** Caches the compressed
  byte count of the last payload frame decoded by
  `#receive_message` (dict-only frames are ignored). Read by the
  NNQ engine's recv loop to attach `wire_size:` to `:message_received`
  verbose monitor events — nnq-cli's `-vvv` trace now renders
  `(1000B wire=21B)` for compressed payloads. Name mirrors the
  analogous hook in omq-zstd. Requires nnq ≥ 0.8.2.

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
