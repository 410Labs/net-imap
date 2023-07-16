# frozen_string_literal: true

require "net/imap"
require "test/unit"
require_relative "fake_server"

class IMAPTest < Test::Unit::TestCase
  CA_FILE = File.expand_path("../fixtures/cacert.pem", __dir__)
  SERVER_KEY = File.expand_path("../fixtures/server.key", __dir__)
  SERVER_CERT = File.expand_path("../fixtures/server.crt", __dir__)

  def setup
    @do_not_reverse_lookup = Socket.do_not_reverse_lookup
    Socket.do_not_reverse_lookup = true
    @threads = []
  end

  def teardown
    if !@threads.empty?
      assert_join_threads(@threads)
    end
  ensure
    Socket.do_not_reverse_lookup = @do_not_reverse_lookup
  end

  if defined?(OpenSSL::SSL::SSLError)
    def test_imaps_unknown_ca
      assert_raise(OpenSSL::SSL::SSLError) do
        imaps_test do |port|
          begin
            Net::IMAP.new("localhost",
                          :port => port,
                          :ssl => true)
          rescue SystemCallError
            skip $!
          end
        end
      end
    end

    def test_imaps_with_ca_file
      assert_nothing_raised do
        imaps_test do |port|
          begin
            Net::IMAP.new("localhost",
                          :port => port,
                          :ssl => { :ca_file => CA_FILE })
          rescue SystemCallError
            skip $!
          end
        end
      end
    end

    def test_imaps_verify_none
      assert_nothing_raised do
        imaps_test do |port|
          Net::IMAP.new(server_addr,
                        :port => port,
                        :ssl => { :verify_mode => OpenSSL::SSL::VERIFY_NONE })
        end
      end
    end

    def test_imaps_post_connection_check
      assert_raise(OpenSSL::SSL::SSLError) do
        imaps_test do |port|
          # server_addr is different from the hostname in the certificate,
          # so the following code should raise a SSLError.
          Net::IMAP.new(server_addr,
                        :port => port,
                        :ssl => { :ca_file => CA_FILE })
        end
      end
    end
  end

  if defined?(OpenSSL::SSL)
    def test_starttls
      imap = nil
      starttls_test do |port|
        imap = Net::IMAP.new("localhost", :port => port)
        imap.starttls(:ca_file => CA_FILE)
        imap
      end
    rescue SystemCallError
      skip $!
    ensure
      if imap && !imap.disconnected?
        imap.disconnect
      end
    end

    def test_starttls_stripping
      starttls_stripping_test do |port|
        imap = Net::IMAP.new("localhost", :port => port)
        assert_raise(Net::IMAP::UnknownResponseError) do
          imap.starttls(:ca_file => CA_FILE)
        end
        imap
      end
    end
  end

  def start_server
    th = Thread.new do
      yield
    end
    @threads << th
    sleep 0.1 until th.stop?
  end

  def test_unexpected_eof
    server = create_tcp_server
    port = server.addr[1]
    start_server do
      sock = server.accept
      begin
        sock.print("* OK test server\r\n")
        sock.gets
