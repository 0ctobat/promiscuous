require 'replicable/publisher/envelope'

module Replicable::Publisher::AMQP
  extend ActiveSupport::Concern
  include Replicable::Publisher::Envelope

  def amqp_publish
    Replicable::AMQP.publish(:key => to, :payload => payload.to_json)
  end

  def payload
    super.merge(:__amqp__ => to)
  end

  included { use_option :to }
end
