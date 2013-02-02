module Promiscuous::Publisher::Model::Mongoid
  extend ActiveSupport::Concern

  class Commit
    attr_accessor :collection, :selector, :document, :operation
    def initialize(options={})
      self.collection = options[:collection]
      self.selector   = options[:selector]
      self.document   = options[:document]
      self.operation  = options[:operation]
    end

    def klass
      @klass ||= document.try(:[], '_type').try(:constantize) ||
                 collection.singularize.camelize.constantize
    rescue NameError
    end

    def fetch
      case operation
      when :create  then klass.new(document, :without_protection => true)
      when :update  then klass.with(:consistency => :strong).where(selector).first
      when :destroy then klass.with(:consistency => :strong).where(selector).first
      end
    end

    def commit(&block)
      return block.call unless klass

      # We bypass the call if instance == nil, the destroy or the update would
      # have had no effect
      instance = fetch
      return if instance.nil?

      return block.call unless instance.class.respond_to?(:promiscuous_publisher)

      self.selector = {:id => instance.id}

      publisher = instance.class.promiscuous_publisher
      publisher.new(:operation  => operation,
                    :instance   => instance,
                    :fetch_proc => method(:fetch)).commit(&block)
    end
  end

  def self.hook_mongoid
    Moped::Collection.class_eval do
      alias_method :insert_orig, :insert
      def insert(documents, flags=nil)
        documents = [documents] unless documents.is_a?(Array)
        documents.each do |doc|
          Promiscuous::Publisher::Model::Mongoid::Commit.new(
            :collection => self.name,
            :document   => doc,
            :operation  => :create
          ).commit do
            insert_orig(doc, flags)
          end
        end
      end
    end

    Moped::Query.class_eval do
      alias_method :update_orig, :update
      def update(change, flags=nil)
        if flags && flags.include?(:multi)
          raise "Promiscuous: Do not use multi updates, update each instance separately"
        end

        Promiscuous::Publisher::Model::Mongoid::Commit.new(
          :collection => collection.name,
          :selector   => selector,
          :operation  => :update
        ).commit do
          update_orig(change, flags)
        end
      end

      alias_method :modify_orig, :modify
      def modify(change, options={})
        Promiscuous::Publisher::Model::Mongoid::Commit.new(
          :collection => collection.name,
          :selector   => selector,
          :operation  => :update
        ).commit do
          modify_orig(change, options)
        end
      end

      alias_method :remove_orig, :remove
      def remove
        Promiscuous::Publisher::Model::Mongoid::Commit.new(
          :collection => collection.name,
          :selector   => selector,
          :operation  => :destroy
        ).commit do
          remove_orig
        end
      end

      alias_method :remove_all_orig, :remove_all
      def remove_all
        raise "Promiscuous: Do not use delete_all, use destroy_all"
      end
    end
  end
  hook_mongoid
end