#       sock.print("* BYE terminating connection\r\n")
#       sock.print("RUBY0001 OK LOGOUT completed\r\n")
      ensure
        sock.close
        server.close
      end
    end
    begin
      imap = Net::IMAP.new(server_addr, :port => port)
      assert_raise(EOFError) do
        imap.logout
      end
    ensure
      imap.disconnect if imap
    end
  end

  def test_idle
    server = create_tcp_server
    port = server.addr[1]
    requests = []
    start_server do
      sock = server.accept
      begin
        sock.print("* OK test server\r\n")
        requests.push(sock.gets)
        sock.print("+ idling\r\n")
        sock.print("* 3 EXISTS\r\n")
        sock.print("* 2 EXPUNGE\r\n")
        requests.push(sock.gets)
        sock.print("RUBY0001 OK IDLE terminated\r\n")
        sock.gets
        sock.print("* BYE terminating connection\r\n")
        sock.print("RUBY0002 OK LOGOUT completed\r\n")
      ensure
        sock.close
        server.close
      end
    end

    begin
      imap = Net::IMAP.new(server_addr, :port => port)
      responses = []
      imap.idle do |res|
        responses.push(res)
        if res.name == "EXPUNGE"
          imap.idle_done
        end
      end
      assert_equal(3, responses.length)
      assert_instance_of(Net::IMAP::ContinuationRequest, responses[0])
      assert_equal("EXISTS", responses[1].name)
      assert_equal(3, responses[1].data)
      assert_equal("EXPUNGE", responses[2].name)
      assert_equal(2, responses[2].data)
      assert_equal(2, requests.length)
      assert_equal("RUBY0001 IDLE\r\n", requests[0])
      assert_equal("DONE\r\n", requests[1])
      imap.logout
    ensure
      imap.disconnect if imap
    end
  end

  def test_exception_during_idle
    server = create_tcp_server
    port = server.addr[1]
    requests = []
    start_server do
      sock = server.accept
      begin
        sock.print("* OK test server\r\n")
        requests.push(sock.gets)
        sock.print("+ idling\r\n")
        sock.print("* 3 EXISTS\r\n")
        sock.print("* 2 EXPUNGE\r\n")
        requests.push(sock.gets)
        sock.print("RUBY0001 OK IDLE terminated\r\n")
        sock.gets
        sock.print("* BYE terminating connection\r\n")
        sock.print("RUBY0002 OK LOGOUT completed\r\n")
      ensure
        sock.close
        server.close
      end
    end
    begin
      imap = Net::IMAP.new(server_addr, :port => port)
      begin
        th = Thread.current
        m = Monitor.new
        in_idle = false
        exception_raised = false
        c = m.new_cond
        raiser = Thread.start do
          m.synchronize do
            until in_idle
              c.wait(0.1)
            end
          end
          th.raise(Interrupt)
          m.synchronize do
            exception_raised = true
            c.signal
          end
        end
        @threads << raiser
        imap.idle do |res|
          m.synchronize do
            in_idle = true
            c.signal
            until exception_raised
              c.wait(0.1)
            end
          end
        end
      rescue Interrupt
      end
      assert_equal(2, requests.length)
      assert_equal("RUBY0001 IDLE\r\n", requests[0])
      assert_equal("DONE\r\n", requests[1])
      imap.logout
    ensure
      imap.disconnect if imap
      raiser.kill unless in_idle
    end
  end

  def test_idle_done_not_during_idle
    server = create_tcp_server
    port = server.addr[1]
    start_server do
      sock = server.accept
      begin
        sock.print("* OK test server\r\n")
        sleep 0.1
      ensure
        sock.close
        server.close
      end
    end
    begin
      imap = Net::IMAP.new(server_addr, :port => port)
      assert_raise(Net::IMAP::Error) do
        imap.idle_done
      end
    ensure
      imap.disconnect if imap
    end
  end

  def test_idle_timeout
    server = create_tcp_server
    port = server.addr[1]
    requests = []
    start_server do
      sock = server.accept
      begin
        sock.print("* OK test server\r\n")
        requests.push(sock.gets)
        sock.print("+ idling\r\n")
        sock.print("* 3 EXISTS\r\n")
        sock.print("* 2 EXPUNGE\r\n")
        requests.push(sock.gets)
        sock.print("RUBY0001 OK IDLE terminated\r\n")
        sock.gets
        sock.print("* BYE terminating connection\r\n")
        sock.print("RUBY0002 OK LOGOUT completed\r\n")
      ensure
        sock.close
        server.close
      end
    end

    begin
      imap = Net::IMAP.new(server_addr, :port => port)
      responses = []
      Thread.pass
      imap.idle(0.2) do |res|
        responses.push(res)
      end
      # There is no guarantee that this thread has received all the responses,
      # so check the response length.
      if responses.length > 0
        assert_instance_of(Net::IMAP::ContinuationRequest, responses[0])
        if responses.length > 1
          assert_equal("EXISTS", responses[1].name)
          assert_equal(3, responses[1].data)
          if responses.length > 2
            assert_equal("EXPUNGE", responses[2].name)
            assert_equal(2, responses[2].data)
          end
        end
      end
      # Also, there is no guarantee that the server thread has stored
      # all the requests into the array, so check the length.
      if requests.length > 0
        assert_equal("RUBY0001 IDLE\r\n", requests[0])
        if requests.length > 1
          assert_equal("DONE\r\n", requests[1])
        end
      end
      imap.logout
    ensure
      imap.disconnect if imap
    end
  end

  def test_unexpected_bye
    server = create_tcp_server
    port = server.addr[1]
    start_server do
      sock = server.accept
      begin
        sock.print("* OK Gimap ready for requests from 75.101.246.151 33if2752585qyk.26\r\n")
        sock.gets
        sock.print("* BYE System Error 33if2752585qyk.26\r\n")
      ensure
        sock.close
        server.close
      end
    end
    begin
      imap = Net::IMAP.new(server_addr, :port => port)
      assert_raise(Net::IMAP::ByeResponseError) do
        imap.login("user", "password")
      end
    end
  end

  def test_exception_during_shutdown
    server = create_tcp_server
    port = server.addr[1]
    start_server do
      sock = server.accept
      begin
        sock.print("* OK test server\r\n")
        sock.gets
        sock.print("* BYE terminating connection\r\n")
        sock.print("RUBY0001 OK LOGOUT completed\r\n")
      ensure
        sock.close
        server.close
      end
    end
    begin
      imap = Net::IMAP.new(server_addr, :port => port)
      imap.instance_eval do
        def @sock.shutdown(*args)
          super
        ensure
          raise "error"
        end
      end
      imap.logout
    ensure
      assert_raise(RuntimeError) do
        imap.disconnect
      end
    end
  end

  def test_connection_closed_during_idle
    server = create_tcp_server
    port = server.addr[1]
    requests = []
    sock = nil
    threads = []
    started = false
    threads << Thread.start do
      started = true
      begin
        sock = server.accept
        sock.print("* OK test server\r\n")
        requests.push(sock.gets)
        sock.print("+ idling\r\n")
      rescue IOError # sock is closed by another thread
      ensure
        server.close
      end
    end
    sleep 0.1 until started
    threads << Thread.start do
      imap = Net::IMAP.new(server_addr, :port => port)
      begin
        m = Monitor.new
        in_idle = false
        closed = false
        c = m.new_cond
        threads << Thread.start do
          m.synchronize do
            until in_idle
              c.wait(0.1)
            end
          end
          sock.close
          m.synchronize do
            closed = true
            c.signal
          end
        end
        assert_raise(EOFError) do
          imap.idle do |res|
            m.synchronize do
              in_idle = true
              c.signal
              until closed
                c.wait(0.1)
              end
            end
          end
        end
        assert_equal(1, requests.length)
        assert_equal("RUBY0001 IDLE\r\n", requests[0])
      ensure
        imap.disconnect if imap
      end
    end
    assert_join_threads(threads)
  ensure
    if sock && !sock.closed?
      sock.close
    end
  end

  def test_connection_closed_without_greeting
    server = create_tcp_server
    port = server.addr[1]
    h = {
      server: server,
      port: port,
      server_created: {
        server: server.inspect,
        t: Process.clock_gettime(Process::CLOCK_MONOTONIC),
      }
    }
    net_imap = Class.new(Net::IMAP) do
      @@h = h
      def tcp_socket(host, port)
        @@h[:in_tcp_socket] = {
          host: host,
          port: port,
          server: @@h[:server].inspect,
          t: Process.clock_gettime(Process::CLOCK_MONOTONIC),
        }
        #super
        s = Socket.tcp(host, port, :connect_timeout => @open_timeout)
        @@h[:in_tcp_socket_2] = {
          s: s.inspect,
          local_address: s.local_address,
          remote_address: s.remote_address,
          t: Process.clock_gettime(Process::CLOCK_MONOTONIC),
        }
        s.setsockopt(:SOL_SOCKET, :SO_KEEPALIVE, true)
        s
      end
    end
    start_server do
      begin
        h[:in_start_server_before_accept] = {
          t: Process.clock_gettime(Process::CLOCK_MONOTONIC),
        }
        sock = server.accept
        h[:in_start_server] = {
          sock_addr: sock.addr,
          sock_peeraddr: sock.peeraddr,
          t: Process.clock_gettime(Process::CLOCK_MONOTONIC),
          sockets: ObjectSpace.each_object(BasicSocket).map{|s| [s.inspect, connect_address: (s.connect_address rescue nil).inspect, local_address: (s.local_address rescue nil).inspect, remote_address: (s.remote_address rescue nil).inspect] },
        }
        sock.close
        h[:in_start_server_sock_closed] = {
          t: Process.clock_gettime(Process::CLOCK_MONOTONIC),
        }
      ensure
        server.close
      end
    end
    assert_raise(Net::IMAP::Error) do
      #Net::IMAP.new(server_addr, :port => port)
      if true
          net_imap.new(server_addr, :port => port)
      else
        # for testing debug print
        begin
          net_imap.new(server_addr, :port => port)
        rescue Net::IMAP::Error
          raise Errno::EINVAL
        end
      end
    rescue SystemCallError => e # for debug on OpenCSW
      h[:in_rescue] = {
        e: e,
        server_addr: server_addr,
        t: Process.clock_gettime(Process::CLOCK_MONOTONIC),
      }
      require 'pp'
      raise(PP.pp(h, +''))
    end
  end

  def test_default_port
    assert_equal(143, Net::IMAP.default_port)
    assert_equal(143, Net::IMAP.default_imap_port)
    assert_equal(993, Net::IMAP.default_tls_port)
    assert_equal(993, Net::IMAP.default_ssl_port)
    assert_equal(993, Net::IMAP.default_imaps_port)
  end

  def test_send_invalid_number
    server = create_tcp_server
    port = server.addr[1]
    start_server do
      sock = server.accept
      begin
        sock.print("* OK test server\r\n")
        sock.gets
        sock.print("RUBY0001 OK TEST completed\r\n")
        sock.gets
        sock.print("RUBY0002 OK TEST completed\r\n")
        sock.gets
        sock.print("RUBY0003 OK TEST completed\r\n")
        sock.gets
        sock.print("RUBY0004 OK TEST completed\r\n")
        sock.gets
        sock.print("* BYE terminating connection\r\n")
        sock.print("RUBY0005 OK LOGOUT completed\r\n")
      ensure
        sock.close
        server.close
      end
    end
    begin
      imap = Net::IMAP.new(server_addr, :port => port)
      assert_raise(Net::IMAP::DataFormatError) do
        imap.__send__(:send_command, "TEST", -1)
      end
      imap.__send__(:send_command, "TEST", 0)
      imap.__send__(:send_command, "TEST", 4294967295)
      assert_raise(Net::IMAP::DataFormatError) do
        imap.__send__(:send_command, "TEST", 4294967296)
      end
      assert_raise(Net::IMAP::DataFormatError) do
        imap.__send__(:send_command, "TEST", Net::IMAP::MessageSet.new(-1))
      end
      assert_raise(Net::IMAP::DataFormatError) do
        imap.__send__(:send_command, "TEST", Net::IMAP::MessageSet.new(0))
      end
      imap.__send__(:send_command, "TEST", Net::IMAP::MessageSet.new(1))
      imap.__send__(:send_command, "TEST", Net::IMAP::MessageSet.new(4294967295))
      assert_raise(Net::IMAP::DataFormatError) do
        imap.__send__(:send_command, "TEST", Net::IMAP::MessageSet.new(4294967296))
      end
      imap.logout
    ensure
      imap.disconnect
    end
  end

  def test_send_literal
    server = create_tcp_server
    port = server.addr[1]
    requests = []
    literal = nil
    start_server do
      sock = server.accept
      begin
        sock.print("* OK test server\r\n")
        line = sock.gets
        requests.push(line)
        size = line.slice(/{(\d+)}\r\n/, 1).to_i
        sock.print("+ Ready for literal data\r\n")
        literal = sock.read(size)
        requests.push(sock.gets)
        sock.print("RUBY0001 OK TEST completed\r\n")
        sock.gets
        sock.print("* BYE terminating connection\r\n")
        sock.print("RUBY0002 OK LOGOUT completed\r\n")
      ensure
        sock.close
        server.close
      end
    end
    begin
      imap = Net::IMAP.new(server_addr, :port => port)
      imap.__send__(:send_command, "TEST", ["\xDE\xAD\xBE\xEF".b])
      assert_equal(2, requests.length)
      assert_equal("RUBY0001 TEST ({4}\r\n", requests[0])
      assert_equal("\xDE\xAD\xBE\xEF".b, literal)
      assert_equal(")\r\n", requests[1])
      imap.logout
    ensure
      imap.disconnect
    end
  end

  def test_disconnect
    server = create_tcp_server
    port = server.addr[1]
    start_server do
      sock = server.accept
      begin
        sock.print("* OK test server\r\n")
        sock.gets
        sock.print("* BYE terminating connection\r\n")
        sock.print("RUBY0001 OK LOGOUT completed\r\n")
      ensure
        sock.close
        server.close
      end
    end
    begin
      imap = Net::IMAP.new(server_addr, :port => port)
      imap.logout
      imap.disconnect
      assert_equal(true, imap.disconnected?)
      imap.disconnect
      assert_equal(true, imap.disconnected?)
    ensure
      imap.disconnect if imap && !imap.disconnected?
    end
  end

  def test_append
    server = create_tcp_server
    port = server.addr[1]
    mail = <<EOF.gsub(/\n/, "\r\n")
