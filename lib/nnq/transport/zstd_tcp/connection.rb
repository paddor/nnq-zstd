# frozen_string_literal: true

require "delegate"

module NNQ
  module Transport
    module ZstdTcp
      # Wraps an NNQ::Connection, transparently compressing every
      # outbound body through the engine-scoped Codec and decompressing
      # every inbound wire message. Dict frames are shipped in-band
      # (first call after training) and silently installed on receive.
      class ZstdConnection < SimpleDelegator
        # @return [Integer, nil] compressed byte count of the last payload
        #   frame decoded by {#receive_message}. Ignores dict-only frames.
        #   Read by the engine's recv loop to attach +wire_size:+ to
        #   +:message_received+ verbose monitor events. Name mirrors
        #   omq-zstd's analogous hook.
        attr_reader :last_wire_size_in


        def initialize(conn, codec)
          super(conn)
          @codec             = codec
          @last_wire_size_in = nil
        end


        def write_message(body, header: nil)
          combined = header ? (header + body) : body
          wire, dict_frame = @codec.encode(combined)
          __getobj__.write_message(dict_frame) if dict_frame
          __getobj__.write_message(wire)
        end


        def send_message(body, header: nil)
          combined = header ? (header + body) : body
          wire, dict_frame = @codec.encode(combined)
          __getobj__.write_message(dict_frame) if dict_frame
          __getobj__.send_message(wire)
        end


        def write_messages(bodies)
          batch = []
          bodies.each do |body|
            wire, dict_frame = @codec.encode(body)
            batch << dict_frame if dict_frame
            batch << wire
          end
          __getobj__.write_messages(batch)
        end


        # Loops until a real payload arrives. Dict frames are installed
        # silently and discarded so the caller only sees plaintext.
        def receive_message
          loop do
            wire    = __getobj__.receive_message
            decoded = @codec.decode(wire)
            next if decoded.nil?

            @last_wire_size_in = wire.bytesize
            return decoded
          end
        end

      end
    end
  end
end
