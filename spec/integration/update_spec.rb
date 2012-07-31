require 'spec_helper'
require 'replicable/subscriber/worker'

describe Replicable do
  before do
    define_constant(:publisher_model) do
      include Mongoid::Document
      include Replicable::Publisher

      field :field_1
      field :field_2
      field :field_3

      replicate :app_name => 'crowdtap'
    end

    define_constant(:subscriber_model) do
      include Mongoid::Document
      include Replicable::Subscriber

      field :field_1
      field :field_2
      field :field_3

      replicate :from => 'crowdtap',
                :class_name => 'publisher_model',
                :fields => [:field_1, :field_2, :field_3]
    end
  end

  before do
    Replicable::AMQP.configure(:backend => :rubyamqp, :app => 'sniper',
                               :queue_options => {:auto_delete => true})
    Replicable::Subscriber::Worker.run
  end

  context 'when replicating the update of a model' do
    let!(:instance) { PublisherModel.create }

    it 'updates the model' do
      instance.update_attributes(:field_1 => 'updated')
      eventually { SubscriberModel.find(instance.id).field_1.should == 'updated' }
    end
  end

  after do
    Replicable::AMQP.close
    Replicable::Subscriber.subscriptions.clear
  end
end
