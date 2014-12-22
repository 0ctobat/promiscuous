require 'spec_helper'

describe Promiscuous do
  let(:lock_expiration) { 2 }

  before { use_real_backend { |config| config.logger.level = Logger::ERROR
                              config.publisher_lock_expiration = lock_expiration
                              config.publisher_lock_timeout    = 0.1
                              config.recovery_interval = 0.01 } }
  before { load_models }
  before { run_subscriber_worker! }

  after { Promiscuous::Publisher::Transport.expired.should be_empty }

  context "when a recovery worker is running" do
    before { run_recovery_worker! }

    context 'when rabbit dies' do
      context 'for updates' do
        it 'still publishes message' do
          pub = PublisherModel.create(:field_1 => '1')

          eventually { SubscriberModel.count.should == 1 }

          amqp_down!

          expect { pub.update_attributes(:field_1 => '2') }.to_not raise_error

          sleep 0.1

          SubscriberModel.count.should == 1

          amqp_up!

          eventually { SubscriberModel.first.field_1.should == '2' }
        end
      end

      context 'for creates' do
        it 'still publishes message updates' do
          amqp_down!

          expect { PublisherModel.create(:field_1 => '1') }.to_not raise_error

          sleep 0.1

          SubscriberModel.count.should == 0

          amqp_up!

          eventually { SubscriberModel.first.field_1.should == '1' }
        end
      end

      context "for two operations on the same document" do
        it "raises for the second operation as the lock has not expired" do
          amqp_down!

          pub = PublisherModel.create(:field_1 => '1')
          expect { pub.destroy }.to raise_error

          amqp_up!

          eventually { Promiscuous::Publisher::Transport.expired.should be_empty }
        end
      end

      context 'destroys' do
        it 'still publishes message updates' do
          pub = PublisherModel.create(:field_1 => '1')

          eventually { SubscriberModel.count.should == 1 }

          amqp_down!

          expect { pub.destroy }.to_not raise_error

          sleep 0.1

          SubscriberModel.count.should == 1

          amqp_up!

          eventually { SubscriberModel.count.should == 0 }
        end
      end

      context 'ephemerals' do
        before { load_ephemerals }

        it 'raises if unable to publish' do
          amqp_down!

          expect { ModelEphemeral.create(:field_1 => '1') }.to raise_error
          SubscriberModel.count.should == 0

          amqp_up!

          expect { ModelEphemeral.create(:field_1 => '1') }.to_not raise_error
          eventually { SubscriberModel.first.field_1.should == '1' }
        end
      end
    end
  end

  context "when a recovery worker is not running" do
    context "when a lock expires" do
      let(:lock_expiration) { 0.1 }

      before { $callback_counter = 0 }
      before do
        SubscriberModel.class_eval do
          after_save { $callback_counter += 1 }
        end
      end
      before do
        amqp_down!
        @pub = PublisherModel.create(:field_1 => 1)
        sleep 1
        amqp_up!
      end

      it "a subsequent operation on the same object publishes the previous state of the database" do
        @pub.update_attributes(:field_2 => 2)

        eventually { $callback_counter.should == 2 }
      end
    end

    context "when a lock is recovered" do
      let(:lock_expiration) { 1 }

      before do
        amqp_down!
        @pub = PublisherModel.create(:field_1 => 1)
        amqp_up!
        sleep 1
        amqp_slow!(1.second)
        @pub.update_attributes(:field_2 => 2) # lock recovered
      end

      it "extends the lock and prevents subsequent operations from recovering" do
        sleep 1.1
        expect { @pub.update_attributes(:field_3 => 1) }.to raise_error
      end
    end
  end
end
