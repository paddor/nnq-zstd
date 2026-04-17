# frozen_string_literal: true

# nnq-zstd: zstd+tcp:// transport plugin for NNQ.
#
# Usage:
#   require "nnq/zstd"
#
#   push = NNQ::PUSH0.new
#   push.connect("zstd+tcp://127.0.0.1:5555", level: -3)
#
#   pull = NNQ::PULL0.new
#   pull.bind("zstd+tcp://127.0.0.1:5555")

require "nnq"
require "rzstd"

require_relative "zstd_tcp/connection"
require_relative "zstd_tcp/transport"

unless NNQ::Engine.transports.frozen?
  NNQ::Engine.transports["zstd+tcp"] ||= NNQ::Transport::ZstdTcp
end
