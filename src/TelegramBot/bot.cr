require "http/client"
require "http/server"
require "json"
require "logger"
require "./fiber.cr"
require "./helper.cr"
require "./types/inline/*"
require "./types/*"

require "./http_client_multipart.cr"
require "./http_client.cr"
require "./response_client.cr"

module TelegramBot
  abstract class Bot
    @logger : Logger?

    # handle messages
    def handle(message : Message)
      raise "message handler is not implemented"
    end

    # handle edited messages
    def handle_edited(message : Message)
      raise "edited message handler is not implemented"
    end

    def handle_channel_post(message : Message)
      raise "channel post handler is not implemented"
    end

    def handle_edited_channel_post(message : Message)
      raise "edited channel post handler is not implemented"
    end

    # handle inline query
    def handle(inline_query : InlineQuery)
      raise "inline_query handler is not implemented"
    end

    # handle choosen inlien query
    def handle(choosen_inline_result : ChoosenInlineResult)
      raise "choosen_inline_result handler is not implemented"
    end

    # handle callback query
    def handle(callback_query : CallbackQuery)
      raise "callback_query handler is not implemented"
    end

    # @name username of the bot
    # @token
    # @whitelist
    # @blacklist
    # @updates_timeout
    def initialize(@name : String, @token : String, @whitelist : Array(String)? = nil, @blacklist : Array(String)? = nil, @updates_timeout : Int32? = nil)
      @nextoffset = 0
    end

    # run long polling in a loop and call handlers for messages
    def polling
      loop do
        begin
          updates = get_updates
          updates.each do |u|
            spawn handle_update(u)
          end
        rescue ex
          logger.error(ex)
        end
      end
    end

    def serve(bind_address : String = "127.0.0.1", bind_port : Int32 = 80, ssl_certificate_path : String | Nil = nil, ssl_key_path : String | Nil = nil)
      server = HTTP::Server.new(bind_address, bind_port) do |context|
        begin
          Fiber.current.telegram_bot_server_http_context = context
          handle_update(TelegramBot::Update.from_json(context.request.body.not_nil!))
        rescue ex
          logger.error(ex)
        ensure
          Fiber.current.telegram_bot_server_http_context = nil
        end
      end

      if ssl_certificate_path && ssl_key_path
        ssl = OpenSSL::SSL::Context.new
        ssl.certificate_chain = ssl_certificate_path.not_nil!
        ssl.private_key = ssl_key_path.not_nil!
        server.ssl = ssl
      end

      logger.info("Listening for Telegram requests in #{bind_address}:#{bind_port}#{" with ssl" if server.ssl}")
      server.listen
    end

    def handle_update(u)
      if msg = u.message
        return if !allowed_user?(msg)
        handle msg
      elsif query = u.inline_query
        return if !allowed_user?(query)
        handle query
      elsif choosen = u.choosen_inline_result
        return if !allowed_user?(choosen)
        handle choosen
      elsif callback_query = u.callback_query
        return if !allowed_user?(callback_query)
        handle callback_query
      elsif message = u.edited_message
        return if !allowed_user?(message)
        handle_edited message
      elsif post = u.channel_post
        return if !allowed_user?(post)
        handle_channel_post post
      elsif post = u.edited_channel_post
        return if !allowed_user?(post)
        handle_edited_channel_post post
      end
    rescue ex
      logger.error("update was not handled because: #{ex.message}")
    end

    protected def logger : Logger
      @logger ||= Logger.new(STDOUT).tap { |l| l.level = Logger::DEBUG }
    end

    private def allowed_user?(msg) : Bool
      if msg.is_a?(Message)
        if mf = msg.from
          from = mf
        else
          return @whitelist.is_a?(Nil)
        end
      else
        from = msg.from
      end

      if blacklist = @blacklist
        if username = from.username
          if blacklist.includes?(username)
            # on the blacklist
            logger.info("#{username} blocked because he/she is on the blacklist")
            return false
          else
            # not on the blacklist
            return true
          end
        else
          # doesn't have username at all
          true
        end
      end

      if whitelist = @whitelist
        if username = from.username
          if whitelist.includes?(username)
            # on the whitelist
            return true
          else
            # not on the whitelist
            logger.info("#{username} blocked because he/she is not on the whitelist")
            return false
          end
        else
          # doesn't have username at all
          logger.info("user without username is blocked because whitelist is set")
          return false
        end
      end
      return true
    end

    protected def request(method : String, force_http : Bool = false, params : Hash = {} of String => Object)
      client = if !force_http && (context = Fiber.current.telegram_bot_server_http_context)
                 ResponseClient.new(context.not_nil!.response) ensure Fiber.current.telegram_bot_server_http_context = nil
               else
                 HttpClient.new(@token)
               end

      response = if params.values.any?(&.is_a?(::IO::FileDescriptor))
                   multipart_params = HTTP::Client::MultipartBody.new(params)
                   client.post_multipart method, multipart_params
                 elsif params.any?
                   stringified_params = params.reduce(Hash(String, String).new) { |h, (k, v)| h[k] = v.to_s; h }
                   client.post_form method, stringified_params
                 else
                   client.post method
                 end

      return nil if response.nil?
      handle_http_response(response)
    end

    protected def handle_http_response(response)
      if response.status_code == 200
        json = JSON.parse(response.body)
        if json["ok"]
          return json["result"]
        else
          raise json["error"].as_s
        end
      else
        raise "Error #{response.status_code} in call to Telegram API: #{response.body}"
      end
    end

    def get_me
      request "getMe", force_http: true
    end

    private def get_updates(offset = @nextoffset, limit : Int32? = nil, timeout : Int32? = @updates_timeout)
      data = request("getUpdates", force_http: true, params: {"offset" => "#{offset}"}).not_nil!

      r = [] of Update
      data.each do |json|
        r << Update.from_json(json.to_json)
      end

      if !r.empty?
        @nextoffset = r.last.update_id + 1
      end
      r
    end

    macro def_request(name, *args)
        request {{name}}, force_http: false, params: {
          {% for arg in args %}
            {{arg.stringify}} => {{arg.id}},
          {% end %}
        }
    end

    macro def_force_request(name, *args)
        request {{name}}, force_http: true, params: {
          {% for arg in args %}
            {{arg.stringify}} => {{arg.id}},
          {% end %}
        }
    end

    alias ReplyMarkup = InlineKeyboardMarkup | ReplyKeyboardMarkup | ReplyKeyboardRemove | ForceReply | Nil

    def send_message(chat_id : Int32 | String,
                     text : String,
                     parse_mode : String? = nil,
                     disable_web_page_preview : Bool? = nil,
                     disable_notification : Bool? = nil,
                     reply_to_message_id : Int32? = nil,
                     reply_markup : ReplyMarkup = nil) : Message?
      reply_markup = reply_markup.try(&.to_json)
      res = def_request "sendMessage", chat_id, text, parse_mode, disable_notification, disable_web_page_preview, reply_to_message_id, reply_markup
      Message.from_json res.to_json if res
    end

    def reply(message : Message, text : String) : Message?
      send_message(message.chat.id, text, reply_to_message_id: message.message_id)
    end

    def forward_message(chat_id : Int32 | String, from_chat_id : Int32 | String, message_id : Int32, disable_notification : Bool? = nil) : Message?
      res = def_request "forwardMessage", chat_id, from_chat_id, message_id, disable_notification
      Message.from_json res.to_json if res
    end

    # @photo file or file id
    def send_photo(chat_id : Int32 | String,
                   photo : ::File | String,
                   caption : String? = nil,
                   disable_notification : Bool? = nil,
                   reply_to_message_id : Int32? = nil,
                   reply_markup : ReplyMarkup = nil) : Message?
      res = def_request "sendPhoto", chat_id, photo, disable_notification, reply_to_message_id, reply_markup
      Message.from_json res.to_json if res
    end

    def send_audio(chat_id : Int32 | String,
                   audio : ::File | String,
                   duration : Int32? = nil,
                   performer : String? = nil,
                   title : String? = nil,
                   disable_notification : Bool? = nil,
                   reply_to_message_id : Int32? = nil,
                   reply_markup : ReplyMarkup = nil) : Message?
      res = def_request "sendPhoto", chat_id, audio, duration, performer, title, disable_notification, reply_to_message_id, reply_markup
      Message.from_json res.to_json if res
    end

    def send_document(chat_id : Int32 | String,
                      document : ::File | String,
                      caption : String? = nil,
                      disable_notification : Bool? = nil,
                      reply_to_message_id : Int32? = nil,
                      reply_markup : ReplyMarkup = nil) : Message?
      res = def_request "sendDocument", chat_id, document, caption, disable_notification, reply_to_message_id, reply_markup
      Message.from_json res.to_json if res
    end

    def send_sticker(chat_id : Int32 | String,
                     sticker : ::File | String,
                     disable_notification : Bool? = nil,
                     reply_to_message_id : Int32? = nil,
                     reply_markup : ReplyMarkup = nil) : Message?
      res = def_request "sendSticker", chat_id, sticker, disable_notification, reply_to_message_id, reply_markup
      Message.from_json res.to_json if res
    end

    def send_video(chat_id : Int32 | String,
                   video : ::File | String,
                   duration : Int32? = nil,
                   width : Int32? = nil,
                   height : Int32? = nil,
                   caption : String? = nil,
                   disable_notification : Bool? = nil,
                   reply_to_message_id : Int32? = nil,
                   reply_markup : ReplyMarkup = nil) : Message?
      res = def_request "sendVideo", chat_id, video, duration, width, height, disable_notification, caption, reply_to_message_id, reply_markup
      Message.from_json res.to_json if res
    end

    def send_voice(chat_id : Int32 | String,
                   voice : ::File | String,
                   duration : Int32? = nil,
                   disable_notification : Bool? = nil,
                   reply_to_message_id : Int32? = nil,
                   reply_markup : ReplyMarkup = nil) : Message?
      res = def_request "sendVoice", chat_id, voice, duration, disable_notification, reply_to_message_id, reply_markup
      Message.from_json res.to_json if res
    end

    def send_location(chat_id : Int32 | String,
                      latitude : Float,
                      longitude : Float,
                      disable_notification : Bool? = nil,
                      reply_to_message_id : Int32? = nil,
                      reply_markup : ReplyMarkup = nil) : Message?
      res = def_request "sendLocation", chat_id, latitude, longitude, disable_notification, reply_to_message_id, reply_markup
      Message.from_json res.to_json if res
    end

    def send_venue(chat_id : Int32 | String,
                   latitude : Float,
                   longitude : Float,
                   title : String,
                   address : String,
                   forsquare_id : String? = nil,
                   disable_notification : Bool? = nil,
                   reply_to_message_id : Int32? = nil,
                   reply_markup : ReplyMarkup = nil) : Message?
      res = def_request "sendVenue", chat_id, latitude, longitude, title, address, forsquare_id, disable_notification, reply_to_message_id, reply_markup
      Message.from_json res.to_json if res
    end

    def send_contact(chat_id : Int32 | String,
                     phone_number : String,
                     first_name : String,
                     last_name : String? = nil,
                     reply_to_message_id : Int32? = nil,
                     reply_markup : ReplyMarkup = nil) : Message?
      res = def_request "sendContact", chat_id, phone_number, first_name, last_name, disable_notification, reply_to_message_id, reply_markup
      Message.from_json res.to_json if res
    end

    def send_chat_action(chat_id : Int32 | String,
                         action : String)
      def_request "sendChatAction", chat_id, action
    end

    def get_user_profile_photos(user_id : Int32,
                                offset : Int32? = nil,
                                limit : Int32? = nil)
      res = def_force_request "getUserProfilePhotos", user_id, offset, limit
      UserProfilePhotos.from_json res.not_nil!.to_json
    end

    def kick_chat_member(chat_id : Int32 | String,
                         user_id : Int32)
      res = def_request "kickChatMember", chat_id, user_id
      res.as_bool if res
    end

    def unban_chat_member(chat_id : Int32 | String,
                          user_id : Int32)
      res = def_request "unbanChatMember", chat_id, user_id
      res.as_bool if res
    end

    def get_chat(chat_id : Int32 | String)
      res = def_request "getChat", chat_id
      Chat.from_json res.not_nil!.to_json
    end

    def leave_chat(chat_id : Int32 | String)
      res = def_request "leaveChat", chat_id
      res.as_bool if res
    end

    def get_chat_administrators(chat_id : Int32 | String)
      res = def_request "getChatAdministrators", chat_id
      res = res.not_nil!
      admins = Array(ChatMember).new
      res.each { |m| admins << ChatMember.from_json(m.to_json) }
      admins
    end

    def get_chat_member(chat_id : Int32 | String,
                        user_id : Int32)
      res = def_request "getChatMember", chat_id, user_id
      ChatMember.from_json res.not_nil!.to_json
    end

    def get_chat_members_count(chat_id : Int32 | String)
      res = def_request "getChatMembersCount", chat_id
      res.as_i if res
    end

    def answer_callback_query(callback_query_id : String,
                              text : String? = nil,
                              show_alert : Bool? = nil,
                              url : String? = nil,
                              cache_time : Int32? = nil)
      res = def_request "answerCallbackQuery", callback_query_id, text, show_alert, url, cache_time
      res.as_bool if res
    end

    def edit_message_text(chat_id : Int32 | String | Nil = nil,
                          message_id : Int32? = nil,
                          inline_message_id : String = nil,
                          text : String? = nil,
                          parse_mode : String? = nil,
                          disable_web_page_preview : Bool? = nil,
                          reply_markup : InlineKeyboardMarkup? = nil) : Message | Bool | Nil
      reply_markup = reply_markup.try(&.to_json)
      res = def_request "editMessageText", chat_id, message_id, inline_message_id, text, parse_mode, disable_web_page_preview, reply_markup
      if res == "True"
        return true
      else
        Message.from_json res.to_json if res
      end
    end

    def edit_message_caption(chat_id : Int32 | String | Nil = nil,
                             message_id : Int32? = nil,
                             inline_message_id : String = nil,
                             caption : String? = nil,
                             reply_markup : InlineKeyboardMarkup? = nil) : Message | Bool | Nil
      reply_markup = reply_markup.try(&.to_json)
      res = def_request "editMessageCaption", chat_id, message_id, inline_message_id, caption, reply_markup
      if res == "True"
        return true
      else
        Message.from_json res.to_json if res
      end
    end

    def edit_message_reply_markup(chat_id : Int32 | String | Nil = nil,
                                  message_id : Int32? = nil,
                                  inline_message_id : String = nil,
                                  reply_markup : InlineKeyboardMarkup? = nil) : Message | Bool | Nil
      reply_markup = reply_markup.try(&.to_json)
      res = def_request "editMessageReplyMarkup", chat_id, message_id, inline_message_id, reply_markup
      if res == "True"
        return true
      else
        Message.from_json res.to_json if res
      end
    end

    def answer_inline_query(inline_query_id : String,
                            results : Array(InlineQueryResult),
                            cache_time : Int32? = nil,
                            is_personal : Bool? = nil,
                            next_offset : String? = nil,
                            switch_pm_text : String? = nil,
                            switch_pm_parameter : String? = nil) : Bool?
      # results   Array of InlineQueryResult  Yes   A JSON-serialized array of results for the inline query
      results = "[" + results.join(", ") { |a| a.to_json } + "]"
      res = def_request "answerInlineQuery", inline_query_id, cache_time, is_personal, next_offset, results, switch_pm_text, switch_pm_parameter
      res.as_bool if res
    end

    def get_file(file_id : String) : File
      res = def_force_request "getFile", file_id
      File.from_json(res.to_json)
    end

    def download(media)
      download(get_file(media.file_id))
    end

    def download(file : File)
      file.file_path.try { |path| download(path) }
    end

    def download(file_path : String)
      HTTP::Client.get("https://api.telegram.org/file/bot#{@token}/#{file_path}").body
    end

    def set_webhook(url : String, certificate : ::File | String | Nil = nil)
      multipart_params = HTTP::Client::MultipartBody.new({"url" => url})
      multipart_params.add_file("certificate", certificate, filename: "cert.pem") if certificate
      logger.info("Setting webhook to '#{url}'#{" with certificate" if certificate}")
      response = HttpClient.new(@token).post_multipart "setWebhook", multipart_params
      handle_http_response(response)
    end

    # game functions

    def send_game(chat_id : Int32 | String,
                  game_short_name : String,
                  disable_notification : Bool? = nil,
                  reply_to_message_id : Int32? = nil,
                  reply_markup : InlineKeyboardMarkup? = nil) : Message?
      reply_markup = reply_markup.try(&.to_json)
      res = def_request "sendGame", chat_id, game_short_name, disable_notification, reply_to_message_id, reply_markup
      Message.from_json res.to_json if res
    end

    def set_game_score(user_id : Int32,
                       score : Int32,
                       force : Bool? = nil,
                       disable_edit_message : Bool? = nil,
                       chat_id : Int32 | String | Nil = nil,
                       message_id : Int32? = nil,
                       inline_message_id : String? = nil) : Message | Bool | Nil
      res = def_request "setGameScore", user_id, score, force, disable_edit_message, chat_id, message_id, inline_message_id
      if res == "True"
        return true
      else
        Message.from_json res.to_json if res
      end
    end

    def get_game_high_scores(user_id : Int32,
                             chat_id : Int32 | String | Nil = nil,
                             message_id : Int32? = nil,
                             inline_message_id : String? = nil) : Array(GameHighScore)
      res = def_request "getGameHighScores", user_id, chat_id, message_id, inline_message_id
      res = res.not_nil!
      r = Array(GameHighScore).new
      res.each { |score| r << GameHighScore.from_json(score.to_json) }
      return r
    end
  end
end
