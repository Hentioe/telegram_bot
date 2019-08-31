module TelegramBot
  module CmdHandler
    macro included
      @commands = {} of String => (TelegramBot::Message ->) | (TelegramBot::Message, Array(String) ->)
    end

    def /(command : String, &block : Message ->)
      @commands[command] = block
    end

    def /(command : String, &block : Message, Array(String) ->)
      @commands[command] = block
    end

    def cmd(command : String, &block : Message ->)
      @commands[command] = block
    end

    def cmd(command : String, &block : Message, Array(String) ->)
      @commands[command] = block
    end

    def call(cmd : String, message : Message, params : Array(String))
      if proc = @commands[cmd]?
        logger.info("handle /#{cmd}")
        if proc.is_a?(Message ->)
          proc.call(message)
        else
          proc.call(message, params)
        end
      end
    end

    def handle(message : Message)
      if txt = message.text || message.caption
        return unless txt.starts_with? '/'

        a = txt.gsub(/\s+/m, ' ').gsub(/^\s+|\s+$/m, "").split(' ')
        cmd = a[0][1..-1]

        if cmd.includes? '@'
          parts = cmd.split('@')

          # not for us
          return if parts[1].upcase != @name.upcase

          cmd = parts[0]
        end

        call cmd, message, a[1..-1]
      end
    end
  end
end
