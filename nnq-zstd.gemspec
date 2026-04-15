# frozen_string_literal: true

require_relative "lib/nnq/zstd/version"

Gem::Specification.new do |s|
  s.name     = "nnq-zstd"
  s.version  = NNQ::Zstd::VERSION
  s.authors  = ["Patrik Wenger"]
  s.email    = ["paddor@gmail.com"]
  s.summary  = "Transparent Zstd compression wrapper for NNQ sockets"
  s.description = "Wraps any NNQ::Socket with per-message Zstd compression, " \
                  "bounded decompression, in-band dictionary shipping, and " \
                  "sender-side dictionary training. No negotiation; both " \
                  "peers must wrap."
  s.homepage = "https://github.com/paddor/nnq-zstd"
  s.license  = "ISC"

  s.required_ruby_version = ">= 4.0"

  s.files = Dir["lib/**/*.rb", "README.md", "RFC.md", "LICENSE", "CHANGELOG.md"]

  s.add_dependency "nnq",   "~> 0.5"
  s.add_dependency "rzstd", "~> 0.3"
end
