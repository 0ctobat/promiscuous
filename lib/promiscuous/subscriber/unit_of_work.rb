class Promiscuous::Subscriber::UnitOfWork
  attr_accessor :message
  delegate :dependencies, :to => :message

  def initialize(message)
    self.message = message
  end

  def app
    message.parsed_payload['app']
  end

  def operations
    message.parsed_payload['operations'].
      each_with_index.
      map { |op, i| Promiscuous::Subscriber::Operation.new(op.merge('dependency' => message.dependencies[i])) }
  end

  def self.process(*args)
    raise "Same thread is processing a message?" if self.current

    begin
      self.current = new(*args)
      self.current.process_message
    ensure
      self.current = nil
    end
  end

  def self.current
    Thread.current[:promiscuous_message_processor]
  end

  def self.current=(value)
    Thread.current[:promiscuous_message_processor] = value
  end

  def process_message
    begin
      on_message
    rescue Exception => e
      @fail_count ||= 0;  @fail_count += 1

      if @fail_count <= Promiscuous::Config.max_retries
        Promiscuous.warn("[receive] #{e.message} #{@fail_count.ordinalize} retry: #{@message}")
        sleep @fail_count ** 2
        process_message
      else
        raise e
      end
    end
  end

  LOCK_OPTIONS = { :timeout => 1.5.minute, # after 1.5 minute, we give up
                   :sleep   => 0.1,        # polling every 100ms.
                   :expire  => 1.minute }  # after one minute, we are considered dead

  def with_instance_locked_for(operation, &block)
    return yield unless operation.dependency

    lock_options = LOCK_OPTIONS.merge(:node => operation.dependency.redis_node)
    mutex = Promiscuous::Redis::Mutex.new(operation.dependency.key(:sub).to_s, lock_options)

    unless mutex.lock
      raise Promiscuous::Error::LockUnavailable.new(mutex.key)
    end

    begin
      yield
    ensure
      unless mutex.unlock
        # TODO Be safe in case we have a duplicate message and lost the lock on it
        raise "The subscriber lost the lock during its operation. It means that someone else\n"+
          "received a duplicate message, and we got screwed.\n"
      end
    end
  end

  # XXX Used for hooking into e.g. by promiscuous-newrelic
  def execute_operation(operation)
    with_instance_locked_for(operation) do
      operation.execute
    end
  end

  def on_message
    # XXX This needs to be done for each operation
    with_transaction do
      self.operations.each { |op| execute_operation(op) if op.model }
    end
    message.ack
  end

  private

  def with_transaction(&block)
    if defined?(ActiveRecord::Base)
      ActiveRecord::Base.transaction { yield }
    else
      yield
    end
  end
end
