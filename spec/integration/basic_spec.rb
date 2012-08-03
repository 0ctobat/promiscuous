require 'spec_helper'
require 'support/models'
require 'replicable/worker'

describe Replicable do
  before { use_real_amqp }

  before do
    define_constant(:publisher, Replicable::Publisher) do
      publish :publisher_model, :app_name => 'crowdtap'

      def payload
        {
          :field_1 => instance.field_1,
          :field_2 => instance.field_2,
          :field_3 => instance.field_3
        }
      end
    end

    define_constant(:subscriber, Replicable::Subscriber) do
      subscribe :subscriber_model, :from => 'crowdtap/publisher_model'

      def replicate(payload)
        instance.field_1 = payload[:field_1]
        instance.field_2 = payload[:field_2]
        instance.field_3 = payload[:field_3]
      end
    end
  end

  before { Replicable::Worker.run }

  context 'when creating' do
    it 'replicates' do
      pub = PublisherModel.create(:field_1 => '1', :field_2 => '2', :field_3 => '3')

      eventually do
        sub = SubscriberModel.first
        sub.id.should == pub.id
        sub.field_1.should == pub.field_1
        sub.field_2.should == pub.field_2
        sub.field_3.should == pub.field_3
      end
    end
  end

  context 'when updating' do
    it 'replicates' do
      pub = PublisherModel.create(:field_1 => '1', :field_2 => '2', :field_3 => '3')
      pub.update_attributes(:field_1 => '1_updated', :field_2 => '2_updated')

      eventually do
        sub = SubscriberModel.first
        sub.id.should == pub.id
        sub.field_1.should == pub.field_1
        sub.field_2.should == pub.field_2
        sub.field_3.should == pub.field_3
      end
    end

    it 'upserts if the instance does not exist'
  end

  context 'when destroying' do
    it 'replicates' do
      pub = PublisherModel.create(:field_1 => '1', :field_2 => '2', :field_3 => '3')

      eventually { SubscriberModel.count.should == 1 }
      pub.destroy
      eventually { SubscriberModel.count.should == 0 }
    end
  end

  after do
    Replicable::AMQP.close
    Replicable::Subscriber.subscriptions.clear
  end
end
