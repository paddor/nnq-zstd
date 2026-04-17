# frozen_string_literal: true

require "nnq"
require "rzstd"

require_relative "zstd/version"

module NNQ
  module Zstd
    class ProtocolError < StandardError; end

    RESERVED_DICT_ID_LOW_MAX  = 32_767
    RESERVED_DICT_ID_HIGH_MIN = 2**31
    USER_DICT_ID_RANGE        = (32_768..(2**31 - 1)).freeze
  end
end

require_relative "zstd/codec"
require_relative "transport/zstd_tcp"
