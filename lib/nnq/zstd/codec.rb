# frozen_string_literal: true

module NNQ
  module Zstd
    # Pure state machine: no socket references. `encode(body)` returns
    # `[wire, dict_frame]` where `dict_frame` is a single dict message
    # that MUST precede `wire` on the wire, or nil if no dict needs
    # shipping. `decode(wire)` returns a plaintext String, or `nil` if
    # the wire message was a dict frame that has been silently installed
    # into the receive-side slot.
    class Codec
      MAX_DECOMPRESSED_SIZE  = 16 * 1024 * 1024
      MAX_DICT_SIZE          = 32 * 1024
      DICT_CAPACITY          = 8 * 1024
      TRAIN_MAX_SAMPLES      = 1000
      TRAIN_MAX_BYTES        = 100 * 1024
      TRAIN_MAX_SAMPLE_LEN   = 1024
      MIN_COMPRESS_NO_DICT   = 512
      MIN_COMPRESS_WITH_DICT = 64

      NUL_PREAMBLE = ("\x00" * 4).b.freeze
      ZSTD_MAGIC   = "\x28\xB5\x2F\xFD".b.freeze
      ZDICT_MAGIC  = "\x37\xA4\x30\xEC".b.freeze


      def initialize(level:, dict: nil, recv_max_size: nil)
        @level         = level
        @recv_max_size = [recv_max_size || MAX_DECOMPRESSED_SIZE, MAX_DECOMPRESSED_SIZE].min

        @send_dict       = nil
        @send_dict_bytes = nil
        @recv_dict       = nil
        @dict_shipped    = false

        @training      = dict.nil?
        @train_samples = []
        @train_bytes   = 0

        install_send_dict(dict.b) if dict
      end


      # Resets send-side state after a reconnect so the dict is
      # re-shipped on the new connection. Does NOT clear @recv_dict —
      # the new peer's dict overwrites it naturally when it arrives,
      # and clearing it here would race with the monitor event.
      def reset_for_reconnect!
        @dict_shipped = false
      end


      # Encodes `body` into a wire message. Returns `[wire, dict_frame]`
      # where `dict_frame` is a wire message that MUST be sent strictly
      # before `wire`, or nil.
      def encode(body)
        body = body.b
        maybe_train!(body)

        dict_frame = pending_dict_frame
        wire       = compress_or_plain(body)
        [wire, dict_frame]
      end


      # Decodes a wire message. Returns the plaintext String, or `nil`
      # if this message was a dict frame (installed into the receive
      # slot, not surfaced to the caller).
      def decode(wire)
        raise ProtocolError, "wire message too short" if wire.bytesize < 4

        head = wire.byteslice(0, 4)

        case head
        when NUL_PREAMBLE
          wire.byteslice(4, wire.bytesize - 4) || "".b
        when ZSTD_MAGIC
          decode_zstd_frame(wire)
        when ZDICT_MAGIC
          install_recv_dict(wire)
          nil
        else
          raise ProtocolError, "unrecognized preamble: #{head.unpack1('H*')}"
        end
      end


      private


      def maybe_train!(body)
        return unless @training
        return if body.bytesize >= TRAIN_MAX_SAMPLE_LEN

        @train_samples << body
        @train_bytes += body.bytesize

        return unless @train_samples.size >= TRAIN_MAX_SAMPLES ||
                      @train_bytes >= TRAIN_MAX_BYTES

        begin
          bytes = RZstd::Dictionary.train(@train_samples, capacity: DICT_CAPACITY)
        rescue RuntimeError
          @training = false
          @train_samples = nil
          return
        end

        @training = false
        @train_samples = nil

        patched = patch_auto_dict_id(bytes)
        install_send_dict(patched)
      end


      # Rewrite bytes [4..7] of a freshly trained dict with a random id
      # in USER_DICT_ID_RANGE, to avoid reserved ranges per the Zstd spec.
      def patch_auto_dict_id(bytes)
        out = bytes.dup.b
        id  = rand(USER_DICT_ID_RANGE)
        out[4, 4] = [id].pack("V")
        out
      end


      def install_send_dict(bytes)
        unless bytes.byteslice(0, 4) == ZDICT_MAGIC
          raise ProtocolError, "supplied dict is not ZDICT-format"
        end

        if bytes.bytesize > MAX_DICT_SIZE
          raise ProtocolError, "dict exceeds #{MAX_DICT_SIZE} bytes"
        end

        @send_dict       = RZstd::Dictionary.new(bytes, level: @level)
        @send_dict_bytes = bytes
      end


      def pending_dict_frame
        return nil if @send_dict_bytes.nil?
        return nil if @dict_shipped

        @dict_shipped = true
        @send_dict_bytes
      end


      def compress_or_plain(body)
        threshold = @send_dict ? MIN_COMPRESS_WITH_DICT : MIN_COMPRESS_NO_DICT
        return plain(body) if body.bytesize < threshold

        compressed =
          if @send_dict
            @send_dict.compress(body)
          else
            RZstd.compress(body, level: @level)
          end

        return plain(body) if compressed.bytesize >= body.bytesize - 4

        compressed
      end


      def plain(body)
        NUL_PREAMBLE + body
      end


      def decode_zstd_frame(wire)
        fcs = parse_frame_content_size(wire)
        raise ProtocolError, "Zstd frame missing Frame_Content_Size" if fcs.nil?

        if fcs > @recv_max_size
          raise ProtocolError, "declared FCS #{fcs} exceeds limit #{@recv_max_size}"
        end

        if @recv_dict
          @recv_dict.decompress(wire, max_output_size: @recv_max_size)
        else
          RZstd.decompress(wire, max_output_size: @recv_max_size)
        end
      rescue RZstd::DecompressError => e
        raise ProtocolError, "decompression failed: #{e.message}"
      rescue RZstd::MissingContentSizeError => e
        raise ProtocolError, "Zstd frame missing Frame_Content_Size (#{e.message})"
      rescue RZstd::OutputSizeLimitError => e
        raise ProtocolError, "declared FCS exceeds limit (#{e.message})"
      end


      def install_recv_dict(wire)
        if wire.bytesize < 8
          raise ProtocolError, "dict frame too short"
        end

        if wire.bytesize > MAX_DICT_SIZE
          raise ProtocolError, "dict exceeds #{MAX_DICT_SIZE} bytes"
        end

        @recv_dict = RZstd::Dictionary.new(wire.b)
      end


      # Parses the Zstandard `Frame_Content_Size` field from a frame
      # header. Returns the FCS as an Integer, or `nil` if absent.
      def parse_frame_content_size(wire)
        return nil if wire.bytesize < 5

        fhd        = wire.getbyte(4)
        did_flag   = fhd & 0x03
        single_seg = (fhd >> 5) & 0x01
        fcs_flag   = (fhd >> 6) & 0x03

        return nil if fcs_flag == 0 && single_seg == 0

        off = 5 + (single_seg == 0 ? 1 : 0) + [0, 1, 2, 4][did_flag]

        case fcs_flag
        when 0
          return nil if wire.bytesize < off + 1
          wire.getbyte(off)
        when 1
          return nil if wire.bytesize < off + 2
          wire.byteslice(off, 2).unpack1("v") + 256
        when 2
          return nil if wire.bytesize < off + 4
          wire.byteslice(off, 4).unpack1("V")
        when 3
          return nil if wire.bytesize < off + 8
          lo, hi = wire.byteslice(off, 8).unpack("VV")
          (hi << 32) | lo
        end
      end

    end
  end
end
