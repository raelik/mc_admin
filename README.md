# mc_admin.rb

```
Usage:
    mc_admin.rb [OPTIONS] SUBCOMMAND [ARG] ...

  A simple Minecraft (Forge) server administration script. Must be installed and run from the
  current working directory of the server being administered (alongside server.properties),
  the system must have tmux installed, and it needs a version of the ps command that supports
  AIX format descriptors and arbitrary delimiters with the -o option (i.e. all modern Linux
  distributions using procps-ng).

Parameters:
    SUBCOMMAND    subcommand
    [ARG] ...     subcommand arguments

Subcommands:
    start         Starts the server with tmux.
    stop          Broadcasts a message and stops the server.
    restart       Broadcasts a message and restarts the server.
    status        Gets the status of the server.
    attach        Attaches to the tmux session.
    send          Sends a message to all connected players.
    rcon          Send an arbitrary command to the server over RCON.

Options:
    --version     Show version.
    -h, --help    print help
```

<details>

<summary><h3>Subcommand Help</h3></summary>

```
$ ./mc_admin.rb start --help
Usage:
    mc_admin.rb start [OPTIONS]

  Starts the Minecraft server (using run.sh, which the Forge installer creates) with tmux
  to allow for easy administration. This assumes the 'nogui' option was added to run.sh, but
  depending on how this script is being run (via cron, etc), it may still function with the
  server GUI enabled.

  By default, this script uses the basename of the current working directory as the tmux
  session name. This can be overridden by putting a different name in a .tmux_session file
  in the Minecraft server root directory alongside this script, or you can use the --session
  option.

Options:
    -s, --session SESSION    The tmux session name. (default: "MC_Server")
    -h, --help               print help
```

```
$ ./mc_admin.rb stop --help
Usage:
    mc_admin.rb stop [OPTIONS]

  Stops the Minecraft server using RCON. By default, it sends a server-wide message to warn
  users of the pending shutdown (which happens in 5 minutes by default), before actually
  taking the server down. The tmux session will automatically close upon shutdown.

Options:
    -d, --delay DELAY    Seconds to delay before stopping. (default: 300)
    -n, --now            Stop immediately without a message.
    -h, --help           print help
```

```
$ ./mc_admin.rb restart --help
Usage:
    mc_admin.rb restart [OPTIONS]

  Restarts the Minecraft server. This is functionally identical to using the stop command
  followed by the start command, except that the script will wait for the tmux session to
  close before restarting. Since this command will ignore the stop command if the server is
  already stopped, it is a safe alternative to the start command.

  By default, this script uses the basename of the current working directory as the tmux
  session name. This can be overridden by putting a different name in a .tmux_session file
  in the Minecraft server root directory alongside this script, or you can use the --session
  option.

Options:
    -s, --session SESSION    The tmux session name. (default: "MC_Server")
    -d, --delay DELAY        Seconds to delay before restarting. (default: 300)
    -n, --now                Restart immediately without a message.
    -h, --help               print help
```

```
$ ./mc_admin.rb status --help
Usage:
    mc_admin.rb status [OPTIONS]

  Determines the status of the server (running or stopped), and also returns the PID of the
  server's Java process (if it is running).

Options:
    -h, --help    print help
```

```
$ ./mc_admin.rb attach --help
Usage:
    mc_admin.rb attach [OPTIONS]

  Runs 'tmux attach-session' with the correct session name. Can be overridden.

Options:
    -s, --session SESSION    The tmux session name. (default: "MC_Server")
    -h, --help               print help
```

```
$ ./mc_admin.rb send --help
Usage:
    mc_admin.rb send [OPTIONS] MESSAGE

  Broadcasts a message to all players connected to the server. By default, it does this in a
  single color (white), which can be changed with the --color option. Alternatively, using
  the --json option allows Minecraft's raw JSON text format to be used for full control of
  the message format.

Parameters:
    MESSAGE              The message to send.

Options:
    -c, --color COLOR    Color of plain text message. Ignored for JSON. Valid colors:
                           black, dark_blue, dark_green, dark_aqua, dark_red, dark_purple, gold, gray,
                           dark_gray, blue, green, aqua, red, light_purple, yellow, white,
                           or a 6-digit hexadecimal code in '#<hex code>' format.
    -j, --json           Message is in raw JSON text format. COLOR will be ignored.
    -h, --help           print help
```

