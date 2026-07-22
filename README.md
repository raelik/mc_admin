# mc_admin.rb

```
Usage:
    mc_admin.rb [OPTIONS] SUBCOMMAND [ARG] ...

  A simple Minecraft (Forge) server administration script. Must be installed and run from the
  current working directory of the server being administered (alongside server.properties),
  and the system must have tmux installed and have a version of the ps command that supports
  AIX format descriptors in the -o option (i.e. all modern Linux distributions).

Parameters:
    SUBCOMMAND    subcommand
    [ARG] ...     subcommand arguments

Subcommands:
    start         Starts the server with tmux.
    stop          Broadcasts a message and stops the server.
    restart       Broadcasts a message and restarts the server.
    status        Gets the status of the server.
    send          Sends a message to all connected players.
    rcon          Send an arbitrary command to the server over RCON.

Options:
    --version     Show version.
    -h, --help    print help
```

---

## Overview

I created `mc_admin.rb` as a simpler alternative to [MSCS](https://github.com/MinecraftServerControl/mscs), primarily for my own use and gratification (as a long time Rubyist, I much prefer working with Ruby instead of shell scripts that call out to Perl and Python), but also because MSCS has a ton of features that I simply didn't need.

I wanted something that I could use to set up a simple cronjob to restart a single Minecraft server (and start it on boot using `@reboot` in the crontab), and I wanted the server console to run under `tmux` so I could still directly interact with it in that way. I also wanted it to simply not try to do EVERYTHING. I can download the Forge/Fabric/etc installer myself, I just wanted a script I could drop in the server folder to do what I  need.

## Dependencies

Unlike some other packages, `mc_admin.rb` makes no hard assumptions about how you're going to run it. As such, the only real dependencies are these:

- Some sort of \*NIX host with a `ps` command that accepts AIX-style format descriptors when using the `-o` options (such as `%p`, `%P`, `%c`, etc) as well as accept arbitrary characters as delimeters. This should include every modern Linux distro and \*NIX OS that uses the `procps-ng` package.

- The `tmux` command. Any moderately recent version should do.

- Ruby 3.0 or higher, in some shape or form (installed on the system, `chruby`, `rvm`, `asdf`, etc). I tested it with Ruby 3.3.9, it will almost certainly work on 3.4 or maybe even 4.0. It may even work with jRuby 9.4 or higher.

- The gems listed in the `Gemfile`. I recommend using Bundler to install these, but you don't have to. There are only four: `clamp`, `json`, `rconrb`, and `java-properties`.

- RCON needs to be enabled in your `server.properties`. Make sure `enable-rcon` is set to `true`, and that your `rcon.port` and `rcon.password` are set. The script will read these values automatically from the file. 

## Setup

Depending on your needs and how you installed the gem dependencies, you just need to drop `mc_admin.rb` into your Minecraft server directory. However, there are some considerations and possibly changes you'll need to make (or create additional scripts) depending on how you intend to use it.

For instance, if you plan on running it via cron, and you're using some sort of Ruby version manager (like `chruby`), you'll probably want a simple shell script to ensure your `chruby` environment is correctly set. Here's an example of one (mine, in fact):

```bash
#!/bin/bash
RUBY_VERSION=3.3.9

cd "$(dirname "$0")"
/usr/local/bin/chruby-exec $RUBY_VERSION -- bundle exec mc_admin.rb "$@"
```

I called this `mc_admin.sh`, and dropped it in my Minecraft server directory along with `mc_admin.rb`. Beforehand, I used `ruby-install` to install Ruby 3.3.9, ran `chruby` to switch to it, and did a `bundle install` to grab the gems. I have a `@reboot` crontab entry that calls `/home/mc_user/<modpack>/mc_admin.sh start` for each modpack instance I'm running, and another that does a restart at 5 AM. YMMV, depending on your setup.

Another consideration to make is exactly where your `server.properties` file is in relation to the directory that you run the Java command that starts your server. They SHOULD be the same place, but some people have very strange setups. The location of  `server.properties` is flexible in `mc_admin.rb` (the `SERVER_PROPERTIES` constant in the script can be changed), but the Java command's current working directory is not. This MUST be where you place `mc_admin.rb`, as that is one of the things it uses to pick out the correct server PID. You CAN change this if you really need to, by digging into the `get_server_pid` method.

The last thing you may need to consider is the tmux session name that `mc_admin.rb` uses when starting or restarting the server. By default, it uses the basename of the directory the script lives in, so if your server is in `/home/mcuser/Minecraft_Server`, the tmux session will be `Minecraft_Server`. This would only really be a problem if you were running a server directly out of a `.minecraft` folder. You have two solutions for this: put a different session name in a file called `.tmux_session` in your Minecraft server directory, OR you can specify the session name with `--session` when running the `start` or `restart` commands. This is detailed in `--help` for those commands (e.g. `./mc_admin start --help` and `./mc_admin restart --help`).
