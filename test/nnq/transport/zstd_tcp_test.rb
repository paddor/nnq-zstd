# frozen_string_literal: true

require "test_helper"

describe "zstd+tcp:// transport" do
  it "round-trips a large payload" do
    Sync do
      pull = NNQ::PULL.bind("zstd+tcp://127.0.0.1:0")
      push = NNQ::PUSH.connect(pull.last_endpoint)

      payload = "a" * 4096
      push.send(payload)

      assert_equal payload, pull.receive
    ensure
      push&.close
      pull&.close
    end
  end


  it "round-trips a small payload" do
    Sync do
      pull = NNQ::PULL.bind("zstd+tcp://127.0.0.1:0")
      push = NNQ::PUSH.connect(pull.last_endpoint)

      push.send("hi")
      assert_equal "hi", pull.receive
    ensure
      push&.close
      pull&.close
    end
  end


  it "auto-trains and ships dict to receiver" do
    Sync do
      pull = NNQ::PULL.bind("zstd+tcp://127.0.0.1:0")
      push = NNQ::PUSH.connect(pull.last_endpoint)

      template = "user=%s|status=active|tier=gold|region=eu-west-%d|payload=" + ("x" * 600)
      sent = 200.times.map { |i| format(template, "user_#{i}@example.com", i % 4) }

      sender = Async::Task.current.async do
        sent.each { |m| push.send(m) }
      end

      received = sent.size.times.map { pull.receive }
      sender.wait

      assert_equal sent, received
    ensure
      push&.close
      pull&.close
    end
  end


  it "supports REQ/REP over zstd+tcp" do
    Sync do
      rep = NNQ::REP0.bind("zstd+tcp://127.0.0.1:0")
      req = NNQ::REQ0.connect(rep.last_endpoint)

      server = Async::Task.current.async do
        body = rep.receive
        rep.send_reply(body.upcase)
      end

      reply = req.send_request("hello")
      server.wait

      assert_equal "HELLO", reply
    ensure
      req&.close
      rep&.close
    end
  end
end
