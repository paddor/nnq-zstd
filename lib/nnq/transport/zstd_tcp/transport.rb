# frozen_string_literal: true

require "socket"
require "uri"
require "io/stream"

module NNQ
  module Transport
    # zstd+tcp — transport-layer Zstd compression over TCP.
    #
    # URI scheme: `zstd+tcp://host:port`. Both peers must use this
    # scheme; a plain tcp:// peer cannot talk to a zstd+tcp:// peer.
    #
    # Compression is handled by a per-engine {NNQ::Zstd::Codec} stored
    # in a WeakKeyMap — all connections on one socket share a codec
    # (critical for dict training across fan-in / fan-out).
    #
    # Connection-layer wrapping happens in
    # {Engine::ConnectionLifecycle#ready!} via the {.wrap_connection}
    # hook, so routing and recv pumps see a duck-typed
    # {NNQ::Connection} and need no changes.
    #
    module ZstdTcp
      SCHEME = "zstd+tcp"

      # WeakKeyMap<Engine, Codec>. Entry auto-drops when the engine is GC'd.
      @codecs = ObjectSpace::WeakKeyMap.new


      class << self
        # Binds a zstd+tcp listener. Dials plain TCP underneath; the
        # compression layer is applied per-connection via {.wrap_connection}.
        #
        # @param endpoint [String] e.g. "zstd+tcp://127.0.0.1:0"
        # @param engine [NNQ::Engine]
        # @param level [Integer] Zstd compression level (default -3)
        # @param dict [String, nil] pre-built dictionary bytes
        # @return [Listener]
        def bind(endpoint, engine, level: -3, dict: nil, **)
          codec_for(engine, level: level, dict: dict)

          host, port = parse_endpoint(endpoint)
          host       = "0.0.0.0" if host == "*"
          server     = TCPServer.new(host, port)
          actual     = server.local_address.ip_port
          host_part  = host.include?(":") ? "[#{host}]" : host

          Listener.new("#{SCHEME}://#{host_part}:#{actual}", server, actual, engine)
        end


        # Dials a zstd+tcp endpoint. Non-blocking via engine's reconnect
        # loop — this is called synchronously on first connect and on
        # each retry.
        #
        # @param endpoint [String]
        # @param engine [NNQ::Engine]
        # @param level [Integer]
        # @param dict [String, nil]
        # @return [void]
        def connect(endpoint, engine, level: -3, dict: nil, **)
          codec_for(engine, level: level, dict: dict)

          host, port = parse_endpoint(endpoint)
          sock       = ::Socket.tcp(host, port, connect_timeout: connect_timeout(engine.options))

          engine.handle_connected(IO::Stream::Buffered.wrap(sock), endpoint: endpoint)
        end


        # Called by {ConnectionLifecycle#ready!} after the SP handshake
        # completes. Returns a {ZstdConnection} wrapping +conn+.
        #
        # @param conn [NNQ::Connection]
        # @param engine [NNQ::Engine]
        # @return [ZstdConnection]
        def wrap_connection(conn, engine)
          ZstdConnection.new(conn, codec_for(engine))
        end


        def parse_endpoint(endpoint)
          uri = URI.parse(endpoint.sub(/\A#{SCHEME}:/, "tcp:"))
          [uri.hostname, uri.port]
        end


        def connect_timeout(options)
          ri = options.reconnect_interval
          ri = ri.end if ri.is_a?(Range)
          [ri, 0.5].max
        end


        private


        # Returns the shared Codec for +engine+, creating one on first
        # call. Ractor fallback: module ivars are inaccessible inside a
        # Ractor, so we fall back to a fresh Codec per call (each Ractor
        # worker owns one socket with one endpoint — nothing to share).
        def codec_for(engine, level: -3, dict: nil)
          @codecs[engine] ||= NNQ::Zstd::Codec.new(
            level:         level,
            dict:          dict,
            recv_max_size: recv_max_size_from(engine),
          )
        rescue Ractor::IsolationError
          NNQ::Zstd::Codec.new(
            level:         level,
            dict:          dict,
            recv_max_size: recv_max_size_from(engine),
          )
        end


        def recv_max_size_from(engine)
          engine.options.max_message_size
        rescue NoMethodError
          nil
        end
      end


      # A bound zstd+tcp listener. Delegates accept + I/O setup to TCP;
      # compression is applied at the connection layer.
      class Listener
        attr_reader :endpoint, :port


        def initialize(endpoint, server, port, engine)
          @endpoint = endpoint
          @server   = server
          @port     = port
          @engine   = engine
          @task     = nil
        end


        def start_accept_loop(parent_task, &on_accepted)
          @task = parent_task.async(annotation: "nnq zstd+tcp accept #{@endpoint}") do
            loop do
              client = @server.accept
              on_accepted.call(IO::Stream::Buffered.wrap(client))
            rescue Async::Stop
              break
            rescue IOError
              break
            end
          ensure
            @server.close rescue nil
          end
        end


        def stop
          @task&.stop
          @server.close rescue nil
        end
      end

    end
  end
end
