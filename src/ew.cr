require "http/client"
require "toml"
require "compress/gzip"
require "crystar"

DIR = "#{ENV["HOME"]}/.ew"
unless Dir.exists? DIR
    STDERR.puts "error: directory ~/.ew doesn't exist"
    exit 1
end
Dir.mkdir_p Path[DIR].join("packages")
Dir.mkdir_p Path[DIR].join("bin")
Dir.mkdir_p Path[DIR].join("lib")

module Ew::CLI
    enum Command
        Help
        Query 
        Install
        Uninstall
    end

    record Operation, type : Command, arguments : Array(String), options : Array(String)

    def self.error(msg)
        STDERR.puts "error: #{msg}"
        exit 1
    end

    def self.get_mirrors
        begin
            File.read(Path[DIR].join "mirrors").split('\n')[..-2]
        rescue
            error "could not get mirrors list"
        end
    end

    def self.lookup_arch
        # TODO: add more of these
        {% if flag?(:x86_64) %}
            "x86_64"
        {% elsif flag?(:x86) %}
            "x86"
        {% elsif flag?(:arm) %}
            "arm"
        {% elsif flag?(:aarch64) %}
            "aarch64"
        {% end %}
    end

    def self.lookup_version(package : String, mirrors : Array(String), verbose = false)
        mirrors.each do |mirror|
            puts "lookup #{mirror}/#{self.lookup_arch}/#{package}/info.toml" if verbose
            response = HTTP::Client.get "#{mirror}/#{self.lookup_arch}/#{package}/info.toml"
            if response.status_code == 200
                puts "200 ok" if verbose
                toml = TOML.parse response.body
                return toml["version"]
            else
                error "couldn't fetch url"
            end
        end

        self.error "could not find version for #{package}"
    end

    def self.is_installed?(package : String, version : String? = nil, arch : String? = nil)
        unless File.exists? "#{DIR}/packages/#{package}.toml"
            return false
        end

        toml = TOML.parse(File.read "#{DIR}/packages/#{package}.toml")
        if version
            if toml["version"] != version
                return false
            end
        end
        if arch
            if toml["arch"] != arch
                return false
            end
        end

        return true
    end

    def self.query(arguments : Array(String), options : Array(String))
        verbose = false
        arch = nil
        version = nil
        package = nil

        if arguments.size >= 1
            package = arguments[0]
        else
            error "1 argument is required"
        end

        options.each do |option|
            if option == "v" || option == "verbose"
                verbose = true
            elsif option.includes? '='
                key, value = option.split '='
                case key
                when "A", "arch"
                    arch = value
                when "v", "version"
                    version = value
                end
            end
        end

        mirrors = get_mirrors

        unless version
            puts "lookup latest version" if verbose
            version = lookup_version package, mirrors, verbose: verbose
        end

        unless arch
            puts "lookup architecture" if verbose
            arch = lookup_arch
        end

        puts "query information for #{package} v #{version} for #{arch}" if verbose

        mirrors.each do |mirror|
            puts "fetch #{mirror}/#{arch}/#{package}/#{version}/package.tar.gz" if verbose

            response = HTTP::Client.get "#{mirror}/#{arch}/#{package}/#{version}/package.toml"
            if response.status_code == 200
                puts "200 ok" if verbose
                toml = TOML.parse response.body
                puts "-~ #{package} v #{version} for #{arch} ~-"
                puts "author: #{toml["author"]}"
                puts "description: #{toml["description"]}"
                puts "license: #{toml["license"]}"
                puts "--~ dependencies ~--"
                deps = toml["dependencies"].as(Hash(String, TOML::Type))
                if deps.keys.size == 0
                    puts "none"
                else
                    deps.keys.each do |dep|
                        spec = deps[dep].as(String)
                        unless spec.includes? ':'
                            spec = "#{spec}:any"
                        end
                        version, arch = spec.split(':')
                        puts "dep v #{version} for #{arch}"
                    end
                end
            else
                error "couldn't fetch url"
            end
        end
    end

    def self.install(arguments : Array(String), options : Array(String))
        verbose = false
        copy = false
        arch = nil
        version = nil
        package = nil

        if arguments.size >= 1
            package = arguments[0]
        else
            error "1 argument is required"
        end

        options.each do |option|
            if option.includes? '='
                key, value = option.split '='
                case key
                when "A", "arch"
                    arch = value
                when "v", "version"
                    version = value
                end
            else
                case option
                when "v", "verbose"
                    verbose = true
                when "C", "copy"
                    copy = true
                end
            end
        end

        mirrors = get_mirrors

        unless version
            puts "lookup latest version" if verbose
            version = lookup_version package, mirrors, verbose: verbose
        end

        unless arch
            puts "lookup architecture" if verbose
            arch = lookup_arch
        end

        puts "install #{package} v #{version} for #{arch}" if verbose

        if self.is_installed? "#{DIR}/packages/#{package}.toml"
            toml = TOML.parse(File.read "#{DIR}/packages/#{package}.toml")
            puts "package #{package} v #{toml["version"]} for #{toml["arch"]} is already installed!"
            overwrite = false
            loop do
                print "overwrite? (y/n) "
                case gets
                when "y", "Y"
                    overwrite = true
                    break
                when "n", "N"
                    puts "abort."
                    return
                else
                    puts "invalid input."
                end
            end

            toml["files"].as(Array).each do |file|
                File.delete file.as(String)
            end

            File.delete "#{DIR}/packages/#{package}.toml"
        end

        mirrors.each do |mirror|
            puts "fetch #{mirror}/#{arch}/#{package}/#{version}/package.toml" if verbose

            response = HTTP::Client.get "#{mirror}/#{arch}/#{package}/#{version}/package.toml"
            if response.status_code == 200
                puts "200 ok" if verbose
                toml = TOML.parse response.body

                toml["dependencies"].as(Hash(String, TOML::Type)).each do |dep, spec|
                    spec = spec.as(String)
                    unless spec.includes? ':'
                        spec = "#{spec}:#{arch}"
                    end 
                    version, arch = spec.split(':')
                    if self.is_installed? dep, version.as(String), arch.as(String)
                        puts "dependency #{dep} v #{version} for #{arch} already installed"
                    else
                        puts "install dependency #{dep} v #{version} for #{arch}"
                        install [ dep ], [ "A=#{arch}", "V=#{version}", verbose ? "v" : "" ]
                    end
                end


                file = File.tempfile
                tmpdir_name = File.basename(file.path)[1..]
                file.delete
                tmpdir = Path[Dir.tempdir].join tmpdir_name

                puts "fetch #{mirror}/#{arch}/#{package}/#{version}/package.tar.gz"
                HTTP::Client.get "#{mirror}/#{arch}/#{package}/#{version}/package.tar.gz" do |response|
                    if response.status_code == 200
                        puts "200 ok" if verbose

                        puts "extract to #{tmpdir.to_s}"
                        Dir.mkdir tmpdir

                        Compress::Gzip::Reader.open(response.body_io) do |gzip|
                            Crystar::Reader.open(gzip) do |tar|
                                tar.each_entry do |entry|
                                    if entry.file_info.type == File::Type::Directory
                                        Dir.mkdir_p tmpdir.join entry.name
                                    else
                                        file = File.open tmpdir.join(entry.name), "w"
                                        File.chmod file.path, entry.mode
                                        IO.copy entry.io, file
                                        file.close
                                    end
                                end
                            end
                        end

                        if copy
                            puts "skipping build script" if verbose
                        else
                            puts "run build script"
                            build = tmpdir.join(toml["install"].as(Hash)["build"].as(Hash)["script"])
                            status = Process.run build.to_s, 
                                input: Process::Redirect::Inherit, 
                                output: Process::Redirect::Inherit, 
                                error: Process::Redirect::Inherit, 
                                chdir: tmpdir.to_s
                            unless status.success?
                                error "build script failed with code #{status.exit_code}"
                            end
                        end
                        puts "copy files"

                        files = [] of String

                        bin_path = toml["install"].as(Hash)["copy"].as(Hash)["bin"]?.as(String?)
                        lib_path = toml["install"].as(Hash)["copy"].as(Hash)["lib"]?.as(String?)
                        if bin_path && File.directory? Path[tmpdir].join(bin_path)
                            bin_path = Path[tmpdir].join bin_path
                            Dir.entries(bin_path).each do |entry|
                                next if entry == "." || entry == ".."
                                if File.directory? Path[bin_path].join(entry)
                                    Dir.mkdir_p Path["#{DIR}/bin"].join(entry)
                                else
                                    File.copy Path[bin_path].join(entry), Path["#{DIR}/bin"].join(entry)
                                end
                                files << Path["#{DIR}/bin"].join(entry).to_s
                            end
                        end
                        if lib_path && File.directory? Path[tmpdir].join(lib_path)
                            lib_path = Path[tmpdir].join lib_path
                            Dir.entries(lib_path).each do |entry|
                                next if entry == "." || entry == ".."
                                if File.directory? Path[lib_path].join(entry)
                                    Dir.mkdir_p Path["#{DIR}/lib"].join(entry)
                                else
                                    File.copy Path[lib_path].join(entry), Path["#{DIR}/lib"].join(entry)
                                end
                                files << Path["#{DIR}/lib"].join(entry).to_s
                            end
                        end

                        File.open("#{DIR}/packages/#{package}.toml", "w") do |f|
                            f.puts <<-END
                            version = "#{version}"
                            arch = "#{arch}"
                            files = [#{files.map{ |x| %("#{x}") }.join(",")}]
                            END
                        end
                    else
                        error "couldn't fetch url"
                    end
                end
            else
                error "couldn't fetch url"
            end
        end
    end

    def self.uninstall(arguments : Array(String), options : Array(String))
        verbose = false
        package = nil

        if arguments.size >= 1
            package = arguments[0]
        else
            error "1 argument is required"
        end

        options.each do |option|
            case option
            when "v", "verbose"
                verbose = true
            end
        end
        if self.is_installed? package
            toml = TOML.parse(File.read "#{DIR}/packages/#{package}.toml")
            puts "uninstalling #{package} v #{toml["version"]} for #{toml["arch"]}"

            toml["files"].as(Array).each do |file|
                File.delete file.as(String)
            end

            File.delete "#{DIR}/packages/#{package}.toml"
        else
            error "package #{package} is not installed"
        end
    end

    class Parser
        @operations = [] of Operation

        def initialize(@commands : Hash(Array(String), Command))
        end

        def parse
            operations = [] of Operation
            args = [] of String
            options = [] of String
            current = nil
            
            while ARGV.size > 0
                arg = ARGV.shift
                @commands.keys.each do |key|
                    if key.includes? arg
                        if current
                            operations << Operation.new type: current, arguments: args, options: options
                        end
                        args = [] of String
                        options = [] of String
                        current = @commands[key]
                        break
                    end
                end
                if arg.starts_with? '-'
                    options << arg.lstrip('-')
                else
                    args << arg
                end
            end

            if current
                operations << Operation.new type: current, arguments: args, options: options
            end
            operations
        end
    end
end

COMMANDS = {
    ["-h", "--help"] => Ew::CLI::Command::Help,
    ["-q", "--query"] => Ew::CLI::Command::Query,
    ["-i", "--install"] => Ew::CLI::Command::Install,
    ["-u", "--uninstall"] => Ew::CLI::Command::Uninstall,
}
HELP = {
    Ew::CLI::Command::Help => "-h\n  show a help message",
    Ew::CLI::Command::Query => "-q <package> [-V|--version=<version>] [-A|--arch=<arch>] [-v|--verbose]\n  query info about <package>",
    Ew::CLI::Command::Install => "-i <package> [-V|--version=<version>] [-A|--arch=<arch>] [-C|--copy] [-v|--verbose]\n  install <package>",
    Ew::CLI::Command::Uninstall => "-u <package> [-v|--verbose]\n  uninstall <package>"
}

parser = Ew::CLI::Parser.new COMMANDS
ops = parser.parse

ops.each do |op|
    case op.type
    when Ew::CLI::Command::Help
        puts "usage: ew (<command> [options] [arguments])*"
        COMMANDS.values.each do |command|
            puts HELP[command]
        end
    when Ew::CLI::Command::Query
        Ew::CLI.query op.arguments, op.options
    when Ew::CLI::Command::Install
        Ew::CLI.install op.arguments, op.options
    when Ew::CLI::Command::Uninstall
        Ew::CLI.uninstall op.arguments, op.options
    end
end
