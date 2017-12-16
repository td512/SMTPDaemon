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
require 'mail'


project_root = File.dirname(File.absolute_path(__FILE__))
Dir.glob(project_root + "/app/models/*.rb").each{|f| require f}
connection_details = YAML.load(File.read(File.expand_path('../database.yml', __FILE__)))
ActiveRecord::Base.establish_connection(connection_details)

class Server
  def initialize( port, ip )
    @server = TCPServer.open( ip, port )
    @config = YAML.load(File.read(File.expand_path('../config.yml', __FILE__)))
    @helo = 0
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
          puts "Client #{@client_host.split(" ").last} disconnected (Too many connections)".red
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
    @mail_from = 0
    @rcpt_to = 0
    @data = 0
    @client_motd = String.new
    @spf_pass = 0
    @data_var = String.new
    @timeout = 1
  end
  def getSPFRecords(domain, ip)
    if @config["SERVICE_SPF"] == 1
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
    else
      @spf_pass = 1
    end
  end
  def checkClientDomain
    getSPFRecords(@client_motd, @client_host.split(" ").last)
    if @spf_pass == 1
      @client.print "250 #{@config["SERVICE_ACCEPTED"]}\r\n"
      @mail_from = 1
    else
      decrementIPConnCount
      puts "Client #{@client_host.split(" ").last} disconnected (SPF record doesn't match)".red
      @client.print("421 #{@config["SERVICE_NO_MATCH"]}\r\n")
      @client.close
    end
  end
  def checkRecvDomain
    if @config["SERVICE_DOMAINS"].include? @rcpt_addr
      @rcpt_to = 1
      @client.print "250 #{@config["SERVICE_ACCEPTED"]}\r\n"
    else
      decrementIPConnCount
      puts "Client #{@client_host.split(" ").last} disconnected (Domain mismatch [#{@rcpt_addr}])".red
      @client.print("550 #{@config["SERVICE_NO_SUCH_ADDRESS"]}\r\n")
      @client.close
    end
  end
  def printMotd
    @client.print "250-#{@config["SERVICE_HOSTNAME"]} Nice to meet you, [#{@client_host.split(" ").last}]\r\n"
    @config["SERVICE_CAPABILITIES"].each do |cap|
      @client.print "250-#{cap}\r\n"
    end
    @client.print "250 SIZE #{@config["SERVICE_MAX_SIZE"]*1024*1024}\r\n"
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
    if((@data == 1) && (msg.chomp == "."))
      mail = Mail.new(@data_var)
      if mail.multipart?
        body = mail.parts[1].body.decoded
      else
        body = mail.body.decoded
      end
      email = Email.new(:to_user => mail.to[0], :from_address => mail.from[0], :subject => mail.subject, :date => mail.date.to_s, :body => body, :priority => 'Normal', :raw_email => @data_var, :read => "0")
      email.save
      puts "Email delivered, row #{email.id}.".green
      clearVars
      @client.print "250 #{@config["SERVICE_MAIL_QUEUED"]}\r\n"
    end
    if(@data == 1)
      @data_var += (msg + "\r\n")
    end
    case
    when (@data == 0)
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
        m.slice! "mail from:"
        m.tr!('<>?=#$%^&*()', '')
        @client_motd = m.split('@').last
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
        m.slice! "rcpt to:"
        m.tr!('<>?=#$%^&*()', '')
        @rcpt_addr = m.split('@').last
        checkRecvDomain
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
    else
      if ! @data == 1
        @client.print "500 Error: #{@config["SERVICE_UNK_CMD"]}\r\n"
      end
    end
  else
    # This comment must stay here
  end
  end
}
end
end
config = YAML.load(File.read(File.expand_path('../config.yml', __FILE__)))
print "\x1Bc"
puts "SMTPd running on port #{config["SERVICE_PORT"]}"
Server.new( config["SERVICE_PORT"], "0.0.0.0" )
