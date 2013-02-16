module Promiscuous::Config
  mattr_accessor :app, :logger, :error_notifier, :backend, :amqp_url,
                 :redis_url, :queue_options, :heartbeat, :bareback,
                 :recovery, :prefetch

  def self.backend=(value)
    @@backend = value
    Promiscuous::AMQP.backend = value
  end

  def self.reset
    Promiscuous::AMQP.backend = nil
    class_variables.each { |var| class_variable_set(var, nil) }
  end

  def self.configure(&block)
    block.call(self)

    self.app           ||= Rails.application.class.parent_name.underscore rescue nil if defined?(Rails)
    self.amqp_url      ||= 'amqp://guest:guest@localhost:5672'
    self.redis_url     ||= 'redis://localhost/'
    self.backend       ||= RUBY_PLATFORM == 'java' ? :hot_bunny : :rubyamqp
    self.queue_options ||= {:durable => true, :arguments => {'x-ha-policy' => 'all'}}
    self.heartbeat     ||= 60
    self.prefetch      ||= 1000
    self.logger        ||= defined?(Rails) ? Rails.logger : Logger.new(STDERR).tap { |l| l.level = Logger::WARN }

    unless self.app
      raise "Promiscuous.configure: please give a name to your app with \"config.app = 'your_app_name'\""
    end

    # amqp connection is done in when setting the backend
    Promiscuous::Redis.connect
  end

  def self.configured?
    self.app != nil
  end
end
