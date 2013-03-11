class Promiscuous::Subscriber::Worker::Message
  attr_accessor :metadata, :payload, :parsed_payload

  def initialize(metadata, payload)
    self.metadata = metadata
    self.payload = payload
  end

  def parsed_payload
    @parsed_payload ||= JSON.parse(payload)
  end

  def endpoint
    parsed_payload['__amqp__']
  end

  def timestamp
    parsed_payload['timestamp'].to_i
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

    @dependencies[:link] = Promiscuous::Dependency.parse(@dependencies[:link]) if @dependencies[:link]
    @dependencies[:read].map!  { |dep| Promiscuous::Dependency.parse(dep) }
    @dependencies[:write].map! { |dep| Promiscuous::Dependency.parse(dep) }
    @dependencies
  end

  def happens_before_dependencies
    # TODO remove code -- r ^ w = 0 ?
    return @happens_before_dependencies if @happens_before_dependencies

    read_increments = {}
    dependencies[:read].each do |dep|
      key = dep.key(:sub).to_s
      read_increments[key] ||= 0
      read_increments[key] += 1
    end

    deps = []
    deps << dependencies[:link] if dependencies[:link]
    deps += dependencies[:read]
    deps += dependencies[:write].map do |dep|
      dep.dup.tap { |d| d.version -= 1 + read_increments[d.key(:sub).to_s].to_i }
    end

    # We return the most difficult condition to satisfy first
    @happens_before_dependencies = deps.uniq.reverse
  end

  def has_dependencies?
    return false if Promiscuous::Config.bareback
    dependencies[:read].present? || dependencies[:write].present?
  end

  def to_s
    "#{endpoint} -> #{happens_before_dependencies.join(', ')}"
  end

  def ack
    time = Time.now
    Celluloid::Actor[:pump].async.notify_processed_message(self, time)
    Celluloid::Actor[:stats].async.notify_processed_message(self, time)
  rescue Exception
    # We don't care if we fail, the message will be redelivered at some point
    #STDERR.puts "Some exception happened, but it's okay: #{e}\n#{e.backtrace.join("\n")}"
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
    unit_of_work(endpoint) do
      payload = Promiscuous::Subscriber::Payload.new(parsed_payload, self)
      Promiscuous::Subscriber::Operation.new(payload).commit
    end
    ack
  rescue Exception => orig_e
    e = Promiscuous::Error::Subscriber.new(orig_e, :payload => payload)

    if orig_e.is_a?(Promiscuous::Error::AlreadyProcessed)
      ack
      Promiscuous.info "[receive] #{e}"
    else
      Promiscuous.warn "[receive] #{e} #{e.backtrace.join("\n")}"
    end

    Promiscuous::Config.error_notifier.try(:call, e)
  end
end
