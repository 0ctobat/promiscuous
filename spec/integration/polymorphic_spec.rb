require 'spec_helper'
require 'integration/models'
require 'replicable/worker'

describe Replicable do
  before { use_real_amqp }

  before do
    define_constant(:publisher, Replicable::Publisher) do
      publish :to => 'crowdtap/publisher_model',
              :model => PublisherModel,
              :attributes => [:field_1, :field_2, :field_3, :child_field_1?]
    end

    define_constant(:subscriber, Replicable::Subscriber) do
      subscribe :from => 'crowdtap/publisher_model',
                :models => {'PublisherModel'      => SubscriberModel,
                            'PublisherModelChild' => SubscriberModelChild },
                :attributes => [:field_1, :field_2, :field_3, :child_field_1?]
    end
  end

  before { Replicable::Worker.run }

  context 'when creating' do
    it 'replicates the parent' do
      pub = PublisherModel.create(:field_1 => '1', :field_2 => '2', :field_3 => '3')

      eventually do
        sub = SubscriberModel.find(pub.id)
        sub.id.should == pub.id
        sub.field_1.should == pub.field_1
        sub.field_2.should == pub.field_2
        sub.field_3.should == pub.field_3
      end
    end

    it 'replicates the child' do
      pub = PublisherModelChild.create(:field_1 => '1', :field_2 => '2', :field_3 => '3',
                                       :child_field_1 => 'child_1')

      eventually do
        sub = SubscriberModelChild.find(pub.id)
        sub.id.should == pub.id
        sub.field_1.should == pub.field_1
        sub.field_2.should == pub.field_2
        sub.field_3.should == pub.field_3
        sub.child_field_1.should == pub.child_field_1
      end
    end
  end

  context 'when updating' do
    it 'replicates the parent' do
      pub = PublisherModel.create(:field_1 => '1', :field_2 => '2', :field_3 => '3')
      pub.update_attributes(:field_1 => '1_updated', :field_2 => '2_updated')

      eventually do
        sub = SubscriberModel.find(pub.id)
        sub.id.should == pub.id
        sub.field_1.should == pub.field_1
        sub.field_2.should == pub.field_2
        sub.field_3.should == pub.field_3
      end
    end

    it 'replicates the child' do
      pub = PublisherModelChild.create(:field_1 => '1', :field_2 => '2', :field_3 => '3',
                                       :child_field_1 => 'child_1')
      pub.update_attributes(:field_1 => '1_updated', :field_2 => '2_updated',
                            :child_field_1 => 'child_1_updated')

      eventually do
        sub = SubscriberModelChild.find(pub.id)
        sub.id.should == pub.id
        sub.field_1.should == pub.field_1
        sub.field_2.should == pub.field_2
        sub.field_3.should == pub.field_3
        sub.child_field_1.should == pub.child_field_1
      end
    end
  end

  context 'when destroying' do
    it 'replicates the parent' do
      pub = PublisherModel.create(:field_1 => '1', :field_2 => '2', :field_3 => '3')

      eventually { SubscriberModel.count.should == 1 }
      pub.destroy
      eventually { SubscriberModel.count.should == 0 }
    end

    it 'replicates the child' do
      pub = PublisherModelChild.create(:field_1 => '1', :field_2 => '2', :field_3 => '3',
                                       :child_field_1 => 'child_1')

      eventually { SubscriberModelChild.count.should == 1 }
      pub.destroy
      eventually { SubscriberModelChild.count.should == 0 }
    end
  end

  after do
    Replicable::AMQP.close
    Replicable::Subscriber.subscriptions.clear
  end
end
