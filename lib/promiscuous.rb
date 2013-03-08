require 'active_support/core_ext'
require 'celluloid'
require 'celluloid/io'

module Promiscuous
  def self.require_for(gem, file)
    require gem
    require file
  rescue LoadError
  end

  require 'promiscuous/autoload'
  require_for 'rails',  'promiscuous/railtie'
  require_for 'resque', 'promiscuous/resque'


  extend Promiscuous::Autoload
  autoload :Common, :Publisher, :Subscriber, :Observer, :Worker, :Ephemeral,
           :CLI, :Error, :Loader, :AMQP, :Redis, :ZK, :Config, :DSL, :Key,
           :Convenience, :Dependency, :Middleware

  extend Promiscuous::DSL

  Object.__send__(:include, Promiscuous::Convenience)

  class << self
    def configure(&block)
      Config.configure(&block)
    end

    [:debug, :info, :error, :warn, :fatal].each do |level|
      define_method(level) do |msg|
        Promiscuous::Config.logger.__send__(level, "[promiscuous] #{msg}")
      end
    end

    def connect
      AMQP.connect
      Redis.connect
    end

    def disconnect
      AMQP.disconnect
      Redis.disconnect
    end

    def healthy?
      AMQP.ensure_connected
      Redis.ensure_connected
    rescue
      false
    else
      true
    end

    def disabled
      Thread.current[:promiscuous_disabled] || $promiscuous_disabled
    end

    def disabled=(value)
      Thread.current[:promiscuous_disabled] = value
    end

    def context(*args, &block)
      Publisher::Context.open(*args, &block)
    end
  end

  at_exit { self.disconnect rescue nil }
end
