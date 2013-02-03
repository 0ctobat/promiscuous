class Promiscuous::Subscriber::Worker::MessageSynchronizer
  include Celluloid::IO

  attr_accessor :worker, :redis

  def initialize(worker)
    self.worker = worker
  end

  def start
    connect
    main_loop!
  end

  def stop
    terminate
  end

  def finalize
    disconnect
  end

  def connect
    @subscriptions = {}
    self.redis = Promiscuous::Redis.new_celluloid_connection
  end

  def rescue_connection
    disconnect
    e = Promiscuous::Error::Connection.new(:service => :redis)

    Promiscuous.warn "[redis] #{e}. Reconnecting..."
    Promiscuous::Config.error_notifier.try(:call, e)

    worker.pump.stop
    reconnect_later
  end

  def disconnect
    self.redis.client.connection.disconnect if self.redis
  rescue
  ensure
    self.redis = nil
  end

  def reconnect
    @reconnect_timer = nil
    self.connect
    main_loop!
  rescue
    reconnect_later
  else
    Promiscuous.warn "[redis] Reconnected"
    worker.pump.start
  end

  def reconnect_later
    @reconnect_timer = after(2.seconds) { reconnect } unless @reconnect_timer
  end

  def main_loop
    redis_client = self.redis.client
    loop do
      reply = redis_client.read
      raise reply if reply.is_a?(Redis::CommandError)
      type, subscription, arg = reply

      case type
      when 'subscribe'
        find_subscription(subscription).finalize_subscription
      when 'unsubscribe'
      when 'message'
        find_subscription(subscription).maybe_perform_callbacks(arg)
      end
    end
  rescue EOFError
    # Unwanted disconnection
    rescue_connection
  rescue IOError => e
    unless redis_client == self.redis.client
      # We were told to disconnect
    else
      raise e
    end
  rescue Celluloid::Task::TerminatedError
  rescue Exception => e
    Promiscuous.warn "[redis] #{e} #{e.backtrace.join("\n")}"

    Promiscuous::Worker.stop
    Promiscuous::Config.error_notifier.try(:call, e)
  end

  # process_when_ready() is called by the AMQP pump. This is what happens:
  # 1. First, we subscribe to redis and wait for the confirmation.
  # 2. Then we check if the version in redis is old enough to process the message.
  #    If not we bail out and rely on the subscription to kick the processing.
  # Because we subscribed in advanced, we will not miss the notification, but
  # extra care needs to be taken to avoid processing the message twice (see
  # perform()).
  def process_when_ready(msg)
    # Dropped messages will be redelivered as we reconnect
    # when calling worker.pump.start
    return unless self.redis

    return worker.runners.process!(msg) unless msg.has_version?

    on_version Promiscuous::Redis.sub_key('global'), msg.version[:global] do
      worker.runners.process!(msg)
    end
  end

  def on_version(key, version, &callback)
    return unless @subscriptions
    cb = Subscription::Callback.new(version, callback)
    get_subscription(key).subscribe.add_callback(version, cb)
    cb.maybe_perform(Promiscuous::Redis.get(key))
  end

  def find_subscription(key)
    raise "Fatal error (redis sub)" unless @subscriptions[key]
    @subscriptions[key]
  end

  def get_subscription(key)
    @subscriptions[key] ||= Subscription.new(self, key)
  end

  class Subscription
    attr_accessor :parent, :key

    def initialize(parent, key)
      self.parent = parent
      self.key = key

      @subscription_requested = false
      @subscribed_to_redis = false
      @callbacks = {}
    end

    def subscribe
      request_subscription

      loop do
        break if @subscribed_to_redis
        parent.wait :subscription
      end
      self
    end

    def request_subscription
      return if @subscription_requested
      parent.redis.client.process([[:subscribe, key]])
      @subscription_requested = true
    end

    def finalize_subscription
      @subscribed_to_redis = true
      parent.signal :subscription
    end

    def destroy
      # TODO parent.redis_client_call(:unsubscribe, key)
    end

    def add_callback(version, callback)
      callback.subscription = self
      @callbacks[callback.token] = callback
    end

    def remove_callback(token)
      !!@callbacks.delete(token)
      # TODO unsubscribe after a while?
    end

    def maybe_perform_callbacks(current_version)
      @callbacks.values.each do |cb|
        cb.maybe_perform(current_version)
      end
    end

    class Callback
      # Tokens are only used so that the callback can find and remove itself
      # in the callback list.
      @next_token = 0
      def self.get_next_token
        @next_token += 1
      end

      attr_accessor :subscription, :version, :callback, :token

      def initialize(version, callback)
        self.version = version
        self.callback = callback
        @token = self.class.get_next_token
      end

      def can_perform?(current_version)
        current_version.to_i + 1 >= self.version
      end

      def perform
        # removing the callback can happen only once, ensuring that the
        # callback is called at most once.
        callback.call if subscription.remove_callback(@token)
      end

      def maybe_perform(current_version)
        perform if can_perform?(current_version)
      end
    end
  end
end
