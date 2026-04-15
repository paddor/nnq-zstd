# frozen_string_literal: true

require "test_helper"

describe NNQ::Zstd::Wrapper do
  def pair_endpoint
    "inproc://nnq-zstd-test-#{SecureRandom.hex(6)}"
  end


  before do
    require "securerandom"
  end


  it "round-trips a stream of similar small payloads through an inproc PAIR" do
    ep = pair_endpoint
    a_raw = NNQ::PAIR0.new
    b_raw = NNQ::PAIR0.new
    a_raw.bind(ep)
    b_raw.connect(ep)

    a = NNQ::Zstd.wrap(a_raw, level: -3)
    b = NNQ::Zstd.wrap(b_raw, level: -3)
    begin
      msgs = 2000.times.map do |i|
        "user_#{i}@example.com|status=active|tier=gold|region=eu-#{i % 4}|" +
          ("pad=" * 20)
      end
      received = []
      Thread.new { msgs.each { |m| a.send(m) } }
      msgs.size.times { received << b.receive }
      assert_equal msgs, received
      refute_nil a.codec.active_send_dict_id
      assert_includes b.codec.recv_dict_ids, a.codec.active_send_dict_id
    ensure
      a.close
      b.close
    end
  end


  # Regression for 8ca0a50: Wrapper#send_request used to return the
  # encoded reply wire untouched, so a caller doing `nnq req -z`
  # against a compressing REP saw the NUL preamble + payload
  # (rendered as "....HELLO") instead of the plaintext. The reply
  # must be decoded before being returned.
  it "Wrapper#send_request decodes the reply body" do
    ep = "inproc://nnq-zstd-req-#{SecureRandom.hex(6)}"
    rep_raw = NNQ::REP0.new
    req_raw = NNQ::REQ0.new
    rep_raw.bind(ep)
    req_raw.connect(ep)

    rep = NNQ::Zstd.wrap(rep_raw, level: -3)
    req = NNQ::Zstd.wrap(req_raw, level: -3)
    begin
      server = Thread.new do
        body = rep.receive
        rep.send_reply(body.upcase)
      end

      reply = req.send_request("hello")
      server.join

      # Must be the plaintext reply, not the NUL-prefixed wire.
      assert_equal "HELLO", reply
      refute reply.start_with?("\x00\x00\x00\x00"),
             "reply still carries the NUL preamble: #{reply.bytes.first(8).inspect}"
    ensure
      req.close
      rep.close
    end
  end


  it "a receive-only wrapper never trains or ships dicts" do
    ep = pair_endpoint
    a_raw = NNQ::PAIR0.new
    b_raw = NNQ::PAIR0.new
    a_raw.bind(ep)
    b_raw.connect(ep)

    a = NNQ::Zstd.wrap(a_raw, level: -3)
    b = NNQ::Zstd.wrap(b_raw, level: -3)
    begin
      msgs = 1500.times.map do |i|
        "user_#{i}@example.com|status=active|tier=gold|region=eu-#{i % 4}|" +
          ("pad=" * 20)
      end
      Thread.new { msgs.each { |m| a.send(m) } }
      msgs.size.times { b.receive }
      # b never sent anything → its codec never trained nor shipped.
      assert_nil b.codec.active_send_dict_id
      assert_empty b.codec.send_dict_ids
      # But it learned the sender's dict from the wire.
      assert_includes b.codec.recv_dict_ids, a.codec.active_send_dict_id
    ensure
      a.close
      b.close
    end
  end
end
