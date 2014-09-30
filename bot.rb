#!/usr/bin/env ruby
require 'bundler'
Bundler.require

require 'time'
require 'pp'
require 'dedupe'

Trello.configure do |config|
  config.developer_public_key = ENV['TRELLO_OAUTH_PUBLIC_KEY']
  config.member_token = ENV['TRELLO_TOKEN']
end

class Bot

  def self.run

    hipchat = HipChat::Client.new(ENV["HIPCHAT_API_TOKEN"])

    dedupe = Dedupe.new

    hipchat_rooms = ENV["HIPCHAT_ROOM"].split(',')
    boards = ENV["TRELLO_BOARD"].split(',').each_with_index.map {|board, i| [Trello::Board.find(board), hipchat_rooms[i]] }
    now = Time.now.utc
    timestamps = {}

    boards.each do |board_with_room|
      timestamps[board_with_room.first.id] = now
    end

    scheduler = Rufus::Scheduler.new

    scheduler.every '5s' do
      puts "Querying Trello at #{Time.now.to_s}"
      boards.each do |board_with_room|
        board = board_with_room.first
        hipchat_room = hipchat[board_with_room.last]
        last_timestamp = timestamps[board.id]
        actions = board.actions(:filter => :all, :since => last_timestamp.iso8601)
        actions.each do |action|
          if last_timestamp < action.date
            board_link = "<a href='https://trello.com/board/#{action.data['board']['id']}'>#{action.data['board']['name']}</a>"
            card_link = "<a href='https://trello.com/card/#{action.data['board']['id']}/#{action.data['card']['idShort']}'>#{action.data['card']['name']}</a> in #{board_link}"
            message = case action.type.to_sym
            when :updateCard
              if action.data['listBefore']
                "moved #{card_link} from <strong>#{action.data['listBefore']['name']}</strong> to <strong>#{action.data['listAfter']['name']}</strong>"
              elsif action.data['card']['closed'] && !action.data['old']['closed']
                "archived #{card_link}"
              elsif !action.data['card']['closed'] && action.data['old']['closed']
                "has been put back #{card_link} to the board"
              elsif action.data['old']['name']
                "renamed <strong>\"#{action.data['old']['name']}\"</strong> to #{card_link}"
              else
                ""
              end

            when :createCard
              "added #{card_link} to <strong>#{action.data['list']['name']}</strong>"

            when :moveCardToBoard
              "moved #{card_link} from the <strong>#{action.data['boardSource']['name']}</strong> board to <strong>#{action.data['board']['name']}</strong>"

            when :updateCheckItemStateOnCard
              if action.data["checkItem"]["state"] == 'complete'
                "checked off <strong>\"#{ action.data['checkItem']['name']}\"</strong> on #{card_link}"
              else
                "unchecked <strong>\"#{action.data['checkItem']['name']}\"</strong> on #{card_link}"
              end

            when :commentCard
              "commented on #{card_link}:<br/> <em>#{action.data['text']}</em>"

            when :deleteCard
              "deleted card <strong>##{action.data['card']['idShort']}</strong>"

            # when :addChecklistToCard
            #   "#{action.member_creator.full_name} added the checklist \"#{action.data['checklist']['name']}\" to #{card_link}"

            # when :removeChecklistFromCard
            #   "#{action.member_creator.full_name} removed the checklist \"#{action.data['checklist']['name']}\" from #{card_link}"

            else
              ""
            end

            if dedupe.new? message
              if message.present?
                member_avatar = "<img src='https://trello-avatars.s3.amazonaws.com/#{action.member_creator.avatar_id}/30.png' />"
                member_name = "<strong>#{action.member_creator.full_name}</strong>"
                message = "#{member_avatar} #{member_name} #{message}"
                hipchat_room.send('Trello', message, :color => :green, :notify => true)
              end
            else
              puts "Supressing duplicate message: #{message}"
            end
          end
        end
        timestamps[board.id] = actions.first.date if actions.length > 0
      end
    end

    scheduler.join
  end

end

if __FILE__ == $0
  Bot.run
end

