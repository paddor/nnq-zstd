# frozen_string_literal: true

module NNQ
  module Zstd
    # Socket decorator that transparently runs every outbound body
    # through the Codec's encoder and every inbound wire message
    # through its decoder. Delegates any unknown method to the wrapped
    # socket, so the wrapper quacks like an `NNQ::Socket`.
    class Wrapper
      attr_reader :codec


      def initialize(socket, level:, dicts:)
        @sock  = socket
        @codec = Codec.new(
          level:         level,
          dicts:         dicts,
          recv_max_size: recv_max_size_from(socket),
        )
        start_dict_monitor!
      end


      def send(body)
        send_with_codec(body) { |wire| @sock.send(wire) }
      end


      def send_reply(body)
        send_with_codec(body) { |wire| @sock.send_reply(wire) }
      end


      def send_survey(body)
        send_with_codec(body) { |wire| @sock.send_survey(wire) }
      end


      def send_request(body)
        send_with_codec(body) { |wire| @sock.send_request(wire) }
      end


      # Loops internally until a real payload arrives or the socket
      # closes. Dict frames are silently installed and discarded.
      def receive
        loop do
          raw = @sock.receive
          return raw if raw.nil?
          decoded = @codec.decode(raw)
          return decoded unless decoded.nil?
        end
      end


      def close
        begin
          @monitor_task&.stop
        rescue StandardError
          # Monitor task may already be gone; fine.
        end
        @sock.close
      end


      def respond_to_missing?(name, include_private = false)
        @sock.respond_to?(name, include_private)
      end


      def method_missing(name, *args, **kwargs, &block)
        if @sock.respond_to?(name)
          @sock.public_send(name, *args, **kwargs, &block)
        else
          super
        end
      end


      private


      def send_with_codec(body)
        wire, dict_frames = @codec.encode(body)
        dict_frames.each { |df| yield(df) }
        yield(wire)
      end


      def recv_max_size_from(socket)
        socket.options.recv_maxsz
      rescue NoMethodError
        nil
      end


      # Best-effort: when a new peer connects, requeue every known
      # dict so the next encode call re-ships them in front of its
      # payload. Uses the underlying socket's monitor stream.
      def start_dict_monitor!
        return unless @sock.respond_to?(:monitor)

        @monitor_task = @sock.monitor do |event|
          @codec.requeue_all_dicts_for_shipping! if event.type == :connected
        end
      rescue StandardError
        # Monitor unavailable on this socket; dict re-shipping on
        # reconnect just won't fire. Not fatal.
      end
    end
  end
end
