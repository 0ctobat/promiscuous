class Promiscuous::Railtie < Rails::Railtie
  module TransactionMiddleware
    def process_action(*args)
      Promiscuous.transaction("#{self.class.controller_name}/#{self.action_name}") do
        super
      end
    rescue Exception => e
      STDERR.puts "\e[0;#{36}m----[ Promiscuous ]---------------------------------------------------------------------------------\e[0m"
      STDERR.puts
      STDERR.puts "\e[0;#{31}m#{e}\e[0m"
      STDERR.puts
      STDERR.puts "\e[0;#{36}m----[  Backtrace  ]---------------------------------------------------------------------------------\e[0m"

      backtrace = e.backtrace
      .take_while { |line| line !~ /#{__FILE__}/ }
      .map do |line|
        case line
        when /`(count|distinct|each|first|last)'$/                     then "\e[1;32m#{line}\e[0m"
        when /`(create|insert|save|update|modify|remove|remove_all)'$/ then "\e[1;31m#{line}\e[0m"
        when /#{Rails.root}/                                           then "\e[1;36m#{line}\e[0m"
        else                                                                "\e[1;30m#{line}\e[0m"
        end
      end
      STDERR.puts backtrace.join("\n")

      raise e
    end
  end

  initializer 'load promiscuous' do
    config.after_initialize do
      Promiscuous::Config.configure unless Promiscuous::Config.configured?
      Promiscuous::Loader.prepare
      ActionController::Base.__send__(:include, TransactionMiddleware)

      ActionDispatch::Reloader.to_prepare do
        Promiscuous::Loader.prepare
      end
      ActionDispatch::Reloader.to_cleanup do
        Promiscuous::Loader.cleanup
      end
    end
  end
end
