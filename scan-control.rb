#!/usr/bin/env ruby
# frozen_string_literal: true

# -------------------------------------------------------------------------------------------
# ------------------------------------------------------------------------------ [Controller]
# -------------------------------------------------------------------------------------------

require 'serialport'

class Controller
  PORT      = '/dev/serial/by-id/usb-FTDI_FT232R_USB_UART_A9MH1ZN7-if00-port0'
  BAUD_RATE = 9600
  DATA_BITS = 8
  STOP_BITS = 1
  PARITY    = SerialPort::NONE

  def initialize(logger)
    @logger = logger
    @quit = false
  end

  def quit?
    @quit
  end

  def quit!
    @quit = true
  end

  def onbutton
    result = ''
    @logger.info 'controller starting'
    SerialPort.open(PORT, BAUD_RATE, DATA_BITS, STOP_BITS, PARITY) do |sp|
      sp.read_timeout = 1000
      until quit?
        @logger.debug 'controller listening'
        result += sp.read
        next unless result.include? ')'

        @logger.info result
        settings = transform result
        @logger.info settings
        yield settings
        result = ''
      end
    end
    @logger.info 'controller exiting'
  end

  private

  def transform(perl)
    # from perl string  "('size' => 'letter', 'mode' => 'pdf', 'crop' => 0, 'deskew' => 1)"
    # to   ruby hash    {:size=>:letter, :mode=>:pdf, :crop=>false, :deskew=>true}
    perl.chomp.gsub(/[)(']/, '').split(/, ?/).map do |h|
      k, v = h.split(/\s?=>\s?/)
      value = case v
              when '0'
                false
              when '1'
                true
              else
                v.to_sym
              end
      { k.to_sym => value }
    end.reduce(:merge)
  end
end


# -------------------------------------------------------------------------------------------
# --------------------------------------------------------------------------------- [Scanner]
# -------------------------------------------------------------------------------------------

require 'fileutils'
require 'tmpdir'

class Scanner
  SCANNER_ICC = File.expand_path(__dir__) + '/profiles/fujitsu-scansnap-ix500.icc'
  TARGET_ICC  = File.expand_path(__dir__) + '/profiles/sRGB_v4_ICC_preference.icc'
  OUT_DIR     = File.join(Dir.home, 'scan')

  attr_reader :source, :crop, :deskew, :normalize, :resolution, :profile, :geometry

  def initialize(logger, settings)
    @logger = logger
    @settings = settings

    @source = "--source='ADF Duplex'"

    @crop = '-border 5x5 -fuzz 10% -trim +repage' if @settings[:crop]
    @crop ||= ''

    @deskew = '-fuzz 20% -deskew 40% +repage' if @settings[:deskew]
    @deskew ||= ''

    @normalize = '-sigmoidal-contrast 6,65%' if pdf?
    @normalize ||= ''

    @resolution = '--resolution 300' if jpg?
    @resolution ||= '--resolution 200'

    @profile ||= ''
    @profile += %(-intent Relative )
    @profile += %(-profile #{SCANNER_ICC} )
    @profile += %(-profile #{TARGET_ICC} +profile "*" )

    @geometry = case @settings[:size]
                when :a4    # A4 21cm x 29.7cm
                  '--page-width 210     --page-height 297 -x 210         -y 297'
                when :legal # legal 8.5 x 14
                  '--page-width 215.9   --page-height 355.6 -x 215.9     -y 355.6'
                when :max   # max 8.7 x 34
                  '--page-width 221.121 --page-height 863.489 -x 221.121 -y 863.489'
                else        # default is letter 8.5 x 11
                  ''
                end
  end

  def pdf?
    @settings[:mode] == :pdf
  end

  def jpg?
    @settings[:mode] == :jpg
  end

  def scan(dry_run)
    timestamp = Time.now.strftime '%Y_%m_%d_%H_%M_%S'
    Dir.mktmpdir('scan-control-') do |tmpdir|
      @logger.info 'scanning'
      command  = %(/usr/bin/scanimage )
      command +=   %(--device-name 'fujitsu' )
      command +=   %(--format=tiff )
      command +=   %(#{source} --mode Color #{resolution} )
      command +=   %(--batch=#{tmpdir}/#{timestamp}_%03d.tif )
      command +=   %(#{geometry} --swdespeck=2 --sleeptimer 60 )
      command.strip!
      @logger.info command
      system command unless dry_run

      @logger.info 'adjusting images'
      Dir.glob("#{tmpdir}/*.tif") do |file|
        command  = %(convert #{file} -set filename:f "%t" )
        command +=   %(-bordercolor '#e0e0e0' -background '#e0e0e0' )
        command +=   %(#{deskew} )
        command +=   %(#{crop} )
        #         command +=   %(-border 5x5 -crop `convert #{file} -virtual-pixel edge -blur 0x15 -fuzz 10% -trim -format '%wx%h%O' info:` +repage )
        command +=   %(#{profile} )
        command +=   %(#{normalize} )
        command +=   %(-quality 90% )
        command += pdf? ? %(#{tmpdir}/%[filename:f].jpg ) : %(#{OUT_DIR}/%[filename:f].jpg )
        command.strip!
        @logger.info command
        system command unless dry_run
      end

      if pdf?
        @logger.info 'converting to pdf'
        command = %(gm convert #{tmpdir}/*.jpg #{OUT_DIR}/#{timestamp}.pdf)
        @logger.info command
        system command unless dry_run
      end

      unless dry_run
        window_name = File.basename File.expand_path OUT_DIR

        if system %(wmctrl -F -a #{window_name})
          @logger.info "activated window #{window_name}"
        else
          # output directory's window could not be activated, switch to "scan" desktop
          scan_desktop = `wmctrl -d | fgrep scan | awk "{ print \\$1; }"`
          @logger.info "found scan desktop on #{scan_desktop}"
          system %(wmctrl -s #{scan_desktop.chomp})
          # spawn file manager (nemo) window for output directory
          system %(sh ~/bin/spawn nemo #{OUT_DIR})
        end
      end
    rescue StandardError => e
      @logger.info e
    end
  end
end


# -------------------------------------------------------------------------------------------
# ---------------------------------------------------------------------------------- [Server]
# -------------------------------------------------------------------------------------------

require 'thor'
require 'logger'

LOGFILE = File.join(Dir.home, '.log', 'scan-control.log')

class Server < Thor
  no_commands do
    def redirect_output
      unless LOGFILE == 'STDOUT'
        logfile = File.expand_path(LOGFILE)
        FileUtils.mkdir_p(File.dirname(logfile), mode: 0o755)
        FileUtils.touch logfile
        File.chmod 0o644, logfile
        $stdout.reopen logfile, 'a'
      end
      $stderr.reopen $stdout
      $stdout.sync = $stderr.sync = true
    end

    def setup_logger
      redirect_output if options[:log]

      @logger = Logger.new STDOUT
      @logger.level = options[:verbose] ? Logger::DEBUG : Logger::INFO
      @logger.info 'starting'

      @log_info_queue = Queue.new
      Thread.start do
        nil while @logger.info(@log_info_queue.pop)
      end
    end

    def trap_signals
      # rubocop: disable Style/Semicolon
      trap(:INT)  { @log_info_queue << 'caught SIGINT, exiting gracefully';  quit! }
      trap(:QUIT) { @log_info_queue << 'caught SIGQUIT, exiting gracefully'; quit! }
      trap(:TERM) { @log_info_queue << 'caught SIGTERM, exiting gracefully'; quit! }
      # rubocop: enable Style/Semicolon
    end

    def quit!
      @quit = true
      @controller&.quit!
    end

    def quit?
      @quit
    end
  end

  class_option :log,     type: :boolean, default: true, desc: "log output to #{LOGFILE}"
  class_option :verbose, type: :boolean, aliases: '-v', desc: 'increase verbosity'

  method_option :dry_run, type: :boolean, aliases: '-n', desc: "don't log to database"
  desc 'listen', 'Listen to the controller and run scanning jobs'
  default_task :listen
  def listen
    setup_logger
    trap_signals

    @controller = Controller.new @logger
    @quit = false
    until quit?
      @controller.onbutton do |settings|
        Scanner.new(@logger, settings).scan(options[:dry_run])
      end
    end

    @logger.info 'exiting'
  end
end

Server.start
