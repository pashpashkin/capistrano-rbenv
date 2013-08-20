require "capistrano-rbenv/version"
require "capistrano/configuration"
require "capistrano/configuration/resources/platform_resources"
require "capistrano/recipes/deploy/scm"

module Capistrano
  module RbEnv
    def self.extended(configuration)
      configuration.load {
        namespace(:rbenv) {
          _cset(:rbenv_root, "$HOME/.rbenv")
          _cset(:rbenv_path) {
            # expand to actual path since rbenv may be executed by users other than `:user`.
            capture("echo #{rbenv_root.dump}").strip
          }
          _cset(:rbenv_bin_path) { File.join(rbenv_path, "bin") }
          _cset(:rbenv_shims_path) { File.join(rbenv_path, "shims") }
          _cset(:rbenv_bin) {
            File.join(rbenv_bin_path, "rbenv")
          }
          def rbenv_command(options={})
            environment = _merge_environment(rbenv_environment, options.fetch(:env, {}))
            environment["RBENV_VERSION"] = options[:version] if options.key?(:version)
            if environment.empty?
              rbenv_bin
            else
              env = (["env"] + environment.map { |k, v| "#{k}=#{v.dump}" }).join(" ")
              "#{env} #{rbenv_bin}"
            end
          end
          _cset(:rbenv_cmd) { rbenv_command(:version => rbenv_ruby_version) } # this declares RBENV_VERSION.
          _cset(:rbenv_environment) {{
            "RBENV_ROOT" => rbenv_path,
            "PATH" => [ rbenv_shims_path, rbenv_bin_path, "$PATH" ].join(":"),
          }}
          _cset(:rbenv_repository, "https://github.com/sstephenson/rbenv.git")
          _cset(:rbenv_branch, "master")

          _cset(:rbenv_plugins) {{
            "ruby-build" => { :repository => "https://github.com/sstephenson/ruby-build.git", :branch => "master" },
          }}
          _cset(:rbenv_plugins_options, {}) # for backward compatibility. plugin options can be configured from :rbenv_plugins.
          _cset(:rbenv_plugins_path) {
            File.join(rbenv_path, 'plugins')
          }
          _cset(:rbenv_ruby_version, "1.9.3-p392")

          _cset(:rbenv_install_bundler) {
            if exists?(:rbenv_use_bundler)
              logger.info(":rbenv_use_bundler has been deprecated. use :rbenv_install_bundler instead.")
              fetch(:rbenv_use_bundler, true)
            else
              true
            end
          }
          set(:bundle_cmd) { # override bundle_cmd in "bundler/capistrano"
            rbenv_install_bundler ? "#{rbenv_cmd} exec bundle" : "bundle"
          }

          _cset(:rbenv_install_dependencies) {
            if rbenv_ruby_dependencies.empty?
              false
            else
              not(platform.packages.installed?(rbenv_ruby_dependencies))
            end
          }

          desc("Setup rbenv.")
          task(:setup, :except => { :no_release => true }) {
            #
            # skip installation if the requested version has been installed.
            #
            reset!(:rbenv_ruby_versions)
            begin
              installed = rbenv_ruby_versions.include?(rbenv_ruby_version)
            rescue
              installed = false
            end
            _setup unless installed
            configure if rbenv_setup_shell
            rbenv.global(rbenv_ruby_version) if fetch(:rbenv_setup_global_version, true)
            setup_bundler if rbenv_install_bundler
          }
          after "deploy:setup", "rbenv:setup"

          task(:_setup, :except => { :no_release => true }) {
            dependencies if rbenv_install_dependencies
            update
            build
          }

          def _update_repository(destination, options={})
            configuration = Capistrano::Configuration.new()
            options = {
              :source => proc { Capistrano::Deploy::SCM.new(configuration[:scm], configuration) },
              :revision => proc { configuration[:source].head },
              :real_revision => proc {
                configuration[:source].local.query_revision(configuration[:revision]) { |cmd| with_env("LC_ALL", "C") { run_locally(cmd) } }
              },
            }.merge(options)
            variables.merge(options).each do |key, val|
              configuration.set(key, val)
            end
            source = configuration[:source]
            revision = configuration[:real_revision]
            #
            # we cannot use source.sync since it cleans up untacked files in the repository.
            # currently we are just calling git sub-commands directly to avoid the problems.
            #
            verbose = configuration[:scm_verbose] ? nil : "-q"
            run((<<-EOS).gsub(/\s+/, ' ').strip)
              if [ -d #{destination} ]; then
                cd #{destination} &&
                #{source.command} fetch #{verbose} #{source.origin} &&
                #{source.command} fetch --tags #{verbose} #{source.origin} &&
                #{source.command} reset #{verbose} --hard #{revision};
              else
                #{source.checkout(revision, destination)};
              fi
            EOS
          end

          desc("Update rbenv installation.")
          task(:update, :except => { :no_release => true }) {
            _update_repository(rbenv_path, :scm => :git, :repository => rbenv_repository, :branch => rbenv_branch)
            plugins.update
          }

          _cset(:rbenv_setup_default_environment) {
            if exists?(:rbenv_define_default_environment)
              logger.info(":rbenv_define_default_environment has been deprecated. use :rbenv_setup_default_environment instead.")
              fetch(:rbenv_define_default_environment, true)
            else
              true
            end
          }
          # workaround for loading `capistrano-rbenv` later than `capistrano/ext/multistage`.
          # https://github.com/yyuu/capistrano-rbenv/pull/5
          if top.namespaces.key?(:multistage)
            after "multistage:ensure", "rbenv:setup_default_environment"
          else
            on :load do
              if top.namespaces.key?(:multistage)
                # workaround for loading `capistrano-rbenv` earlier than `capistrano/ext/multistage`.
                # https://github.com/yyuu/capistrano-rbenv/issues/7
                after "multistage:ensure", "rbenv:setup_default_environment"
              else
                setup_default_environment
              end
            end
          end

          _cset(:rbenv_environment_join_keys, %w(DYLD_LIBRARY_PATH LD_LIBRARY_PATH MANPATH PATH))
          def _merge_environment(x, y)
            x.merge(y) { |key, x_val, y_val|
              if rbenv_environment_join_keys.include?(key)
                ( y_val.split(":") + x_val.split(":") ).uniq.join(":")
              else
                y_val
              end
            }
          end

          task(:setup_default_environment, :except => { :no_release => true }) {
            if rbenv_setup_default_environment
              set(:default_environment, _merge_environment(default_environment, rbenv_environment))
            end
          }

          desc("Purge rbenv.")
          task(:purge, :except => { :no_release => true }) {
            run("rm -rf #{rbenv_path.dump}")
          }

          namespace(:plugins) {
            desc("Update rbenv plugins.")
            task(:update, :except => { :no_release => true }) {
              rbenv_plugins.each do |name, repository|
                # for backward compatibility, obtain plugin options from :rbenv_plugins_options first
                options = rbenv_plugins_options.fetch(name, {})
                options = options.merge(Hash === repository ? repository : {:repository => repository})
                _update_repository(File.join(rbenv_plugins_path, name), options.merge(:scm => :git))
              end
            }
          }

          _cset(:rbenv_configure_home) { capture("echo $HOME").chomp }
          _cset(:rbenv_configure_shell) { capture("echo $SHELL").chomp }
          _cset(:rbenv_configure_files) {
            if fetch(:rbenv_configure_basenames, nil)
              [ rbenv_configure_basenames ].flatten.map { |basename|
                File.join(rbenv_configure_home, basename)
              }
            else
              bash_profile = File.join(rbenv_configure_home, '.bash_profile')
              profile = File.join(rbenv_configure_home, '.profile')
              case File.basename(rbenv_configure_shell)
              when /bash/
                [ capture("test -f #{profile.dump} && echo #{profile.dump} || echo #{bash_profile.dump}").chomp ]
              when /zsh/
                [ File.join(rbenv_configure_home, '.zshenv') ]
              else # other sh compatible shell such like dash
                [ profile ]
              end
            end
          }
          _cset(:rbenv_configure_script) {
            (<<-EOS).gsub(/^\s*/, '')
              # Configured by capistrano-rbenv. Do not edit directly.
              export PATH=#{[ rbenv_bin_path, "$PATH"].join(":").dump}
              eval "$(rbenv init -)"
            EOS
          }

          def _do_update_config(script_file, file, tempfile)
            execute = []
            ## (1) ensure copy source file exists
            execute << "( test -f #{file.dump} || touch #{file.dump} )"
            ## (2) copy originao config to temporary file
            execute << "rm -f #{tempfile.dump}" # remove tempfile to preserve permissions of original file
            execute << "cp -fp #{file.dump} #{tempfile.dump}" 
            ## (3) modify temporary file
            execute << "sed -i -e '/^#{Regexp.escape(rbenv_configure_signature)}/,/^#{Regexp.escape(rbenv_configure_signature)}/d' #{tempfile.dump}"
            execute << "echo #{rbenv_configure_signature.dump} >> #{tempfile.dump}"
            execute << "cat #{script_file.dump} >> #{tempfile.dump}"
            execute << "echo #{rbenv_configure_signature.dump} >> #{tempfile.dump}"
            ## (4) update config only if it is needed
            execute << "cp -fp #{file.dump} #{(file + ".orig").dump}"
            execute << "( diff -u #{file.dump} #{tempfile.dump} || mv -f #{tempfile.dump} #{file.dump} )"
            run(execute.join(" && "))
          end

          def _update_config(script_file, file)
            begin
              tempfile = capture("mktemp /tmp/rbenv.XXXXXXXXXX").strip
              _do_update_config(script_file, file, tempfile)
            ensure
              run("rm -f #{tempfile.dump}") rescue nil
            end
          end

          _cset(:rbenv_setup_shell) {
            if exists?(:rbenv_use_configure)
              logger.info(":rbenv_use_configure has been deprecated. please use :rbenv_setup_shell instead.")
              fetch(:rbenv_use_configure, true)
            else
              true
            end
          }
          _cset(:rbenv_configure_signature, '##rbenv:configure')
          task(:configure, :except => { :no_release => true }) {
            begin
              script_file = capture("mktemp /tmp/rbenv.XXXXXXXXXX").strip
              top.put(rbenv_configure_script, script_file)
              [ rbenv_configure_files ].flatten.each do |file|
                _update_config(script_file, file)
              end
            ensure
              run("rm -f #{script_file.dump}") rescue nil
            end
          }

          _cset(:rbenv_platform) { fetch(:platform_identifier) }
          _cset(:rbenv_ruby_dependencies) {
            case rbenv_platform.to_sym
            when :debian, :ubuntu
              %w(git-core build-essential libreadline6-dev zlib1g-dev libssl-dev bison)
            when :redhat, :fedora, :centos, :amazon, :amazonami
              %w(git autoconf gcc-c++ glibc-devel patch readline readline-devel zlib zlib-devel openssl openssl-devel bison)
            else
              []
            end
          }
          task(:dependencies, :except => { :no_release => true }) {
            begin
              platform.packages.install(rbenv_ruby_dependencies)
            rescue
              missing_dependencies = rbenv_ruby_dependencies.reject { |dep| platform.packages.installed?(dep) rescue false }
              abort("Failed to install rbenv dependencies: #{missing_dependencies.join(", ")}\n\n" +
                    "Please install missing packages from outside of Capistrano, or allow #{user} to invoke commands via sudo(8).")
            end
          }

          _cset(:rbenv_ruby_versions) { rbenv.versions }
          desc("Build ruby within rbenv.")
          task(:build, :except => { :no_release => true }) {
#           reset!(:rbenv_ruby_versions)
            ruby = fetch(:rbenv_ruby_cmd, "ruby")
            if rbenv_ruby_version != "system" and not rbenv_ruby_versions.include?(rbenv_ruby_version)
              rbenv.install(rbenv_ruby_version)
            end
            rbenv.exec("#{ruby} --version") # check if ruby is executable
          }

          _cset(:rbenv_bundler_gem, 'bundler')
          task(:setup_bundler, :except => { :no_release => true }) {
            gem = "#{rbenv_cmd} exec gem"
            if version = fetch(:rbenv_bundler_version, nil)
              query_args = "-i -n #{rbenv_bundler_gem.dump} -v #{version.dump}"
              install_args = "-v #{version.dump} #{rbenv_bundler_gem.dump}"
            else
              query_args = "-i -n #{rbenv_bundler_gem.dump}"
              install_args = "#{rbenv_bundler_gem.dump}"
            end
            run("unset -v GEM_HOME; #{gem} query #{query_args} 2>/dev/null || #{gem} install -q #{install_args}")
            rbenv.rehash
            run("#{bundle_cmd} version")
          }

          # call `rbenv rehash` to update shims.
          def rehash(options={})
            invoke_command("#{rbenv_command} rehash", options)
          end

          def global(version, options={})
            invoke_command("#{rbenv_command} global #{version.dump}", options)
          end

          def invoke_command_with_path(cmdline, options={})
            path = options.delete(:path)
            if path
              chdir = "cd #{path.dump}"
              via = options.delete(:via)
              # as of Capistrano 2.14.2, `sudo()` cannot handle multiple command correctly.
              if via == :sudo
                invoke_command("#{chdir} && #{sudo} #{cmdline}", options)
              else
                invoke_command("#{chdir} && #{cmdline}", options.merge(:via => via))
              end
            else
              invoke_command(cmdline, options)
            end
          end

          def local(version, options={})
            invoke_command_with_path("#{rbenv_command} local #{version.dump}", options)
          end

          def which(command, options={})
            version = ( options.delete(:version) || rbenv_ruby_version )
            invoke_command_with_path("#{rbenv_command(:version => version)} which #{command.dump}", options)
          end

          def exec(command, options={})
            # users of rbenv.exec must sanitize their command line.
            version = ( options.delete(:version) || rbenv_ruby_version )
            invoke_command_with_path("#{rbenv_command(:version => version)} exec #{command}", options)
          end

          def versions(options={})
            capture("#{rbenv_command} versions --bare", options).split(/(?:\r?\n)+/)
          end

          def available_versions(options={})
            capture("#{rbenv_command} install --complete", options).split(/(?:\r?\n)+/)
          end

          _cset(:rbenv_install_ruby_threads) {
            capture("cat /proc/cpuinfo | cut -f1 | grep processor | wc -l").to_i rescue 1
          }
          # create build processes as many as processor count
          _cset(:rbenv_make_options) { "-j #{rbenv_install_ruby_threads}" }
          _cset(:rbenv_configure_options, nil)
          def install(version, options={})
            environment = {}
            environment["CONFIGURE_OPTS"] = rbenv_configure_options.to_s if rbenv_configure_options
            environment["MAKE_OPTS"] = rbenv_make_options.to_s if rbenv_make_options
            invoke_command("#{rbenv_command(:env => environment)} install #{version.dump}", options)
          end

          def uninstall(version, options={})
            invoke_command("#{rbenv_command} uninstall -f #{version.dump}", options)
          end
        }
      }
    end
  end
end

if Capistrano::Configuration.instance
  Capistrano::Configuration.instance.extend(Capistrano::RbEnv)
end

# vim:set ft=ruby ts=2 sw=2 :
