module Promiscuous::Subscriber::Model::Observer
  extend ActiveSupport::Concern
  include Promiscuous::Subscriber::Model

  included do
    extend ActiveModel::Callbacks
    attr_accessor :id
    define_model_callbacks :create, :update, :destroy, :only => :after
  end

  def __promiscuous_update(payload, options={})
    super
    run_callbacks payload.operation
  end

  def destroy
    run_callbacks :destroy
  end

  def save!
  end

  module ClassMethods
    def __promiscuous_fetch_new(id)
      new.tap { |o| o.id = id }
    end
    alias __promiscuous_fetch_existing __promiscuous_fetch_new
  end
end
