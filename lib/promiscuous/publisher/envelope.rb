module Promiscuous::Publisher::Envelope
  extend ActiveSupport::Concern

  def payload
    { :payload => super }
  end
end
