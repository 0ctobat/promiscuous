module Replicable::Subscriber::Mongoid::Embedded
  extend ActiveSupport::Concern

  def fetch
    old_value.nil? ? klass.new.tap {|m| m.id = id} : old_value
  end

  def old_value
    options[:old_value]
  end

  module ClassMethods
    def subscribe(options)
      super
      use_payload_attribute :id
    end
  end
end
