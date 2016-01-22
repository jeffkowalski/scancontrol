#!/usr/bin/ruby2.0


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

  def initialize
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
    $logger.info 'controller starting'
    SerialPort.open(PORT, BAUD_RATE, DATA_BITS, STOP_BITS, PARITY) do |sp|
      sp.read_timeout = 1000
      while !quit?
        $logger.debug 'controller listening'
        result += sp.read
        if result.include? ')'
          $logger.info result
          settings = transform result
          $logger.info settings
          yield settings
          result = ''
        end
      end
    end
    $logger.info 'controller exiting'
  end

  private
  def transform perl
    # from perl string  "('size' => 'letter', 'mode' => 'pdf', 'crop' => 0, 'deskew' => 1)"
    # to   ruby hash    {:size=>:letter, :mode=>:pdf, :crop=>false, :deskew=>true}
    perl.chomp.gsub(/[)(']/,'').split(/, ?/).map{|h| k,v = h.split(/\s?=>\s?/); {k.to_sym => v=='0' ? false : v=='1' ? true : v.to_sym}}.reduce(:merge)
  end
end


# -------------------------------------------------------------------------------------------
# --------------------------------------------------------------------------------- [Scanner]
# -------------------------------------------------------------------------------------------

require 'fileutils'
require 'tmpdir'

class Scanner
  SCANNER_ICC = 'profiles/scansnap.icc'
  TARGET_ICC  = 'profiles/sRGB_v4_ICC_preference.icc'
  OUT_DIR     = File.join(Dir.home, 'scan')

  attr_reader :source, :crop, :deskew, :normalize, :resolution, :profile, :geometry

  def initialize settings
    @settings = settings

    @source = "--source='ADF Duplex'"

    @crop = '-border 5x5 -fuzz 20% -trim +repage' if @settings[:crop]
    @crop ||= ''

    @deskew = '-fuzz 10% -deskew 40% +repage' if @settings[:deskew]
    @deskew ||= ''

    @normalize = '-normalize' if pdf?
    @normalize ||= ''

    @resolution = '--resolution 300' if jpg?
    @resolution ||= '--resolution 200'

    @profile ||= ''
    @profile += %{-intent Relative }
    @profile += %{-profile #{SCANNER_ICC} }
    @profile += %{-profile #{TARGET_ICC} +profile "*" }

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

  def scan
    timestamp = Time::now.strftime '%Y_%m_%d_%H_%M_%S'
    Dir.mktmpdir('scan-control-') { |tmpdir|
      begin
        $logger.info 'scanning'
        command  = %{/usr/bin/scanimage }
        command +=   %{--device-name 'fujitsu' }
        command +=   %{--format=tiff }
        command +=   %{#{source} --mode Color #{resolution} }
        command +=   %{--batch=#{tmpdir}/#{timestamp}_%03d.tif }
        command +=   %{#{geometry} --swdespeck=2 --sleeptimer 60}
        $logger.info command
        system command unless $dryrun

        $logger.info 'adjusting images'
        Dir.glob("#{tmpdir}/*.tif") do |file|
          command  = %{convert #{file} -set filename:f "%t" }
          command +=   %{-bordercolor '#bdc9d0' -background '#bdc9d0' }
          command +=   %{#{deskew} }
          command +=   %{#{crop} }
          #         command +=   %{-border 5x5 -crop `convert #{file} -virtual-pixel edge -blur 0x15 -fuzz 10% -trim -format '%wx%h%O' info:` +repage }
          command +=   %{#{profile} }
          command +=   %{#{normalize} }
          command +=   %{-quality 90% }
          command += pdf?  ?
                       %{#{tmpdir}/%[filename:f].jpg } :
                       %{#{OUT_DIR}/%[filename:f].jpg }
          $logger.info command
          system command unless $dryrun
        end

        if pdf?
          $logger.info 'converting to pdf'
          command  = %{gm convert #{tmpdir}/*.jpg #{OUT_DIR}/#{timestamp}.pdf}
          $logger.info command
          system command unless $dryrun
        end

        if not $dryrun
          if not system %{wmctrl -F -a scan}
            scan_desktop = `wmctrl -d | fgrep scan | awk "{ print \\$1; }"`
            system %{wmctrl -s #{scan_desktop.chomp}}
            system %{nemo #{OUT_DIR}}
          end
        end
      rescue => e
        $logger.info e
      end
    }
  end
end


# -------------------------------------------------------------------------------------------
# ---------------------------------------------------------------------------------- [Server]
# -------------------------------------------------------------------------------------------

require 'thor'
require 'logger'

LOGFILE = File.join(Dir.home, '.scan-control.log')

class Server < Thor
  no_commands {
    def redirect_output
      unless LOGFILE == 'STDOUT'
        logfile = File.expand_path(LOGFILE)
        FileUtils.mkdir_p(File.dirname(logfile), :mode => 0755)
        FileUtils.touch logfile
        File.chmod 0644, logfile
        $stdout.reopen logfile, 'a'
      end
      $stderr.reopen $stdout
      $stdout.sync = $stderr.sync = true
    end

    def trap_signals
      trap(:INT)  do $logger.info 'caught SIGINT, exiting gracefully'  ; quit! ; end
      trap(:QUIT) do $logger.info 'caught SIGQUIT, exiting gracefully' ; quit! ; end
      trap(:TERM) do $logger.info 'caught SIGTERM, exiting gracefully' ; quit! ; end
    end

    def quit!
      @quit = true
      @controller.quit! if @controller
    end

    def quit?
      @quit
    end

    def setup_logger
      redirect_output if options[:log]

      $logger = Logger.new STDOUT
      $logger.level = options[:verbose] ? Logger::DEBUG : Logger::INFO
      $logger.info 'starting'
    end
  }

  class_option :log,     :type => :boolean, :default => true, :desc => "log output to ~/.scan-control.log"
  class_option :verbose, :type => :boolean, :aliases => "-v", :desc => "increase verbosity"
  class_option :dryrun,  :type => :boolean, :aliases => "-n", :desc => "perform a trial run with no changes made"
  desc "listen", "Listen to the controller and run scanning jobs"
  def listen
    $dryrun = options[:dryrun]

    setup_logger
    trap_signals

    @controller = Controller.new
    @quit = false
    while !quit? do
      @controller.onbutton { |settings|
        Scanner.new(settings).scan
      }
    end

    $logger.info 'exiting'
  end
end

Server.start
