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
