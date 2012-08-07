require 'replicable/publisher/generic'

class Replicable::Publisher::MongoidEmbedded < Replicable::Publisher::Generic
  def payload
    super.merge(:id => instance.id)
  end

  def self.publish(options)
    super

    options[:class].class_eval do
      callback = proc do
        if _parent.respond_to?(:replicable_publish_update)
          _parent.save
          _parent.reload # mongoid is not that smart, so we need to reload here.
          _parent.replicable_publish_update
        end
      end

      after_create callback
      after_update callback
      after_destroy callback
    end
  end
end
