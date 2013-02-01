class Promiscuous::Subscriber::Worker
  extend Promiscuous::Autoload
  autoload :Message, :Pump, :MessageSynchronizer

  attr_accessor :options, :stopped, :pump, :message_synchronizer
  alias_method :stopped?, :stopped

  def initialize(options={})
    self.options = options
    self.stopped = true

    self.pump = Pump.new(self)
  end

  def resume
    return unless self.stopped
    self.stopped = false
    self.message_synchronizer = MessageSynchronizer.new(self)
    self.message_synchronizer.resume
    self.pump.resume
  end

  def stop
    return if self.stopped
    self.pump.stop
    self.message_synchronizer.stop rescue Celluloid::Task::TerminatedError
    self.message_synchronizer = nil
    self.stopped = true
  end

  def unit_of_work(type)
    # type is used by the new relic agent, by monkey patching.
    # middleware?
    if defined?(Mongoid)
      Mongoid.unit_of_work { yield }
    else
      yield
    end
  ensure
    if defined?(ActiveRecord)
      ActiveRecord::Base.clear_active_connections!
    end
  end
end
