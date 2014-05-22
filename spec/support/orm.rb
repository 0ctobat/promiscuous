module ORM
  def self.backend
    @backend ||= ENV['TEST_ENV'].to_sym
  end

  def self.has(feature)
    {
      :active_record           => [:active_record32, :active_record40],
      :transaction             => [:active_record32, :active_record40],
      :mongoid                 => [:mongoid3, :mongoid40],
      :polymorphic             => [:mongoid3, :mongoid40],
      :embedded_documents      => [:mongoid3, :mongoid40],
      :many_embedded_documents => [:mongoid3, :mongoid40],
      :versioning              => [:mongoid3, :mongoid40],
      :find_and_modify         => [:mongoid3, :mongoid40],
    }[feature].any? { |orm| orm == backend }
  end

  if has(:mongoid)
    #Operation = Promiscuous::Publisher::Model::Mongoid::Operation
    ID = :_id
  elsif has(:active_record)
    #Operation = Promiscuous::Publisher::Operation
    ID = :id
  end

  def self.generate_id
    if has(:mongoid)
      BSON::ObjectId.new
    else
      @ar_id ||= 10
      @ar_id += 1
      @ar_id
    end
  end

  def self.purge!
    Mongoid.purge! if has(:mongoid)

    if has(:active_record)
      DatabaseCleaner.clean
      DatabaseCleaner.start
    end
  end
end
