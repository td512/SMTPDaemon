require 'mini-smtp-server'
class MonarchSmtpServer < MiniSmtpServer

  def new_message_event(message_hash)
    puts "# New email received:"
    puts "From: #{message_hash[:from]}"
    puts "To:   #{message_hash[:to]}"
    puts ""
    puts "" + message_hash[:data]
    puts
  end
  server = MonarchSmtpServer.new
  server.start
  server.join
end
