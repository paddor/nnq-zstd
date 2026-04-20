# NNQ-Zstd wire protocol (RFC-style)

**Status:** experimental. Version: 0.1.0.

## 1. Scope and non-goals

This document specifies the wire format and behavior of a transparent
Zstandard compression layer for messages carried over NNG/SP sockets
(`inproc`, `ipc`, `tcp`). It is not a replacement for SP and does not
define a connection-level handshake.

Non-goals:

- No capability negotiation. Both peers MUST wrap their sockets; an
  unwrapped peer will see garbled bytes and SHOULD disconnect.
- No persistence of dictionaries across process restarts.
- No receiver-side training. Receivers only install dictionaries
  shipped by senders.

The key words **MUST**, **MUST NOT**, **SHOULD**, **MAY**, and
**SHALL** are to be interpreted as described in RFC 2119.

## 2. Terminology

- **Sender** — a wrapper instance that sends messages.
- **Receiver** — a wrapper instance that receives messages.
- **Wrapper** — an `NNQ::Zstd::Wrapper` (or equivalent in another
  language) decorating an `NNQ::Socket`.
- **Codec** — the pure state machine inside the wrapper that
  encodes/decodes individual messages.
- **Dictionary** (**dict**) — a Zstandard dictionary, as produced by
  `ZDICT_trainFromBuffer` or handed in by the user.
- **Dict ID** — the 32-bit `Dictionary_ID` field carried in the
  dict's header and in each frame header that references it.
- **Preamble** — the first four bytes of every wire message; see §3.
- **Wire message** — one SP message as handed to/from the underlying
  socket.

## 3. Wire format

Every wire message begins with a 4-byte preamble. The first four
bytes discriminate three mutually exclusive cases:

| First 4 bytes (hex, wire order) | LE u32      | Meaning       |
|---|---|---|
| `00 00 00 00`                   | `0x00000000` | uncompressed  |
| `28 B5 2F FD`                   | `0xFD2FB528` | Zstd frame    |
| `37 A4 30 EC`                   | `0xEC30A437` | Zstd dict     |

The Zstandard frame magic and Zstandard dictionary magic are fixed
by the Zstandard format specification. The NUL preamble is specific
to this protocol.

### 3.1 Uncompressed

```
+----+----+----+----+=========================+
| 00 | 00 | 00 | 00 |   plaintext body        |
+----+----+----+----+=========================+
```

The receiver MUST strip the 4-byte NUL preamble and deliver the
remainder to the application.

### 3.2 Zstd frame

```
+----+----+----+----+=========================+
| 28 | B5 | 2F | FD |   rest of Zstd frame    |
+----+----+----+----+=========================+
```

The entire wire message is a valid Zstandard frame; the preamble
is the frame's magic number. The receiver MUST NOT strip the
preamble before decompression.

### 3.3 Zstd dictionary

```
+----+----+----+----+=========================+
| 37 | A4 | 30 | EC |   rest of Zstd dict     |
+----+----+----+----+=========================+
```

The entire wire message is a valid Zstandard dictionary. The
receiver MUST install the dictionary in its local store (§5.3)
and MUST NOT deliver this message to the application.

## 4. Sender behavior

### 4.1 Levels

The sender's compression level is set at wrapper construction. This
specification RECOMMENDS two levels:

- `-3` — fast strategy, low CPU, moderate ratio.
- `3` — balanced Zstd default.

Implementations MAY support arbitrary Zstd levels.

### 4.2 Training

Unless the user supplied dictionaries at construction, the sender
SHALL collect training samples from outbound messages until either
condition is met:

- **1000** samples collected, OR
- **100 KiB** cumulative sample bytes collected.

Only messages with body size **< 1024 bytes** are eligible as
samples. The sender SHALL train via ZDICT with a dictionary
capacity of **8 KiB** (the training cap; the resulting dict may be
smaller).

On training failure (insufficient or pathological samples, ZDICT
internal error), the sender SHALL permanently disable training for
the session and continue in no-dict mode.

### 4.3 Auto-generated dictionary IDs

Auto-trained dictionary IDs MUST fall in the user range:

```
USER_DICT_ID_RANGE = 32_768 .. (2**31 - 1)
```

Values `0..32767` are reserved for a future registrar; values
`>= 2**31` are reserved by the Zstandard format. Senders MUST NOT
assign auto-trained dicts to either reserved range. This is
enforced by post-patching bytes `[4..7]` of the trained dict buffer
with a randomly-chosen u32 LE value in the user range.

User-supplied dictionaries passed via `dict:` are honored as-is.
The user is responsible for choosing a non-reserved ID, or for
accepting the collision risk of using a reserved one.

### 4.4 Compression thresholds

- **No dict loaded**: the sender MUST emit the message uncompressed
  (§3.1) if `body.bytesize < 512`.
- **With a loaded dict**: the sender MUST emit the message
  uncompressed if `body.bytesize < 64`.

In addition, the sender MUST emit the message uncompressed if the
compressed result would not save at least four bytes (i.e.
`compressed.bytesize >= body.bytesize - 4`); this avoids paying a
preamble's worth of overhead for negative wins.

