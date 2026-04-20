# frozen_string_literal: true

require "test_helper"

describe NNQ::Zstd::Codec do
  def codec(**opts)
    NNQ::Zstd::Codec.new(level: -3, **opts)
  end


  def similar_samples(n = 300)
    n.times.map { |i| "user_#{i}@example.com|status=active|tier=gold|region=eu-#{i % 4}" }
  end


  it "round-trips a small plaintext body via NUL preamble" do
    c = codec
    wire, dict_frame = c.encode("hi")
    assert_nil dict_frame
    assert_equal("\x00\x00\x00\x00hi".b, wire)
    assert_equal "hi", c.decode(wire)
  end


  it "emits plaintext for bodies under 512 B with no dict loaded" do
    c = codec
    body = "a" * 500
    wire, = c.encode(body)
    assert_equal "\x00\x00\x00\x00".b, wire.byteslice(0, 4)
  end


  it "compresses bodies >= 512 B with no dict loaded" do
    c = codec
    body = ("The quick brown fox jumps over the lazy dog. " * 40).b
    wire, = c.encode(body)
    assert_equal NNQ::Zstd::Codec::ZSTD_MAGIC, wire.byteslice(0, 4)
    assert_operator wire.bytesize, :<, body.bytesize
    round = c.decode(wire)
    assert_equal body, round
  end


  it "emits plaintext if compression would not save at least 4 bytes" do
    c = codec
    body = Random.bytes(600)
    wire, = c.encode(body)
    assert_equal "\x00\x00\x00\x00".b, wire.byteslice(0, 4)
    assert_equal body, c.decode(wire)
  end


  it "rejects a Zstd frame whose header omits Frame_Content_Size" do
    c = codec
    bad = NNQ::Zstd::Codec::ZSTD_MAGIC + "\x00".b + "\x00".b
    assert_raises(NNQ::Zstd::ProtocolError) { c.decode(bad) }
  end


  it "raises ProtocolError on unknown preamble" do
    c = codec
    assert_raises(NNQ::Zstd::ProtocolError) { c.decode("XXXXpayload") }
  end


  describe "training" do
    it "trains after ~100 KiB of samples and queues a dict frame" do
      c = codec
      dict_frame = nil
      similar_samples(1500).each do |s|
        _, df = c.encode(s)
        dict_frame ||= df
        break if dict_frame
      end
      refute_nil dict_frame
      assert_equal NNQ::Zstd::Codec::ZDICT_MAGIC, dict_frame.byteslice(0, 4)
    end


    it "auto-trained dict_id lands in USER_DICT_ID_RANGE" do
      c = codec
      dict_frame = nil
      similar_samples(1500).each do |s|
        _, df = c.encode(s)
        dict_frame ||= df
        break if dict_frame
      end
      refute_nil dict_frame
      id = dict_frame.byteslice(4, 4).unpack1("V")
      assert_includes NNQ::Zstd::USER_DICT_ID_RANGE, id
    end


    it "disables training permanently on ZDICT failure" do
      c = codec
      calls = 0
      sc = RZstd::Dictionary.singleton_class
      original = sc.instance_method(:train)
      sc.alias_method(:__orig_train, :train)
      sc.define_method(:train) do |*_args, **_kw|
        calls += 1
        raise RuntimeError, "boom"
      end
      begin
        1500.times { c.encode("x" * 100) }
      ensure
        sc.alias_method(:train, :__orig_train)
        sc.remove_method(:__orig_train)
        _ = original
      end
      assert_equal 1, calls, "train should be called exactly once"
    end
  end


  describe "single-dict round-trip" do
    it "ships dict before payload and decodes via dict on the peer" do
      sender   = codec
      receiver = codec

      similar_samples(1500).each do |s|
        wire, dict_frame = sender.encode(s)
        if dict_frame
          assert_nil receiver.decode(dict_frame)
        end
        plain = receiver.decode(wire)
        refute_nil plain
      end

      msg = "user_4242@example.com|status=active|tier=gold|region=eu-2|extra=" + ("x" * 40)
      wire, dict_frame = sender.encode(msg)
      assert_nil dict_frame
      assert_equal NNQ::Zstd::Codec::ZSTD_MAGIC, wire.byteslice(0, 4)
      assert_equal msg, receiver.decode(wire)
    end


    it "raises on compressed frame when receiver has no dict" do
      sender   = codec
      receiver = codec
      similar_samples(1500).each do |s|
        sender.encode(s)
      end
      msg = "user_42@example.com|status=active|tier=gold|region=eu-2|extra=" + ("y" * 40)
      wire, = sender.encode(msg)
      assert_raises(NNQ::Zstd::ProtocolError) { receiver.decode(wire) }
    end
  end


  describe "dict overwrite" do
    it "allows a second dict to overwrite the first" do
      dict_bytes = RZstd::Dictionary.train(similar_samples(400), capacity: 8 * 1024)
      c = codec
      assert_nil c.decode(dict_bytes)
      assert_nil c.decode(dict_bytes)
    end
  end


  describe "user-supplied dict" do
    def trained_dict_bytes
      RZstd::Dictionary.train(similar_samples(400), capacity: 8 * 1024)
    end


    it "ships supplied dict and skips training" do
      bytes = trained_dict_bytes
      c = NNQ::Zstd::Codec.new(level: -3, dict: bytes)
      body = "user_42@example.com|status=active|tier=gold|region=eu-2"
      wire, dict_frame = c.encode(body)
      refute_nil dict_frame
      assert_equal NNQ::Zstd::Codec::ZDICT_MAGIC, dict_frame.byteslice(0, 4)

      receiver = NNQ::Zstd::Codec.new(level: -3)
      assert_nil receiver.decode(dict_frame)
      assert_equal body, receiver.decode(wire)
    end


    it "refuses a non-ZDICT-format dict" do
      assert_raises(NNQ::Zstd::ProtocolError) do
        NNQ::Zstd::Codec.new(level: -3, dict: "just some raw bytes that are long enough" * 4)
      end
    end
  end


  describe "dict size cap" do
    it "raises when dict exceeds MAX_DICT_SIZE" do
      oversized = RZstd::Dictionary.train(similar_samples(400), capacity: 8 * 1024)
      # Pad to exceed 64 KiB while keeping ZDICT magic
      padded = oversized + ("\x00" * (65 * 1024))
      assert_raises(NNQ::Zstd::ProtocolError) do
        NNQ::Zstd::Codec.new(level: -3, dict: padded)
      end
    end
  end


  describe "reset_for_reconnect!" do
    it "re-emits dict on next encode" do
      bytes = RZstd::Dictionary.train(similar_samples(400), capacity: 8 * 1024)
      c = NNQ::Zstd::Codec.new(level: -3, dict: bytes)
      _, dict_frame = c.encode("first payload " * 20)
      refute_nil dict_frame

      _, dict_frame2 = c.encode("second payload " * 20)
      assert_nil dict_frame2

      c.reset_for_reconnect!

      _, dict_frame3 = c.encode("third payload " * 20)
      refute_nil dict_frame3
    end


    it "does not clear recv dict" do
      bytes = RZstd::Dictionary.train(similar_samples(400), capacity: 8 * 1024)
      c = NNQ::Zstd::Codec.new(level: -3)
      assert_nil c.decode(bytes)

      c.reset_for_reconnect!

      sender = NNQ::Zstd::Codec.new(level: -3, dict: bytes)
      msg = "user_42@example.com|status=active|tier=gold|region=eu-2|extra=" + ("x" * 40)
      wire, _ = sender.encode(msg)
      assert_equal msg, c.decode(wire)
    end
  end
end
