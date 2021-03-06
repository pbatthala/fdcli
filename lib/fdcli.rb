# fdcli - a flowdock command line client
# Copyright 2016 by Richard Wossal <richard@r-wos.org>
# MIT licensed, see README for details
require_relative 'ui'
require_relative 'utils'
require_relative 'api'
require_relative 'db'

module FDCLI
  def self.start(_options)
    puts 'Hello! Checking if we can connect to flowdock...'
    Utils.log.info 'hello world'
    Utils.init_config
    Api.test_connection
    Utils.log.info 'all good - starting'
    UI.init
    begin
      update_aux
      _, first_flow = DB.from(:flows, 'joined', 'parameterized_name')
        .select { |row| row.first === 'true' }
        .first
      update_flow first_flow, :below_bottom
      run first_flow
    rescue StandardError => e
      puts e.message
      Utils.log.fatal e
      exit 255
    end
  end

  class FlowSelector < UI::Element
  end

  class PrivateChatSelector < UI::Element
  end

  def self.update_aux
    DB.into :users, Api.get("/organizations/#{Utils::ORG}/users"), 'id', 'nick', 'name', 'email'
    DB.into :flows, Api.get('/flows/all'), 'id', 'parameterized_name', 'name', 'description', 'joined'
    DB.into :private, Api.get('/private'), 'id', 'name', 'open'
  end

  def self.update_flow(flow, mode)
    head_id, tail_id = DB.messages_boundaries flow
    case mode
    when :above_top
      if top_id
        ### TODO: get only stuff above the top id
      else
        new = Api.get "/flows/#{Utils::ORG}/#{flow}/messages?limit=100"
      end
    when :below_bottom
      new = Api.get "/flows/#{Utils::ORG}/#{flow}/messages?limit=100"
      if tail_id
        ### TODO: check if we hit the tail_id
        ### TODO: re-run if we didn't hit the tail_id yet
      end
    end
    DB.add_to_messages flow, new, 'id', 'sent', 'event', 'thread_id', 'user', 'tags', 'content'
  end

  def self.run(current_flow, is_private: false)

    UI.fill :flows,
      DB.from(:flows, 'joined', 'name', 'parameterized_name')
      .select { |row| row.first === 'true' }
      .map { |row|
        _, name, param_name = row
        if (param_name.strip === current_flow)
          content = [:reverse, name, :endreverse]
        else
          content = [name]
        end
        FlowSelector.new content, hoverable: true, clickable: true, state: param_name
      }
      .unshift(UI::Element.new [''])
      .unshift(UI::Element.new [:underline, "Flows", :endunderline])

    UI.fill :chats,
      DB.from(:private, 'open', 'name')
      .select { |row| row.first === 'true' }
      .map { |row|
        _, name = row
        PrivateChatSelector.new [name], hoverable: true, clickable: true, state: name
      }
      .unshift(UI::Element.new [''])
      .unshift(UI::Element.new [:underline, "Private", :endunderline])

    UI.fill :main, main_content(current_flow, is_private)
    UI.fill :main_info,
      DB.from(:flows, 'parameterized_name', 'name', 'description')
      .select { |row| row.first === current_flow }
      .map { |row|
        param_name, name, description = row
        description = '' if description == 'NULL'
        UI::Element.new [:underline, "#{name} (#{param_name})", :endunderline, "\n#{description}"]
      }
    ##### XXX XXX return to simple map
    #UI.fill :main_input, 'huhuh'
    UI.running do |action, data|
      Utils.log.info "action: #{action} #{data}"
      case action
      when :quit
        exit
      when :hover
        case data
        when FlowSelector
          display_help "Switch to #{data.text[0]} (#{data.state})"
        when PrivateChatSelector
          display_help "Switch to private chat with #{data.state}"
        end
      when :unhover
        display_help ''
      when :click
        case data
        when FlowSelector
          update_flow data.state, :below_bottom
          run data.state
        when PrivateChatSelector
          run data.state, is_private: true
        end
      end
    end
  end

  def self.render_message(content)
    return ['──── deleted ────'] if content == 'NULL'
    parts = content.scan /[^\s]*\s?/
    parts.flat_map do |p|
      # user name
      if p =~ /^@/
        tmp = p.match /^@(\w*)(.*)/
        [:bold, tmp[1], :endbold, tmp[2]]
      else
        p
      end
    end
  end

  def self.main_content(current_flow, is_private)
    ### XXX TODO scrolling: if we're at the top of the pad, put new data into it
    ###          - maybe implement as an event, too
    nicks = {}
    DB.from(:users, 'id', 'nick').map { |row| nicks[row[0]] = row[1] }

    start_day = nil;
    last_poster = nil;
    last_thread = nil;
    DB.from_messages(current_flow, 'event', 'thread_id', 'sent', 'user', 'content') ## TODO use tags?
    .sort { |a, b|
      _, _, a_sent, _, _ = a
      _, _, b_sent, _, _ = b
      a_sent = "0" if a_sent.nil?
      b_sent = "0" if b_sent.nil?
      a_sent <=> b_sent
    }
    .select { |row| row.first === 'message' } ### TODO: also let other stuff through
    .flat_map { |row|
      _, thread_id, timestamp, user_id, content = row
      content = '' if content.nil?
      rendered_content = render_message(content)
      nick = nicks.fetch user_id, 'unknown user'
      sent = Time.at(timestamp.to_i / 1000).strftime '%H:%M'
      day = Time.at(timestamp.to_i / 1000).strftime '%F'

      #### XXX this isn't final
      thread = ''
      #markers = '▖▗▘▙▚▛▜▞▟░▒▓█'
      thread_num = 0
      thread_id[-4..-1].each_char do |c|
        thread_num += c.ord
      end
      thread_length = 8
      thread_start = thread_num % thread_length
      thread_start_marker  = (' ' * thread_start) + '┌┐' + (' ' * (thread_length - thread_start))
      thread_normal_marker = (' ' * thread_start) + '││' + (' ' * (thread_length - thread_start))
      thread =  (thread_id == last_thread && day == start_day ? thread_normal_marker : thread_start_marker)

      out = []
      start_day = day if start_day.nil?
      if thread_id != last_thread && !last_thread.nil? || (day != start_day)
        # thread end marker XXX cleanup
        thread_num = 0
        last_thread[-4..-1].each_char do |c|
          thread_num += c.ord
        end
        thread_start = thread_num % thread_length
        end_thread = (' ' * thread_start) + '└' + '┘' + (' ' * (thread_length - thread_start)) + '      │'
        out.push(UI::Element.new ["#{end_thread}"])
      end
      if day != start_day
        out.push(UI::Element.new ["#{day} ─────┐"])
      end
      prefix = "#{thread_normal_marker}      │    "
      if nick == last_poster && day == start_day && thread_id == last_thread
        out.push(UI::Element.new [thread, " #{sent}┤ └─ ", *rendered_content], wrap_prefix: prefix)
      else
        out.push(UI::Element.new [thread, " #{sent}┤ ", :bold, nick, :endbold, " ", *rendered_content], wrap_prefix: prefix)
      end
      start_day = day
      last_poster = nick
      last_thread = thread_id
      out
    }
  end

  def self.display_help(msg)
    UI.fill :main_input, [UI::Element.new([msg])]
  end
end
