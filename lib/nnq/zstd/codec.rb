# frozen_string_literal: true

module NNQ
  module Zstd
    # Pure state machine: no socket references. `encode(body)` returns
    # `[wire, dict_frames]` where `dict_frames` are any dict frames
    # that MUST precede the wire payload on the wire. `decode(wire)`
    # returns a plaintext String, or `nil` if the wire message was a
    # dict frame that has been silently installed into the receive-
    # side dictionary store.
    class Codec
      MAX_DECOMPRESSED_SIZE  = 16 * 1024 * 1024
      MAX_DICTS              = 32
      MAX_DICTS_TOTAL_BYTES  = 128 * 1024
      DICT_CAPACITY          = 8 * 1024
      TRAIN_MAX_SAMPLES      = 1000
      TRAIN_MAX_BYTES        = 100 * 1024
      TRAIN_MAX_SAMPLE_LEN   = 1024
      MIN_COMPRESS_NO_DICT   = 512
      MIN_COMPRESS_WITH_DICT = 64

      NUL_PREAMBLE = ("\x00" * 4).b.freeze
      ZSTD_MAGIC   = "\x28\xB5\x2F\xFD".b.freeze
      ZDICT_MAGIC  = "\x37\xA4\x30\xEC".b.freeze


      def initialize(level:, dicts: [], recv_max_size: nil)
        @level           = level
        @recv_max_size   = [recv_max_size || MAX_DECOMPRESSED_SIZE, MAX_DECOMPRESSED_SIZE].min

        @send_dicts      = {}
        @send_dict_bytes = {}
        @send_dict_order = []
        @pending_ship    = []
        @shipped_peers   = Set.new
        @active_send_id  = nil

        @recv_dicts      = {}
        @recv_total_bytes = 0

        @training        = dicts.empty?
        @train_samples   = []
        @train_bytes     = 0

        dicts.each { |db| install_send_dict(db.b) }
      end


      # @return [Integer, nil] id of the dict currently used for compression
      def active_send_dict_id
        @active_send_id
      end


      # @return [Array<Integer>] ids of dicts in the send-side store
      def send_dict_ids
        @send_dict_order.dup
      end


      # @return [Array<Integer>] ids of dicts in the recv-side store
      def recv_dict_ids
        @recv_dicts.keys
      end


      # Resets the shipped-tracker so the next encode calls will re-emit
      # every known dict before the next real payload. Called by the
      # wrapper when a new peer connects.
      def requeue_all_dicts_for_shipping!
        @pending_ship = @send_dict_order.dup
      end


      # Encodes `body` into a wire message. Returns `[wire, dict_frames]`
      # where `dict_frames` is an array of wire messages that MUST be
      # sent strictly before `wire`.
      def encode(body)
        body = body.b
        maybe_train!(body)

        dict_frames = drain_pending_dict_frames
        wire = compress_or_plain(body)
        [wire, dict_frames]
      end


      # Decodes a wire message. Returns the plaintext String, or `nil`
      # if this message was a dict frame (installed into the receive
      # store, not surfaced to the caller).
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
      # in USER_DICT_ID_RANGE, to avoid reserved ranges per §4.3.
      def patch_auto_dict_id(bytes)
        out = bytes.dup.b
        id  = rand(USER_DICT_ID_RANGE)
        out[4, 4] = [id].pack("V")
        out
      end


      def install_send_dict(bytes)
        if @send_dict_order.size >= MAX_DICTS
          raise ProtocolError, "send-side dict count would exceed #{MAX_DICTS}"
        end
        total = @send_dict_bytes.each_value.sum(&:bytesize) + bytes.bytesize
        if total > MAX_DICTS_TOTAL_BYTES
          raise ProtocolError, "send-side dict bytes would exceed #{MAX_DICTS_TOTAL_BYTES}"
        end
        unless bytes.byteslice(0, 4) == ZDICT_MAGIC
          raise ProtocolError, "supplied dict is not ZDICT-format"
        end

        dict = RZstd::Dictionary.new(bytes, level: @level)
        id   = dict.id
        return if @send_dicts.key?(id)

        @send_dicts[id]      = dict
        @send_dict_bytes[id] = bytes
        @send_dict_order << id
        @pending_ship << id
        @active_send_id ||= id
      end


      def drain_pending_dict_frames
        return [] if @pending_ship.empty?

        frames = @pending_ship.map { |id| @send_dict_bytes.fetch(id) }
        @pending_ship = []
        frames
      end


      def compress_or_plain(body)
        threshold = @active_send_id ? MIN_COMPRESS_WITH_DICT : MIN_COMPRESS_NO_DICT
        return plain(body) if body.bytesize < threshold

        compressed =
          if @active_send_id
            @send_dicts.fetch(@active_send_id).compress(body)
          else
            RZstd.compress(body, level: @level)
          end

        # Sanity bailout: a compressed result that doesn't save at
        # least four bytes gets emitted as plaintext instead. Avoids
        # paying a preamble's worth of overhead for negative wins.
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

        dict_id = parse_frame_dict_id(wire)
        if dict_id && dict_id != 0
          dict = @recv_dicts[dict_id]
          raise ProtocolError, "unknown dict_id #{dict_id}" if dict.nil?
          dict.decompress(wire, max_output_size: @recv_max_size)
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
        if @recv_dicts.size >= MAX_DICTS
          raise ProtocolError, "recv-side dict count would exceed #{MAX_DICTS}"
        end
        total = @recv_total_bytes + wire.bytesize
        if total > MAX_DICTS_TOTAL_BYTES
          raise ProtocolError, "recv-side dict bytes would exceed #{MAX_DICTS_TOTAL_BYTES}"
        end
        if wire.bytesize < 8
          raise ProtocolError, "dict frame too short"
        end

        id = wire.byteslice(4, 4).unpack1("V")
        dict = RZstd::Dictionary.new(wire.b)
        unless dict.id == id
          raise ProtocolError, "dict header id mismatch"
        end

        if (existing = @recv_dicts[id])
          # Idempotent overwrite: adjust running total.
          @recv_total_bytes -= @send_dict_bytes[id]&.bytesize || 0
          _ = existing
        end
        @recv_dicts[id] = dict
        @recv_total_bytes += wire.bytesize
      end


      # Parses the Zstandard `Frame_Content_Size` field from a frame
      # header. Returns the FCS as an Integer, or `nil` if absent.
      # Per the Zstandard spec, FCS is absent iff
      # `Single_Segment_flag == 0 && FCS_flag == 0`.
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


      # Parses the `Dictionary_ID` field from a Zstd frame header.
      # Returns the id as an Integer (0 if the frame carries no
      # Dictionary_ID field), or `nil` if the header is truncated.
      def parse_frame_dict_id(wire)
        return nil if wire.bytesize < 5
        fhd        = wire.getbyte(4)
        did_flag   = fhd & 0x03
        single_seg = (fhd >> 5) & 0x01

        off = 5 + (single_seg == 0 ? 1 : 0)
        case did_flag
        when 0
          0
        when 1
          return nil if wire.bytesize < off + 1
          wire.getbyte(off)
        when 2
          return nil if wire.bytesize < off + 2
          wire.byteslice(off, 2).unpack1("v")
        when 3
          return nil if wire.bytesize < off + 4
          wire.byteslice(off, 4).unpack1("V")
        end
      end
    end
  end
end