From: shugo@example.com
To: matz@example.com
Subject: hello

hello world
EOF
    requests = []
    received_mail = nil
    start_server do
      sock = server.accept
      begin
        sock.print("* OK test server\r\n")
        line = sock.gets
        requests.push(line)
        size = line.slice(/{(\d+)}\r\n/, 1).to_i
        sock.print("+ Ready for literal data\r\n")
        received_mail = sock.read(size)
        sock.gets
        sock.print("RUBY0001 OK APPEND completed\r\n")
        requests.push(sock.gets)
        sock.print("* BYE terminating connection\r\n")
        sock.print("RUBY0002 OK LOGOUT completed\r\n")
      ensure
        sock.close
        server.close
      end
    end

    begin
      imap = Net::IMAP.new(server_addr, :port => port)
      imap.append("INBOX", mail)
      assert_equal(1, requests.length)
      assert_equal("RUBY0001 APPEND INBOX {#{mail.size}}\r\n", requests[0])
      assert_equal(mail, received_mail)
      imap.logout
      assert_equal(2, requests.length)
      assert_equal("RUBY0002 LOGOUT\r\n", requests[1])
    ensure
      imap.disconnect if imap
    end
  end

  def test_append_fail
    server = create_tcp_server
    port = server.addr[1]
    mail = <<EOF.gsub(/\n/, "\r\n")
