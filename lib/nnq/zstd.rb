# frozen_string_literal: true

require "nnq"
require "rzstd"
require "set"

require_relative "zstd/version"

module NNQ
  module Zstd
    class ProtocolError < StandardError; end
  end
end

require_relative "zstd/codec"
require_relative "zstd/wrapper"

module NNQ
  module Zstd

    RESERVED_DICT_ID_LOW_MAX  = 32_767
    RESERVED_DICT_ID_HIGH_MIN = 2**31
    USER_DICT_ID_RANGE        = (32_768..(2**31 - 1)).freeze

    # Wraps an NNQ::Socket with transparent Zstd compression.
    #
    # Both peers must wrap their sockets; there is no negotiation. See
    # RFC.md for the wire protocol.
    #
    # @param socket  [NNQ::Socket]
    # @param level   [Integer] Zstd level (default -3; fast strategy)
    # @param dict    [String, Array<String>, nil] pre-built dictionary
    #   bytes. If provided, training is skipped and all supplied dicts
    #   are shipped to peers on the wire. Each buffer MUST be a valid
    #   Zstd dictionary (ZDICT magic + header).
    #
    # A receive-only "passive" decoder needs no special flag — wrap
    # the socket and just never call `send`. Training is driven by
    # outbound traffic, so a socket that only receives naturally
    # skips training and dict shipping.
    def self.wrap(socket, level: -3, dict: nil)
      Wrapper.new(socket, level: level, dicts: Array(dict).compact)
    end
  end
end
