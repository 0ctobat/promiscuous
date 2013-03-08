require 'redis'

module Promiscuous::Redis
  mattr_accessor :master

  def self.connect
    disconnect
    self.master = new_connection
  end

  def self.disconnect
    self.master.client.disconnect if self.master
    self.master = nil
  end

  def self.new_connection(url=nil)
    return Null.new if Promiscuous::Config.backend == :null

    url ||= Promiscuous::Config.redis_url
    redis = ::Redis.new(:url => url, :tcp_keepalive => 60)
    redis.client.connect
    redis
  end

  def self.new_celluloid_connection
    return Null.new if Promiscuous::Config.backend == :null

    new_connection.tap do |redis|
      redis.client.connection.instance_eval do
        @sock = Celluloid::IO::TCPSocket.from_ruby_socket(@sock)
        @sock.instance_eval do
          extend ::Redis::Connection::SocketMixin
          @timeout = nil
          @buffer = ""

          def _read_from_socket(nbytes)
            readpartial(nbytes)
          end
        end
      end
    end
  end

  def self.lost_connection_exception
    Promiscuous::Error::Connection.new(:service => :redis)
  end

  def self.ensure_connected
    Promiscuous::Redis.master.ping
  rescue
    raise lost_connection_exception
  end

  def self.method_missing(name, *args, &block)
    self.master.__send__(name, *args, &block)
  end

  def self.pub_key(str)
    "publishers:#{Promiscuous::Config.app}:#{str}"
  end

  def self.sub_key(str)
    "subscribers:#{Promiscuous::Config.app}:#{str}"
  end

  class Null
    def pipelined(&block)
      @pipelined = true
      res = block.call if block
      @pipelined = false
      res
    end

    def client
      return self.class.new
    end

    def method_missing(name, *args, &block)
      @pipelined ? Future.new : 0
    end

    class Future
      def value; 0; end
    end
  end

  class Mutex
    def initialize(key, options={})
      @orig_key = key.to_s
      @key = "locks:#{key}"
      @block = options[:block]
      @sleep = options[:sleep]
      @expire = options[:expire]
      @token = Random.rand(1000000000)
    end

    def key
      @orig_key
    end

    def lock
      if @block > 0
        # Blocking mode
        result = false
        start_at = Time.now
        while Time.now - start_at < @block
          break if result = try_lock
          sleep @sleep
        end
        result
      else
        # Non-blocking mode
        try_lock
      end
    end

    def try_lock
      now = Time.now.to_i
      @expires_at = now + @expire

      # This script loading is not thread safe (touching a class variable), but
      # that's okay, because the race is harmless.
      @@lock_script_sha ||= Promiscuous::Redis.script(:load, <<-SCRIPT)
        local key = KEYS[1]
        local now = tonumber(ARGV[1])
        local expires_at = tonumber(ARGV[2])
        local token = ARGV[3]
        local old_value = redis.call('get', key)

        if old_value and tonumber(old_value:match("([^:]*):"):rep(1)) > now then return false end
        redis.call('set', key, expires_at .. ':' .. token)
        if old_value then return 'recovered' else return true end
      SCRIPT
      result = Promiscuous::Redis.evalsha(@@lock_script_sha, :keys => [@key], :argv => [now, @expires_at, @token])
      return :recovered if result == 'recovered'
      !!result
    end

    def unlock
      # Since it's possible that the operations in the critical section took a long time,
      # we can't just simply release the lock. The unlock method checks if @expires_at
      # remains the same, and do not release when the lock timestamp was overwritten.

      @@unlock_script_sha ||= Promiscuous::Redis.script(:load, <<-SCRIPT)
        local key = KEYS[1]
        local old_value = ARGV[1]

        if redis.call('get', key) == old_value then
          redis.call('del', key)
          return true
        else
          return false
        end
      SCRIPT
      Promiscuous::Redis.evalsha(@@unlock_script_sha, :keys => [@key], :argv => ["#{@expires_at}:#{@token}"])
    end
  end
end