```
$ ./mc_admin.rb rcon --help
Usage:
    mc_admin.rb rcon [OPTIONS] COMMAND

  Immediately sends a command to the server over RCON. There is no filtering or confirmation,
  so USE WITH CAUTION.

Parameters:
    COMMAND            The command to send.

Options:
    -s, --segmented    Expect the server to send a segmented response.
    -w, --wait WAIT    How many seconds to wait after sending the trash packet.
                       Ignored for non-segmented responses. (default: 0.0)
    -h, --help         print help
```

</details>

---

## Overview

I created `mc_admin.rb` as a simpler alternative to [MSCS](https://github.com/MinecraftServerControl/mscs), primarily for my own use and gratification (as a long time Rubyist, I much prefer working with Ruby instead of shell scripts that call out to Perl and Python), but also because MSCS has a ton of features that I simply didn't need.

I wanted something that I could use to set up a simple cronjob to restart a single Minecraft server (and start it on boot using `@reboot` in the crontab), and I wanted the server console to run under `tmux` so I could still directly interact with it in that way. I also wanted it to simply not try to do EVERYTHING. I can download the Forge/Fabric/etc installer myself, I just wanted a script I could drop in the server folder to do what I  need.

## Dependencies

Unlike some other packages, `mc_admin.rb` makes no hard assumptions about how you're going to run it. As such, the only real dependencies are these:

- A Linux host with a `ps` command with the `-o` option that accepts AIX format descriptors (such as `%p`, `%P`, `%c`, etc) and allows arbitrary characters as delimeters. This should include every modern Linux distro that uses the `procps-ng` package.

- The `tmux` command. Any moderately recent version should do.

- Ruby 3.0 or higher, in some shape or form (installed on the system, `chruby`, `rvm`, `asdf`, etc). I tested it with Ruby 3.3.9, it will almost certainly work on 3.4 or maybe even 4.0.

- The gems listed in the `Gemfile`. I recommend using Bundler to install these, but you don't have to. There are only four: `clamp`, `json`, `rconrb`, and `java-properties`.

- RCON needs to be enabled in the `server.properties` file. Make sure `enable-rcon` is set to `true`, and that your `rcon.port` and `rcon.password` are set. The script will read these values automatically from the file. 

## Setup

Depending on your needs and how you installed the gem dependencies, you just need to drop `mc_admin.rb` into your Minecraft server directory. However, there are some considerations and possibly changes you'll need to make (or create additional scripts) depending on how you intend to use it.

### Version Managers
If you plan on running it via cron, and you're using some sort of Ruby version manager (like `chruby`), you'll probably want a simple shell script to ensure your `chruby` environment is correctly set. Here's an example of one (mine, in fact):

```bash
#!/bin/bash
RUBY_VERSION=3.3.9

cd "$(dirname "$0")"
/usr/local/bin/chruby-exec $RUBY_VERSION -- bundle exec mc_admin.rb "$@"
```

I called this `mc_admin.sh`, and dropped it in my Minecraft server directory along with `mc_admin.rb`. Beforehand, I used `ruby-install` to install Ruby 3.3.9, ran `chruby` to switch to it, and did a `bundle install` to grab the gems. I have a `@reboot` crontab entry that calls `/home/mc_user/<modpack>/mc_admin.sh start` for each modpack instance I'm running, and another that does a restart at 5 AM. I also needed to add `SHELL=/bin/bash` to my crontab. YMMV, depending on your setup and exactly which version manager you're using.

### Script Location
Another consideration to make is exactly where your `server.properties` file is in relation to the directory that you run the Java command that starts your server. They SHOULD be the same place, but some people have very strange setups. The location of  `server.properties` is flexible in `mc_admin.rb` (the `SERVER_PROPERTIES` constant in the script can be changed), but the Java command's current working directory is not. This MUST be where you place `mc_admin.rb`, as that is one of the things it uses to pick out the correct server PID. You CAN change this if you really need to, by modifying the `get_server_pid` method in the MC::PSUtil module.

### Non-Forge Servers
This script assumes you're using Forge and expects a `run.sh` script to be present in the server directory. If you're using something else, this is easily fixed by changing the `SERVER_START_CMD` constant in the script.

### Session Names
The last thing you may need to consider is the tmux session name that `mc_admin.rb` uses when starting or restarting the server. By default, it uses the basename of the directory the script lives in, so if your server is in `/home/mcuser/Minecraft_Server`, the tmux session will be `Minecraft_Server`. This would only really be a problem if you were running a server directly out of a `.minecraft` folder. You have two solutions for this: put a different session name in a file called `.tmux_session` in your Minecraft server directory, OR you can specify the session name with `--session` when running the `start`, `restart`, or `attach` subcommands. This is detailed in `--help` for those commands (e.g. `./mc_admin start --help`, `./mc_admin restart --help`, and `./mc_admin.rb attach --help`).
