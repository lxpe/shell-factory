require 'rake'
require 'rake/clean'

require 'pathname'
require 'ipaddr'

class String
    COLORS = {
        red: 31, green: 32, brown: 33, blue: 34,  magenta: 35, cyan: 36, gray: 37,
    }

    def color(c)
        colors = {
        }
        "\e[#{COLORS[c]}m#{self}\e[0m"
    end

    def bold
        "\e[1m#{self}\e[0m"
    end
end

class IPAddr
    def to_define
        if self.ipv4?
            "#{self.to_string.gsub(".",",")}"
        else
            "#{
            self.to_string.gsub(":","")
                .split(/(..)/)
                .delete_if{|x| x.empty?}
                .map{|d| "0x" + d}
                .join(',')
            }"
        end
    end
end

class Triple
    attr_accessor :arch, :vendor, :os, :abi

    def initialize(arch, vendor, os, abi)
        @arch, @vendor, @os, @abi = arch, vendor, os, abi
    end

    def to_s
        [ @arch, @vendor, @os, @abi ].delete_if{|f| f.nil?}.join('-')
    end

    def self.parse(str)
        fields = str.split('-')
        case fields.size
        when 1 then Triple.new(fields[0], nil, nil, nil)
        when 2 then Triple.new(fields[0], nil, fields[1], nil)
        when 3 then Triple.new(fields[0], nil, fields[1], fields[2])
        when 4 then Triple.new(fields[0], fields[1], fields[2], fields[3])
        else
            fail "Cannot parse triple: #{str}"
        end
    end

    def self.current
        arch, vendor = RbConfig::CONFIG['target_cpu'], RbConfig::CONFIG['target_vendor']
        os, abi = RbConfig::CONFIG['target_os'].split('-')

        Triple.new(arch, vendor, os, abi)
    end
end

CC = "cc"
OUTPUT_DIR = "bins"
SHELLCODE_DIR = "shellcodes"
INCLUDE_DIRS = %w{include}
LD_SCRIPT_ELF = File.join(File.dirname(__FILE__), "factory-elf.lds")
LD_SCRIPT_PE = File.join(File.dirname(__FILE__), "factory-pe.lds")
OUTPUT_SECTIONS = %w{.text .rodata .data}
CFLAGS = %W{-std=c++1y
            -Wall
            -Wno-unused-function
            -Wextra
            -Wfatal-errors
            -ffreestanding
            -fshort-wchar
            -fshort-enums
            -fno-common
            -fno-rtti
            -fno-exceptions
            -fno-non-call-exceptions
            -fno-asynchronous-unwind-tables
            -fomit-frame-pointer
            -ffunction-sections
            -fdata-sections
            -fno-stack-protector
            -nostdlib
         }

COMPILER_CFLAGS =
{
    /^g\+\+|gcc/ =>
        %w{-fno-toplevel-reorder
           -finline-functions
           -fno-jump-tables
           -fno-leading-underscore
           -flto
           -nodefaultlibs
           -Os
           },

    /^clang/ =>
        %w{-Oz
           -Wno-invalid-noreturn
          }
}

OS_CFLAGS =
{
    /linux/ =>
        %W{-Wl,-T#{LD_SCRIPT_ELF}
           -Wl,--gc-sections
           -Wl,-N
           -Wl,--build-id=none
           },

    /bsd/ =>
        %W{-Wl,-T#{LD_SCRIPT_ELF}
           -Wl,--gc-sections
           -Wl,-N
          },

    /darwin/ =>
        %w{
           -Wl,-e -Wl,__start
           -Wl,-dead_strip
           -Wl,-no_eh_labels
           -static
          },

    /cygwin|w32|w64/ =>
        %W{-Wl,-T#{LD_SCRIPT_PE}
           -Wl,-N
           -Wl,--gc-sections
           -Wa,--no-pad-sections
        },

    /none/ =>
        %W{-Wl,-T#{LD_SCRIPT_ELF}
           -Wl,--gc-sections
           -Wl,-N
           -U__STDC_HOSTED__
        }
}

# Architecture-dependent flags.
ARCH_CFLAGS =
{
    /mips/ => %w{-mshared -mno-abicalls -mno-plt -mno-gpopt -mno-long-calls -G 0},
    /.*/ => %w{-fPIC}
}