From: shugo@example.com
To: matz@example.com
Subject: hello

hello world
EOF
    requests = []
    start_server do
      sock = server.accept
      begin
        sock.print("* OK test server\r\n")
        requests.push(sock.gets)
        sock.print("RUBY0001 NO Mailbox doesn't exist\r\n")
        requests.push(sock.gets)
        sock.print("* BYE terminating connection\r\n")
        sock.print("RUBY0002 OK LOGOUT completed\r\n")
      ensure
        sock.close
        server.close
      end
    end

    begin
      imap = Net::IMAP.new(server_addr, :port => port)
      assert_raise(Net::IMAP::NoResponseError) do
        imap.append("INBOX", mail)
      end
      assert_equal(1, requests.length)
      assert_equal("RUBY0001 APPEND INBOX {#{mail.size}}\r\n", requests[0])
      imap.logout
      assert_equal(2, requests.length)
      assert_equal("RUBY0002 LOGOUT\r\n", requests[1])
    ensure
      imap.disconnect if imap
    end
  end

  def test_id
    server = create_tcp_server
    port = server.addr[1]
    requests = Queue.new
    server_id = {"name" => "test server", "version" => "v0.1.0"}
    server_id_str = '("name" "test server" "version" "v0.1.0")'
    @threads << Thread.start do
      sock = server.accept
      begin
        sock.print("* OK test server\r\n")
        requests.push(sock.gets)
        # RFC 2971 very clearly states (in section 3.2):
        # "a server MUST send a tagged ID response to an ID command."
        # And yet... some servers report ID capability but won't the response.
        sock.print("RUBY0001 OK ID completed\r\n")
        requests.push(sock.gets)
        sock.print("* ID #{server_id_str}\r\n")
        sock.print("RUBY0002 OK ID completed\r\n")
        requests.push(sock.gets)
        sock.print("* ID #{server_id_str}\r\n")
        sock.print("RUBY0003 OK ID completed\r\n")
        requests.push(sock.gets)
        sock.print("* BYE terminating connection\r\n")
        sock.print("RUBY0004 OK LOGOUT completed\r\n")
      ensure
        sock.close
        server.close
      end
    end

    begin
      imap = Net::IMAP.new(server_addr, :port => port)
      resp = imap.id
      assert_equal(nil, resp)
      assert_equal("RUBY0001 ID NIL\r\n", requests.pop)
      resp = imap.id({})
      assert_equal(server_id, resp)
      assert_equal("RUBY0002 ID ()\r\n", requests.pop)
      resp = imap.id("name" => "test client", "version" => "latest")
      assert_equal(server_id, resp)
      assert_equal("RUBY0003 ID (\"name\" \"test client\" \"version\" \"latest\")\r\n",
                   requests.pop)
      imap.logout
      assert_equal("RUBY0004 LOGOUT\r\n", requests.pop)
    ensure
      imap.disconnect if imap
    end
  end

  def test_uidplus_uid_expunge
    with_fake_server(select: "INBOX",
                     extensions: %i[UIDPLUS]) do |server, imap|
      server.on "UID EXPUNGE" do |resp|
        resp.untagged("1 EXPUNGE")
        resp.untagged("1 EXPUNGE")
        resp.untagged("1 EXPUNGE")
        resp.done_ok
      end
      response = imap.uid_expunge(1000..1003)
      cmd = server.commands.pop
      assert_equal ["UID EXPUNGE", "1000:1003"], [cmd.name, cmd.args]
      assert_equal(response, [1, 1, 1])
    end
  end

  def test_uidplus_appenduid
    with_fake_server(select: "INBOX",
                     extensions: %i[UIDPLUS]) do |server, imap|
      server.on "APPEND" do |cmd|
        cmd.done_ok code: "APPENDUID 38505 3955"
      end
      resp = imap.append("inbox", <<~EOF.gsub(/\n/, "\r\n"), [:Seen], Time.now)
        Subject: hello
        From: shugo@ruby-lang.org
        To: shugo@ruby-lang.org

        hello world
      EOF
      assert_equal([38505, nil, [3955]], resp.data.code.data.to_a)
      assert_equal "APPEND", server.commands.pop.name
    end
  end

  def test_uidplus_copyuid_multiple
    with_fake_server(select: "INBOX",
                     extensions: %i[UIDPLUS]) do |server, imap|
      server.on "UID COPY" do |cmd|
        cmd.done_ok code: "COPYUID 38505 3955,3960:3962 3963:3966"
      end
      resp = imap.uid_copy([3955,3960..3962], 'trash')
      cmd  = server.commands.pop
      assert_equal(["UID COPY", "3955,3960:3962 trash"], [cmd.name, cmd.args])
      assert_equal(
        [38505, [3955, 3960, 3961, 3962], [3963, 3964, 3965, 3966]],
        resp.data.code.data.to_a
      )
    end
  end

  def test_uidplus_copyuid_single
    with_fake_server(select: "INBOX",
                     extensions: %i[UIDPLUS]) do |server, imap|
      server.on "UID COPY" do |cmd|
        cmd.done_ok code: "COPYUID 38505 3955 3967"
      end
      resp = imap.uid_copy(3955, 'trash')
      cmd  = server.commands.pop
      assert_equal(["UID COPY", "3955 trash"], [cmd.name, cmd.args])
      assert_equal([38505, [3955], [3967]], resp.data.code.data.to_a)
    end
  end

  def test_uidplus_uidnotsticky
    with_fake_server(extensions: %i[UIDPLUS]) do |server, imap|
      server.config.mailboxes["trash"] = { uidnotsticky: true }
      imap.select('trash')
      assert imap.responses("NO", &:to_a).any? {
        _1.code == Net::IMAP::ResponseCode.new('UIDNOTSTICKY', nil)
      }
    end
  end

  def test_enable
    with_fake_server(
      with_extensions: %i[ENABLE CONDSTORE UTF8=ACCEPT],
      capabilities_enablable: %w[CONDSTORE UTF8=ACCEPT]
    ) do |server, imap|
      cmdq = server.commands

      result1 = imap.enable(%w[CONDSTORE x-pig-latin])
      result2 = imap.enable(:utf8, "condstore QResync")
      result3 = imap.enable(:utf8, "UTF8=ACCEPT", "UTF8=ONLY")
      cmd1, cmd2, cmd3 = Array.new(3) { cmdq.pop.raw.strip }

      assert_equal "RUBY0001 ENABLE CONDSTORE x-pig-latin",         cmd1
      assert_equal "RUBY0002 ENABLE UTF8=ACCEPT condstore QResync", cmd2
      assert_equal "RUBY0003 ENABLE UTF8=ACCEPT",                   cmd3
      assert_empty cmdq

      assert_equal %w[CONDSTORE],   result1
      assert_equal %w[UTF8=ACCEPT], result2
      assert_equal [],              result3
    end
  end

  def test_responses
    with_fake_server do |server, imap|
      # responses available before SELECT/EXAMINE
      assert_equal(%w[IMAP4REV1 NAMESPACE MOVE IDLE UTF8=ACCEPT],
                   imap.responses("CAPABILITY", &:last))
      resp = imap.select "INBOX"
      # responses are cleared after SELECT/EXAMINE
      assert_equal(nil, imap.responses("CAPABILITY", &:last))
      assert_equal([Net::IMAP::TaggedResponse, "RUBY0001", "OK"],
                   [resp.class, resp.tag, resp.name])
      assert_equal([172], imap.responses { _1["EXISTS"] })
      assert_equal([3857529045], imap.responses("UIDVALIDITY") { _1 })
      assert_equal(1, imap.responses("RECENT", &:last))
      assert_raise(ArgumentError) do imap.responses("UIDNEXT") end
      # Deprecated style, without a block:
      # assert_warn(/Pass a block.*or.*clear_responses/i) do
      #   assert_equal(%i[Answered Flagged Deleted Seen Draft],
      #                imap.responses["FLAGS"]&.last)
      # end
    end
  end

  def test_clear_responses
    with_fake_server do |server, imap|
      resp = imap.select "INBOX"
      assert_equal([Net::IMAP::TaggedResponse, "RUBY0001", "OK"],
                   [resp.class, resp.tag, resp.name])
      # called with "type", clears and returns only that type
      assert_equal([172],        imap.clear_responses("EXISTS"))
      assert_equal([],           imap.clear_responses("EXISTS"))
      assert_equal([1],          imap.clear_responses("RECENT"))
      assert_equal([3857529045], imap.clear_responses("UIDVALIDITY"))
      # called without "type", clears and returns all responses
      responses = imap.clear_responses
      assert_equal([],   responses["EXISTS"])
      assert_equal([],   responses["RECENT"])
      assert_equal([],   responses["UIDVALIDITY"])
      assert_equal([12], responses["UNSEEN"])
      assert_equal([4392], responses["UIDNEXT"])
      assert_equal(5, responses["FLAGS"].last&.size)
      assert_equal(3, responses["PERMANENTFLAGS"].last&.size)
      assert_equal({}, imap.responses(&:itself))
      assert_equal({}, imap.clear_responses)
    end
  end

  def test_close
    with_fake_server(select: "inbox") do |server, imap|
      resp = imap.close
      assert_equal("RUBY0002 CLOSE", server.commands.pop.raw.strip)
      assert_equal([Net::IMAP::TaggedResponse, "RUBY0002", "OK"],
                   [resp.class, resp.tag, resp.name])
      assert_empty server.commands
    end
  end

  def test_unselect
    with_fake_server(select: "inbox") do |server, imap|
      resp = imap.unselect
      sent = server.commands.pop
      assert_equal(["UNSELECT", nil], [sent.name, sent.args])
      assert_equal([Net::IMAP::TaggedResponse, "RUBY0002", "OK"],
                   [resp.class, resp.tag, resp.name])
      assert_empty server.commands
    end
  end

  private

  def with_fake_server(select: nil, timeout: 5, **opts)
    Timeout.timeout(timeout) do
      server = Net::IMAP::FakeServer.new(timeout: timeout, **opts)
      @threads << Thread.new do server.run end
      tls = opts[:implicit_tls]
      tls = {ca_file: server.config.tls[:ca_file]} if tls == true
      client = Net::IMAP.new("localhost", port: server.port, ssl: tls)
      begin
        if select
          client.select(select)
          server.commands.pop
          assert server.state.selected?
        end
        yield server, client
      ensure
        client.logout rescue pp $!
        client.disconnect if !client.disconnected?
      end
    ensure
      server&.shutdown
    end
  end

  def imaps_test
    server = create_tcp_server
    port = server.addr[1]
    ctx = OpenSSL::SSL::SSLContext.new
    ctx.ca_file = CA_FILE
    ctx.key = File.open(SERVER_KEY) { |f|
      OpenSSL::PKey::RSA.new(f)
    }
    ctx.cert = File.open(SERVER_CERT) { |f|
      OpenSSL::X509::Certificate.new(f)
    }
    ssl_server = OpenSSL::SSL::SSLServer.new(server, ctx)
    started = false
    ths = Thread.start do
      Thread.current.report_on_exception = false # always join-ed
      begin
        started = true
        sock = ssl_server.accept
        begin
          sock.print("* OK test server\r\n")
          sock.gets
          sock.print("* BYE terminating connection\r\n")
          sock.print("RUBY0001 OK LOGOUT completed\r\n")
        ensure
          sock.close
        end
      rescue Errno::EPIPE, Errno::ECONNRESET, Errno::ECONNABORTED
      end
    end
    sleep 0.1 until started
    begin
      begin
        imap = yield(port)
        imap.logout
      ensure
        imap.disconnect if imap
      end
    ensure
      ssl_server.close
      ths.join
    end
  end

  def starttls_test
    server = create_tcp_server
    port = server.addr[1]
    start_server do
      sock = server.accept
      begin
        sock.print("* OK test server\r\n")
        sock.gets
        sock.print("RUBY0001 OK completed\r\n")
        ctx = OpenSSL::SSL::SSLContext.new
        ctx.ca_file = CA_FILE
        ctx.key = File.open(SERVER_KEY) { |f|
          OpenSSL::PKey::RSA.new(f)
        }
        ctx.cert = File.open(SERVER_CERT) { |f|
          OpenSSL::X509::Certificate.new(f)
        }
        sock = OpenSSL::SSL::SSLSocket.new(sock, ctx)
        sock.sync_close = true
        sock.accept
        sock.gets
        sock.print("* BYE terminating connection\r\n")
        sock.print("RUBY0002 OK LOGOUT completed\r\n")
      ensure
        sock.close
        server.close
      end
    end
    begin
      imap = yield(port)
      imap.logout if !imap.disconnected?
    ensure
      imap.disconnect if imap && !imap.disconnected?
    end
  end

  def starttls_stripping_test
    server = create_tcp_server
    port = server.addr[1]
    start_server do
      sock = server.accept
      begin
        sock.print("* OK test server\r\n")
        sock.gets
        sock.print("RUBY0001 BUG unhandled command\r\n")
      ensure
        sock.close
        server.close
      end
    end
    begin
      imap = yield(port)
    ensure
      imap.disconnect if imap && !imap.disconnected?
    end
  end

  def create_tcp_server
    return TCPServer.new(server_addr, 0)
  end

  def server_addr
    Addrinfo.tcp("localhost", 0).ip_address
  end
end
