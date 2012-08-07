require 'replicable/publisher/descriptor'

module Replicable::Publisher::AMQP
  extend ActiveSupport::Concern
  include Replicable::Publisher::Descriptor

  def amqp_publish
    Replicable::AMQP.publish(:key => to,
                             :payload => payload.to_json)
  end

  def payload
    super.merge(:__amqp__ => to)
  end

  module ClassMethods
    def publish(options)
      super
      use_option :to
    end
  end
end
