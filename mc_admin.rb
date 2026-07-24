#!/usr/bin/env ruby

require 'clamp'
require 'json'
require 'rcon'
require 'java-properties'

module MC

  # This is for a default Forge install. Change this if needed.
  SERVER_START_CMD = './run.sh'

  # If you need to change these, you're doing something weird. Good luck!
  SERVER_PROPERTIES = File.join(__dir__, 'server.properties')
  TMUX_SESSION      = File.readlines('.tmux_session').first.strip rescue File.basename(__dir__)

  # Utility module for running the ps command.
  module PSUtil
    class Row
      # This should not be changed, but additional fields may be added if necessary.
      FMT = { pid: '%p', ppid: '%P', cmd: '%c', args: '%a' }
      attr_accessor *(FMT.keys)

      def initialize(arr)
        fields = FMT.keys
        arr.each_with_index { |descriptor, i| self.send("#{fields[i]}=", descriptor.strip) }
      end
    end

    FS  = 31.chr # This low-ASCII control character is the delimiter for the user-defined format.
    CMD = "ps -a -U #{Process.uid} -ww -o " # The ps command with the necessary args.

    class << self
      # Executes the 'ps' command with a user-defined format (which is built using the Row::FMT &
      # FS constants) and returns an Array of Row instances, with each element representing a row
      # of output. The Row attributes are built from its FMT keys. The base set of keys must not
      # be changed, but additional fields could be included if get_server_pid() is modified such
      # that it requires them.
      def run_ps
        fmt = Row::FMT.values.join(FS) # The user-defined format string used for the -o option.
        num = Row::FMT.keys.size       # The number of fields in the output.
        IO.popen(%Q(#{CMD} "#{fmt}")) do |ps_io|
          pid = ps_io.pid
          out = ps_io.readlines
          ps_io.close

          raise AdminError, "ps command failed with #{out.first}." unless $?.success?

          out.shift # Discard the header row
          rows = out.map { |line| Row.new(line.strip.split(FS, num)) }

          # This self-validates that the ps command supports AIX format descriptors.
          ps_cmd = rows.select { |r| r.ppid.to_i == pid }.first
          raise AdminError, 'ps format syntax invalid.' unless ps_cmd&.cmd == 'ps' &&
                                                               ps_cmd&.args =~ /^#{CMD}/

          rows
        end
      end

      # Grabs the first Java PID that is running in the same current working directory as the script
      # running this method. If other Java utilities are run from the same working directory as your
      # Minecraft server, additional filter conditions will need to be added to the select() call in
      # this method.
      def get_server_pid
        (run_ps.select do |row|
          row.cmd == 'java' &&
          (File.readlink("/proc/#{row.pid}/cwd") rescue '') == __dir__
        end).first&.pid&.to_i
      end
    end
  end

  class AdminError < RuntimeError; end

  # This class has private methods for stopping, starting, restarting, and getting the status of a
  # Minecraft server running on Linux. It runs the console under 'tmux' (to give admins easy access
  # access to the console without using RCON), and assumes the admin script will be run from the
  # same directory as the server. Although it houses all of the actual command functionality, it
  # isn't intended to have run() called directly on it. The Admin class later in this file uses
  # this class as an explicit subcommand class for each command.
  class AdminCommand < Clamp::Command
    attr_reader :properties, :rcon_cfg, :pid, :state

    # This is used as a wrapper (via passing a block to super) by the subcommand definitions on
    # the main Admin class. You should not call MC::AdminCommand.run directly.
    def execute
      raise AdminError, 'Invalid command.' unless block_given?

      setup
      yield
      exit(0)
    rescue AdminError => e
      STDERR.puts e.message
      exit(1)
    end

    def running?
      state == :running
    end

    def stopped?
      state == :stopped
    end

    def rcon_enabled?
      properties[:'enable-rcon'].downcase == 'true' ? true : false
    end

    def tmux_installed?
      File.basename(`which tmux`).strip == 'tmux'
    end

    private

    # Checks if tmux is installed, parses the server.properties file, sets up the RCON connection
    # parameters, and then gets the server PID (if any), setting the server state based on that.
    def setup
      raise AdminError, 'tmux is not installed!' unless tmux_installed?

      @properties = JavaProperties.load(MC::SERVER_PROPERTIES)

      @rcon_cfg = {
        host: '127.0.0.1',
        port: properties[:'rcon.port'].to_i,
        password: properties[:'rcon.password'].to_s
      }

      @pid   = MC::PSUtil.get_server_pid
      @state = pid ? :running : :stopped
    rescue Errno::ENOENT
      raise AdminError, 'Could not load server.properties.'
    end

    # Spins up a background thread to watch for a server PID change while yielding to a block that
    # will cause the change. Will raise an AdminError if the PID does not change in 60 seconds, as
    # this indicates some sort of exceptional problem (i.e. the server won't start, or shut down)
    def refresh_pid
      retry_t = nil
      return unless block_given?

      retries = 60 # Feel free to change this if 60 seconds isn't adequate for your server.
      old_pid = pid.dup
      error   = false
      retry_t = Thread.new do
        while !error && old_pid == pid && retries > 0
          @pid = MC::PSUtil.get_server_pid
          retries -= 1
          sleep 1 if retries > 0
        end

        if !error && old_pid == pid
          raise AdminError, "Timed out waiting for server to #{old_pid.nil? ? 'start' : 'stop'}."
        end
      end

      yield
    rescue => e
      error = true
      raise e
    ensure
      retry_t&.join
    end

    # Used by the stop and restart methods to trap signals in order to abort a pending server
    # shutdown or restart.
    def delay_or_abort_shutdown(delay, abort_msg)
      # Do a funky sleep loop here so unhandled signals don't cause the delay
      # to start over.
      begin
        (sleep(delay - delay.floor) && delay = delay.to_i) if delay.is_a?(Float)
        (sleep(1) && delay -= 1) while delay > 0
      rescue SignalException => e
        retry if %w(SIGUSR1 SIGUSR2).include?(e.to_s) # Ignore these signals.

        # If someone does a CTRL-C or if the script gets a signal while it's waiting to shut
        # down the server, send a message about canceling the restart.
        send_message(announce_json(abort_msg), true) if running?
        raise
      end
    end

    # Starts the Minecraft server in a detached tmux session, and waits for the Java process to
    # start. The tmux session will close if the server is stopped or crashes.
    def start(session)
      refresh_pid { tmux_cmd(:new_session, session) }
      @state = :running
    end

    # Stops the Minecraft server using RCON, and waits for the Java process to exit.
    def stop(delay=nil)
      delay = delay.to_f # Just to be safe...

      unless delay == 0.0
        send_message(announce_json('The server is shutting down', delay), true)
        delay_or_abort_shutdown(delay, 'The shutdown has been aborted. Sorry!')
      end

      refresh_pid do
        do_rcon do |rcon|
          rcon.execute('save-all')
          sleep 1
          rcon.execute('stop')
          sleep 1
        end
      end
      @state = :stopped
    end

    # Restarts the Minecraft server.
    def restart(session, delay=nil)
      delay = delay.to_f # Just to be safe...

      unless stopped?
        unless delay == 0.0
          send_message(announce_json('The server is restarting', delay), true)
          delay_or_abort_shutdown(delay, 'The restart has been aborted. Sorry!')
        end

        stop

        # Wait for the tmux session to stop.
        sleep 1 until !tmux_cmd(:list_sessions).include?(session)
      end

      start(session)
    end

    # Gets the server status (and PID if running).
    def status
      puts "Server is #{state}" + (state == :running ? " (PID: #{pid})." : '.')
    end

    # Sends a message to all connected players.
    def send_message(message, is_json=false, color='white')
      json = is_json ? message : ({ text: message, color: color }.to_json)

      do_rcon do |rcon|
        rcon.execute("/tellraw @a #{json}")
      end
    end

    # Sends an arbitrary console command to the server.
    def send_command(cmd, segmented=false, wait=0.0)
      do_rcon do |rcon|
        rcon.execute(cmd, expect_segmented_response: segmented, wait: wait)
      end
    end

    # Used to create announcement raw JSON messages
    def announce_json(msg, delay=nil)
      extra = delay.nil? ? [{ color: 'white', text: msg}] : [
        { color: 'white', text: "#{msg} in " },
        { color: 'aqua',  text: ('%g minutes' % [delay / 60.0]) },
        { color: 'white', text: '. Please log off.'}
      ]

      { color: 'yellow', text: '[SERVER ANNOUNCEMENT] ', extra: extra }.to_json
    end

    # Wrapper for tmux commands. These should be the only ones required, but any additions should
    # be added to this method.
    def tmux_cmd(cmd, session=nil)
      case cmd
        when :attach_session
          exec("tmux attach-session -t #{session}")
        when :new_session
          `tmux new-session -d -s #{session} 'cd #{__dir__} && #{MC::SERVER_START_CMD}'`
        when :list_sessions
          `tmux list-sessions -F '\#{session_name}' 2> /dev/null`.split("\n")
      end
    end

    # RCON client wrapper. Handles authenticating and cleanly closing the session.
    def do_rcon
      client = Rcon::Client.new(**rcon_cfg)
      client.authenticate!(ignore_first_packet: false)
      result = yield client
      client.end_session!
      result
    rescue => e
      raise AdminError, "RCON error received: #{e.message}"
    end
  end

  # This class sets up the actual command-line options used by the script, as the AdminCommand
  # class is not intended to have 'run()' called on it directly.
  class Admin < Clamp::Command
    VERSION = '1.0.0'
    COLORS  = %w(black dark_blue dark_green dark_aqua dark_red dark_purple gold
                 gray dark_gray blue green aqua red light_purple yellow white)

    VALID_COLOR_TEXT = [COLORS[0..7].join(', '), COLORS[8..-1].join(', '),
                       "or a 6-digit hexadecimal code in '#<hex code>' format."]
    COLOR_OPTION_MSG = "Color of plain text message. Ignored for JSON. Valid colors:\n  " +
                       VALID_COLOR_TEXT.join(",\n  ")

    self.description = <<-DESC
      A simple Minecraft (Forge) server administration script. Must be installed and run from the
      current working directory of the server being administered (alongside server.properties),
      the system must have tmux installed, and it needs a version of the ps command that supports
      AIX format descriptors and arbitrary delimiters with the -o option (i.e. all modern Linux
      distributions using procps-ng).
    DESC

    option '--version', :flag, 'Show version.' do
      puts VERSION
      exit(0)
    end

    subcommand 'start', 'Starts the server with tmux.', AdminCommand do
      self.description = <<-DESC
        Starts the Minecraft server (using run.sh, which the Forge installer creates) with tmux
        to allow for easy administration. This assumes the 'nogui' option was added to run.sh, but
        depending on how this script is being run (via cron, etc), it may still function with the
        server GUI enabled.

        By default, this script uses the basename of the current working directory as the tmux
        session name. This can be overridden by putting a different name in a .tmux_session file
        in the Minecraft server root directory alongside this script, or you can use the --session
        option.
      DESC

      option %w(-s --session), 'SESSION', 'The tmux session name.', default: MC::TMUX_SESSION

      def execute
        super do
          raise AdminError, 'Server is already running.' if running?
          start(session)
        end
      end
    end

    subcommand 'stop', 'Broadcasts a message and stops the server.', AdminCommand do
      self.description = <<-DESC
        Stops the Minecraft server using RCON. By default, it sends a server-wide message to warn
        users of the pending shutdown (which happens in 5 minutes by default), before actually
        taking the server down. The tmux session will automatically close upon shutdown.
      DESC

      option %w(-d --delay), 'DELAY', 'Seconds to delay before stopping.', default: 300 do |d|
        Float(d) rescue (raise ArgumentError, "#{d} is not a valid number of seconds.")
      end

      option %w(-n --now), :flag, 'Stop immediately without a message.'

      def execute
        super do
          raise AdminError, 'Server is already stopped.' if stopped?
          raise AdminError, 'RCON is not enabled.' unless rcon_enabled?
          stop(now? ? nil : delay)
        end
      end
    end

    subcommand 'restart', 'Broadcasts a message and restarts the server.', AdminCommand do
      self.description = <<-DESC
        Restarts the Minecraft server. This is functionally identical to using the stop command
        followed by the start command, except that the script will wait for the tmux session to
        close before restarting. Since this command will ignore the stop command if the server is
        already stopped, it is a safe alternative to the start command.

        By default, this script uses the basename of the current working directory as the tmux
        session name. This can be overridden by putting a different name in a .tmux_session file
        in the Minecraft server root directory alongside this script, or you can use the --session
        option.
      DESC

      option %w(-s --session), 'SESSION', 'The tmux session name.', default: MC::TMUX_SESSION

      option %w(-d --delay), 'DELAY', 'Seconds to delay before restarting.', default: 300 do |d|
        f = Float(d) rescue (raise ArgumentError, "#{d} is not a valid number of seconds.")
        raise ArgumentError, 'DELAY cannot be negative.' if f.negative
        f
      end

      option %w(-n --now), :flag, 'Restart immediately without a message.'

      def execute
        super do
          raise AdminError, 'RCON is not enabled.' unless rcon_enabled?
          restart(session, (now? ? nil : delay))
        end
      end
    end

    subcommand 'status', 'Gets the status of the server.', AdminCommand do
      self.description = <<-DESC
        Determines the status of the server (running or stopped), and also returns the PID of the
        server's Java process (if it is running).
      DESC

      def execute
        super { status }
      end
    end

    subcommand 'attach', 'Attaches to the tmux session.', AdminCommand do
      self.description = <<-DESC
        Runs 'tmux attach-session' with the correct session name. Can be overridden.
      DESC

      option %w(-s --session), 'SESSION', 'The tmux session name.', default: MC::TMUX_SESSION

      def execute
        raise AdminError, 'Server is not running.' if stopped?
        tmux_cmd(:attach_session, session)
      end
    end

    subcommand 'send', 'Sends a message to all connected players.', AdminCommand do
      self.description = <<-DESC
        Broadcasts a message to all players connected to the server. By default, it does this in a
        single color (white), which can be changed with the --color option. Alternatively, using
        the --json option allows Minecraft's raw JSON text format to be used for full control of
        the message format.
      DESC

      option %w(-c --color), 'COLOR', COLOR_OPTION_MSG do |c|
        unless COLORS.include?(c) || c =~ /^#[0-9A-Fa-f]{6}$/
          raise ArgumentError, "Invalid color specified. Valid colors:\n\t" +
                               VALID_COLOR_TEXT.join(",\n\t")
        end
      end

      option %w(-j --json), :flag, 'Message is in raw JSON text format. COLOR will be ignored.'

      parameter 'MESSAGE', 'The message to send.'

      def execute
        super do
          raise AdminError, 'Server is not running.' unless running?
          raise AdminError, 'RCON is not enabled.' unless rcon_enabled?
          send_message(message, json?, color)
        end
      end
    end

    subcommand 'rcon', 'Send an arbitrary command to the server over RCON.', AdminCommand do
      self.description = <<-DESC
        Immediately sends a command to the server over RCON. There is no filtering or confirmation,
        so USE WITH CAUTION.
      DESC

      option %w(-s --segmented), :flag, 'Expect the server to send a segmented response.'

      option %w(-w --wait), 'WAIT', "How many seconds to wait after sending the trash packet.\n" +
                                    'Ignored for non-segmented responses.', default: 0.0 do |w|
        f = Float(w) rescue (raise ArgumentError, "#{w} is not a valid number of seconds.")
        raise ArgumentError, 'WAIT cannot be negative.' if f.negative?
        f
      end

      parameter 'COMMAND', 'The command to send.'

      def execute
        super do
          raise AdminError, 'Server is not running.' unless running?
          raise AdminError, 'RCON is not enabled.' unless rcon_enabled?
          puts send_command(command, segmented?, wait).body
        end
      end
    end
  end
end

# When being run directly
MC::Admin.run if File.expand_path(__FILE__) == File.expand_path($0)