### 4.5 Dictionary shipping

**Every dictionary the sender knows** (user-supplied or
auto-trained) MUST be delivered to the peer in-band, as a dict
frame (§3.3), before any payload that requires it.

Shipping policy: a sender SHALL ship all known dicts eagerly. In
practice this means:

- On the first call to `encode` after construction (or after
  training completes), return a dict frame for each dict not yet
  shipped, followed by the real payload.
- On each newly-connected peer (observed via the underlying
  socket's monitor stream), re-ship the full known-dict set.
- **Ordering**: any dict needed to decompress a given payload MUST
  appear strictly before that payload on the wire.

### 4.6 Per-wrapper caps (sender)

- At most **32 distinct dictionaries**.
- At most **128 KiB** cumulative dictionary bytes (sum of
  `dict.bytesize` across the store).
- There is no per-dictionary size cap beyond the total-bytes
  budget; a single 128 KiB dict is valid.

If training or user input would exceed either cap, the sender MUST
refuse to install the offending dict.

### 4.7 Receive-only wrappers

A wrapper that is never asked to `send` naturally skips training
and dict shipping, since both are driven by outbound traffic. No
special mode is required: to obtain a decode-only decorator,
simply `wrap` the socket and only call `receive`.

## 5. Receiver behavior

### 5.1 Preamble dispatch

For each wire message received:

- If it begins with `00 00 00 00`, strip the preamble and deliver
  the remainder to the application.
- If it begins with the Zstd frame magic, decompress it per §5.2
  and deliver the plaintext.
- If it begins with the Zstd dict magic, install it per §5.3 and
  do not deliver anything to the application; continue with the
  next wire message.
- Otherwise, the preamble is unrecognized. The receiver MUST raise
  a protocol error and SHOULD treat the wrapped socket as failed.

### 5.2 Bounded decompression

For each Zstd frame:

1. Inspect the frame header for `Frame_Content_Size`. If absent,
   the receiver MUST raise a protocol error. This is the
   anti-zip-bomb guarantee.
2. Read the frame header's `Dictionary_ID` field. If non-zero, the
   receiver MUST look up a dictionary with that ID in its local
   store; if absent, raise a protocol error. If zero, decompress
   without a dictionary.
3. Call Zstandard decompression with a `max_output_size` equal to
   the wrapped socket's own configured maximum inbound message size
   (`recv_maxsz`). If the socket has no such cap, decompression is
   unbounded — the caller has opted out of the plaintext cap and
   the compressed path honors that choice. Exceeding the cap is a
   protocol error.
4. Deliver the decompressed plaintext to the application.

### 5.3 Dictionary installation

For each dict frame:

1. Parse the dictionary (the Zstd dict header carries the dict_id
   at bytes `[4..7]`).
2. Check the per-wrapper caps (§5.4). A violation is a protocol
   error.
3. Insert `id => dictionary` into the local store. If an entry
   with the same id already exists, overwrite it (idempotent);
   adjust the cumulative-bytes accounting accordingly.
4. Do not deliver the dict frame to the application.

Note: dict IDs in the reserved ranges are accepted if a peer
chooses to ship them (the reserved-range rule applies only to
auto-generated IDs at the sender; a receiver does not second-guess
the peer's choices).

### 5.4 Per-wrapper caps (receiver)

- At most **32 distinct dictionaries**.
- At most **128 KiB** cumulative dictionary bytes.

These match the sender caps and protect against a malicious or
buggy peer shipping unbounded dictionary state.

### 5.5 `#receive` contract

The wrapper's `#receive` operation MUST NEVER return a dict frame
to the application. It MUST loop internally over the underlying
socket's `receive`, silently installing any dict frames it
encounters, until it produces a real payload (plaintext or
successfully-decompressed frame) or the underlying socket closes.

## 6. Interoperability

Both peers of a connection MUST wrap their sockets with a
compatible implementation of this protocol. An unwrapped peer will
see byte sequences it cannot parse (an SP message starting with a
NUL preamble, or a valid Zstd frame) and is expected to close the
connection.

## 7. Security considerations

- **Zip bombs**. §5.2's mandatory `Frame_Content_Size` check plus
  bounded `max_output_size` prevent an attacker from forcing
  unbounded memory allocation during decompression.
- **Dictionary DoS**. §5.4's count and cumulative-bytes caps
  prevent a malicious peer from exhausting memory by shipping
  unbounded dictionaries.
- **Reserved-range squatting**. Auto-trained dicts MUST avoid
  reserved ID ranges (§4.3) so that future registry-allocated
  dicts can coexist with in-the-wild private dicts without
  collision.
- **No confidentiality or integrity**. This protocol provides
  neither. Wrap the underlying transport with TLS or a similar
  mechanism for either property.

## 8. Appendix: test vectors

*(Placeholder — to be filled with concrete hex dumps once the
reference implementation produces them.)*

1. **NUL-preamble `"hi"`** — wire bytes: `00 00 00 00 68 69`.
2. **Empty compressed frame** — TBD.
3. **Minimal trained dictionary** — TBD.
