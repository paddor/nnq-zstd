# nnq-zstd — Zstd compression transport plugin for NNQ

[![CI](https://github.com/paddor/nnq-zstd/actions/workflows/ci.yml/badge.svg)](https://github.com/paddor/nnq-zstd/actions/workflows/ci.yml)
[![Gem Version](https://img.shields.io/gem/v/nnq-zstd?color=e9573f)](https://rubygems.org/gems/nnq-zstd)
[![License: ISC](https://img.shields.io/badge/License-ISC-blue.svg)](LICENSE)
[![Ruby](https://img.shields.io/badge/Ruby-%3E%3D%204.0-CC342D?logo=ruby&logoColor=white)](https://www.ruby-lang.org)

Registers `zstd+tcp://` as an NNQ transport: TCP underneath, with
transparent per-message Zstd compression, sender-side dictionary
training, and in-band dictionary shipping. No handshake, no
negotiation — both peers must use `zstd+tcp://`.

See [RFC.md](RFC.md) for the normative wire protocol.

## Quick start

```ruby
require "nnq"
require "nnq/zstd"   # registers the transport

push = NNQ::PUSH0.new
push.connect("zstd+tcp://127.0.0.1:5555", level: -3)   # -3 fast, 3 balanced
push.send("payload")                                   # compressed on the wire
```

```ruby
pull = NNQ::PULL0.new
pull.bind("zstd+tcp://*:5555")   # receiver: no level, no dict config
pull.receive                     # => "payload"
```

Any `tcp://` URL in an NNQ/nnq-cli API works with the `zstd+` prefix —
`nnq` CLI users get this for free via `-z` / `-Z` / `--compress=LEVEL`,
which rewrite `tcp://` to `zstd+tcp://`.

## How it works

- `require "nnq/zstd"` installs `NNQ::Transport::ZstdTcp` under the
  `zstd+tcp` scheme in `NNQ::Engine.transports`.
- `bind` / `connect` dial plain TCP; after the SP handshake,
  `ConnectionLifecycle#ready!` calls `ZstdTcp.wrap_connection(conn, engine)`,
  which decorates the connection with a `ZstdConnection` (SimpleDelegator)
  that runs every outbound body through the codec and decompresses every
  inbound wire message.
- One `NNQ::Zstd::Codec` per engine, cached in a `WeakKeyMap` — all
  connections on one socket share codec state, which is what makes
  dict training meaningful across fan-in / fan-out.
- Each wire message carries a 4-byte discriminator preamble:
  - `00 00 00 00` — plaintext (stripped on recv),
  - Zstd frame magic — a full Zstd frame (compressed payload),
  - Zstd dict magic — a dictionary to install (silently swallowed on recv).
- The sender trains a single dict from its first ~1000 small messages
  (or 100 KiB cumulative sample bytes), then compresses subsequent small
  messages with it and ships the dict once per peer. User-supplied dicts
  (`dict: bytes`) replace training.
- Decompression is bounded by `min(16 MiB, socket.options.max_message_size)`.
  Frames whose header omits `Frame_Content_Size` are rejected.
- `ZstdConnection#last_wire_size_in` caches the compressed byte count of
  the last decoded payload frame so nnq's recv loop can surface it to
  `:message_received` verbose monitor events (`(1000B wire=21B)` in
  nnq-cli's `-vvv` trace).

## Out of scope

- Non-TCP transports. `ipc://` and `inproc://` are plaintext-only; there
  is no `zstd+ipc://`. A transport-layer plugin would need an analogous
  wrap hook at the framing layer.
- Negotiation / auto-detection. Both peers must use `zstd+tcp://`.
- Dict persistence across process restarts. Training is per-session.
- Receiver-side training — receivers only install shipped dicts.

## License

ISC. See [LICENSE](LICENSE).
