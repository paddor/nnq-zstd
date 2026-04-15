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
    wire, dict_frames = c.encode("hi")
    assert_equal [], dict_frames
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
    # Incompressible random data: expect NUL preamble bailout.
    assert_equal "\x00\x00\x00\x00".b, wire.byteslice(0, 4)
    assert_equal body, c.decode(wire)
  end


  it "rejects a Zstd frame whose header omits Frame_Content_Size" do
    c = codec
    # Magic + FHD with Single_Segment=0, FCS_flag=0 → no FCS.
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
      # Feed many small similar samples until training fires.
      dict_frames = []
      similar_samples(1500).each do |s|
        _, dfs = c.encode(s)
        dict_frames.concat(dfs)
        break unless dict_frames.empty? || c.active_send_dict_id.nil?
      end
      refute_nil c.active_send_dict_id
      refute_empty dict_frames
      # The dict frame is a valid Zstd dictionary.
      assert_equal NNQ::Zstd::Codec::ZDICT_MAGIC, dict_frames.first.byteslice(0, 4)
    end


    it "auto-trained dict_id lands in USER_DICT_ID_RANGE" do
      c = codec
      similar_samples(1500).each do |s|
        c.encode(s)
        break unless c.active_send_dict_id.nil?
      end
      refute_nil c.active_send_dict_id
      assert_includes NNQ::Zstd::USER_DICT_ID_RANGE, c.active_send_dict_id
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
        # 1500 * 100 B > 100 KiB → triggers training exactly once.
        1500.times { c.encode("x" * 100) }
      ensure
        sc.alias_method(:train, :__orig_train)
        sc.remove_method(:__orig_train)
        _ = original
      end
      assert_equal 1, calls, "train should be called exactly once"
      assert_nil c.active_send_dict_id
    end
  end


  describe "multi-dict peer dispatch" do
    it "ships dicts before payloads and decodes via dict_id on the peer" do
      sender   = codec
      receiver = codec

      # Drive training on the sender.
      similar_samples(1500).each do |s|
        wire, dfs = sender.encode(s)
        dfs.each { |df| assert_nil receiver.decode(df) }
        plain_or_decoded = receiver.decode(wire)
        refute_nil plain_or_decoded
      end

      refute_nil sender.active_send_dict_id
      assert_includes receiver.recv_dict_ids, sender.active_send_dict_id

      # Now send a post-training small payload that triggers compression.
      msg = "user_4242@example.com|status=active|tier=gold|region=eu-2|extra=" + ("x" * 40)
      wire, dfs = sender.encode(msg)
      assert_empty dfs
      assert_equal NNQ::Zstd::Codec::ZSTD_MAGIC, wire.byteslice(0, 4)
      assert_equal msg, receiver.decode(wire)
    end


    it "raises on an unknown dict_id in a frame" do
      sender   = codec
      receiver = codec
      similar_samples(1500).each do |s|
        sender.encode(s)
        break unless sender.active_send_dict_id.nil?
      end
      msg = "user_42@example.com|status=active|tier=gold|region=eu-2|extra=" + ("y" * 40)
      wire, = sender.encode(msg)
      # receiver has no dicts installed yet
      assert_raises(NNQ::Zstd::ProtocolError) { receiver.decode(wire) }
    end
  end


  describe "user-supplied dicts" do
    def trained_dict_bytes
      RZstd::Dictionary.train(similar_samples(400), capacity: 8 * 1024)
    end


    it "ships supplied dicts and skips training" do
      bytes = trained_dict_bytes
      c = NNQ::Zstd::Codec.new(level: -3, dicts: [bytes])
      refute_nil c.active_send_dict_id
      body = "user_42@example.com|status=active|tier=gold|region=eu-2"
      wire, dfs = c.encode(body)
      assert_equal 1, dfs.size
      assert_equal NNQ::Zstd::Codec::ZDICT_MAGIC, dfs.first.byteslice(0, 4)

      receiver = NNQ::Zstd::Codec.new(level: -3)
      assert_nil receiver.decode(dfs.first)
      assert_equal body, receiver.decode(wire)
    end


    it "refuses a non-ZDICT-format dict" do
      assert_raises(NNQ::Zstd::ProtocolError) do
        NNQ::Zstd::Codec.new(level: -3, dicts: ["just some raw bytes that are long enough" * 4])
      end
    end
  end


  describe "caps" do
    def tiny_dict(id)
      # Minimal ZDICT-format header: magic + dict_id + 4 bytes padding.
      # zstd accepts these as "short" dicts for our ship/count test — but
      # building a real trainable dict per id is overkill. Instead,
      # produce a proper trained dict and patch its id.
      bytes = RZstd::Dictionary.train(
        300.times.map { |i| "user_#{i}|key=#{i}|val=#{i * 7}" },
        capacity: 2 * 1024,
      )
      out = bytes.dup.b
      out[4, 4] = [id].pack("V")
      out
    end


    it "raises when the 33rd send-side dict is installed" do
      c = codec
      32.times { |i| c.send(:install_send_dict, tiny_dict(40_000 + i)) }
      assert_raises(NNQ::Zstd::ProtocolError) do
        c.send(:install_send_dict, tiny_dict(99_999))
      end
    end
  end


  describe "requeue_all_dicts_for_shipping!" do
    it "re-emits every known dict on the next encode" do
      bytes = RZstd::Dictionary.train(similar_samples(400), capacity: 8 * 1024)
      c = NNQ::Zstd::Codec.new(level: -3, dicts: [bytes])
      _, dfs = c.encode("first payload " * 20)
      assert_equal 1, dfs.size

      _, dfs2 = c.encode("second payload " * 20)
      assert_empty dfs2

      c.requeue_all_dicts_for_shipping!
      _, dfs3 = c.encode("third payload " * 20)
      assert_equal 1, dfs3.size
    end
  end
end
