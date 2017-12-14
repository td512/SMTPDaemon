require 'socket'
require 'yaml'
require 'colored'
require "rubygems"
require "bundler/setup"
require "active_record"
require 'securerandom'
require 'spf/query'
require 'netaddr'
require 'ostruct'

project_root = File.dirname(File.absolute_path(__FILE__))
Dir.glob(project_root + "/app/models/*.rb").each{|f| require f}
connection_details = YAML.load(File.read(File.expand_path('../database.yml', __FILE__)))
ActiveRecord::Base.establish_connection(connection_details)

class Server
  def initialize( port, ip )
    @server = TCPServer.open( ip, port )
    @config = YAML.load(File.read(File.expand_path('../config.yml', __FILE__)))
    @helo = 0
    @to = String.new
    @from = String.new
    @mail_from = 0
    @rcpt_to = 0
    @data = 0
    @data_var = String.new
    @auth_user = String.new
    @auth_pass = String.new
    @authu = 0
    @client_motd = String.new
    @authp = 0
    @timer = 0
    @spf_pass = 0
    @sid = SecureRandom.uuid
    clearSessionPool
    run
  end
  def restartClearSessionPool
    clearSessionPool
  end
  def clearSessionPool
    ip_timer = 0
    puts "Clearing Sessions"
    Session.delete_all
    @ip_counter = Thread.new do
      while ip_timer != @config["SERVICE_CLEAR_SESSIONS_TIMER"]
        if ip_timer >= @config["SERVICE_CLEAR_SESSIONS_TIMER"] - 1
          restartClearSessionPool
          Thread.kill self
        end
        sleep 1
        ip_timer += 1
      end
    end
  end
  def startCounting
    @counter = Thread.new do
      while @timer != @config["SERVICE_MAX_TIMEOUT"]
        if @timer >= @config["SERVICE_MAX_TIMEOUT"] - 1
          @client.print "421 #{@config["SERVICE_TIMEOUT_NOTICE"]}\r\n"
          @client.close
          @timer = 0
          Thread.kill self
        end
        sleep 1
        @timer += 1
      end
    end
  end
  def stopCounting
    Thread.kill @counter
  end
  def decrementIPConnCount
    s = @sess.session_count.to_i
    s = s - 1
    @sess.session_count = s
    @sess.save
  end
  def clearVars
    @to = String.new
    @from = String.new
    @mail_from = 0
    @rcpt_to = 0
    @data = 0
    @client_motd = String.new
    @spf_pass = 0
    @data_var = String.new
    @timeout = 1
  end
  def getSPFRecords(domain, ip)
    spf_array = Array.new
    addr_array = Array.new
    if SPF::Query::Record.query(domain) != nil
      SPF::Query::Record.query(domain).include.each do |dspf|
        spf_array.push(dspf)
        @timer = 0
      end
    end
    if spf_array.empty?
      @spf_pass = 1
    end
    while ! spf_array.empty? do
      spf_array.each do |s|
        spf_array.delete_at(spf_array.index(s))
          SPF::Query::Record.query(s.value).each do |spf|
            x = spf.to_s.split(":")
            if x[0] == "ip4"
              @timer = 0
              addr_array.push(x[1])
            end
            if x[0] == "include"
              @timer = 0
              spf_array.push(OpenStruct.new(value: x[1]))
            end
          end
        end
      end
    addr_array.each do |addr|
      cidr = NetAddr::CIDR.create(addr)
      if cidr.contains?(ip)
        @spf_pass = 1
      end
    end
  end
  def checkClientDomain
    getSPFRecords(@client_motd, @client_host.split(" ").last)
    if @spf_pass == 1
      @client.print "250 #{@config["SERVICE_ACCEPTED"]}\r\n"
      @mail_from = 1
    else
      decrementIPConnCount
      puts "Client #{@client_host.split(" ").last} disconnected"
      @client.print("421 #{@config["SERVICE_NO_MATCH"]}\r\n")
      @client.close
    end
  end
  def printMotd
    @client.print "250-#{@config["SERVICE_HOSTNAME"]} Nice to meet you, [#{@client_host.split(" ").last}]\r\n"
    @client.print "250-PIPELINING\r\n"
    @client.print "250-8BITMIME\r\n"
    @client.print "250-SMTPUTF8\r\n"
    @client.print "250-AUTH LOGIN\r\n"
    @client.print "250 SIZE 10485760\r\n"
    @helo = 1
  end
  def run
    loop {
      Thread.start(@server.accept) do | client |
        puts "New client connected from #{client.peeraddr.last}".green
        startCounting
        if ! Session.exists?(:ip => client.peeraddr.last)
          @sess = Session.new(:ip => client.peeraddr.last, :session_count => 1)
          @sess.save
        else
          @sess = Session.find_by(ip: client.peeraddr.last)
          if @sess.session_count.to_i > @config["SERVICE_MAX_SESSIONS"]
            decrementIPConnCount
            client.print "421 #{@config["SERVICE_TOO_MANY_CONNECTIONS"]}\r\n"
            client.close
            Thread.kill self
          else
            s = @sess.session_count.to_i
            s = s + 1
            @sess.session_count = s
            @sess.save
          end
        end
        client.print "220 #{@config["SERVICE_HOSTNAME"]} ESMTP #{@config["SERVICE_BANNER"]} ready.\r\n"
        @client = client
        @client_host = client.peeraddr.last
        loop {
          listen_commands( client.gets.chomp )
        }
  end
  def listen_commands( msg )
    m = msg.downcase
    @timer = 0
    if((@data == 1) && (msg.chomp =~ /^\.$/))
      @data = 0
      puts "Mail from: #{@from}"
      puts "Mail for: #{@to}"
      puts "Body:"
      puts @data_var
      clearVars
      @client.print "250 #{@config["SERVICE_MAIL_QUEUED"]}\r\n"
    end
    if(@data == 1)
      @data_var += (msg + "\r\n")
    end
    if(@authu == 1)
      @auth_user = msg
      puts @auth_user
      @authu = 0
      @authp = 1
    end
    if(@authp == 1)
      @auth_pass = msg
      puts @auth_pass
      @authp = 0
    end
    case
    when (m.include?("helo"))
      printMotd
    when (m.include?("ehlo"))
      printMotd
    when (m.include?("quit"))
      decrementIPConnCount
      clearVars
      @client.print "221 #{@config["SERVICE_GOODBYE"]}\r\n"
      puts "Client #{@client_host.split(" ").last} disconnected"
      @client.close
      stopCounting
      Thread.kill self
    when (m.include?("mail"))
      if @helo == 0
        @client.print "503 Error: #{@config["SERVICE_NO_HELO"]}\r\n"
      else
        m.slice! "mail from: "
        m.tr!('<>?=#$%^&*()', '')
        @from = m
        @client_motd = @from.split('@').last
        checkClientDomain
      end
    when (m.include?("rcpt"))
      if @helo == 0
        @client.print "503 Error: #{@config["SERVICE_NO_HELO"]}\r\n"
      end
      if @mail_from == 0
        @client.print "503 Error: #{@config["SERVICE_NO_MAIL"]}\r\n"
      else
        m.slice! "rcpt to: "
        m.tr!('<>?=#$%^&*()', '')
        @to = m
        @client.print "250 #{@config["SERVICE_ACCEPTED"]}\r\n"
        @rcpt_to = 1
        puts "Got mail for #{@to} from #{@from}, sender: #{@client_host.split(" ").last}".yellow
      end
    when (m.include?("data"))
      if @helo == 0
        @client.print "503 Error: #{@config["SERVICE_NO_HELO"]}\r\n"
      end
      if @mail_from == 0
        @client.print "503 Error: #{@config["SERVICE_NO_MAIL"]}\r\n"
      end
      if @rcpt_to == 0
        @client.print "503 Error: #{@config["SERVICE_NO_RCPT"]}\r\n"
      else
        @client.print "354 #{@config["SERVICE_DATA_MOTD"]}\r\n"
        @data = 1
      end
    when (m.include?("rset"))
      clearVars
      @client.print "250 #{@config["SERVICE_NOOP"]}\r\n"
    when (m.include?("vrfy"))
      @client.print "252 #{@config["SERVICE_VRFY"]}\r\n"
    when (m.include?("noop"))
      @client.print "250 #{@config["SERVICE_NOOP"]}\r\n"
    when (m.include?("help"))
      @client.print "214 #{@config["SERVICE_HELP"]}\r\n"
    when (m.include?("auth"))
      if m.split(" ")[1] != "login"
        @client.print "504 Error: #{@config["SERVICE_UNK_AUTH"]}\r\n"
        puts "Client #{@client_host.split(" ").last} failed authentication: Wrong type".red
      else
        @client.print "334 VXNlcm5hbWU6\r\n"
        @authu = 1
        @client.print "334 UGFzc3dvcmQ6\r\n"
        @client.print "250 #{@config["SERVICE_ACCEPTED"]}\r\n"
      end
    else
      if ! @data == 1
        @client.print "500 Error: #{@config["SERVICE_UNK_CMD"]}\r\n"
      end
    end
  end
}
end
end
config = YAML.load(File.read(File.expand_path('../config.yml', __FILE__)))
puts "\x1Bc"
puts "SMTPd running on port #{config["SERVICE_PORT"]}"
Server.new( config["SERVICE_PORT"], "0.0.0.0" )
