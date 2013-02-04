class Promiscuous::CLI
  attr_accessor :options

  def self.trap_signals
    Signal.trap 'SIGUSR2' do
      Thread.list.each do |thread|
        print_status '-' * 80
        if thread.backtrace
          print_status "Thread #{thread} #{thread['label']}"
          print_status thread.backtrace.join("\n")
        else
          print_status "Thread #{thread} #{thread['label']} -- no backtrace"
        end
      end
    end
  end
  trap_signals

  def publish
    options[:criterias].map { |criteria| eval(criteria) }.each do |criteria|
      title = criteria.name
      title = "#{title}#{' ' * [0, 20 - title.size].max}"
      bar = ProgressBar.create(:format => '%t |%b>%i| %c/%C %e', :title => title, :total => criteria.count)
      criteria.each do |doc|
        doc.promiscuous_sync
        bar.increment
      end
    end
  end

  def subscribe
    Promiscuous::Loader.load_descriptors if defined?(Rails)
    print_status "Replicating with #{Promiscuous::Subscriber::AMQP.subscribers.count} subscribers"
    Promiscuous::Subscriber::Worker.run
  rescue Interrupt
    # SIGINT
  end

  def parse_args(args)
    options = {}

    require 'optparse'
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: promiscuous [options] action"

      opts.separator ""
      opts.separator "Actions:"
      opts.separator "    promiscuous publish \"Member.where(:updated_at.gt => 1.day.ago)\" BrandAction"
      opts.separator "    promiscuous subscribe"
      opts.separator ""
      opts.separator "Options:"

      opts.on "-b", "--bareback", "Bareback mode aka no dependencies. Use with extreme caution" do
        options[:bareback] = true
      end

      opts.on "-r", "--require FILE", "File to require to load your app. Don't worry about it with rails" do |file|
        options[:require] = file
      end

      opts.on("-h", "--help", "Show this message") do
        puts opts
        exit
      end

      opts.on("-V", "--version", "Show version") do
        puts "Promiscuous #{Promiscuous::VERSION}"
        puts "License MIT"
        exit
      end
    end

    args = args.dup
    parser.parse!(args)

    options[:action] = args.shift.try(:to_sym)
    options[:criterias] = args

    unless options[:action].in? [:publish, :subscribe]
      puts parser
      exit
    end

    if options[:action] == :publish
      raise "Please specify one or more criterias" unless options[:criterias].present?
    else
      raise "Why are you specifying a criteria?" if options[:criterias].present?
    end

    options
  rescue Exception => e
    puts e
    exit
  end

  def load_app
    if options[:require]
      require options[:require]
    else
      require 'rails'
      require File.expand_path("./config/environment.rb")
      ::Rails.application.eager_load!
    end
  end

  def boot
    self.options = parse_args(ARGV)
    load_app
    maybe_run_bareback
    run
  end

  def run
    case options[:action]
    when :publish then publish
    when :subscribe then subscribe
    end
  end

  def maybe_run_bareback
    if options[:bareback]
      Promiscuous::Config.bareback = true
      print_status "WARNING: --- BAREBACK MODE ----"
      print_status "WARNING: You are replicating without protection, you can get out of sync in no time"
      print_status "WARNING: --- BAREBACK MODE ----"
    end
  end

  def print_status(msg)
    Promiscuous.info msg
    $stderr.puts msg
  end
end