FILE_EXT =
{
    :exec => {
        /darwin/ => 'macho',
        /cygwin|w32|w64/ => 'exe',
        /.*/ => 'elf'
    },
    :shared => {
        /darwin/ => 'dylib',
        /cygwin|w32|w64/ => 'dll',
        /.*/ => 'so'
    }
}

def detect_compiler(cmd)
    version = %x{#{cmd} -v 2>&1}
    case version
    when /gcc version (\S+)/ then ["gcc", $1]
    when /clang version (\S+)/, /Apple LLVM version (\S+)/ then ["clang", $1]
    else
        [cmd, '']
    end
end

def show_info(str, list = {})
    STDERR.puts "[".bold + "*".bold.color(:green) + "] ".bold + str

    list.each_with_index do |item, i|
        name, value = item
        branch = (i == list.size - 1) ? '└' : '├'
        STDERR.puts "    #{branch.bold} #{(name + ?:).color(:green)} #{value}"
    end
end

def show_error(str)
    STDERR.puts "[".bold + "*".bold.color(:red) + "] ".bold + 'Error: '.color(:cyan) + str
    abort
end

def cc_invoke(cc, triple, sysroot = nil)
    if triple.empty?
        return cc if sysroot.nil?
        return "#{cc} --sysroot=#{sysroot}"
    end

    triple_cc =
    case cc
    when /^g\+\+|gcc/
        "#{triple}-#{cc}"

    when /^clang/
        sysroot ||= "/usr/#{triple}"
        "#{cc} -target #{triple} --sysroot=#{sysroot}"
    end

    triple_cc << " --sysroot=#{sysroot}" unless sysroot.nil?
    triple_cc
end

# Returns [ source_path, output_basename ]
def target_to_source(target)
    path = Pathname.new(target.to_s).cleanpath
    if path.relative? and path.each_filename.to_a.size == 1
        path = Pathname.new(SHELLCODE_DIR).join(path)
    end

    path.split
end

def compile(target, triple, output_dir, *opts)
    common_opts = %w{CHANNEL RHOST LHOST HOST RPORT LPORT PORT HANDLE NO_BUILTIN FORK_ON_ACCEPT REUSE_ADDR RELAX_INLINE NO_ASSERTS HEAP_BASE HEAP_SIZE NO_ERROR_CHECKS THREAD_SAFE}
    options = common_opts + opts
    defines = ENV.select{|e| options.include?(e)}
    options = common_opts + opts
    cc = ENV['CC'] || CC
    if cc == 'cc'
        cc, ver = detect_compiler(cc)
    else
        _, ver = detect_compiler(cc)
    end
    cflags = CFLAGS.dup
    source_dir, target_name = target_to_source(target)
    source_file = source_dir.join("#{target_name}.cc")
    sysroot = ENV['SYSROOT']
    file_type = :exec

    unless File.exists?(source_file)
        show_error("Cannot find source for target '#{target.to_s.color(:red)}'.")
    end

    host_triple = Triple.current
    target_triple = triple.empty? ? Triple.current : Triple.parse(triple)

    show_info("#{'Generating target'.color(:cyan)} '#{target.to_s.color(:red)}'",
        'Compiler' => "#{cc} #{ver}",
        'Host architecture' => host_triple,
        'Target architecture' => target_triple,
        'Options' => defines
    )
    STDERR.puts

    ARCH_CFLAGS.each_pair do |arch, flags|
        if target_triple.arch =~ arch
            cflags += flags
            break
        end
    end

    OS_CFLAGS.each_pair do |os, flags|
        if target_triple.os =~ os
            cflags += flags
            break
        end
    end

    COMPILER_CFLAGS.each_pair do |comp, flags|
        if cc =~ comp
            cflags += flags
            break
        end
    end

    if ENV['VERBOSE'].to_i == 1
        cflags << '-v'
    end

    if ENV['STACK_REALIGN'].to_i == 1
        cflags << "-mstackrealign"
    end

    if ENV['LD']
        cflags << "-fuse-ld=#{ENV['LD'].inspect}"
    end

    if ENV['CFLAGS']
        cflags += [ ENV['CFLAGS'] ]
    end

    if ENV['ARCH']
        cflags << "-march=#{ENV['ARCH']}"
    end

    if ENV['CPU']
        cflags << "-mcpu=#{ENV['CPU']}"
    end

    if ENV['32BIT'].to_i == 1
        cflags << '-m32'
        if target_triple.os =~ /cygwin|w32|w64/
            cflags << '-Wl,--format=pe-i386' << '-Wl,--oformat=pei-i386'
        end
    end

    if ENV['IMAGEBASE']
        base_addr = ENV['IMAGEBASE']
        if target_triple.os =~ /darwin/
            cflags << "-Wl,-segaddr" << "-Wl,__TEXT" << "-Wl,#{base_addr}"
        else
            cflags << "-Ttext=#{base_addr}"
        end
    end

    if ENV['THUMB'].to_i == 1
        cflags << "-mthumb"
    end

    if ENV['CODE_MODEL']
        cmodel = ENV['CODE_MODEL']
        cflags << "-mcmodel=#{cmodel}"
    end

    unless ENV['WITH_WARNINGS'].to_i == 1
        cflags << '-w'
    end

    if defines['NO_BUILTIN'].to_i == 1
        cflags << "-fno-builtin"
    end

    if ENV['OUTPUT_LIB'].to_i == 1
        file_type = :shared
        cflags << '-shared'
    end

    cflags += INCLUDE_DIRS.map{|d| "-I#{d}"}
    defines = defines.map{|k,v|
        v = IPAddr.new(v).to_define if %w{HOST RHOST LHOST}.include?(k)
        "-D#{k}=#{v}"
    }

    if ENV['OUTPUT_STRIP'].to_i == 1
        cflags << "-s"
    end

    if ENV['OUTPUT_DEBUG'].to_i == 1 or ENV['OUTPUT_LLVM'].to_i == 1
        asm_cflags = ['-S'] + cflags + ['-fno-lto']
        asm_cflags += ['-emit-llvm'] if ENV['OUTPUT_LLVM'].to_i == 1
        output_file = output_dir.join("#{target_name}.S")
        sh "#{cc_invoke(cc,triple,sysroot)} #{asm_cflags.join(" ")} #{source_file} -o #{output_file} #{defines.join(' ')}" do |ok, _|
            (STDERR.puts; show_error("Compilation failed.")) unless ok
        end

        cflags << '-g'
    end

    output_ext = FILE_EXT[file_type].select{|os, ext| target_triple.os =~ os}.values.first
    output_file = output_dir.join("#{target_name}.#{output_ext}")
    sh "#{cc_invoke(cc,triple,sysroot)} #{cflags.join(' ')} #{source_file} -o #{output_file} #{defines.join(' ')}" do |ok, _|
        (STDERR.puts; show_error("Compilation failed.")) unless ok
    end

    output_file
end

def generate_shellcode(object_file, target, triple, output_dir)
    _, target_name = target_to_source(target)
    triple_info = triple.empty? ? Triple.current : Triple.parse(triple)

    output_file = output_dir.join("#{target_name}.#{triple_info.arch}-#{triple_info.os}.bin")

    # Extract shellcode.
    if triple_info.os =~ /darwin/
        segments = %w{__TEXT __DATA}.map{|s| "-S #{s}"}.join(' ')
        sh "#{File.dirname(__FILE__)}/tools/mach-o-extract #{segments} #{object_file} #{output_file}" do |ok, res|
            STDERR.puts
            show_error("Cannot extract shellcode from #{object_file}") unless ok
        end
    else
        triple += '-' unless triple.empty?
        sections = OUTPUT_SECTIONS.map{|s| "-j #{s}"}.join(' ')
        sh "#{triple}objcopy -O binary #{sections} #{object_file} #{output_file}" do |ok, res|
            STDERR.puts
            show_error("Cannot extract shellcode from #{object_file}") unless ok
        end
    end

    # Read shellcode.
    data = File.binread(output_file)

    output = {}
    output['Contents'] = "\"#{data.unpack("C*").map{|b| "\\x%02x" % b}.join.color(:brown)}\"" if ENV['OUTPUT_HEX'].to_i == 1
    show_info("#{'Generated target:'.color(:cyan)} #{data.size} bytes.", output)

    print data unless STDOUT.tty?
end

def build(target, *opts)
    output_dir = Pathname.new(OUTPUT_DIR)
    triple = ''
    triple = ENV['TRIPLE'] if ENV['TRIPLE']

    make_directory(output_dir)
    object_file = compile(target, triple, output_dir, *opts)
    generate_shellcode(object_file, target, triple, output_dir)
end

def make_directory(path)
    Dir.mkdir(path) unless Dir.exists?(path)
end

task :shellexec do
    build(:shellexec, "COMMAND", "SET_ARGV0")
end

task :memexec do
    build(:memexec, "PAYLOAD_SIZE")
end

desc 'Show help'
task :help do
    STDERR.puts <<-USAGE

 #{'Shellcode generation:'.color(:cyan)}

    #{'rake <shellcode> [OPTION1=VALUE1] [OPTION2=VALUE2] ...'.bold}

 #{'Compilation options:'.color(:cyan)}

    #{'CC:'.color(:green)}                 Let you choose the compiler. Only supported are g++ and clang++.
    #{'LD:'.color(:green)}                 Let you choose the linker. Supported values are "bfd" and "gold".
    #{'TRIPLE:'.color(:green)}             Cross compilation target. For example: "aarch64-linux-gnu".
    #{'ARCH'.color(:green)}                Specify a specific architecture to compile to (e.g. armv7-r).
    #{'CPU'.color(:green)}                 Specify a specific CPU to compile to (e.g. cortex-a15).
    #{'CFLAGS:'.color(:green)}             Add custom flags to the compiler. For example "-m32".
    #{'SYSROOT:'.color(:green)}            Use the specified directory as the filesystem root for finding headers.
    #{'NO_BUILTIN:'.color(:green)}         Does not use the compiler builtins for common memory operations.
    #{'OUTPUT_LIB:'.color(:green)}         Compiles to a shared library instead of a standard executable.
    #{'OUTPUT_DEBUG:'.color(:green)}       Instructs the compiler to emit an assembly file and debug symbols.
    #{'OUTPUT_LLVM:'.color(:green)}        Instructs the compiler to emit LLVM bytecode (clang only).
    #{'OUTPUT_STRIP:'.color(:green)}       Strip symbols from output file.
    #{'OUTPUT_HEX:'.color(:green)}         Prints the resulting shellcode as an hexadecimal string.
    #{'VERBOSE:'.color(:green)}            Set to 1 for verbose compilation commands.
    #{'WITH_WARNINGS:'.color(:green)}      Set to 1 to enable compiler warnings.
    #{'RELAX_INLINE:'.color(:green)}       Set to 1, 2 or 3 to let the compiler uninline some functions.
    #{'IMAGEBASE:'.color(:green)}          Address where code is executed (for ELF and Mach-O).
    #{'THREAD_SAFE:'.color(:green)}        Set to 1 to enable thread safety.

 #{'Target specific options:'.color(:cyan)}

    #{'32BIT:'.color(:green)}              Set to 1 to compile for a 32-bit environment.
    #{'STACK_REALIGN:'.color(:green)}      Set to 1 to ensure stack alignment to a 16 bytes boundary (Intel only).
    #{'THUMB:'.color(:green)}              Set to 1 to compile to Thumb mode (ARM only).
    #{'CODE_MODEL:'.color(:green)}         Select target code model: tiny, small, large (AArch64 only).

 #{'Shellcode customization options:'.color(:cyan)}

    #{'CHANNEL:'.color(:green)}            Shellcode communication channel.
                        Supported options: {TCP,SCTP}[6]_{CONNECT,LISTEN}, UDP[6]_CONNECT,
                                           USE_STDOUT, USE_STDERR, REUSE_SOCKET, REUSE_FILE
    #{'[R,L]HOST:'.color(:green)}          Remote host or local address for socket bind.
    #{'[R,L]PORT:'.color(:green)}          Remote port or local port for socket bind.
    #{'HANDLE:'.color(:green)}             File descriptor (for REUSE_SOCKET and REUSE_FILE only).
    #{'FORK_ON_ACCEPT:'.color(:green)}     Keeps listening when accepting connections.
    #{'REUSE_ADDR:'.color(:green)}         Bind sockets with SO_REUSEADDR.
    #{'HEAP_BASE:'.color(:green)}          Base address for heap allocations.
    #{'HEAP_SIZE:'.color(:green)}          Size of heap, defaults to 64k.
    #{'NO_ASSERTS:'.color(:green)}         Set to 1 to disable runtime asserts.
    #{'NO_ERROR_CHECKS:'.color(:green)}    Set to 1 to short-circuit error checks (more compact, less stable).

    USAGE

    exit
end

task :default => :help

rule '' do |task|
    if task.name != 'default'
        build(task.name)
    end
end

CLEAN.include("bins/*.{elf,bin}")
