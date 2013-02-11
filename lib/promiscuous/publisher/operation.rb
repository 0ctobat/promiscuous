require 'crowdtap_redis_lock'

class Promiscuous::Publisher::Operation
  class TryAgain < RuntimeError; end

  attr_accessor :operation, :instance

  def initialize(options={})
    self.operation = options[:operation]
    self.instance  = options[:instance]
  end

  def klass
    self.instance.try(:class)
  end

  def instance_key
    "#{self.klass.name.underscore}:#{self.instance.id}"
  end

  def with_instance_lock(&block)
    return yield if Promiscuous::Config.backend == :null

    # create operations don't need locking as the race with concurrent updates
    # cannot happen.
    return yield if operation == :create

    key = Promiscuous::Redis.pub_key(instance_key)
    # We'll block for 60 seconds before raising an exception
    ::RedisLock.new(Promiscuous::Redis, key).retry(300).every(0.2).lock_for_update(&block)
  end

  def version
    {:global => @global_version}
  end

  def update_dependencies
    @global_version = Promiscuous::Redis.incr(Promiscuous::Redis.pub_key('global'))
  end

  # Overriden when using custom selectors
  def fetch_instance(id=nil)
    id ? self.klass.find(id) : self.instance
  end

  def commit(&db_operation)
    ret = exception = nil

    self.instance ||= fetch_instance()
    begin
      # We bypass the operation if instance == nil, as the operation would have had no effect
      return if self.instance.nil?

      Promiscuous::AMQP.ensure_connected

      with_instance_lock do
        old_instance, self.instance = self.instance, fetch_instance()
        raise TryAgain if old_instance.id != self.instance.id

        update_dependencies
        begin
          ret = db_operation.call(self.instance.id) if db_operation
        rescue Exception => exception
          # we must publish something so the subscriber can sync
          # with the updated dependencies
          self.operation = :dummy
        end

        begin
          self.instance = fetch_instance(self.instance.id) if operation == :update
        rescue Exception => e
          raise Promiscuous::Error::Publisher.new(e, :instance => instance, :out_of_sync => true)
        end
      end
    rescue TryAgain
      retry
    end

    self.instance.__promiscuous_publish(:operation => operation, :version => version)

    raise exception if exception
    ret
  end
end
