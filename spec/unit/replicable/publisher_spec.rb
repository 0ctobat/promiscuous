require 'spec_helper'

describe Replicable::Publisher do
  before { Replicable::AMQP.configure(:backend => :fake, :app => 'crowdtap') }

  before do
    define_constant(:parent) do
      include Mongoid::Document
      include Replicable::Publisher

      field :parent_field_1
      field :parent_field_2
      field :parent_field_3

      replicate :app_name => 'crowdtap'
    end

    define_constant(:child, Parent) do
      include Mongoid::Document
      include Replicable::Publisher

      field :child_field_1
      field :child_field_2
      field :child_field_3

      replicate :app_name => 'crowdtap'
    end
  end

  context "when creating" do
    let!(:instance) { Child.create(:child_field_1  => "child_1",
                                   :child_field_2  => "child_2",
                                   :parent_field_1 => "parent_1") }

    before do
      re = /crowdtap\.(.+)\.(.+)/
      _, @model_name, @operation = Replicable::AMQP.messages.last[:key].match(re).to_a
    end

    it "broadcasts the model hierarchy in the key" do
      @model_name.split('.').should =~ ['child', 'parent']
    end

    it "broadcasts the create operation in the key" do
      @operation.should == 'create'
    end
  end

  context "when updating" do
    let!(:instance) { Child.create }

    before do
      Replicable::AMQP.clear
      instance.update_attributes(:child_field_1  => "child_1",
                                 :child_field_2  => "child_2",
                                 :parent_field_1 => "parent_1")
    end

    before do
      re = /crowdtap\.(.+)\.(.+)/
      _, @model_name, @operation = Replicable::AMQP.messages.last[:key].match(re).to_a
    end

    it "broadcasts the model hierarchy in the key" do
      @model_name.split('.').should =~ ['child', 'parent']
    end

    it "broadcasts the update operation in the key" do
      @operation.should == 'update'
    end
  end

  context "when destroying" do
    let!(:instance) { Child.create }

    before do
      Replicable::AMQP.clear
      instance.destroy
    end

    before do
      re = /crowdtap\.(.+)\.(.+)/
      _, @model_name, @operation = Replicable::AMQP.messages.last[:key].match(re).to_a
    end

    it "broadcasts the model hierarchy in the key" do
      @model_name.split('.').should =~ ['child', 'parent']
    end

    it "broadcasts the destroy operation in the key" do
      @operation.should == 'destroy'
    end
  end
end
