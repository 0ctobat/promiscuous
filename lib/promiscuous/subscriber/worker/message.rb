class Promiscuous::Subscriber::Worker::Message
  attr_accessor :metadata, :payload, :parsed_payload

  def initialize(metadata, payload)
    self.metadata = metadata
    self.payload = payload
  end

  def parsed_payload
    @parsed_payload ||= JSON.parse(payload)
  end

  def queue_name
    parsed_payload['__amqp__']
  end

  def dependencies
    return @dependencies if @dependencies
    @dependencies = parsed_payload['dependencies'].try(:symbolize_keys) || {}
    @dependencies[:read]  ||= []
    @dependencies[:write] ||= []

    # --- backward compatiblity code ---
    # TODO remove code
    if global = (parsed_payload['version'] || {})['global']
      @dependencies[:write] << "global:#{global}"
    end
    # --- backward compatiblity code ---

    @dependencies[:link] = Promiscuous::Dependency.from_json(@dependencies[:link]) if @dependencies[:link]
    @dependencies[:read].map!  { |dep| Promiscuous::Dependency.from_json(dep) }
    @dependencies[:write].map! { |dep| Promiscuous::Dependency.from_json(dep) }
    @dependencies
  end

  def has_dependencies?
    return false if Promiscuous::Config.bareback
    dependencies[:read].present? || dependencies[:write].present?
  end

  def ack
    metadata.ack
  rescue
    # We don't care if we fail, the message will be redelivered at some point
  end

  def unit_of_work(type, &block)
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

  def process
    Promiscuous.debug "[receive] #{payload}"
    unit_of_work(queue_name) do
      payload = Promiscuous::Subscriber::Payload.new(parsed_payload, self)
      Promiscuous::Subscriber::Operation.new(payload).commit
    end

    ack if metadata
  rescue Exception => e
    e = Promiscuous::Error::Subscriber.new(e, :payload => payload)
    Promiscuous.warn "[receive] #{e} #{e.backtrace.join("\n")}"
    Promiscuous::Config.error_notifier.try(:call, e)
  end
end
