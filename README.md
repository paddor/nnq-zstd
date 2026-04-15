# NNQ::Zstd — transparent Zstd compression for NNQ sockets

[![CI](https://github.com/paddor/nnq-zstd/actions/workflows/ci.yml/badge.svg)](https://github.com/paddor/nnq-zstd/actions/workflows/ci.yml)
[![Gem Version](https://img.shields.io/gem/v/nnq-zstd?color=e9573f)](https://rubygems.org/gems/nnq-zstd)
[![License: ISC](https://img.shields.io/badge/License-ISC-blue.svg)](LICENSE)
[![Ruby](https://img.shields.io/badge/Ruby-%3E%3D%204.0-CC342D?logo=ruby&logoColor=white)](https://www.ruby-lang.org)

Wraps any `NNQ::Socket` with transparent per-message Zstd compression,
sender-side dictionary training, and in-band dictionary shipping. No
handshake, no negotiation — both peers must wrap for it to work.

See [RFC.md](RFC.md) for the normative wire protocol.

## Quick start

```ruby
require "nnq"
require "nnq/zstd"

push = NNQ::PUSH0.new
push.connect("tcp://127.0.0.1:5555")
push = NNQ::Zstd.wrap(push, level: -3)   # fast (-3) or balanced (3)

push.send("payload")                      # compressed on the wire
```

```ruby
pull = NNQ::PULL0.new
pull.bind("tcp://*:5555")
pull = NNQ::Zstd.wrap(pull)               # receiver-only: no dict config

pull.receive                              # => "payload"
```

## How it works

- Every message carries a 4-byte preamble:
  - `00 00 00 00` — uncompressed plaintext (preamble stripped on recv).
  - Zstd frame magic — a full Zstd frame (compressed).
  - Zstd dict magic — a Zstd dictionary to install (not surfaced to the app).
- The sender trains a dict from its first ~1000 small messages (or 100 KiB
  cumulative sample bytes), then compresses subsequent small messages
  with it. The dict is shipped in-band before the next real payload.
- User-supplied dictionaries may be passed via `dict:`:
  ```ruby
  NNQ::Zstd.wrap(socket, level: -3, dict: [dict_bytes_1, dict_bytes_2])
  ```
  All supplied dicts are shipped to peers on the wire. Training is
  skipped when `dict:` is given.
- Decompression is bounded by `min(16 MiB, recv_maxsz)`. Frames whose
  header omits `Frame_Content_Size` are rejected.
- Up to **32 dicts** and **128 KiB cumulative** per wrapper. Any
  protocol violation raises `NNQ::Zstd::ProtocolError`.

## Out of scope

- Negotiation / auto-detection. Both peers must wrap.
- Dict persistence across process restarts. Training is per-session.
- Receiver-side training — receivers only install shipped dicts.

## License

ISC. See [LICENSE](LICENSE).
