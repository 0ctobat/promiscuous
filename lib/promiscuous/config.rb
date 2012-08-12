module Promiscuous
  module Config
    mattr_accessor :app, :logger, :error_handler, :backend, :server_uri, :queue_options

    def self.backend=(value)
      @@backend = "Promiscuous::AMQP::#{value.to_s.camelize.gsub(/amqp/, 'AMQP')}".constantize
    end

    def self.configure(&block)
      class_variables.each { |var| class_variable_set(var, nil) }

      block.call(self)
      self.backend ||= defined?(EM) ? :rubyamqp : :bunny
      self.queue_options ||= {:durable => true, :arguments => {'x-ha-policy' => 'all'}}
      self.logger ||= Logger.new(STDOUT).tap { |l| l.level = Logger::WARN }

      Promiscuous::AMQP.connect
    end
  end
end
