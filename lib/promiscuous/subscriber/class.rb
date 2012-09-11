module Promiscuous::Subscriber::Class
  extend ActiveSupport::Concern
  include Promiscuous::Common::ClassHelpers

  def instance
    @instance ||= fetch
  end

  included { use_option :class, :as => :klass }

  module ClassMethods
    def klass
      if super
        "::#{super}".constantize
      elsif name
        guess_class_name('Subscribers').constantize
      end
    end
  end
end
