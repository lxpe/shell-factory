require 'rake'
require 'rake/clean'

require 'ipaddr'

class IPAddr
    def to_define
        if self.ipv4?
            "\\{#{self.to_string.gsub(".",",")}\\}"
        else
            "\\{#{
            self.to_string.gsub(":","")
                .split(/(..)/)
                .delete_if{|x| x.empty?}
                .map{|d| "0x" + d}
                .join(',')
            }\\}"
        end
    end
end

CC = "g++"
OUTPUT_DIR = "bins"
INCLUDE_DIRS = %w{include}
CFLAGS = %w{-std=c++1y
            -Wall
            -Wextra
            -Wfatal-errors
            -fno-common
            -fomit-frame-pointer
            -nostdlib
            -Wl,-e_start
            -Wl,--gc-sections
         }

COMPILER_CFLAGS =
{
    /^g\+\+$/ =>
        %w{-fno-toplevel-reorder
           -finline-functions
           -nodefaultlibs
           -Os
           },

    /^clang\+\+$/ =>
        %w{-Oz
           -Wno-invalid-noreturn
          }
}

# Architecture-dependent flags.
ARCH_CFLAGS =
{
    /mips/ => %w{-mshared -mno-abicalls -mno-plt -mno-gpopt -mno-long-calls -G 0},
    /.*/ => %w{-fPIC}
}

def cc_invoke(cc, triple)
    return cc if triple.empty?

    case cc
    when 'g++'
        "#{triple}-#{cc}"

    when 'clang++'
        "#{cc} -target #{triple} --sysroot /usr/#{triple}/"
    end
end

def compile(target, triple, output_dir, *opts)
    common_opts = %w{CHANNEL HOST PORT NO_BUILTIN FORK_ON_ACCEPT REUSE_ADDR RELAX_INLINE}
    options = common_opts + opts
    defines = ENV.select{|e| options.include?(e)}
    options = common_opts + opts
    cc = ENV['CC'] || CC
    cflags = CFLAGS.dup

    puts "[*] Generating shellcode '#{target}'"
    puts "    ├ Compiler: #{cc}"
    puts "    ├ Target architecture: #{triple.empty? ? `uname -m` : triple}"
    puts "    └ Options: #{defines}"
    puts

    ARCH_CFLAGS.each_pair { |arch, flags|
        if triple =~ arch
            cflags += flags
            break
        end
    }

    COMPILER_CFLAGS.each_pair { |comp, flags|
        if cc =~ comp
            cflags += flags
            break
        end
    }

    if ENV['CFLAGS']
        cflags += [ ENV['CFLAGS'] ]
    end

    unless ENV['WITH_WARNINGS'] and ENV['WITH_WARNINGS'].to_i == 1
        cflags << '-w'
    end
    
    if defines['NO_BUILTIN'] and defines['NO_BUILTIN'].to_i == 1
        cflags << "-fno-builtin"
    end

    if ENV['OUTPUT_LIB'] and ENV['OUTPUT_LIB'].to_i == 1
        cflags << '-shared'
    end

    cflags += INCLUDE_DIRS.map{|d| "-I#{d}"}
    defines = defines.map{|k,v|
        v = IPAddr.new(v).to_define if k == 'HOST'
        "-D#{k}=#{v}"
    }

    if ENV['OUTPUT_DEBUG'] and ENV['OUTPUT_DEBUG'].to_i == 1
        sh "#{cc_invoke(cc,triple)} -S #{cflags.join(" ")} shellcodes/#{target}.cc -o #{output_dir}/#{target}.S #{defines.join(' ')}"
    end

    sh "#{cc_invoke(cc,triple)} #{cflags.join(' ')} shellcodes/#{target}.cc -o #{output_dir}/#{target}.elf #{defines.join(' ')}"
end

def generate_shellcode(target, triple, output_dir)
    triple += '-' unless triple.empty?
    sh "#{triple}objcopy -O binary -j .text -j .funcs -j .rodata bins/#{target}.elf #{output_dir}/#{target}.bin" 

    puts
    puts "[*] Generated shellcode: #{File.size("#{output_dir}/#{target}.bin")} bytes."
end

def build(target, *opts)
    output_dir = OUTPUT_DIR
    triple = ''
    triple = ENV['TRIPLE'] if ENV['TRIPLE']

    compile(target, triple, output_dir, *opts)
    generate_shellcode(target, triple, output_dir)
end

task :shellexec do
    build(:shellexec, "COMMAND", "SET_ARGV0")
end

task :help do
    STDERR.puts <<-USAGE

 Shellcode generation:

    rake <shellcode> [OPTION1=VALUE1] [OPTION2=VALUE2] ...

 Compilation options:

    CC:             Let you choose the compiler. Only supported are g++ and clang++.  
    TRIPLE:         Cross compilation target. For example: "aarch64-linux-gnu".
    CFLAGS:         Add custom flags to the compiler. For example "-m32".
    NO_BUILTIN:     Does not use the compiler builtins for common memory operations. 
    OUTPUT_LIB:     Compiles to a shared library instead of a standard executable.
    OUTPUT_DEBUG:   Instructs the compiler to emit an assembly file.
    WITH_WARNINGS:  Set to 1 to enable compiler warnings.
    RELAX_INLINE:   Set to 1 to let the compiler uninline some functions.

 Shellcode customization options:

    CHANNEL:        Shellcode communication channel.
                    Supported options: NO_CHANNEL, TCP_CONNECT, TCP_LISTEN, TCP6_CONNECT, TCP6_LISTEN, SCTP_CONNECT, SCTP_LISTEN, SCTP6_CONNECT, SCTP6_LISTEN, USE_STDOUT, USE_STDERR
    HOST:           Remote host or local address for socket bind.
    PORT:           Remote port or local port for socket bind.
    FORK_ON_ACCEPT: Keeps listening when accepting connections.
    REUSE_ADDR:     Bind sockets with SO_REUSEADDR.

    USAGE
end

task :default => :help

rule '' do |task|
    if task.name != 'default'
        build(task.name)
    end
end

CLEAN.include("bins/*.{elf,bin}")
