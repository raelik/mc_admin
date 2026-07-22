#!/usr/bin/env ruby

require 'clamp'
require 'json'
require 'rcon'
require 'java-properties'

module MC

  class AdminError < RuntimeError; end

  # This class has private methods for stopping, starting, restarting, and getting the status of
  # a Minecraft server running on Linux. It runs the console under 'tmux' (to allow admins easy
  # access to the console without using RCON), and assumes the admin script will be run from the
  # same directory as the server. Although it houses all of the actual command functionality, it
  # isn't intended to have run() called directly on it. The Admin class later in this file uses
  # this class as an explicit subcommand class for each command.
  class AdminCommand < Clamp::Command

    # These should not be changed, but additional fields may be added to PS_COLS if necessary.
    PS_COLS = { pid: '%p', ppid: '%P', cmd: '%c', args: '%a' }.freeze
    SERVER_PROPERTIES = File.join(__dir__, 'server.properties').freeze

    FS = 31.chr # This low-ASCII control character is used as a delimiter for the ps command.

    attr_reader :properties, :rcon, :pid, :state

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

    # Executes the 'ps' command with a user-defined format (which is set using the FS and PS_COLS
    # constants) and returns an Array of Hashes, with each Array element representing a row of
    # output. The Hash keys are the same as the PS_COLS keys. These must not be changed, but
    # additional fields could be included if the get_server_pid() method needs them.
    def run_ps_cmd
      cols = PS_COLS.keys
      fmt  = PS_COLS.values.join(FS)
      cmd  = "ps -a -U #{Process.uid} -ww -o "
      IO.popen(%Q(#{cmd} "#{fmt}")) do |ps_io|
        pid = ps_io.pid
        out = ps_io.readlines
        ps_io.close

        raise AdminError, "ps command failed with #{out.first}." unless $?.success?

        result = out[1..-1].map do |line|
          Hash[cols.zip(line.lstrip.split(FS, cols.size).map(&:strip))]
        end

        ps_cmd = result.select { |r| r[:ppid].to_i == pid }.first
        raise AdminError, 'ps user-defined format syntax invalid.' unless ps_cmd&.dig(:args) =~ /^#{cmd}/

        result
      end
    end

    # Grabs the first Java PID that is running in the same current working directory as the script
    # running this method. If other Java utilities are run from the same working directory as your
    # Minecraft server, additional filter conditions will need to be added to the select() call in
    # this method.
    def get_server_pid
      (run_ps_cmd.select do |row|
        # Filter out the current process PID just in case you're running this with jRuby.
        Process.pid != row[:pid].to_i && row[:cmd] == 'java' &&
        (File.readlink("/proc/#{row[:pid]}/cwd") rescue '') == __dir__
      end).first&.dig(:pid)&.to_i
    end

    private

    # Checks if tmux is installed, parses the server.properties file, sets up the RCON connection
    # parameters, and then gets the server PID (if any), setting the server state based on that.
    def setup
      raise AdminError, 'tmux is not installed!' unless tmux_installed?

      @properties = JavaProperties.load(SERVER_PROPERTIES)

      @rcon = {
        host: '127.0.0.1',
        port: properties[:'rcon.port'].to_i,
        password: properties[:'rcon.password'].to_s
      }

      @pid   = get_server_pid
      @state = pid ? :running : :stopped
    rescue Errno::ENOENT
      raise AdminError, 'Could not load server.properties.'
    end

    # Spins up a background thread to watch for a server PID change. Will raise an AdminError
    # if the PID does not change in 60 seconds, as this indicates some sort of exceptional
    # problem (i.e. the server will not start, or shut down)
    def refresh_pid
      prev_pid = pid.dup
      retries = 60
      Thread.new do
        while retries > 0
          @pid = get_server_pid
          retries -= (prev_pid == pid ? 1 : 60)
          sleep 1
        end

        if prev_pid == pid
          raise AdminError, "Timed out waiting for server to #{prev_pid.nil? ? 'start' : 'stop'}."
        end
      end
    end

    # Starts the Minecraft server in a detached tmux session, and waits for the Java process to
    # start. The tmux session will close if the server is stopped or crashes. The name of the
    # session is the same as the current working directory name.
    def start(session)
      thread = refresh_pid
      tmux_cmd(:new_session, session)

      thread.join
      @state = :running
    end

    # Stops the Minecraft server using RCON, and waits for the Java process to exit.
    def stop(delay=nil)
      unless delay.to_f == 0.0
        send_message(announce_json('The server is shutting down'), true)
        sleep delay
      end

      thread = refresh_pid
      do_rcon do |rcon|
        rcon.execute('save-all')
        sleep 1
        rcon.execute('stop')
        sleep 1
      end

      thread.join
      @state = :stopped
    end

    def restart(session, delay=nil)
      unless delay.to_f == 0.0
        send_message(announce_json('The server is restarting'), true)
        sleep delay
      end

      stop unless stopped?

      # Wait for the tmux session to stop.
      while tmux_cmd(:list_sessions).include?(session) do
        sleep 1
      end

      start(session)
    end

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

    # Used to create the stop/restart announce raw JSON text format
    def announce_json(msg)
      { color: 'yellow', text: '[SERVER ANNOUNCEMENT] ', extra: [
        { color: 'white', text: "#{msg} in " },
        { color: 'aqua', text: (delay / 60.0).to_s },
        { color: 'white', text: ' minutes. Please log off.'} ] }.to_json
    end

    # Wrapper for tmux commands. These should be the only ones required, but any additions should
    # be added to this method. If you're running a non-Forge server, or have your own custom server
    # start script, feel free to change 'run.sh' to a different command for :new_session.
    def tmux_cmd(cmd, session=nil)
      case cmd
        when :new_session
          `tmux new-session -d -s #{session} 'cd #{__dir__} && ./run.sh'`
        when :list_sessions
          `tmux list-sessions -F '\#{session_name}' 2> /dev/null`.split("\n")
      end
    end

    # RCON client wrapper. Handles authenticating and cleanly closing the session.
    def do_rcon
      client = Rcon::Client.new(**rcon)
      client.authenticate!(ignore_first_packet: false)
      result = yield client
      client.end_session!
      result
    rescue => e
      raise AdminError, "RCON error received: #{e.message}"
    end
  end

  # This class sets up the actual command-line options used by the script, as the AdminCommand
  # class is not intended to be run directly.
  class Admin < Clamp::Command
    VERSION = '1.0.0'
    COLORS  = %w(black dark_blue dark_green dark_aqua dark_red dark_purple gold
                 gray dark_gray blue green aqua red light_purple yellow white).freeze

    TMUX_SESSION     = File.readlines('.tmux_session').first.strip rescue File.basename(__dir__)
    VALID_COLOR_TEXT = [COLORS[0..7].join(', '), COLORS[8..-1].join(', '),
                       "or a 6-digit hexadecimal code in '#<hex code>' format."].freeze
    COLOR_OPTION_MSG = "Color of plain text message. Ignored for JSON. Valid colors:\n  " +
                       VALID_COLOR_TEXT.join(",\n  ")

    self.description = <<-DESC
      A simple Minecraft (Forge) server administration script. Must be installed and run from the
      current working directory of the server being administered (alongside server.properties),
      and the system must have tmux installed and have a version of the ps command that supports
      AIX format descriptors in the -o option (i.e. all modern Linux distributions).
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

      option ['-s', '--session'], 'SESSION', 'The tmux session name.', default: TMUX_SESSION

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

      option ['-d', '--delay'], 'DELAY', 'Seconds to delay before stopping.', default: 300 do |d|
        Float(d) rescue (raise ArgumentError, "#{d} is not a valid number of seconds.")
      end

      option ['-n', '--now'], :flag, 'Stop immediately without a message.'

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

      option ['-s', '--session'], 'SESSION', 'The tmux session name.', default: TMUX_SESSION

      option ['-d', '--delay'], 'DELAY', 'Seconds to delay before restarting.', default: 300 do |d|
        Float(d) rescue (raise ArgumentError, "#{d} is not a valid number of seconds.")
      end

      option ['-n', '--now'], :flag, 'Restart immediately without a message.'

      def execute
        super do
          raise AdminError, 'RCON is not enabled.' unless rcon_enabled?
          restart(session, (now? ? nil : delay))
        end
      end
    end

    subcommand 'status', 'Gets the status of the server.', AdminCommand do
      self.description = <<-DESC
        Determines the status of the server (running or stopped), and also returns the PID if it is running.
      DESC

      def execute
        super { status }
      end
    end

    subcommand 'send', 'Sends a message to all connected players.', AdminCommand do
      self.description = <<-DESC
        Broadcasts a message to all players connected to the server. By default, it does this in a
        single color (white), which can be changed with the --color option. Alternatively, using
        the --json option allows Minecraft's raw JSON text format to be used for full control of
        the message format.
      DESC

      option ['-c', '--color'], 'COLOR', COLOR_OPTION_MSG do |c|
        unless COLORS.include?(c) || c =~ /^#[0-9A-Fa-f]{6}$/
          raise ArgumentError, "Invalid color specified. Valid colors:\n\t" +
                               VALID_COLOR_TEXT.join(",\n\t")
        end
      end

      option ['-j', '--json'], :flag, 'Message is in raw JSON text format. COLOR will be ignored.'

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
        Immediately sends a command to the server over RCON. There is no filtering or confirmation, so USE WITH CAUTION.
      DESC

      option ['-s', '--segmented'], :flag, 'Expect the server to send a segmented response for this command.'

      option ['-w', '--wait'], 'WAIT', "How many seconds to wait after sending the trash packet. This only\n" +
                                       'applies to segmented responses.', default: 0.0 do |w|
        Float(w) rescue (raise ArgumentError, "#{w} is not a valid number of seconds.")
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
