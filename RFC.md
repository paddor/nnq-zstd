# SP over Zstd+TCP: Zstandard-Compressed TCP Transport for NNQ

| Field    | Value                                                                 |
|----------|-----------------------------------------------------------------------|
| Status   | Draft                                                                 |
| Editor   | Patrik Wenger                                                         |
| Requires | [Scalability Protocols](https://nanomsg.org/documentation-zeromq.html) over TCP |

## 1. Abstract

This specification defines `zstd+tcp://`, a TCP transport for the
Scalability Protocols (SP) wire format used by nanomsg and nng that
applies per-message Zstandard compression after the SP handshake. Both
peers use the `zstd+tcp://` scheme in their endpoint URIs. The SP
greeting proceeds over raw TCP exactly as it would over `tcp://`. After
the handshake completes, every message on the wire is individually
encoded with a 4-byte sentinel dispatch that distinguishes uncompressed
plaintext, Zstandard-compressed frames, and dictionary shipments. No SP
properties, control bytes, or negotiation are involved — compression is
an intrinsic property of the transport, like encryption is an intrinsic
property of TLS.

## 2. Motivation

Zstandard at low compression levels encodes in single-digit microseconds
per kilobyte, decompresses faster still, and on dictionary-trained
workloads compresses small messages to a fraction of their size. For
most SP deployments compression can be treated as almost free
CPU-wise, while recovering large fractions of the wire budget.

Network-bound or bandwidth-constrained deployments (publish/subscribe
fan-out, cross-region replication, IoT telemetry) trade a small amount
of CPU for a large reduction in wire time. Zstandard's dictionary mode
is a good fit for the small-message profile typical of SP workloads.

SP applications today either accept the wire cost or layer ad-hoc,
per-payload compression into the application format. The latter
requires both sides to opt in and bakes compression into the payload
rather than the transport. `zstd+tcp://` replaces it with a
transport-level mechanism that any SP application benefits from without
changes to the payload.

### 2.1 Why a transport scheme

Compression could live at three layers. Each has a fatal flaw except
the transport layer.

**Socket-level wrapper** (too high). A wrapper above routing knows
nothing about transports. It compresses local connections (pure
overhead) and cannot act on new connections naturally — dictionary
shipping requires per-connection state, but a wrapper only sees
messages after routing has dispatched them. Reconnect handling requires
hooking into connection lifecycle events that are awkward from
outside. (This is what `nnq-zstd` 0.1.x did; 0.2.0 replaced it with the
present scheme.)

**SP connection layer** (too low). Embedding compression into each SP
connection means fan-out patterns compress the same message N times
(once per subscriber connection). The connection layer has no
socket-wide view, so there is no way to share compression work across
connections.

**Transport layer** (right). `zstd+tcp://` makes transport selection
explicit in the endpoint URI. Only TCP connections get compressed.
Local transports are unaffected even on the same socket. Dictionary
lifetime matches connection lifetime naturally (new connection = new
wrapper = re-ship dictionary). No negotiation is needed — both peers
use `zstd+tcp://`. The codec is socket-wide (shared across
connections), so fan-out patterns compress once and reuse the result.

### 2.2 Why not negotiate

Compression is a deployment decision, not a runtime discovery. Both
peers are configured to use `zstd+tcp://` or they are not. The
transport scheme approach eliminates the entire negotiation surface
and its edge cases.

### 2.3 Why Zstandard

Zstandard at low levels matches LZ4 on encode latency, beats it on
decompression speed and ratio at every realistic SP payload size, and
has a first-class dictionary story. The decompression advantage is
particularly important for fan-out patterns (PUB/SUB, SURVEYOR): the
publisher pays one compress, every subscriber pays decompress, so
per-subscriber CPU dominates the total budget.

## 3. Goals and Non-goals

### 3.1 Goals

- Transparent to application code: send/receive operations see plaintext.
- Per-message sender decision: opt out for short or incompressible
  messages.
- Works for every SP socket type (PUSH/PULL, PUB/SUB, REQ/REP, PAIR,
  BUS, SURVEYOR/RESPONDENT).
- Small-message-friendly via an optional shared dictionary, either
  supplied out of band or automatically trained from early traffic.
- No SP-level negotiation, no new protocol identifier, no new control
  bytes.

### 3.2 Non-goals

- New SP protocol, new socket type, new greeting, new frame flag bit.
- Compression of the SP greeting.
- Application to non-TCP transports (`inproc://` is zero-copy —
  compression is pure overhead; `ipc://` rarely benefits).
- Any security property. SP carries no security mechanism at the wire
  level; layer TLS or similar below `zstd+tcp://` if needed. See Sec. 8.
- Streaming / context-takeover compression. Each message is decodable
  in isolation with no dependency on a previous message's LZ77 history.

## 4. Terminology

| Term                | Meaning                                                                   |
|---------------------|---------------------------------------------------------------------------|
| Message             | One SP wire message (one length-prefixed blob).                           |
| Sentinel            | The first 4 bytes of a post-handshake message on the wire (Sec. 5.1).    |
| Uncompressed message| A wire message whose sentinel is `00 00 00 00`.                           |
| Compressed message  | A wire message whose first 4 bytes are the Zstandard magic `28 B5 2F FD`.|
| Dictionary message  | A wire message whose first 4 bytes are `37 A4 30 EC` (Sec. 6).           |

## 5. Message Encoding

After the SP handshake completes, every message on the wire is
individually encoded. SP has no multipart concept — each message is one
length-prefixed blob and is encoded independently.

### 5.1 Sentinel dispatch

The first 4 bytes of each wire message determine how it is decoded.

| Sentinel (hex)   | Meaning                                                         |
|------------------|-----------------------------------------------------------------|
| `00 00 00 00`    | Uncompressed plaintext (Sec. 5.3)                               |
| `28 B5 2F FD`    | Zstandard compressed frame (Sec. 5.4)                           |
| `37 A4 30 EC`    | Dictionary shipment (Sec. 6)                                    |

All other 4-byte values are reserved. A receiver that encounters an
unknown sentinel MUST drop the connection with an error.

### 5.2 Compression level

The default compression level is **-3** (Zstandard fast strategy). At
this level the encoder cost is in the low single-digit microseconds per
kilobyte, and the achieved ratio is within a few percent of level 3
once a dictionary is in play.

The compression level is a sender choice and is not communicated on
the wire — the receiver decodes any valid Zstandard frame regardless
of the level used to encode it. Implementations SHOULD expose the
level as a configurable parameter.

### 5.3 Uncompressed sentinel `00 00 00 00`

```
+------------------+-------------------+
| 00 00 00 00      | plaintext payload |
| (4 bytes)        | (N bytes)         |
+------------------+-------------------+
```

The sender uses this sentinel when it decides not to compress the
message. The 4-byte overhead is the price of per-message selective
compression without any extra flag bit or header.

Four zero bytes cannot collide with a valid Zstandard frame magic or
the dictionary sentinel, so no ambiguity arises.

### 5.4 Compressed Zstandard frame

```
+------------------+
| Zstandard frame  |
| (M bytes)        |
+------------------+
```

The wire message IS the Zstandard frame — its first 4 bytes are the
standard Zstandard frame magic `28 B5 2F FD`. No additional framing is
added.

The sender MUST configure the encoder to write the
`Frame_Content_Size` field in the Zstandard frame header (RFC 8878
§3.1.1.1.2). This field is required for the receiver's budget
enforcement (Sec. 5.6).

### 5.5 Sender rules

For each outgoing message, the sender proceeds as follows:

1. Compute `min_size`:
   - If a dictionary is currently installed: **64 bytes**.
   - Otherwise: **512 bytes**.

   These thresholds reflect empirical measurement: without a
   dictionary, Zstandard cannot usefully compress typical payloads
   below ~512 bytes; with a dictionary, even 64-byte payloads compress
   to ~20 bytes. Implementations MAY tune these thresholds.

2. If `plaintext_size < min_size`, prepend `00 00 00 00` and emit.

3. Otherwise, run the Zstandard encoder. The encoder MUST write the
   `Frame_Content_Size` field. If the compressed output's size is
   ≥ `plaintext_size - 4` (net saving ≤ 0 after accounting for the
   4-byte sentinel of the uncompressed alternative), prepend
   `00 00 00 00` and emit the plaintext instead. Otherwise emit the
   Zstandard frame as-is.

4. If the plaintext's first 4 bytes happen to be `28 B5 2F FD` or
   `37 A4 30 EC` and the sender chooses not to compress, the sender
   MUST still prepend `00 00 00 00` to avoid sentinel ambiguity.
   Step 2 and step 3's fallback path already guarantee this.

### 5.6 Receiver rules

For each incoming wire message, the receiver proceeds as follows:

1. Read the first 4 bytes as the sentinel. If the message is shorter
   than 4 bytes, drop the connection with an error.

2. Sentinel `00 00 00 00`: the remaining `N - 4` bytes are plaintext.
   Return them.

3. Sentinel `28 B5 2F FD`: the entire wire message is a Zstandard
   frame.
   - Read the `Frame_Content_Size` field from the Zstandard header. If
     the field is absent, drop the connection with an error.
   - If the connection enforces a maximum message size and the
     declared `Frame_Content_Size` exceeds it, drop the connection
     with an error without invoking the decoder. If the connection is
     configured with no maximum (the application has explicitly opted
     out), this check is skipped — the compressed path honors the
     caller's choice just as the plaintext path does.
   - Invoke the decoder in a bounded mode that aborts if it would
     write more bytes than `Frame_Content_Size` declared (or, when a
     maximum message size is set, whichever is lower). On such an
     abort, drop the connection with an error.
   - Return the decompressed plaintext.

4. Sentinel `37 A4 30 EC`: dictionary shipment. See Sec. 6.

5. Any other sentinel: drop the connection with an error.

The maximum message size always refers to the **decompressed**
plaintext.

## 6. Dictionary Shipment

### 6.1 Dictionary message format

A dictionary is shipped as a single SP wire message whose body begins
with the dictionary sentinel:

```
+------------------+------------------------+
| 37 A4 30 EC      | dictionary bytes       |
| (4 bytes)        | (D bytes)              |
+------------------+------------------------+
```

The sentinel `37 A4 30 EC` is specific to this specification and has
no relationship to Zstandard's internals. It was chosen to avoid
collision with the Zstandard frame magic and the uncompressed
sentinel.

The remaining `D` bytes are the raw dictionary as it should be passed
to the Zstandard decoder's dictionary-load operation.

### 6.2 Constraints

- A dictionary message MUST NOT exceed **64 KiB** total (sentinel +
  dictionary bytes). A receiver that receives a dictionary message
  larger than 64 KiB MUST drop the connection with an error.

- A sender MUST send at most **one** dictionary message per direction
  per connection. A receiver that receives a second dictionary message
  on the same connection MUST drop the connection with an error.

- A dictionary message MUST be sent BEFORE any compressed message that
  references the dictionary. In practice this means the sender ships
  the dictionary before (or immediately after training triggers
  during) the first compressed write that would benefit from it.

### 6.3 Receiver handling

When the receiver encounters a dictionary message:

1. Validate the constraints in Sec. 6.2.
2. Strip the 4-byte sentinel.
3. Install the remaining bytes as the decompression dictionary for
   this connection.
4. Discard the message — it is not delivered to the application. The
   receiver loops to receive the next message.

### 6.4 Dictionary scope

The dictionary a sender ships applies to a single direction of a
single connection. Each peer may independently ship its own dictionary
for its own send direction. The common deployment is one-directional:
a publisher ships its dictionary; subscribers decode with it and send
nothing (or uncompressed traffic) back.

The sender's dictionary is typically socket-wide: trained once from
early traffic across all connections and reused. But this is an
implementation choice — the wire protocol carries no dictionary
identity or scope metadata.

An implementation MAY pool training samples and share the resulting
auto-trained dictionary across all `zstd+tcp://` connections of a
single socket. This is beneficial when a socket binds or connects
multiple `zstd+tcp://` endpoints: samples from one endpoint accelerate
training for all of them, and newly opened connections benefit from a
dictionary trained by their predecessors. Connections that were
configured with an explicit out-of-band dictionary MUST NOT
participate in shared training — they use their own dictionary
independently.

### 6.5 Automatic dictionary training

A sender MAY train a dictionary automatically from early traffic:

1. Buffer plaintext samples from the first messages. Samples larger
   than **1024 bytes** SHOULD be skipped — dictionaries primarily
   benefit small messages.
2. When the buffer reaches **1000 samples** OR **100 KiB** of
   plaintext (whichever comes first), train a Zstandard dictionary
   from the buffered samples and discard the buffer.
3. The recommended dictionary capacity (training target size) is
   **8 KiB**.
4. Ship the trained dictionary via a dictionary message (Sec. 6.1) on
   every connection, before any compressed message that uses it.
5. Switch to dictionary-bound compression for all subsequent messages.

If training fails (the sample set was too small or too uniform), the
sender MUST stay in no-dictionary mode for the rest of the socket's
lifetime. It MUST NOT retry training.

### 6.6 Dictionary ID

Auto-trained dictionaries SHOULD be patched with a random dictionary
ID in the Zstandard user range (32768 to 2^31 - 1) to avoid collisions
with Zstandard's built-in dictionary IDs. Out-of-band dictionaries
retain whatever dictionary ID they were created with.

## 7. SP Interaction

### 7.1 Greeting and handshake

The SP greeting (`00 'S' 'P' 00 <peer-proto:u16-BE> 00 00`, 8 bytes)
proceeds over raw TCP exactly as specified by the SP wire format.
`zstd+tcp://` does not modify the greeting, peer-protocol identifier,
or any other aspect of the handshake. The compression layer activates
only after the handshake is complete and the connection is ready for
message traffic.

### 7.2 Socket type compatibility

`zstd+tcp://` is compatible with all SP socket types (PUSH/PULL,
PUB/SUB, REQ/REP, PAIR, BUS, SURVEYOR/RESPONDENT). Protocol-specific
in-message headers (REQ/REP request IDs, SURVEYOR/RESPONDENT survey
IDs, SUB topic prefixes) live inside the plaintext and are opaque to
this specification — they are compressed and decompressed along with
the rest of the message.

### 7.3 Peer requirement

Both peers of a connection MUST use `zstd+tcp://`. There is no
fallback to plaintext TCP and no negotiation. A `zstd+tcp://` peer
connecting to a plain `tcp://` peer (or vice versa) will see garbled
data or sentinel errors and the connection will fail.

## 8. Security Considerations

### 8.1 Compression combined with encryption (CRIME / BREACH)

Combining length-revealing compression with a secure channel that
carries attacker-influenced plaintext enables CRIME- and BREACH-style
side-channel attacks. An attacker who can inject chosen bytes into the
plaintext and observe the ciphertext length can extract secrets byte
by byte.

Implementations SHOULD refuse to layer `zstd+tcp://` inside an
encrypted tunnel when the plaintext contains attacker-controlled
content. Deployments that accept this risk MUST do so with explicit
opt-in.

### 8.2 Length side-channel

Compression makes the wire length of a message depend on its content.
An on-path observer can learn something about the plaintext from the
compressed length alone. Deployments that care about traffic analysis
MUST NOT rely on `zstd+tcp://` to hide payload shape.

### 8.3 Dictionary contents

When auto-training is enabled, the receiver loads dictionary bytes
chosen by the peer. The Zstandard reference dictionary loader is
hardened against malformed inputs, but implementations MUST enforce
the 64 KiB cap on dictionary messages (Sec. 6.2) and SHOULD NOT cache
received dictionaries across connections.

### 8.4 Decompression bombs

A small compressed message can decompress to many megabytes of
plaintext. The receiver rules in Sec. 5.6 mitigate this:

1. Every compressed message MUST carry `Frame_Content_Size`. When the
   connection enforces a maximum message size, the receiver checks
   the declared size against it before invoking the decoder, so a
   bomb is rejected on its header alone.
2. The decoder is invoked in bounded mode — it aborts if it would
   write more bytes than declared (or more than the maximum message
   size, whichever is lower). A peer that lies in the header cannot
   expand a message past its declared size.

Implementations SHOULD set a conservative maximum message size on
`zstd+tcp://` connections. Leaving the maximum unbounded is valid
(and honored by the decompressed path) but trades the zip-bomb
guarantee for the caller's explicit opt-out.

## 9. Constants

```
SENTINEL_UNCOMPRESSED   = 00 00 00 00   (4 bytes)
SENTINEL_ZSTD_FRAME     = 28 B5 2F FD   (4 bytes, Zstandard frame magic)
SENTINEL_ZSTD_DICT      = 37 A4 30 EC   (4 bytes)

DEFAULT_LEVEL           = -3

MIN_COMPRESS_NO_DICT    = 512 bytes
MIN_COMPRESS_WITH_DICT  = 64 bytes

MAX_DICT_SIZE           = 64 KiB

TRAIN_MAX_SAMPLES       = 1000
TRAIN_MAX_BYTES         = 100 KiB
TRAIN_MAX_SAMPLE_LEN    = 1024 bytes
DICT_CAPACITY           = 8 KiB
```

## 10. References

- [Scalability Protocols](https://nanomsg.org/documentation-zeromq.html) — underlying wire protocol (nanomsg / nng)
- [protocol-sp](https://github.com/paddor/protocol-sp) — Ruby codec used by NNQ
- [RFC 8878 — Zstandard Compression Data Format](https://datatracker.ietf.org/doc/html/rfc8878)
- [Zstandard dictionary builder](https://github.com/facebook/zstd/blob/dev/lib/dictBuilder/zdict.h)
- [CRIME attack](https://en.wikipedia.org/wiki/CRIME) — compression side-channel on TLS
- [BREACH attack](https://en.wikipedia.org/wiki/BREACH) — HTTP-layer variant
