class Promiscuous::AMQP::Bunny
  def self.hijack_bunny
    return if @bunny_hijacked
    ::Bunny::Session.class_eval do
      alias_method :handle_network_failure_without_promiscuous, :handle_network_failure

      def handle_network_failure(e)
        Promiscuous.warn "[amqp] #{e}. Reconnecting..."
        Promiscuous::Config.error_notifier.try(:call, e)
        handle_network_failure_without_promiscuous(e)
      end
    end
    @bunny_hijacked = true
  end

  attr_accessor :connection, :connection_lock, :callback_mapping

  def initialize_driver
    require 'bunny'
    self.class.hijack_bunny
  end

  def initialize
    initialize_driver
    # The bunny socket doesn't like when multiple threads access to it apparently
    @connection_lock = Mutex.new
    @callback_mapping = {}
  end

  def raw_new_connection(options={})
    connection = ::Bunny.new(options[:url], :heartbeat_interval => Promiscuous::Config.heartbeat,
                                            :socket_timeout     => Promiscuous::Config.socket_timeout,
                                            :connect_timeout    => Promiscuous::Config.socket_timeout)
    connection.start
    connection
  end

  def new_connection(options={})
    connection = raw_new_connection(options)
    channel = connection.create_channel
    channel.basic_qos(options[:prefetch]) if options[:prefetch]
    channel.confirm_select(&method(:on_confirm)) if options[:confirm]

    if options[:exchanges]
      exchanges = options[:exchanges].map do |exchange_name|
        channel.exchange(exchange_name, :type => :topic, :durable => true)
      end
      [connection, channel, exchanges]
    else
      exchange = channel.exchange(options[:exchange], :type => :topic, :durable => true)
      [connection, channel, exchange]
    end
  end

  def connect
    connection_options = { :url      => Promiscuous::Config.publisher_amqp_url,
                           :exchange => Promiscuous::Config.publisher_exchange,
                           :confirm  => true }
    @connection, @channel, @exchange = new_connection(connection_options)
  end

  def disconnect
    @connection_lock.synchronize do
      return unless connected?
      @connection.stop
      @connection = @channel = nil
    end
  end

  def connected?
    !!@connection.try(:connected?)
  end

  def raw_publish(options)
    options[:exchange].publish(options[:payload], :key => options[:key], :persistent => true)
  end

  def publish(options={})
    Promiscuous.debug "[publish] #{options[:key]} -> #{options[:payload]}"
    @connection_lock.synchronize do
      tag = @channel.next_publish_seq_no if options[:on_confirm]
      raw_publish(options.merge(:exchange => @exchange))
      @callback_mapping[tag] = options[:on_confirm] if options[:on_confirm]
    end
  rescue Exception => e
    e = Promiscuous::Error::Publisher.new(e, :payload => options[:payload])
    Promiscuous.warn "[publish] #{e} #{e.backtrace.join("\n")}"
    Promiscuous::Config.error_notifier.try(:call, e)
  end

  def on_confirm(tag, multiple, nack=false)
    if multiple
      cbs = @callback_mapping.keys
              .select { |k| k <= tag }
              .map    { |k| @callback_mapping.delete(k) }
      cbs.each(&:call) unless nack
    else
      cb = @callback_mapping.delete(tag)
      cb.try(:call) unless nack
    end
  end

  module Subscriber
    def subscribe(options={}, &block)
      @lock = Mutex.new

      connection_options = { :url       => Promiscuous::Config.subscriber_amqp_url,
                             :exchanges => options[:bindings].keys,
                             :prefetch  => Promiscuous::Config.prefetch }
      @connection, @channel, exchanges = Promiscuous::AMQP.new_connection(connection_options)

      @queue = @channel.queue(Promiscuous::Config.queue_name, Promiscuous::Config.queue_options)
      exchanges.zip(options[:bindings].values).each do |exchange, bindings|
        bindings.each do |binding|
          @queue.bind(exchange, :routing_key => binding)
          Promiscuous.debug "[bind] #{exchange.name} -> #{binding} -> #{Promiscuous::Config.queue_name}"
        end
      end

      @subscription = subscribe_queue(@queue, &block)
    end

    def subscribe_queue(queue, &block)
      queue.subscribe(:ack => true) do |delivery_info, metadata, payload|
        block.call(MetaData.new(self, delivery_info), payload)
      end
    end

    class MetaData
      def initialize(subscriber, delivery_info)
        @subscriber = subscriber
        @delivery_info = delivery_info
      end

      def ack
        @subscriber.ack_message(@delivery_info.delivery_tag)
      end
    end

    def ack_message(tag)
      @lock.synchronize { @channel.ack(tag) } if @channel
    end

    def recover
      @lock.synchronize { @channel.basic_recover(true) } if @channel
    end

    def disconnect
      @lock.synchronize { @connection.stop; @channel = nil }
    end
  end
end
