module Promiscuous::AMQP::RubyAMQP
  mattr_accessor :channel

  def self.connect
    require 'amqp'

    amqp_options = if Promiscuous::Config.amqp_url
      url = URI.parse(Promiscuous::Config.amqp_url)
      raise "Please use amqp://user:password@host:port/vhost" if url.scheme != 'amqp'

      {
        :host      => url.host,
        :port      => url.port,
        :scheme    => url.scheme,
        :user      => url.user,
        :pass      => url.password,
        :vhost     => url.path.empty? ? "/" : url.path,
        :heartbeat => Promiscuous::Config.heartbeat
      }
    end

    connection = ::AMQP.connect(amqp_options)
    self.channel = ::AMQP::Channel.new(connection, :auto_recovery => true, :prefetch => 1000)

    connection.on_tcp_connection_loss do |conn|
      unless conn.reconnecting?
        e = Promiscuous::AMQP.lost_connection_exception
        Promiscuous.warn "[amqp] #{e}. Reconnecting..."
        Promiscuous::Config.error_notifier.try(:call, e)

        worker = Promiscuous::Worker.workers.first
        worker.message_synchronizer.disconnect if worker

        conn.periodically_reconnect(2.seconds)
      end
    end

    connection.on_recovery do |conn|
      Promiscuous.warn "[amqp] Reconnected"

      worker = Promiscuous::Worker.workers.first
      worker.message_synchronizer.reconnect if worker
    end

    connection.on_error do |conn, conn_close|
      # No need to handle CONNECTION_FORCED since on_tcp_connection_loss takes
      # care of it.
      Promiscuous.warn "[amqp] #{conn_close.reply_text}"
    end
  end

  def self.disconnect
    if self.channel && self.channel.connection.connected?
      self.channel.connection.close
      self.channel.close
    end
    self.channel = nil
  end

  # Always disconnect when shutting down to avoid reconnection
  EM.add_shutdown_hook { Promiscuous::AMQP::RubyAMQP.disconnect }

  def self.connected?
    !!self.channel.try(:connection).try(:connected?)
  end

  def self.open_queue(options={}, &block)
    queue_name = options[:queue_name]
    bindings   = options[:bindings]

    queue = self.channel.queue(queue_name, Promiscuous::Config.queue_options)
    bindings.each do |binding|
      queue.bind(exchange(options[:exchange_name]), :routing_key => binding)
      Promiscuous.debug "[bind] #{queue_name} -> #{binding}"
    end
    block.call(queue) if block
  end

  def self.publish(options={})
    info_msg = "(#{options[:exchange_name]}) #{options[:key]} -> #{options[:payload]}"
    Promiscuous.debug "[publish] #{info_msg}"

    EM.next_tick do
      exchange(options[:exchange_name]).
        publish(options[:payload], :routing_key => options[:key], :persistent => true)
    end
  end

  def self.exchange(name)
    channel.topic(name, :durable => true)
  end
end
